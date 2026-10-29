//
//  CodexManager.swift
//  ClangNotch
//
//  Created for OpenAI Codex CLI JSONL session integration
//

import Foundation
import Combine
import AppKit

// MARK: - Debug Logging (uses shared debugLog from ClaudeCodeManager)
// Note: debugLog is defined in ClaudeCodeManager.swift and available app-wide

@MainActor
final class CodexManager: ObservableObject {
    static let shared = CodexManager()

    // MARK: - Published Properties

    @Published private(set) var availableSessions: [CodexSession] = []
    @Published var selectedSession: CodexSession?
    @Published private(set) var state: CodexState = CodexState()
    @Published private(set) var rateLimits = CodexRateLimits() {
        didSet {
            // Show the real next poll instead of a 5-minute countdown that will be skipped.
            if let resetsAt = weeklyLimitResetsAt { nextRateLimitRefreshAt = resetsAt.addingTimeInterval(60) }
        }
    }
    /// Set while the weekly window is spent: it cannot move before this instant.
    private var weeklyLimitResetsAt: Date? {
        guard let week = rateLimits.secondary, week.usedPercent >= 100,
              let resetsAt = week.resetsAt, resetsAt > Date() else { return nil }
        return resetsAt
    }
    @Published private(set) var isRefreshingRateLimits = false
    @Published private(set) var nextRateLimitRefreshAt: Date?
    private var primaryRateLimitUpdatedAt = Date.distantPast
    private var secondaryRateLimitUpdatedAt = Date.distantPast

    /// Per-session state tracking
    @Published private(set) var sessionStates: [String: CodexState] = [:]

    /// When any session last finished a turn normally (task_complete); drives the closed-notch Done.
    @Published private(set) var lastTurnCompletedAt: Date?
    /// What that turn ended with, for the 완료 드롭다운.
    @Published private(set) var lastCompletedTurn: CompletedTurn?

    var pendingInputRequests: [CodexInputRequest] {
        sessionStates.values.compactMap(\.pendingInputRequest)
    }

    /// Remembered so a history reload can't bring a dismissed question back.
    private var dismissedInputRequestIDs: Set<String> = []

    /// The NEEDS YOU 카드's X, for a question whose answer never reached the transcript.
    func dismissInputRequest(id: String) {
        dismissedInputRequestIDs.insert(id)
        for (sessionId, var sessionState) in sessionStates where sessionState.pendingInputRequest?.id == id {
            sessionState.pendingInputRequest = nil
            sessionStates[sessionId] = sessionState
        }
        objectWillChange.send()
    }

    /// Track when we last had activity (for grace period)
    private var lastActivityTime: Date = Date.distantPast
    private let activityGracePeriod: TimeInterval = 1.0

    /// True if any session has activity
    var hasAnySessionActivity: Bool {
        for sessionState in sessionStates.values {
            if sessionState.isActive {
                lastActivityTime = Date()
                return true
            }
        }
        if state.isActive {
            lastActivityTime = Date()
            return true
        }

        let timeSinceLastActivity = Date().timeIntervalSince(lastActivityTime)
        if timeSinceLastActivity < activityGracePeriod {
            return true
        }

        return false
    }

    // MARK: - Private Properties

    private let codexDir: URL = {
        if let pw = getpwuid(getuid()), let home = pw.pointee.pw_dir {
            let homePath = String(cString: home)
            return URL(fileURLWithPath: homePath).appendingPathComponent(".codex")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }()

    private var sessionsDir: URL { codexDir.appendingPathComponent("sessions") }

    private var sessionScanTimer: Timer?
    private var rateLimitRefreshTimer: Timer?
    private var rateLimitProcess: Process?
    private var rateLimitOutputBuffer = Data()
    private var sessionWatchers: [String: DispatchSourceFileSystemObject] = [:]
    private var sessionFileHandles: [String: FileHandle] = [:]
    private var sessionReadPositions: [String: UInt64] = [:]
    private var sessionLineBuffers: [String: JSONLLineBuffer] = [:]
    private var isLoadingHistoryBySession: [String: Bool] = [:]
    private var externalImportSessions: Set<String> = []
    private var sessionActivityCache: [URL: (modifiedAt: Date, fileSize: UInt64, activity: Date?)] = [:]

    /// Track pending function calls for timing
    private var pendingFunctionCalls: [String: [String: Date]] = [:]  // sessionId -> (callId -> startTime)

    /// When each quiet working session was last checked for a live writer (`clearEndedSessions`).
    private var endedCheckTimes: [String: Date] = [:]

    /// Timer to detect idle state
    private var idleCheckTimer: Timer?
    private let idleCheckDelay: TimeInterval = 3.0
    private let staleLineAfter: TimeInterval = 120

    // MARK: - Date Formatters

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let plainISO8601Formatter = ISO8601DateFormatter()

    // MARK: - Initialization

    private init() {
        debugLog("[Codex] ========================================")
        debugLog("[Codex] CodexManager initializing...")
        debugLog("[Codex] Codex dir: \(codexDir.path)")
        debugLog("[Codex] Sessions dir: \(sessionsDir.path)")
        debugLog("[Codex] ========================================")
        if AppSettings.shared.enableCodexJSONL {
            startSessionScanning()
            startRateLimitRefreshing()
        }
    }

    // MARK: - Public Methods

    /// Scan for active Codex sessions
    func scanForSessions() {
        let fm = FileManager.default
        var sessions: [CodexSession] = []
        var latestSessionFile: (url: URL, modifiedAt: Date)?
        var allSessionFiles: [(url: URL, modifiedAt: Date)] = []

        debugLog("[Codex] Scanning for sessions...")

        guard fm.fileExists(atPath: sessionsDir.path) else {
            debugLog("[Codex] Sessions directory does not exist")
            availableSessions = []
            return
        }

        clearEndedSessions()

        // Codex stores sessions as: ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl
        // Find recent session files (last 5 minutes)
        let recentThreshold = Date().addingTimeInterval(-300)
        let retainedFiles = Set(availableSessions.compactMap { session -> URL? in
            guard let state = sessionStates[session.id],
                  state.isActive || state.pendingInputRequest != nil else { return nil }
            return session.jsonlFile
        })

        do {
            let enumerator = fm.enumerator(
                at: sessionsDir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )

            while let fileURL = enumerator?.nextObject() as? URL {
                guard fileURL.pathExtension == "jsonl",
                      fileURL.lastPathComponent.hasPrefix("rollout-") else {
                    continue
                }

                let attrs = try? fm.attributesOfItem(atPath: fileURL.path)
                let modDate = attrs?[.modificationDate] as? Date ?? .distantPast
                allSessionFiles.append((fileURL, modDate))
                if latestSessionFile == nil || modDate > latestSessionFile!.modifiedAt {
                    latestSessionFile = (fileURL, modDate)
                }

                // A quiet working session or unanswered question must not expire.
                if retainedFiles.contains(fileURL)
                    || (modDate > recentThreshold
                        && (latestCodexActivityDate(in: fileURL, modifiedAt: modDate) ?? .distantPast) > recentThreshold) {
                    if let session = parseSessionFromFile(fileURL) {
                        debugLog("[Codex] Found session: \(session.displayName) (id: \(session.id.prefix(8))...)")
                        sessions.append(session)
                    }
                }
            }
        } catch {
            debugLog("[Codex] Error scanning sessions: \(error)")
        }
        sessionActivityCache = sessionActivityCache.filter { $0.value.modifiedAt > recentThreshold }

        if !rateLimits.hasData {
            // File modification order is not a reliable account-usage order when
            // several Codex tasks are open. Each loader compares the JSONL event
            // timestamp, so every recent rollout can safely contribute its newest
            // matching window without stale sessions winning.
            for candidate in allSessionFiles {
                loadLatestRateLimits(from: candidate.url)
            }
        }

        // Sort by timestamp (most recent first)
        sessions.sort { $0.timestamp > $1.timestamp }

        debugLog("[Codex] Total sessions found: \(sessions.count)")
        availableSessions = sessions

        // Auto-select first session if none selected
        if selectedSession == nil && sessions.count == 1 {
            selectSession(sessions[0])
        }

        // Clear selected session if no longer available
        if let selected = selectedSession,
           !sessions.contains(where: { $0.id == selected.id }) {
            selectedSession = nil
            state = CodexState()
        }

        // Watch all sessions
        let currentSessionIds = Set(sessions.map { $0.id })

        for session in sessions {
            if sessionWatchers[session.id] == nil {
                startWatchingSession(session)
            }
        }

        // Stop watching sessions that are no longer active
        let watchedIds = Array(sessionWatchers.keys)
        for watchedId in watchedIds where !currentSessionIds.contains(watchedId) {
            stopWatchingSession(id: watchedId)
        }
    }

    /// Clears a running tool or open question left by a Codex process that has exited. Those
    /// states are exempt from the silence timeout and their output will never arrive, so they
    /// would otherwise read as working until the app restarts. lsof runs off the main actor,
    /// only after a minute of silence and at most once a minute per session.
    private func clearEndedSessions() {
        let now = Date()
        let quiet = availableSessions.filter { session in
            guard let state = sessionStates[session.id],
                  !state.activeTools.isEmpty || state.pendingInputRequest != nil,
                  now.timeIntervalSince(state.lastUpdateTime ?? .distantPast) > 60,
                  now.timeIntervalSince(endedCheckTimes[session.id] ?? .distantPast) > 60 else { return false }
            return true
        }
        guard !quiet.isEmpty else { return }
        for session in quiet { endedCheckTimes[session.id] = now }

        Task {
            let ended = await Task.detached(priority: .utility) {
                quiet.filter { !SessionAppResolver.isOpenByCodex($0.jsonlFile) }
            }.value
            for session in ended {
                // Skip a session that wrote again while lsof ran.
                guard var sessionState = sessionStates[session.id],
                      Date().timeIntervalSince(sessionState.lastUpdateTime ?? .distantPast) > 60 else { continue }
                debugLog("[Codex] Session \(session.id.prefix(8))... has no live writer; clearing its working state")
                sessionState.activeTools.removeAll()
                sessionState.isThinking = false
                sessionState.isTurnInProgress = false
                if sessionState.pendingInputRequest?.isAsync != true {
                    sessionState.pendingInputRequest = nil
                }
                pendingFunctionCalls[session.id]?.removeAll()
                sessionStates[session.id] = sessionState
                if selectedSession?.id == session.id { state = sessionState }
            }
        }
    }

    /// Select a session to monitor
    func selectSession(_ session: CodexSession) {
        guard session != selectedSession else { return }

        debugLog("[Codex] Selecting session: \(session.displayName)")
        selectedSession = session

        // Copy session state to main state
        if let sessionState = sessionStates[session.id] {
            state = sessionState
        } else {
            state = CodexState()
            state.cwd = session.cwd
            state.sessionId = session.id
            state.gitBranch = session.gitBranch ?? ""
        }
    }

    @Published private(set) var sessionAppDestinations: [String: SessionAppDestination] = [:]

    func appDestination(for session: CodexSession) -> SessionAppDestination {
        sessionAppDestinations[session.id] ?? .codex(originator: session.originator, source: session.source)
    }

    func focusApp(for session: CodexSession) {
        resolveApp(for: session, open: true)
    }

    private func resolveApp(for session: CodexSession, open: Bool = false) {
        Task {
            let (destination, warpURL) = await Task.detached(priority: .userInitiated) { () -> (SessionAppDestination, URL?) in
                let destination = SessionAppResolver.codexOwner(of: session.jsonlFile)
                    ?? .codex(originator: session.originator, source: session.source)
                // A terminal session started in a Warp tab goes back to that exact tab.
                let warpURL = open && destination == .terminal
                    ? SessionAppResolver.codexWarpFocusURL(file: session.jsonlFile, sessionId: session.id, cwd: session.cwd)
                    : nil
                return (destination, warpURL)
            }.value
            if sessionStates[session.id] != nil { sessionAppDestinations[session.id] = destination }
            guard open else { return }
            if let warpURL {
                NSWorkspace.shared.open(warpURL)
            } else {
                SessionAppLauncher.open(destination)
            }
        }
    }

    /// Manually refresh state
    func refresh() {
        scanForSessions()
        refreshRateLimitsNow()
    }

    /// Apply the JSONL tracking setting immediately. A telemetry pause keeps the usage card:
    /// the account quota is still true while activity tracking is off.
    func setTrackingEnabled(_ enabled: Bool, keepingUsage: Bool = false) {
        if enabled {
            startSessionScanning()
            startRateLimitRefreshing()
        } else {
            stopWatching()
            availableSessions = []
            selectedSession = nil
            state = CodexState()
            sessionStates = [:]
            sessionActivityCache.removeAll()
            lastActivityTime = .distantPast
            guard !keepingUsage else { return }
            rateLimits = CodexRateLimits()
            primaryRateLimitUpdatedAt = .distantPast
            secondaryRateLimitUpdatedAt = .distantPast
            nextRateLimitRefreshAt = nil
        }
    }

    // MARK: - Session Scanning

    private func startSessionScanning() {
        guard sessionScanTimer == nil, !DemoMode.isActive else { return }
        if let port = UInt16(exactly: AppSettings.shared.telemetryOtlpPort) {
            do {
                try PermissionHooks.install(in: codexDir.appendingPathComponent("hooks.json"), port: port, maxTime: 35)
            } catch {
                debugLog("[Codex] Could not install permission hook: \(error.localizedDescription)")
            }
        }
        scanForSessions()
        sessionScanTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.scanForSessions()
            }
        }
    }

    // MARK: - Direct Account Usage

    /// JSONL is per-session telemetry and can lag behind account-wide limits.
    /// The local Codex App Server returns the same authenticated account bucket
    /// used by Codex Desktop, without spending any model usage.
    private func startRateLimitRefreshing() {
        guard rateLimitRefreshTimer == nil, !DemoMode.isActive else { return }
        refreshRateLimitsNow()
        rateLimitRefreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshRateLimitsIfDue()
            }
        }
    }

    /// Timer path only. A spent weekly window can't change before it resets, so the
    /// app-server round trip is skipped until then; `refresh()` (manual) still goes through.
    private func refreshRateLimitsIfDue() {
        if let resetsAt = weeklyLimitResetsAt {
            nextRateLimitRefreshAt = resetsAt.addingTimeInterval(60)
            return
        }
        refreshRateLimitsNow()
    }

    private func refreshRateLimitsNow() {
        refreshRateLimitsDirectly()
        nextRateLimitRefreshAt = Date().addingTimeInterval(300)
    }

    private func refreshRateLimitsDirectly() {
        guard rateLimitProcess == nil, let executableURL = codexExecutableURL() else { return }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["app-server"]

        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        rateLimitProcess = process
        isRefreshingRateLimits = true
        rateLimitOutputBuffer.removeAll()

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in
                self?.handleRateLimitOutput(data, input: input)
            }
        }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.rateLimitProcess = nil
                self?.isRefreshingRateLimits = false
            }
        }

        do {
            try process.run()
            sendAppServerMessage([
                "method": "initialize",
                "id": 1,
                "params": [
                    "clientInfo": [
                        "name": "ClangNotch",
                        "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
                    ]
                ]
            ], to: input)
        } catch {
            rateLimitProcess = nil
            isRefreshingRateLimits = false
        }
    }

    private func codexExecutableURL() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".local/bin/codex"),
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex")
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private func handleRateLimitOutput(_ data: Data, input: Pipe) {
        rateLimitOutputBuffer.append(data)
        let newline = Data([0x0A])

        while let range = rateLimitOutputBuffer.range(of: newline) {
            let line = rateLimitOutputBuffer.subdata(in: rateLimitOutputBuffer.startIndex..<range.lowerBound)
            rateLimitOutputBuffer.removeSubrange(rateLimitOutputBuffer.startIndex...range.lowerBound)

            guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = message["id"] as? Int else { continue }

            if id == 1 {
                sendAppServerMessage(["method": "initialized", "params": [:]], to: input)
                sendAppServerMessage(["method": "account/rateLimits/read", "id": 2, "params": [:]], to: input)
            } else if id == 2 {
                if let result = message["result"] as? [String: Any] {
                    applyDirectRateLimits(result)
                }
                input.fileHandleForWriting.closeFile()
                rateLimitProcess?.terminate()
            }
        }
    }

    private func sendAppServerMessage(_ message: [String: Any], to input: Pipe) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        input.fileHandleForWriting.write(data)
        input.fileHandleForWriting.write(Data([0x0A]))
    }

    private func applyDirectRateLimits(_ result: [String: Any]) {
        let byLimitId = result["rateLimitsByLimitId"] as? [String: Any]
        guard let raw = (byLimitId?["codex"] as? [String: Any])
            ?? (result["rateLimits"] as? [String: Any]),
            raw["limitId"] as? String == "codex" else { return }

        // Same reasoning as the JSONL path: classify by the rolling-window
        // length rather than trusting the primary/secondary key names.
        let windows = [
            parseDirectRateLimitWindow(raw["primary"] as? [String: Any]),
            parseDirectRateLimitWindow(raw["secondary"] as? [String: Any])
        ].compactMap { $0 }

        let direct = CodexRateLimits(
            primary: windows.first(where: { $0.windowMinutes < 1_440 }),
            secondary: windows.first(where: { $0.windowMinutes >= 1_440 }),
            planType: raw["planType"] as? String,
            // The account-wide verdict, which no single window percentage carries.
            limitReached: result["ordinaryUsageAllowed"] as? Bool == false
                || raw["rateLimitReachedType"] as? String != nil
        )
        guard direct.hasData else { return }

        let now = Date()
        rateLimits = direct
        // A window absent from this authoritative read doesn't exist; stop older JSONL
        // snapshots from bringing it back.
        primaryRateLimitUpdatedAt = now
        secondaryRateLimitUpdatedAt = now
    }

    private func parseDirectRateLimitWindow(_ raw: [String: Any]?) -> CodexRateLimitWindow? {
        guard let raw,
              let usedPercent = (raw["usedPercent"] as? NSNumber)?.doubleValue,
              let windowMinutes = (raw["windowDurationMins"] as? NSNumber)?.intValue else { return nil }

        let resetsAt = (raw["resetsAt"] as? NSNumber).map {
            Date(timeIntervalSince1970: $0.doubleValue)
        }
        return CodexRateLimitWindow(
            usedPercent: usedPercent,
            windowMinutes: windowMinutes,
            resetsAt: resetsAt
        )
    }

    /// File writes from opening/settings/importing a conversation are not Codex work.
    /// Walk complete records backwards so a large tail record cannot hide the latest turn.
    private func latestCodexActivityDate(in file: URL, modifiedAt: Date) -> Date? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let fileSize = handle.seekToEndOfFile()
        if let cached = sessionActivityCache[file], cached.modifiedAt == modifiedAt, cached.fileSize == fileSize {
            return cached.activity
        }
        var activity: Date?
        defer { sessionActivityCache[file] = (modifiedAt, fileSize, activity) }
        let recentThreshold = Date().addingTimeInterval(-300)
        var position = fileSize
        var pending = Data()
        while position > 0 {
            let start = position > 64 * 1024 ? position - 64 * 1024 : 0
            handle.seek(toFileOffset: start)
            var data = handle.readData(ofLength: Int(position - start))
            data.append(pending)
            let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
            pending = start > 0 ? Data(lines.first ?? Data()) : Data()
            let completeLines = start > 0 ? lines.dropFirst() : lines[...]
            for line in completeLines.reversed() {
                guard let json = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let payload = json["payload"] as? [String: Any],
                      let type = json["type"] as? String,
                      let eventType = payload["type"] as? String else { continue }
                let isTurn = type == "event_msg"
                    && ["task_started", "task_complete", "turn_aborted", "agent_reasoning"].contains(eventType)
                    && !(payload["turn_id"] as? String ?? "").hasPrefix("external-import-turn-")
                let isToolOrReasoning = type == "response_item"
                    && ["function_call", "custom_tool_call", "function_call_output", "custom_tool_call_output", "reasoning"].contains(eventType)
                let isResponse = type == "response_item" && eventType == "message"
                    && payload["role"] as? String == "assistant"
                    && ["commentary", "final_answer"].contains(payload["phase"] as? String ?? "")
                guard isTurn || isToolOrReasoning || isResponse,
                      let timestamp = json["timestamp"] as? String,
                      let date = Self.iso8601Formatter.date(from: timestamp) ?? Self.plainISO8601Formatter.date(from: timestamp) else { continue }
                activity = max(activity ?? .distantPast, date)
                if date > recentThreshold { return activity }
            }
            position = start
        }
        return activity
    }

    private func parseSessionFromFile(_ file: URL) -> CodexSession? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }

        // Codex Desktop includes base_instructions in session_meta, so the first
        // JSONL record can exceed the old fixed 10 KB read substantially.
        guard let lineData = readFirstJSONLRecord(from: handle),
              let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              let type = json["type"] as? String,
              type == "session_meta",
              let payload = json["payload"] as? [String: Any],
              let sessionId = payload["id"] as? String,
              let cwd = payload["cwd"] as? String else {
            return nil
        }

        let cliVersion = payload["cli_version"] as? String ?? "unknown"
        let modelProvider = payload["model_provider"] as? String ?? "openai"

        var gitBranch: String?
        var gitCommit: String?
        if let git = payload["git"] as? [String: Any] {
            gitBranch = git["branch"] as? String
            gitCommit = git["commit_hash"] as? String
        }

        var timestamp = Date()
        if let timestampStr = json["timestamp"] as? String {
            timestamp = Self.iso8601Formatter.date(from: timestampStr) ?? Date()
        } else if let payloadTimestamp = payload["timestamp"] as? String {
            timestamp = Self.iso8601Formatter.date(from: payloadTimestamp) ?? Date()
        }

        return CodexSession(
            id: sessionId,
            cwd: cwd,
            cliVersion: cliVersion,
            modelProvider: modelProvider,
            gitBranch: gitBranch,
            gitCommit: gitCommit,
            timestamp: timestamp,
            jsonlFile: file,
            originator: payload["originator"] as? String ?? "",
            source: payload["source"] as? String ?? ""
        )
    }

    private func readFirstJSONLRecord(from handle: FileHandle) -> Data? {
        let chunkSize = 16 * 1024
        let maximumRecordSize = 1024 * 1024
        var data = Data()

        while data.count < maximumRecordSize {
            let chunk = handle.readData(ofLength: min(chunkSize, maximumRecordSize - data.count))
            guard !chunk.isEmpty else { break }
            data.append(chunk)

            if let newlineIndex = data.firstIndex(of: 0x0A) {
                return data.subdata(in: data.startIndex..<newlineIndex)
            }
        }

        return data.isEmpty ? nil : data
    }

    // MARK: - Session Watching

    private func startWatchingSession(_ session: CodexSession) {
        debugLog("[Codex] startWatchingSession: \(session.displayName)")
        guard sessionWatchers[session.id] == nil else {
            debugLog("[Codex]   - Already watching")
            return
        }

        let jsonlFile = session.jsonlFile

        var sessionState = CodexState()
        sessionState.cwd = session.cwd
        sessionState.sessionId = session.id
        sessionState.gitBranch = session.gitBranch ?? ""
        sessionState.isConnected = true
        sessionStates[session.id] = sessionState

        do {
            let handle = try FileHandle(forReadingFrom: jsonlFile)
            handle.seekToEndOfFile()
            sessionFileHandles[session.id] = handle
            sessionReadPositions[session.id] = handle.offsetInFile
            loadRecentHistoryForSession(from: jsonlFile, sessionId: session.id)
        } catch {
            debugLog("[Codex] Error opening file: \(error)")
            return
        }

        let fd = open(jsonlFile.path, O_EVTONLY)
        guard fd >= 0 else {
            debugLog("[Codex] Failed to open file descriptor")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend],
            queue: .main
        )

        source.setEventHandler { [weak self] in
            self?.readNewSessionData(sessionId: session.id)
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
        sessionWatchers[session.id] = source
        readNewSessionData(sessionId: session.id)
        resolveApp(for: session)
    }

    private func stopWatchingSession(id sessionId: String) {
        sessionWatchers[sessionId]?.cancel()
        sessionWatchers.removeValue(forKey: sessionId)
        sessionFileHandles[sessionId]?.closeFile()
        sessionFileHandles.removeValue(forKey: sessionId)
        sessionReadPositions.removeValue(forKey: sessionId)
        sessionLineBuffers.removeValue(forKey: sessionId)
        sessionStates.removeValue(forKey: sessionId)
        sessionAppDestinations.removeValue(forKey: sessionId)
        pendingFunctionCalls.removeValue(forKey: sessionId)
        endedCheckTimes.removeValue(forKey: sessionId)
        isLoadingHistoryBySession.removeValue(forKey: sessionId)
        externalImportSessions.remove(sessionId)
    }

    private func loadRecentHistoryForSession(from file: URL, sessionId: String) {
        let maxBytesToRead: UInt64 = 50 * 1024

        guard let handle = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? handle.close() }

        let fileSize = sessionReadPositions[sessionId] ?? handle.seekToEndOfFile()
        let startPosition = fileSize > maxBytesToRead ? fileSize - maxBytesToRead : 0
        handle.seek(toFileOffset: startPosition)

        guard var data = try? handle.read(upToCount: Int(fileSize - startPosition)) else { return }
        if startPosition > 0, let newline = data.firstIndex(of: 0x0A) {
            data.removeSubrange(...newline)
        }
        var buffer = JSONLLineBuffer()
        let linesToProcess = buffer.append(data).suffix(100)
        sessionLineBuffers[sessionId] = buffer

        isLoadingHistoryBySession[sessionId] = true
        for line in linesToProcess where !line.isEmpty {
            parseJSONLLine(line, sessionId: sessionId)
        }
        isLoadingHistoryBySession[sessionId] = false

        let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        if var sessionState = sessionStates[sessionId] {
            let isLive = modified.map { Date().timeIntervalSince($0) < 300 } == true
                && sessionState.lastUpdateTime.map { Date().timeIntervalSince($0) < 300 } == true
            if !isLive {
                sessionState.activeTools.removeAll()
                sessionState.isTurnInProgress = false
                sessionState.isThinking = false
                sessionState.pendingInputRequest = nil
                pendingFunctionCalls[sessionId]?.removeAll()
            }
            sessionStates[sessionId] = sessionState
            if selectedSession?.id == sessionId { state = sessionState }
        }
        resetIdleTimer()
    }

    private func readNewSessionData(sessionId: String) {
        guard let handle = sessionFileHandles[sessionId],
              let lastPosition = sessionReadPositions[sessionId] else { return }

        handle.seek(toFileOffset: lastPosition)
        let newData = handle.readDataToEndOfFile()
        sessionReadPositions[sessionId] = handle.offsetInFile

        guard !newData.isEmpty else { return }
        let lines = sessionLineBuffers[sessionId, default: JSONLLineBuffer()].append(newData)
        for line in lines {
            parseJSONLLine(line, sessionId: sessionId)
        }

        resetIdleTimer()
    }

    private func resetIdleTimer(after delay: TimeInterval? = nil) {
        idleCheckTimer?.invalidate()
        idleCheckTimer = Timer.scheduledTimer(withTimeInterval: delay ?? idleCheckDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.markAllSessionsIdle()
            }
        }
    }

    private func markAllSessionsIdle() {
        let now = Date()
        var nextCheck: TimeInterval?
        objectWillChange.send()
        for sessionId in sessionStates.keys {
            guard var sessionState = sessionStates[sessionId], sessionState.isActive,
                  sessionState.activeTools.isEmpty, sessionState.pendingInputRequest == nil else { continue }
            let remaining = 300 - now.timeIntervalSince(sessionState.lastUpdateTime ?? .distantPast)
            if remaining > 0 {
                nextCheck = min(nextCheck ?? remaining, remaining)
                continue
            }
            sessionState.isThinking = false
            sessionState.isTurnInProgress = false
            sessionStates[sessionId] = sessionState
        }
        if let id = selectedSession?.id, let sessionState = sessionStates[id] { state = sessionState }
        if let nextCheck { resetIdleTimer(after: nextCheck) }
    }

    // MARK: - JSONL Parsing

    private func parseJSONLLine(_ line: String, sessionId: String) {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        guard var sessionState = sessionStates[sessionId] else { return }

        let type = json["type"] as? String ?? ""
        let isLoadingHistory = isLoadingHistoryBySession[sessionId] == true
        let eventTimestamp = (json["timestamp"] as? String).flatMap {
            Self.iso8601Formatter.date(from: $0) ?? Self.plainISO8601Formatter.date(from: $0)
        } ?? (isLoadingHistory ? .distantPast : Date())
        // Resume/sync may append old records to a file being watched already.
        let ignoreActivity = (!isLoadingHistory && Date().timeIntervalSince(eventTimestamp) > staleLineAfter)
            || eventTimestamp < (sessionState.lastUpdateTime ?? .distantPast)

        switch type {
        case "session_meta":
            // Already parsed during session discovery
            break

        case "turn_context":
            if let payload = json["payload"] as? [String: Any] {
                if let model = payload["model"] as? String {
                    sessionState.model = model
                }
                if let cwd = payload["cwd"] as? String {
                    sessionState.cwd = cwd
                }
            }

        case "event_msg":
            if let payload = json["payload"] as? [String: Any] {
                if ignoreActivity, let eventType = payload["type"] as? String,
                   ["task_started", "task_complete", "turn_aborted", "agent_reasoning"].contains(eventType) { return }
                parseEventMsg(
                    payload,
                    sessionState: &sessionState,
                    sessionId: sessionId,
                    rateLimitTimestamp: eventTimestamp
                )
            }

        case "response_item":
            guard !ignoreActivity else { return }
            if let payload = json["payload"] as? [String: Any] {
                parseResponseItem(payload, sessionState: &sessionState, sessionId: sessionId, eventTimestamp: eventTimestamp)
            }

        default:
            break
        }

        sessionStates[sessionId] = sessionState

        // Sync to main state if selected
        if selectedSession?.id == sessionId {
            state = sessionState
        }

        objectWillChange.send()
    }

    private func parseEventMsg(
        _ payload: [String: Any],
        sessionState: inout CodexState,
        sessionId: String,
        rateLimitTimestamp: Date
    ) {
        guard let eventType = payload["type"] as? String else { return }

        // Imported Claude conversations use fresh write timestamps but synthetic turn ids.
        if let turnId = payload["turn_id"] as? String, turnId.hasPrefix("external-import-turn-") {
            if eventType == "task_started" {
                externalImportSessions.insert(sessionId)
            } else if eventType == "task_complete" || eventType == "turn_aborted" {
                externalImportSessions.remove(sessionId)
                // The bounded history read may start after the imported turn's start marker.
                if isLoadingHistoryBySession[sessionId] == true {
                    sessionState.isTurnInProgress = false
                    sessionState.isThinking = false
                    sessionState.activeTools.removeAll()
                    sessionState.pendingInputRequest = nil
                    pendingFunctionCalls[sessionId]?.removeAll()
                }
            }
            return
        }

        if ["task_started", "task_complete", "turn_aborted", "agent_reasoning"].contains(eventType) {
            sessionState.lastUpdateTime = rateLimitTimestamp
        }
        switch eventType {
        case "task_started":
            externalImportSessions.remove(sessionId)
            // Codex Desktop emits this at the beginning of a turn.
            sessionState.isThinking = true
            sessionState.isTurnInProgress = true

        case "task_complete", "turn_aborted":
            sessionState.isTurnInProgress = false
            sessionState.isThinking = false
            sessionState.activeTools.removeAll()
            if eventType == "turn_aborted" || sessionState.pendingInputRequest?.isAsync != true {
                sessionState.pendingInputRequest = nil
            }
            // A rejected turn reports usage_limit_exceeded here instead of
            // emitting a 100% token_count rate-limit snapshot.
            if let error = payload["error"] as? [String: Any],
               error["codex_error_info"] as? String == "usage_limit_exceeded" {
                markUsageLimitExceeded(at: rateLimitTimestamp)
            }
            // Aborted or rejected turns aren't done; replayed history isn't news.
            if eventType == "task_complete", payload["error"] == nil,
               isLoadingHistoryBySession[sessionId] != true {
                lastTurnCompletedAt = Date()
                let started = payload["started_at"] as? Double, completed = payload["completed_at"] as? Double
                lastCompletedTurn = CompletedTurn(sessionId: sessionId, answer: payload["last_agent_message"] as? String ?? "",
                                                  elapsed: started.flatMap { start in completed.map { $0 - start } })
            }

        case "token_count":
            if let info = payload["info"] as? [String: Any],
               let totalUsage = info["total_token_usage"] as? [String: Any] {
                sessionState.tokenUsage.inputTokens = totalUsage["input_tokens"] as? Int ?? 0
                sessionState.tokenUsage.cachedInputTokens = totalUsage["cached_input_tokens"] as? Int ?? 0
                sessionState.tokenUsage.outputTokens = totalUsage["output_tokens"] as? Int ?? 0
                sessionState.tokenUsage.reasoningOutputTokens = totalUsage["reasoning_output_tokens"] as? Int ?? 0
                sessionState.tokenUsage.totalTokens = totalUsage["total_tokens"] as? Int ?? 0

                if let lastUsage = info["last_token_usage"] as? [String: Any] {
                    sessionState.tokenUsage.contextTokens = lastUsage["total_tokens"] as? Int ?? 0
                }
                if let contextWindow = info["model_context_window"] as? Int {
                    sessionState.tokenUsage.modelContextWindow = contextWindow
                }

                debugLog("[Codex] Token update: in=\(sessionState.tokenUsage.inputTokens) out=\(sessionState.tokenUsage.outputTokens) total=\(sessionState.tokenUsage.totalTokens)")
            }

            if let rawRateLimits = payload["rate_limits"] as? [String: Any],
               rawRateLimits["limit_id"] as? String == "codex" {
                let parsed = parseRateLimits(rawRateLimits)
                if parsed.hasData {
                    mergeRateLimits(parsed, at: rateLimitTimestamp)
                }
            }

        case "agent_reasoning":
            sessionState.isTurnInProgress = true
            sessionState.isThinking = true
            if let text = payload["text"] as? String {
                sessionState.lastReasoningText = text
                debugLog("[Codex] Reasoning: \(text.prefix(50))...")
            }

        default:
            break
        }
    }

    private func markUsageLimitExceeded(at timestamp: Date) {
        guard timestamp >= primaryRateLimitUpdatedAt else { return }
        rateLimits.limitReached = true
        if let primary = rateLimits.primary {
            rateLimits.primary = CodexRateLimitWindow(
                usedPercent: 100,
                windowMinutes: primary.windowMinutes,
                resetsAt: primary.resetsAt
            )
            primaryRateLimitUpdatedAt = timestamp
        } else if let secondary = rateLimits.secondary {
            rateLimits.secondary = CodexRateLimitWindow(
                usedPercent: 100,
                windowMinutes: secondary.windowMinutes,
                resetsAt: secondary.resetsAt
            )
            secondaryRateLimitUpdatedAt = timestamp
        }
    }

    private func parseResponseItem(_ payload: [String: Any], sessionState: inout CodexState, sessionId: String, eventTimestamp: Date) {
        guard let itemType = payload["type"] as? String else { return }

        // Keep the last prompt as the session hint, including while importing history.
        if itemType == "message", payload["role"] as? String == "user" {
            var prompt = (payload["content"] as? [[String: Any]] ?? [])
                .compactMap { $0["text"] as? String }
                .joined()
            if var request = sessionState.pendingInputRequest, request.isAsync,
               let start = prompt.range(of: "<send_user_message_question_reply>"),
               let end = prompt.range(of: "</send_user_message_question_reply>", range: start.upperBound..<prompt.endIndex),
               let data = String(prompt[start.upperBound..<end.lowerBound]).data(using: .utf8),
               let replies = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                for reply in replies {
                    guard let itemId = reply["questionItemId"] as? String,
                          let itemData = itemId.data(using: .utf8),
                          let parts = try? JSONSerialization.jsonObject(with: itemData) as? [Any],
                          parts.count == 3, parts[0] as? String == "request_user_input_async",
                          parts[1] as? String == request.id, let index = parts[2] as? Int,
                          request.questions.indices.contains(index) else { continue }
                    request.answeredQuestionIndices.insert(index)
                }
                sessionState.pendingInputRequest = request.questions.indices.allSatisfy(request.answeredQuestionIndices.contains)
                    ? nil : request
            }
            if let heading = prompt.range(of: "\n## My request") {
                prompt = String(prompt[heading.upperBound...].drop { $0 != "\n" })
            }
            prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !prompt.isEmpty, !prompt.hasPrefix("<"), !prompt.hasPrefix("#") {
                sessionState.lastUserPrompt = prompt
                // A normal chat reply answers or supersedes the previous async question.
                if sessionState.pendingInputRequest?.isAsync == true {
                    sessionState.pendingInputRequest = nil
                }
            }
        }
        guard !externalImportSessions.contains(sessionId) else { return }

        if ["function_call", "custom_tool_call", "function_call_output", "custom_tool_call_output", "reasoning", "message"].contains(itemType) {
            sessionState.lastUpdateTime = eventTimestamp
        }
        switch itemType {
        case "function_call", "custom_tool_call":
            sessionState.isTurnInProgress = true
            sessionState.isThinking = false

            guard let callId = payload["call_id"] as? String,
                  let name = payload["name"] as? String else { return }

            // CLI sessions use `arguments`; Codex Desktop uses `input`.
            let argumentsJson = payload["arguments"] as? String
                ?? payload["input"] as? String
                ?? ""
            var argument: String?
            var workdir: String?

            // Parse arguments JSON to extract useful info
            if let argsData = argumentsJson.data(using: .utf8),
               let args = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any] {
                if let command = args["command"] as? String {
                    argument = String(command.prefix(80))
                } else if let content = args["content"] as? String {
                    argument = String(content.prefix(80))
                } else if let path = args["path"] as? String {
                    argument = URL(fileURLWithPath: path).lastPathComponent
                }
                workdir = args["workdir"] as? String
            } else if !argumentsJson.isEmpty {
                // Codex Desktop custom tools may store plain-text input instead
                // of a JSON argument object.
                argument = String(argumentsJson.prefix(80))
            }

            var tool = CodexToolExecution(
                id: callId,
                toolName: name,
                argument: argument,
                startTime: eventTimestamp
            )
            tool.workdir = workdir
            // apply_patch arrives on its own or inside an `exec` script.
            tool.change = ToolChange.patch(argumentsJson)

            if !sessionState.activeTools.contains(where: { $0.id == callId }) {
                debugLog("[Codex] Tool started: \(name) (id: \(callId.prefix(8))...) arg: \(argument ?? "-")")
                sessionState.activeTools.append(tool)
                pendingFunctionCalls[sessionId, default: [:]][callId] = eventTimestamp
            }

            if ["request_user_input", "request_user_input_async"].contains(name),
               !dismissedInputRequestIDs.contains(callId),
               let request = parseInputRequest(argumentsJson, callId: callId, isAsync: name == "request_user_input_async") {
                sessionState.pendingInputRequest = request
            }

        case "function_call_output", "custom_tool_call_output":
            guard let callId = payload["call_id"] as? String else { return }

            if sessionState.pendingInputRequest?.id == callId {
                let output = (payload["output"] as? String)?.data(using: .utf8)
                let result = output.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                if sessionState.pendingInputRequest?.isAsync != true || result?["accepted"] as? Bool != true {
                    sessionState.pendingInputRequest = nil
                }
            }

            pendingFunctionCalls[sessionId]?.removeValue(forKey: callId)

            if let index = sessionState.activeTools.firstIndex(where: { $0.id == callId }) {
                var tool = sessionState.activeTools.remove(at: index)
                tool.endTime = eventTimestamp

                // Parse output for exit code
                if let output = payload["output"] as? String {
                    tool.output = String(output.prefix(200))
                    if output.hasPrefix("Exit code: ") {
                        let codeStr = output.dropFirst("Exit code: ".count).prefix(while: { $0.isNumber })
                        tool.exitCode = Int(codeStr)
                    }
                }

                debugLog("[Codex] Tool completed: \(tool.toolName) (id: \(callId.prefix(8))...) duration: \(tool.formattedDuration)")

                sessionState.recentTools.insert(tool, at: 0)
                if sessionState.recentTools.count > 10 {
                    sessionState.recentTools.removeLast()
                }
            }

            // After tool completes, model is likely thinking again
            sessionState.isTurnInProgress = true
            sessionState.isThinking = true

        case "reasoning":
            // Current Codex Desktop records reasoning as a response item rather
            // than the legacy event_msg.agent_reasoning event.
            sessionState.isTurnInProgress = true
            sessionState.isThinking = true

        case "message":
            if let role = payload["role"] as? String {
                if role == "user" {
                    // User message = start of turn
                    sessionState.isTurnInProgress = true
                    sessionState.isThinking = true
                } else if role == "assistant" {
                    // Codex Desktop writes in-progress commentary as assistant
                    // output_text. It is not the final answer.
                    if payload["phase"] as? String == "commentary" {
                        sessionState.isTurnInProgress = true
                        sessionState.isThinking = true
                        return
                    }

                    // Assistant message with content
                    if let content = payload["content"] as? [[String: Any]] {
                        for item in content {
                            if let type = item["type"] as? String {
                                if type == "output_text" || type == "text" {
                                    // Final text output - done thinking
                                    sessionState.isThinking = false
                                    sessionState.isTurnInProgress = false
                                    sessionState.activeTools.removeAll()
                                    if sessionState.pendingInputRequest?.isAsync != true {
                                        sessionState.pendingInputRequest = nil
                                    }
                                    pendingFunctionCalls[sessionId]?.removeAll()
                                }
                            }
                        }
                    }
                }
            }

        default:
            break
        }
    }

    private func parseInputRequest(_ input: String, callId: String, isAsync: Bool = false) -> CodexInputRequest? {
        guard let data = input.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawQuestions = object["questions"] as? [[String: Any]] else { return nil }

        let questions = rawQuestions.compactMap { rawQuestion -> AgentInputQuestion? in
            guard let question = rawQuestion["question"] as? String ?? rawQuestion["title"] as? String else { return nil }
            let options = (rawQuestion["options"] as? [String])?.map {
                AgentInputOption(label: $0, description: "")
            } ?? (rawQuestion["options"] as? [[String: Any]] ?? []).compactMap { rawOption -> AgentInputOption? in
                guard let label = rawOption["label"] as? String else { return nil }
                return AgentInputOption(
                    label: label,
                    description: rawOption["description"] as? String ?? ""
                )
            }
            return AgentInputQuestion(
                header: rawQuestion["header"] as? String ?? "Question",
                question: question,
                options: options
            )
        }

        guard !questions.isEmpty else { return nil }
        return CodexInputRequest(id: callId, questions: questions, isAsync: isAsync)
    }

    private func parseRateLimits(_ raw: [String: Any]) -> CodexRateLimits {
        let windows = [
            parseRateLimitWindow(raw["primary"] as? [String: Any]),
            parseRateLimitWindow(raw["secondary"] as? [String: Any])
        ].compactMap { $0 }

        // The primary/secondary keys are not stable meanings. Classify by the
        // actual rolling-window length instead (300m = 5h, 10080m = 7d).
        return CodexRateLimits(
            primary: windows.first(where: { $0.windowMinutes < 1_440 }),
            secondary: windows.first(where: { $0.windowMinutes >= 1_440 }),
            planType: raw["plan_type"] as? String
        )
    }

    private func parseRateLimitWindow(_ raw: [String: Any]?) -> CodexRateLimitWindow? {
        guard let raw,
              let usedPercent = (raw["used_percent"] as? NSNumber)?.doubleValue,
              let windowMinutes = (raw["window_minutes"] as? NSNumber)?.intValue else { return nil }

        let resetsAt = (raw["resets_at"] as? NSNumber).map {
            Date(timeIntervalSince1970: $0.doubleValue)
        }
        return CodexRateLimitWindow(
            usedPercent: usedPercent,
            windowMinutes: windowMinutes,
            resetsAt: resetsAt
        )
    }

    /// The same account-wide quota can be reported by several Codex sessions.
    /// JSONL's event timestamp—not file modification order or the percentage—is
    /// authoritative, because utilization may decrease after a rolling reset.
    private func mergeRateLimits(_ incoming: CodexRateLimits, at timestamp: Date) {
        var merged = rateLimits

        // Each snapshot is the whole account state, so a window missing from a newer one
        // no longer exists (e.g. Plus → Pro drops the 5h window) rather than being unknown.
        if timestamp >= primaryRateLimitUpdatedAt {
            merged.primary = incoming.primary
            primaryRateLimitUpdatedAt = timestamp
        }
        if timestamp >= secondaryRateLimitUpdatedAt {
            merged.secondary = incoming.secondary
            secondaryRateLimitUpdatedAt = timestamp
        }
        merged.planType = incoming.planType ?? merged.planType
        rateLimits = merged
    }

    private func loadLatestRateLimits(from file: URL) {
        let maximumBytes: UInt64 = 256 * 1024
        guard let handle = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? handle.close() }

        let fileSize = handle.seekToEndOfFile()
        handle.seek(toFileOffset: fileSize > maximumBytes ? fileSize - maximumBytes : 0)
        guard let data = try? handle.readToEnd(),
              let content = String(data: data, encoding: .utf8) else { return }

        for line in content.components(separatedBy: .newlines).reversed() {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  json["type"] as? String == "event_msg",
                  let payload = json["payload"] as? [String: Any] else { continue }
            let timestamp = (json["timestamp"] as? String).flatMap {
                Self.iso8601Formatter.date(from: $0)
            } ?? .distantPast

            if payload["type"] as? String == "task_complete",
               let error = payload["error"] as? [String: Any],
               error["codex_error_info"] as? String == "usage_limit_exceeded" {
                markUsageLimitExceeded(at: timestamp)
                continue
            }

            guard payload["type"] as? String == "token_count",
                  let rawRateLimits = payload["rate_limits"] as? [String: Any],
                  rawRateLimits["limit_id"] as? String == "codex" else { continue }

            let parsed = parseRateLimits(rawRateLimits)
            if parsed.hasData {
                mergeRateLimits(parsed, at: timestamp)
            }
        }
    }

    // MARK: - Cleanup

    func stopWatching() {
        sessionScanTimer?.invalidate()
        sessionScanTimer = nil
        rateLimitRefreshTimer?.invalidate()
        rateLimitRefreshTimer = nil
        nextRateLimitRefreshAt = nil
        rateLimitProcess?.terminate()
        rateLimitProcess = nil
        isRefreshingRateLimits = false
        idleCheckTimer?.invalidate()
        idleCheckTimer = nil

        for sessionId in Array(sessionWatchers.keys) {
            stopWatchingSession(id: sessionId)
        }
    }
}

// MARK: - Demo

extension CodexManager {
    /// `--demo`: every session comes from `DemoDriver` instead of a rollout file.
    func demoApply(sessions: [CodexSession], states: [String: CodexState], rateLimits: CodexRateLimits) {
        availableSessions = sessions
        sessionStates = states
        selectedSession = sessions.first
        state = sessions.first.flatMap { states[$0.id] } ?? CodexState()
        self.rateLimits = rateLimits
    }

    func demoComplete(_ turn: CompletedTurn) {
        lastCompletedTurn = turn
        lastTurnCompletedAt = Date()
    }
}
