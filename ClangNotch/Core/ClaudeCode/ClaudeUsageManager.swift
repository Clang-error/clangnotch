//
//  ClaudeUsageManager.swift
//  ClangNotch
//
//  Fetches Claude subscription usage via the OAuth usage endpoint using the token that
//  Claude Code already stored on this machine — no login, no claude.ai web, no Cloudflare.
//  Mirrors how CodexIsland / CodexBar read usage.
//

import Foundation
import Combine
import os.log

@MainActor
final class ClaudeUsageManager: ObservableObject {
    static let shared = ClaudeUsageManager()

    // MARK: - Logger

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ClangNotch", category: "ClaudeUsage")

    // MARK: - Published Properties

    @Published private(set) var usageData: ClaudeUsageData = .empty
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var lastError: ClaudeUsageError?
    /// True when a Claude Code OAuth token was found on this machine.
    @Published private(set) var isConfigured: Bool = false

    /// The plan Claude Code logged in with, from the credential blob ("pro", "max",
    /// "max_5x"…). Persisted: the blob is only read when the token cache misses, so after
    /// a relaunch the mirrored token is used and the blob isn't touched.
    @Published private(set) var subscriptionPlan: String?

    /// The Fable weekly cap is Max-only. This can't be derived from the usage response —
    /// a Max 5x account still gets `seven_day_opus`/`seven_day_sonnet` back as null
    /// (measured 2026-09-22), so the blob's plan field is the only signal.
    var isMaxPlan: Bool { subscriptionPlan?.lowercased().hasPrefix("max") ?? false }

    /// Current monitoring mode (for smart refresh)
    @Published private(set) var currentMonitoringMode: UsageMonitoringMode = .active

    /// When the next automatic refresh is scheduled to fire (nil while stopped).
    /// The interval is variable in smart mode, so the UI counts down to this instant.
    @Published private(set) var nextRefreshAt: Date?

    // MARK: - Private Properties

    /// The OAuth usage endpoint Claude Code itself uses (not behind Cloudflare).
    private let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    /// Anthropic rate-limits this endpoint hard — never poll faster than this.
    private let minInterval: TimeInterval = 300      // 5 minutes
    private let rateLimitBackoff: TimeInterval = 1800 // 30 minutes after a 429
    /// Consecutive 429s double the backoff (30 → 60 → 120 min); the endpoint's own window
    /// outlasted a single 30-minute wait on 2026-09-22. Persisted with the deadline.
    private var rateLimitStreak: Int {
        didSet { UserDefaults.standard.set(rateLimitStreak, forKey: rateLimitStreakKey) }
    }
    private let rateLimitStreakKey = "claudeUsageRateLimitStreak"
    private let rateLimitBackoffCap: TimeInterval = 7200

    private var refreshTimer: Timer?
    private var lastUtilization: Double = 0
    private var unchangedCount: Int = 0
    private var lastManualRefreshTime: Date = .distantPast
    private let manualRefreshDebounce: TimeInterval = 30
    /// When a 429 backoff ends. Persisted so a relaunch (or a dozen, on a build-heavy day)
    /// doesn't fire the startup fetch straight back into the same wall.
    private var rateLimitedUntil: Date? {
        didSet { UserDefaults.standard.set(rateLimitedUntil?.timeIntervalSince1970 ?? 0, forKey: rateLimitedUntilKey) }
    }
    private let rateLimitedUntilKey = "claudeUsageRateLimitedUntil"
    private var isRateLimited: Bool { rateLimitedUntil.map { $0 > Date() } ?? false }

    /// Token cache. Reading Claude Code's own Keychain item re-prompts for access every
    /// time (Claude Code recreates that item on token refresh, which wipes any "Always
    /// Allow" grant), so we read it as little as possible: once, then mirror the token
    /// into *our own* Keychain item — which we own and can read prompt-free, even across
    /// relaunches — reusing it until shortly before it expires (or a 401 invalidates it).
    private var cachedToken: String?
    private var cacheValidUntil: Date = .distantPast
    /// Coalesces concurrent reads so a slow (prompt-blocked) source read isn't started
    /// again by the next poll, which would stack a second password prompt.
    private var inFlightRead: Task<TokenLookup, Never>?
    /// Refresh the cache this long before the token's real expiry, to avoid racing it.
    private let tokenExpirySafetyMargin: TimeInterval = 600   // 10 min
    /// Fallback cache lifetime when the token carries no usable expiry.
    private let tokenCacheFallbackTTL: TimeInterval = 1800    // 30 min
    /// Key for our own mirrored-token Keychain item (service = our bundle id).
    private let mirroredTokenKey = "claudeUsageAccessTokenMirror"
    /// UserDefaults key backing `subscriptionPlan`.
    private let subscriptionPlanKey = "claudeUsageSubscriptionPlan"

    private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    // MARK: - Initialization
    private init() {
        subscriptionPlan = UserDefaults.standard.string(forKey: subscriptionPlanKey)
        rateLimitStreak = UserDefaults.standard.integer(forKey: rateLimitStreakKey)
        let until = UserDefaults.standard.double(forKey: rateLimitedUntilKey)
        if until > Date().timeIntervalSince1970 { rateLimitedUntil = Date(timeIntervalSince1970: until) }
    }

    // MARK: - Public Methods

    /// Start automatic refresh polling.
    func startRefreshing() {
        guard !DemoMode.isActive else { return }
        stopRefreshing()
        Task { await fetchUsage(interactive: false) }
        scheduleNextRefresh()
    }

    /// Stop automatic refresh polling
    func stopRefreshing() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        nextRefreshAt = nil
    }

    /// Manual refresh (with debounce). Kept conservative — the endpoint is rate-limited.
    /// Auth failures are exempt: those taps re-read the local token and only reach the
    /// network if a fresh one appeared, so silently swallowing them just looks broken.
    func manualRefresh() async {
        let now = Date()
        let isAuthFailure: Bool = {
            switch lastError {
            case .tokenExpired, .needsReauth, .noCredentials: return true
            default: return false
            }
        }()
        guard isAuthFailure || now.timeIntervalSince(lastManualRefreshTime) >= manualRefreshDebounce else {
            logger.debug("Manual refresh debounced")
            return
        }
        lastManualRefreshTime = now
        if AppSettings.shared.claudeUsageRefreshMode == "smart" {
            currentMonitoringMode = .active
            unchangedCount = 0
        }
        // Re-read the plan from the credential blob. Claude Code rewrites it on login, but
        // routine polls run off the cached token and never look at the blob — so without
        // this an upgrade to Max wouldn't surface the Fable row until the token expired.
        await refreshSubscriptionPlan()
        // User-initiated: allow the Keychain prompt if re-authorization is needed.
        await fetchUsage(interactive: true)
    }

    /// Fetch usage from the OAuth endpoint with Claude Code's token.
    /// `interactive` = true only for user-initiated refreshes, which may show the
    /// Keychain prompt; background polls stay silent.
    func fetchUsage(interactive: Bool, retryingAfter401: Bool = false) async {
        isLoading = true
        let token: String
        switch await currentToken(interactive: interactive) {
        case .token(let value):
            token = value
        case .expired:
            // Only Claude Code can renew this (it holds the refresh token). Sending the
            // dead token would just 401 forever, so report the real state instead.
            // These polls never touch the network, so any 429 backoff must be dropped —
            // otherwise the 30-minute interval outlives its cause and delays recovery
            // long after Claude Code has written a fresh token.
            rateLimitedUntil = nil
            isConfigured = true
            lastError = .tokenExpired
            isLoading = false
            return
        case .missing:
            // Silent background read blocked by the Keychain ACL → ask the user to tap
            // refresh rather than surfacing a "not logged in" error.
            lastError = interactive ? .noCredentials : .needsReauth
            if interactive { isConfigured = false }
            isLoading = false
            return
        }
        isConfigured = true
        lastError = nil

        // Inside a 429 backoff the token still gets read above (so the card knows we are
        // signed in), but the endpoint is left alone; tapping through only extends the ban.
        if isRateLimited {
            lastError = .rateLimited
            isLoading = false
            return
        }

        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "accept")

        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw ClaudeUsageError.noData }

            switch http.statusCode {
            case 200...299:
                break
            case 401:
                invalidateTokenCache()   // stale/revoked — re-read (may prompt) next time
                throw ClaudeUsageError.unauthorized
            case 429:
                rateLimitStreak += 1
                // The server's own answer wins when it gives one; the doubling is only a
                // guess for when it doesn't.
                let backoff: TimeInterval
                if let retryAfter = Self.retryAfter(from: http) {
                    backoff = retryAfter + 5
                } else {
                    backoff = min(rateLimitBackoffCap, rateLimitBackoff * pow(2, Double(rateLimitStreak - 1)))
                }
                rateLimitedUntil = Date().addingTimeInterval(backoff)
                let header = http.value(forHTTPHeaderField: "Retry-After") ?? "none"
                logger.error("Usage endpoint 429 — backing off \(Int(backoff / 60)) min (Retry-After: \(header), streak \(self.rateLimitStreak))")
                // A timer armed before this answer (startup, or the poll a manual tap
                // raced) still holds the short interval; move it out to the backoff.
                if refreshTimer != nil { scheduleNextRefresh() }
                throw ClaudeUsageError.rateLimited
            default:
                throw ClaudeUsageError.httpError(statusCode: http.statusCode)
            }

            let usage = try JSONDecoder().decode(ClaudeUsageResponse.self, from: data)
            usageData = ClaudeUsageData(
                fiveHour: parseLimitDataOptional(usage.fiveHour),
                sevenDay: parseLimitDataOptional(usage.sevenDay),
                opus: parseLimitDataOptional(usage.sevenDayOpus),
                sonnet: parseLimitDataOptional(usage.sevenDaySonnet),
                fable: parseLimitEntry(usage.fable),
                fetchedAt: Date()
            )
            rateLimitedUntil = nil
            rateLimitStreak = 0

            if AppSettings.shared.claudeUsageRefreshMode == "smart" {
                updateSmartMonitoringMode(currentUtilization: usageData.fiveHour?.percentage ?? 0)
            }
            logger.info("Usage fetched: 5hr=\(self.usageData.fiveHour?.percentage ?? 0, format: .fixed(precision: 1))%")

        } catch let error as ClaudeUsageError {
            // A 401 usually means Claude Code rotated its token after we mirrored it. The
            // cache is already cleared, so one silent re-read from the source fixes it —
            // the same thing a manual tap did by hand.
            if case .unauthorized = error, !retryingAfter401 {
                logger.info("Usage endpoint 401 — re-reading token once")
                await fetchUsage(interactive: interactive, retryingAfter401: true)
                return
            }
            lastError = error
            logger.error("Failed to fetch usage: \(error.localizedDescription)")
        } catch {
            lastError = .networkError(error)
            logger.error("Network error: \(error.localizedDescription)")
        }

        isLoading = false
    }

    // MARK: - Private Methods

    /// Outcome of looking up an access token. `expired` and `missing` are different
    /// problems with different fixes, so the UI must be able to tell them apart.
    private enum TokenLookup {
        case token(String)
        case expired
        case missing
    }

    /// Return a usable access token, reading the Keychain/file only when the cache is
    /// empty or about to expire — so routine polls don't re-trigger the Keychain prompt.
    private func currentToken(interactive: Bool) async -> TokenLookup {
        // 1) In-memory cache (fastest).
        if let token = cachedToken, Date() < cacheValidUntil { return .token(token) }

        // 2) Our own mirrored Keychain item — prompt-free, survives relaunch.
        if let mirror = await loadMirroredToken(), Date() < mirror.validUntil {
            cachedToken = mirror.token
            cacheValidUntil = mirror.validUntil
            return .token(mirror.token)
        }

        // 3) Read Claude Code's Keychain item (via `security`, so no prompt — see
        //    ClaudeOAuthToken.readFromKeychain). Coalesce concurrent reads so a slow read
        //    isn't started again by the next poll.
        if let existing = inFlightRead { return await existing.value }
        let task = Task { [weak self] () -> TokenLookup in
            guard let self else { return .missing }
            return await self.readFromSourceAndMirror()
        }
        inFlightRead = task
        let result = await task.value
        inFlightRead = nil
        return result
    }

    /// Read the access token from Claude Code's Keychain/file, cache it in memory, and
    /// mirror it into our own Keychain item for prompt-free reuse. An expired token is
    /// renewed here rather than reported as a failure: only the terminal CLI ever refreshed
    /// this credential, so once the user works entirely in Claude Desktop / the VSCode
    /// extension nothing keeps it alive and usage would stay dead forever.
    private func readFromSourceAndMirror() async -> TokenLookup {
        guard let stored = await Task.detached(priority: .utility, operation: { ClaudeOAuthToken.read() }).value,
              !stored.token.isEmpty else {
            invalidateTokenCache()
            return .missing
        }

        let creds: ClaudeOAuthToken.Creds
        if stored.isExpired {
            guard let renewed = await ClaudeOAuthToken.refresh(stored) else {
                logger.error("Token refresh failed — usage stays unavailable until Claude Code re-authenticates")
                invalidateTokenCache()
                return .expired
            }
            logger.info("Refreshed the Claude Code OAuth token and wrote it back to the Keychain")
            creds = renewed
        } else {
            creds = stored
        }

        updateSubscriptionPlan(creds.subscriptionType)

        let validUntil: Date = creds.expiresAt > 0
            ? Date(timeIntervalSince1970: creds.expiresAt / 1000).addingTimeInterval(-tokenExpirySafetyMargin)
            : Date().addingTimeInterval(tokenCacheFallbackTTL)
        cachedToken = creds.token
        cacheValidUntil = validUntil
        await saveMirroredToken(token: creds.token, validUntil: validUntil)
        return .token(creds.token)
    }

    private func refreshSubscriptionPlan() async {
        let creds = await Task.detached(priority: .utility, operation: { ClaudeOAuthToken.read() }).value
        updateSubscriptionPlan(creds?.subscriptionType)
    }

    private func updateSubscriptionPlan(_ plan: String?) {
        guard let plan, !plan.isEmpty, plan != subscriptionPlan else { return }
        subscriptionPlan = plan
        UserDefaults.standard.set(plan, forKey: subscriptionPlanKey)
    }

    private func invalidateTokenCache() {
        cachedToken = nil
        cacheValidUntil = .distantPast
        KeychainHelper.delete(key: mirroredTokenKey)
    }

    /// Our mirrored token is stored as "<validUntilEpochSeconds>\t<token>".
    ///
    /// ⚠️ Keychain calls must never run on the main actor. Whenever the app's signature
    /// changes (every rebuild of this self-signed app), macOS puts up an approval dialog
    /// and `SecItemCopyMatching` blocks until the user answers — and the notch panel sits
    /// above that dialog, so it can be invisible. Measured twice: the whole app froze
    /// (notch stopped hiding for Mission Control, timers never firing) with no
    /// crash and no log. `sample <pid>` is the fastest way to spot it.
    private func loadMirroredToken() async -> (token: String, validUntil: Date)? {
        let key = mirroredTokenKey
        guard let raw = await Task.detached(priority: .utility, operation: {
            KeychainHelper.load(key: key)
        }).value else { return nil }
        let parts = raw.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let epoch = Double(parts[0]), !parts[1].isEmpty else { return nil }
        return (String(parts[1]), Date(timeIntervalSince1970: epoch))
    }

    private func saveMirroredToken(token: String, validUntil: Date) async {
        let key = mirroredTokenKey
        let value = "\(validUntil.timeIntervalSince1970)\t\(token)"
        _ = await Task.detached(priority: .utility, operation: {
            KeychainHelper.save(key: key, value: value)
        }).value
    }

    /// `Retry-After` is either a number of seconds or an HTTP date.
    private static func retryAfter(from response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespaces),
              !raw.isEmpty else { return nil }
        if let seconds = TimeInterval(raw) { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: raw) else { return nil }
        return max(0, date.timeIntervalSinceNow)
    }

    private func scheduleNextRefresh() {
        refreshTimer?.invalidate()
        let interval = nextInterval()
        nextRefreshAt = Date().addingTimeInterval(interval)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.fetchUsage(interactive: false)
                self?.scheduleNextRefresh()
            }
        }
    }

    /// Effective poll interval: never below 5 min, and the rest of the backoff after a 429.
    /// A spent weekly window can't change until it resets, so polling pauses until then;
    /// the 5-hour window keeps its normal cadence, and a manual tap still fetches.
    private func nextInterval() -> TimeInterval {
        if let week = usageData.sevenDay, week.percentage >= 100,
           let resetsAt = week.resetsAt, resetsAt > Date() {
            return resetsAt.timeIntervalSinceNow + 60
        }
        // +1s so the timer lands past the deadline; on the deadline itself the guard in
        // fetchUsage still saw "limited" and pushed the retry out another minute.
        if let until = rateLimitedUntil, until > Date() { return max(60, until.timeIntervalSinceNow + 1) }
        let settings = AppSettings.shared
        let base = settings.claudeUsageRefreshMode == "smart"
            ? currentMonitoringMode.interval
            : TimeInterval(settings.claudeUsageRefreshInterval)
        return max(minInterval, base)
    }

    private func updateSmartMonitoringMode(currentUtilization: Double) {
        let hasChanged = abs(currentUtilization - lastUtilization) > 0.01
        if hasChanged {
            currentMonitoringMode = .active
            unchangedCount = 0
        } else {
            unchangedCount += 1
            let newMode: UsageMonitoringMode? = {
                switch currentMonitoringMode {
                case .active:     return unchangedCount >= 3 ? .idleShort : nil
                case .idleShort:  return unchangedCount >= 6 ? .idleMedium : nil
                case .idleMedium: return unchangedCount >= 12 ? .idleLong : nil
                case .idleLong:   return nil
                }
            }()
            if let newMode { currentMonitoringMode = newMode }
        }
        lastUtilization = currentUtilization
    }

    private func parseLimitDataOptional(_ limit: ClaudeUsageResponse.LimitUsage?) -> ClaudeUsageData.LimitData? {
        // Hide a limit only when the field is absent (null) — e.g. Opus/Sonnet you haven't
        // used. A present limit is always shown, including 0% (an idle 5-hour session),
        // so the 5시간 row doesn't vanish between sessions.
        guard let limit else { return nil }
        return ClaudeUsageData.LimitData(percentage: limit.utilization, resetsAt: parseResetDate(limit.resetsAt))
    }

    private func parseLimitEntry(_ limit: ClaudeUsageResponse.LimitEntry?) -> ClaudeUsageData.LimitData? {
        guard let limit else { return nil }
        return ClaudeUsageData.LimitData(percentage: limit.percent, resetsAt: parseResetDate(limit.resetsAt))
    }

    private func parseResetDate(_ dateString: String?) -> Date? {
        guard let dateString else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: dateString) {
            return Date(timeIntervalSinceReferenceDate: round(date.timeIntervalSinceReferenceDate))
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: dateString)
    }
}

// MARK: - OAuth Token

/// Reads the OAuth access token that Claude Code stored on this machine.
/// Order: `~/.claude/.credentials.json`, then the `Claude Code-credentials` Keychain item.
/// Runs off the main actor (Keychain reads can block on an access prompt).
enum ClaudeOAuthToken {
    /// Prefer the plaintext file (no Keychain prompt) when it's still valid. The file is a
    /// cache Claude Code doesn't always refresh — and on many machines doesn't exist at all
    /// — so when it's stale or absent we fall back to the Keychain item, which the CLI
    /// keeps current. The credential comes back with its expiry (epoch ms, 0 if unknown) so
    /// the caller can cache it and avoid re-reading the Keychain on every poll.
    ///
    /// The result may itself be expired, when every source is stale — check `isExpired`
    /// before using it. Only Claude Code can renew the token (it holds the refresh token),
    /// so "expired" is a distinct, actionable state, not a failure to find credentials.
    fileprivate static func read() -> Creds? {
        if let creds = readFromFile(), !creds.isExpired { return creds }
        if let creds = readFromKeychain() { return creds }
        return readFromFile()
    }

    fileprivate struct Creds {
        let token: String
        let expiresAt: Double  // epoch milliseconds, 0 if unknown
        let refreshToken: String
        /// Plan the CLI logged in with ("pro", "max", "max_5x"…); nil on older blobs.
        let subscriptionType: String?
        /// The whole stored blob, so a refresh can rewrite it without dropping fields we
        /// don't model (subscriptionType, rateLimitTier, scopes…).
        let rawJSON: String
        var isExpired: Bool { expiresAt > 0 && expiresAt < Date().timeIntervalSince1970 * 1000 }
    }

    private static func parse(_ data: Data) -> Creds? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else {
            return nil
        }
        let exp = (oauth["expiresAt"] as? Double) ?? Double((oauth["expiresAt"] as? Int) ?? 0)
        return Creds(
            token: token,
            expiresAt: exp,
            refreshToken: (oauth["refreshToken"] as? String) ?? "",
            subscriptionType: oauth["subscriptionType"] as? String,
            rawJSON: String(data: data, encoding: .utf8) ?? ""
        )
    }

    private static func readFromFile() -> Creds? {
        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/.credentials.json")
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return parse(data)
    }

    /// Read via `/usr/bin/security` rather than SecItemCopyMatching.
    ///
    /// Claude Code stores the item by shelling out to `security add-generic-password -U`,
    /// so the item's access list trusts `/usr/bin/security` — and `-U` rewrites that list
    /// on every token refresh, which is why any grant we get for *our own* binary is wiped
    /// every few hours. Going through `security` makes it the accessing app, so the read
    /// is always allowed and never shows the password prompt.
    ///
    /// Blocking (spawns a process) — call off the main actor.
    private static func readFromKeychain() -> Creds? {
        let account = ProcessInfo.processInfo.environment["USER"] ?? NSUserName()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        task.arguments = ["find-generic-password", "-a", account, "-s", "Claude Code-credentials", "-w"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            guard task.terminationStatus == 0,
                  let output = String(data: data, encoding: .utf8) else { return nil }
            let json = output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !json.isEmpty else { return nil }
            return parse(Data(json.utf8))
        } catch {
            return nil
        }
    }

    // MARK: - Refresh

    // Lifted from the Claude Code 2.1.220 binary's OAuth config so the request we send is
    // the same one the CLI sends.
    private static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let scopes = "user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"
    private static let backupKey = "claudeCredentialsBackup"
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ClangNotch", category: "ClaudeOAuth")

    /// Trade the refresh token for a fresh access token, then write the result back to the
    /// Keychain item Claude Code reads.
    ///
    /// The write-back is the important half: the server may rotate the refresh token, and if
    /// we kept the new one to ourselves the CLI would be left holding a dead one. Writing
    /// through the same `security add-generic-password -U` path the CLI uses keeps both
    /// clients on the same credential. The original blob is backed up to our own Keychain
    /// item once, before the first write.
    fileprivate static func refresh(_ creds: Creds) async -> Creds? {
        guard !creds.refreshToken.isEmpty, !creds.rawJSON.isEmpty else { return nil }

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": creds.refreshToken,
            "client_id": clientID,
            "scope": scopes
        ])
        guard request.httpBody != nil else { return nil }

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String, !accessToken.isEmpty else {
            return nil
        }

        let nowMillis = Date().timeIntervalSince1970 * 1000
        // A rotating server returns a new refresh token; a non-rotating one omits it.
        let refreshToken = (json["refresh_token"] as? String) ?? creds.refreshToken
        let expiresAt = seconds(json["expires_in"]).map { nowMillis + $0 * 1000 } ?? 0
        let refreshExpiresAt = seconds(json["refresh_token_expires_in"]).map { nowMillis + $0 * 1000 }

        guard let updated = merge(
            into: creds.rawJSON,
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            refreshTokenExpiresAt: refreshExpiresAt
        ) else { return nil }

        let original = creds.rawJSON
        let wroteBack = await Task.detached(priority: .utility) { () -> Bool in
            if !KeychainHelper.exists(key: backupKey) {
                _ = KeychainHelper.save(key: backupKey, value: original)
            }
            return writeToKeychain(updated)
        }.value

        if !wroteBack, refreshToken != creds.refreshToken {
            // The server rotated the refresh token but we failed to persist it, so Claude
            // Code is now holding a dead one. Loud, because only a re-login fixes it.
            logger.error("Refreshed the token but could not write it back — Claude Code may need `claude /login`")
        }

        return Creds(
            token: accessToken,
            expiresAt: expiresAt,
            refreshToken: refreshToken,
            subscriptionType: creds.subscriptionType,
            rawJSON: updated
        )
    }

    private static func seconds(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        return nil
    }

    /// Rewrite the credential blob in place, leaving every field we don't own untouched.
    private static func merge(
        into rawJSON: String,
        accessToken: String,
        refreshToken: String,
        expiresAt: Double,
        refreshTokenExpiresAt: Double?
    ) -> String? {
        guard var json = try? JSONSerialization.jsonObject(with: Data(rawJSON.utf8)) as? [String: Any],
              var oauth = json["claudeAiOauth"] as? [String: Any] else { return nil }
        oauth["accessToken"] = accessToken
        oauth["refreshToken"] = refreshToken
        oauth["expiresAt"] = expiresAt
        if let refreshTokenExpiresAt { oauth["refreshTokenExpiresAt"] = refreshTokenExpiresAt }
        json["claudeAiOauth"] = oauth
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Blocking (spawns a process) — call off the main actor.
    private static func writeToKeychain(_ json: String) -> Bool {
        let account = ProcessInfo.processInfo.environment["USER"] ?? NSUserName()
        let hex = Data(json.utf8).map { String(format: "%02X", $0) }.joined()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        task.arguments = ["add-generic-password", "-U", "-a", account, "-s", "Claude Code-credentials", "-X", hex]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }
}

// MARK: - Demo

extension ClaudeUsageManager {
    /// `--demo`: made-up quota numbers, so the card shows without a network call.
    func demoApply(_ usage: ClaudeUsageData) {
        usageData = usage
        isConfigured = true
        lastError = nil
    }
}
