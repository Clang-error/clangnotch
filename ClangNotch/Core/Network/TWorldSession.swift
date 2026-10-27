import Combine
import Foundation

@MainActor
final class TWorldSession: ObservableObject {
    static let shared = TWorldSession()

    @Published private(set) var balance: TWorldBalance?
    @Published private(set) var isRefreshing = false
    @Published private(set) var requiresLogin = true
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastAttempt: Date?
    @Published private(set) var hasCredentials = false

    private let vault = TWorldCookieVault()
    private let client = TWorldClient()
    private var cookies: [HTTPCookie] = []
    /// Request headers and URL captured from the T world page (see `TWorldHeaderCapture`).
    private var headers: [String: String] = [:]
    private var endpoint: URL?
    private var lastCaptureAt: Date?
    private var credentials: TWorldCredentials?
    private var restoreTask: Task<Void, Never>?
    private var generation = 0
    private var loginWindow: TWorldLoginWindow?
    private var silentLogins: [Date] = []
    private var refreshTask: Task<Void, Never>?
    private var keepAliveTimer: Timer?

    var canRefresh: Bool {
        !requiresLogin && !isRefreshing && (lastAttempt.map { Date().timeIntervalSince($0) >= 180 } ?? true)
    }

    /// When the 10-minute loop is allowed to query again; the tick that follows may be up to 30s late.
    var nextAutoRefresh: Date? { lastAttempt?.addingTimeInterval(600) }

    func prepare() async {
        guard AppSettings.shared.enableTWorld else { return }
        if let restoreTask { await restoreTask.value; return }
        let task = Task {
            do {
                let stored = try await vault.load()
                cookies = stored.cookies
                headers = stored.headers
                endpoint = stored.endpoint
                credentials = try await vault.loadCredentials()
                hasCredentials = credentials != nil
                requiresLogin = cookies.isEmpty && credentials == nil
                if !requiresLogin { startKeepAlive() }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        restoreTask = task
        await task.value
    }

    /// The BFF's line context (what fills T-SvcMgmtNum/T-DubScrbInfo server-side) lapses after
    /// roughly half an hour idle, and only a fresh T ID hand-off rebuilds it. One query every
    /// ten minutes keeps it alive whether or not any card is showing, so the WebView route
    /// stays the exception. The first query runs shortly after launch.
    private func startKeepAlive() {
        guard keepAliveTimer == nil else { return }
        let timer = Timer(timeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        keepAliveTimer = timer
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            await self?.refresh()
        }
    }

    private func stopKeepAlive() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
    }

    /// The SKT 공유 데이터 switch: off stops the queries and automatic sign-ins at once.
    func syncWithSettings() async {
        guard AppSettings.shared.enableTWorld else { stopKeepAlive(); return }
        await prepare()
        if !requiresLogin { startKeepAlive() }
    }

    /// Runs as its own task: the card that asks for a refresh lives only while the popover or
    /// Speed tab is open, and closing it must not cancel a sign-in halfway through.
    func refresh(force: Bool = false) async {
        guard AppSettings.shared.enableTWorld else { return }
        if let refreshTask { await refreshTask.value; return }
        let task = Task { [self] in
            await performRefresh(force: force)
            refreshTask = nil
        }
        refreshTask = task
        await task.value
    }

    private func performRefresh(force: Bool) async {
        await prepare()
        guard !requiresLogin, !isRefreshing else { return }
        // Even manual refresh has a cooldown: T world allows 50 queries / 120 minutes.
        guard lastAttempt.map({ Date().timeIntervalSince($0) >= (force ? 180 : 600) }) ?? true else { return }
        isRefreshing = true
        lastAttempt = Date()
        let currentGeneration = generation
        defer { isRefreshing = false }
        do {
            let (newBalance, updatedCookies) = try await fetchRecoveringSession()
            guard currentGeneration == generation else { return }
            try await vault.save(updatedCookies, headers: headers, endpoint: endpoint)
            guard currentGeneration == generation else { return }
            cookies = updatedCookies
            balance = newBalance
            errorMessage = nil
        } catch {
            guard currentGeneration == generation else { return }
            if case TWorldError.loginRequired = error { requiresLogin = true }
            errorMessage = error.localizedDescription
        }
    }

    /// T world limits sign-ins per day, so silent recovery is capped; beyond it the user signs in.
    private func fetchRecoveringSession() async throws -> (TWorldBalance, [HTTPCookie]) {
        do { return try await client.fetch(cookies: cookies, headers: headers, endpoint: endpoint) }
        catch let error as TWorldError { return try await recover(after: error) }
    }

    private func recover(after error: TWorldError) async throws -> (TWorldBalance, [HTTPCookie]) {
        do { throw error }
        catch let error as TWorldError {
            // A server error is worth one re-capture: the API's required headers changed on
            // 2026-09-23 (T-SvcMgmtNum, T-DubScrbInfo) and the page's own request is the
            // only source of the current set. Not more than every 30 minutes, though.
            let staleCapture = lastCaptureAt.map { Date().timeIntervalSince($0) > 1_800 } ?? true
            guard error == .loginRequired || (error == .serviceUnavailable && (headers.isEmpty || staleCapture)) else { throw error }
            silentLogins.removeAll { Date().timeIntervalSince($0) > 86_400 }
            guard silentLogins.count < 12 else { throw TWorldError.loginRequired }
            silentLogins.append(Date())
            let recovered = try await TWorldSilentLogin.recover(credentials: credentials)
            adopt(recovered.capture)
            return try await client.fetch(cookies: recovered.cookies, headers: headers, endpoint: endpoint)
        }
    }

    private func adopt(_ capture: TWorldHeaderCapture.Capture) {
        lastCaptureAt = Date()
        guard !capture.isEmpty else { return }
        headers = capture.headers
        endpoint = capture.endpoint
    }

    /// Stored in the Keychain only; the next refresh signs in with it right away.
    func saveCredentials(id: String, password: String) async {
        await prepare()
        let trimmed = TWorldCredentials(id: id.trimmingCharacters(in: .whitespaces), password: password)
        do {
            try await vault.saveCredentials(trimmed)
            credentials = trimmed
            hasCredentials = true
            requiresLogin = false
            errorMessage = nil
            lastAttempt = nil
            startKeepAlive()
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func showLogin(onConnected: (() -> Void)? = nil) {
        if let loginWindow { loginWindow.show(); return }
        Task { [self] in
            await prepare()
            if let loginWindow { loginWindow.show(); return }
            let window = TWorldLoginWindow(cookies: cookies) { [weak self] newCookies, capture in
                guard let self else { return }
                guard !self.isRefreshing else { throw TWorldError.serviceUnavailable }
                self.isRefreshing = true
                defer { self.isRefreshing = false }
                self.generation += 1
                self.adopt(capture)
                let (newBalance, updatedCookies) = try await self.client.fetch(cookies: newCookies, headers: self.headers, endpoint: self.endpoint)
                try await self.vault.save(updatedCookies, headers: self.headers, endpoint: self.endpoint)
                self.cookies = updatedCookies
                self.balance = newBalance
                self.requiresLogin = false
                self.errorMessage = nil
                self.lastAttempt = Date()
                self.startKeepAlive()
            } onConnected: {
                onConnected?()
            } onClosed: { [weak self] in
                self?.loginWindow = nil
            }
            loginWindow = window
            window.show()
        }
    }

    func disconnect() async {
        await prepare()
        generation += 1
        loginWindow?.close()
        stopKeepAlive()
        do {
            try await vault.clear()
            requiresLogin = true
            cookies = []
            headers = [:]
            endpoint = nil
            lastCaptureAt = nil
            credentials = nil
            hasCredentials = false
            await TWorldLoginWindow.clearWebsiteData()
            balance = nil
            lastAttempt = nil
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
