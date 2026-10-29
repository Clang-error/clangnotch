//
//  ClaudeCodeManager.swift
//  ClangNotch
//
//  Created for Claude Code JSONL session integration
//

import Foundation
import Combine
import AppKit

// MARK: - Debug Logging (disabled in Release builds)

/// Debug-only logging function - prints only in DEBUG builds to save CPU in production
@inline(__always)
func debugLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    print(message())
    #endif
}

@MainActor
final class ClaudeCodeManager: ObservableObject {
    static let shared = ClaudeCodeManager()

    // MARK: - Published Properties

    @Published private(set) var availableSessions: [ClaudeSession] = []
    @Published var selectedSession: ClaudeSession?
    @Published private(set) var state: ClaudeCodeState = ClaudeCodeState()

    // MARK: - Multi-Session Permission Tracking

    /// Per-session state tracking for permission detection
    @Published private(set) var sessionStates: [String: ClaudeCodeState] = [:] {
        didSet {
            for (id, newState) in sessionStates {
                let oldConfirmed = oldValue[id]?.needsPermissionConfirmed ?? false
                let oldNeeds = oldValue[id]?.needsPermission ?? false
                if newState.needsPermissionConfirmed != oldConfirmed || newState.needsPermission != oldNeeds {
                    let stack = Thread.callStackSymbols.prefix(8).joined(separator: "\n    ")
                    debugLog("[ClaudeCode] [\(Date())] STATE CHANGE \(id.prefix(30))... needsPermission \(oldNeeds)->\(newState.needsPermission) confirmed \(oldConfirmed)->\(newState.needsPermissionConfirmed)\n    \(stack)")
                }
            }
        }
    }

    /// Sessions currently waiting for user permission approval
    @Published private(set) var sessionsNeedingPermission: [ClaudeSession] = []

    /// Tool approval requests confirmed via Claude Code's Notification hook.
    /// Questions are tracked separately in `pendingInputRequests`.
    @Published private(set) var sessionsConfirmedNeedingPermission: [ClaudeSession] = []

    /// The last turn any session finished normally (end_turn); drives the closed-notch Done and the 완료 드롭다운.
    @Published private(set) var lastCompletedTurn: CompletedTurn?

    var sessionsAwaitingInput: [ClaudeSession] {
        availableSessions.filter { sessionStates[$0.id]?.isAwaitingInput == true }
    }

    var pendingInputRequests: [ClaudeInputRequest] {
        availableSessions.flatMap { sessionStates[$0.id]?.pendingInputRequests ?? [] }
    }

    /// Track when we last had activity (for grace period before notch collapses)
    private var lastActivityTime: Date = Date.distantPast
    /// Grace period to keep notch visible after activity stops (seconds)
    private let activityGracePeriod: TimeInterval = 1.0

    /// True if any session has activity (thinking, active tools, or needs permission)
    var hasAnySessionActivity: Bool {
        for sessionState in sessionStates.values {
            if sessionState.isActive || sessionState.needsPermission || sessionState.isAwaitingInput {
                lastActivityTime = Date()
                return true
            }
        }
        if state.isActive || state.needsPermission || state.isAwaitingInput {
            lastActivityTime = Date()
            return true
        }
        if !sessionsNeedingPermission.isEmpty {
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

    private let claudeDir: URL = {
        if let pw = getpwuid(getuid()), let home = pw.pointee.pw_dir {
            let homePath = String(cString: home)
            return URL(fileURLWithPath: homePath).appendingPathComponent(".claude")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }()
    private var ideDir: URL { claudeDir.appendingPathComponent("ide") }
    private var projectsDir: URL { claudeDir.appendingPathComponent("projects") }

    private var sessionScanTimer: Timer?

    /// Cap only idle recent sessions; working and waiting sessions are always retained.
    private let maxRetainedSessions = 5

    /// Watcher on the top-level projects dir (detects new project folders)
    private var projectsDirWatcher: DispatchSourceFileSystemObject?
    /// Watchers on each project subdir (detects new session JSONL files instantly)
    private var projectDirWatchers: [String: DispatchSourceFileSystemObject] = [:]

    /// The only tool whose in-flight presence *is* a wait on the user. Everything else
    /// (Bash, Task, WebFetch, mcp__*) looks identical in the JSONL whether it's blocked on
    /// a permission prompt or merely slow, so those are left entirely to the `permission_prompt`
    /// Notification hook (see `handleNotificationHook`) rather than guessed from timing.
    private let questionToolName = "AskUserQuestion"
    private let wrapUpToolName = "mcp__ccd_turn__wrap_up"
    /// How recently a transcript must have been written for a question found during history
    /// load to count as still waiting (seconds).
    private let questionWaitStaleAfter: TimeInterval = 300
    /// A message line older than this is history, not activity. Claude Code re-appends old
    /// lines (resume/sync) with their original timestamps; treating those as "thinking now"
    /// produced ghost sessions that revived every time the file was touched (2026-09-22).
    private let staleLineAfter: TimeInterval = 120
    private static let lineTimestampFormatters: [ISO8601DateFormatter] = {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return [fractional, plain]
    }()

    // MARK: - Multi-Session Watching

    private var sessionWatchers: [String: DispatchSourceFileSystemObject] = [:]
    private var sessionFileHandles: [String: FileHandle] = [:]
    private var sessionReadPositions: [String: UInt64] = [:]
    private var sessionLineBuffers: [String: JSONLLineBuffer] = [:]
    /// Maps a watched session's id to the absolute path of the JSONL file it's tailing,
    /// so a Notification-hook payload (which carries `transcript_path`) can be matched
    /// back to the right session. See `handleNotificationHook`.
    private var sessionJSONLPaths: [String: String] = [:]
    /// Answer hooks can arrive before the matching JSONL tool_use is written.
    private var completedQuestionHookIDs: [String: Set<String>] = [:]
    /// The end_turn message last announced per session; its lines all repeat the stop reason.
    private var completedTurnMessageIDs: [String: String] = [:]
    /// Next-step boxes closed with the 다음 단계 드롭다운's X, so a history reload can't bring them back.
    private var dismissedInputRequestIDs: Set<String> = []
    private var isLoadingHistoryBySession: [String: Bool] = [:]

    /// Sessions running on SSH hosts, keyed by Claude's own session id. They have no JSONL
    /// here; `handleRemoteHook` creates and updates them from forwarded hook events.
    private var remoteSessions: [String: ClaudeSession] = [:]

    /// Conversation ids seen held by a running process in Claude Code's session registry.
    private var seenLiveConversationIds: Set<String> = []
    /// Real `cwd` read from each transcript's head (it never changes for a file).
    private var cwdByFile: [String: String] = [:]
    /// A session must be this quiet before a missing registry record ends it, so a new or
    /// /clear'd session isn't ended in the moment before its record is rewritten.
    private let endedSessionGrace: TimeInterval = 30
    /// A working session must be this quiet before its registry status is consulted; the
    /// record is rewritten within moments of a turn starting.
    private let idleStatusGrace: TimeInterval = 10

    /// Timer to detect idle state (for thinking)
    private var idleCheckTimer: Timer?
    /// Initial idle check; an active turn reschedules this once at its expiry.
    private let idleCheckDelay: TimeInterval = 1.0

    /// Timer to re-evaluate quiet activity after a tool starts.
    private var toolIdleTimer: Timer?
    /// Tool execution itself remains active until its result arrives.
    private let toolIdleDelay: TimeInterval = 4.0

    /// Silence limit since the latest meaningful activity, unless a tool/question is pending.
    private let turnSafetyTimeout: TimeInterval = 300.0

    // MARK: - Initialization

    private init() {
        debugLog("[ClaudeCode] ========================================")
        debugLog("[ClaudeCode] ClaudeCodeManager initializing...")
        debugLog("[ClaudeCode] Claude dir: \(claudeDir.path)")
        debugLog("[ClaudeCode] IDE dir: \(ideDir.path)")
        debugLog("[ClaudeCode] Projects dir: \(projectsDir.path)")
        debugLog("[ClaudeCode] ========================================")
        startSessionScanning()
    }

    // MARK: - Public Methods

    /// Scan for active Claude Code sessions
    func scanForSessions() {
        let fm = FileManager.default
        var sessions: [ClaudeSession] = []

        debugLog("[ClaudeCode] Scanning for sessions...")

        clearEndedSessions()
        let recentThreshold = Date().addingTimeInterval(-300)

        // First try IDE lock files (for VS Code/Cursor extensions)
        if fm.fileExists(atPath: ideDir.path) {
            debugLog("[ClaudeCode] Checking IDE dir: \(ideDir.path)")

            do {
                let allFiles = try fm.contentsOfDirectory(at: ideDir, includingPropertiesForKeys: nil)
                let lockFiles = allFiles.filter { $0.pathExtension == "lock" }
                debugLog("[ClaudeCode] Found \(lockFiles.count) IDE lock files")

                for lockFile in lockFiles {
                    guard let data = fm.contents(atPath: lockFile.path) else { continue }

                    do {
                        let session = try JSONDecoder().decode(ClaudeSession.self, from: data)
                        if isProcessRunning(pid: session.pid) {
                            debugLog("[ClaudeCode] IDE session: \(session.displayName) (pid \(session.pid))")
                            sessions.append(session)
                        }
                    } catch {
                        debugLog("[ClaudeCode] Failed to decode lock file: \(error)")
                    }
                }
            } catch {
                debugLog("[ClaudeCode] Error reading IDE dir: \(error)")
            }
        } else {
            debugLog("[ClaudeCode] No IDE dir - checking for terminal sessions")
        }

        // Also discover from recently active project JSONL files (terminal sessions)
        if fm.fileExists(atPath: projectsDir.path) {
            debugLog("[ClaudeCode] Scanning projects dir for active terminal sessions...")

            do {
                let projectDirs = try fm.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: [.contentModificationDateKey])
                    .filter { url in
                        var isDir: ObjCBool = false
                        return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
                    }

                // Projects already represented by an IDE lock session (same underlying
                // JSONL). Skip them here so one session isn't shown twice — once as an
                // IDE row and once as a terminal row.
                let ideProjectKeys = Set(sessions.compactMap { $0.projectKey })

                // One synthetic session per recent JSONL. Several Claude sessions often share
                // a folder; picking only the newest file hid the others — including one that
                // stopped writing because it waits on a permission prompt. Files that went
                // quiet are kept only while their session is still working or waiting.
                for projectDir in projectDirs {
                    if ideProjectKeys.contains(projectDir.lastPathComponent) {
                        debugLog("[ClaudeCode] Skipping terminal scan for \(projectDir.lastPathComponent) (covered by IDE session)")
                        continue
                    }

                    // Keep the lossy dir-name decoding for `workspaceFolders` so the
                    // project-key round-trips back to the same directory for file lookup.
                    let workspacePath = projectDir.lastPathComponent
                        .replacingOccurrences(of: "-", with: "/")

                    for jsonlFile in findActiveSessionFiles(in: projectDir) {
                        let sessionId = jsonlFile.deletingPathExtension().lastPathComponent
                        var session = ClaudeSession(
                            pid: 0,  // Terminal sessions don't have a single PID
                            workspaceFolders: ["\(workspacePath)#\(sessionId)"],
                            ideName: "Terminal",
                            transport: nil,
                            runningInWindows: nil
                        )
                        let modified = (try? jsonlFile.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                        guard modified > recentThreshold
                                || sessionStates[session.id].map({ $0.isActive || $0.needsPermission || $0.isAwaitingInput }) == true
                        else { continue }

                        // Real path from the JSONL `cwd` field (the dir-name encoding is
                        // lossy: e.g. "-Users-clang-error" can't tell "_" from "/"). A new
                        // file may not have its first `cwd` line yet, so only hits are cached.
                        if let cwd = cwdByFile[jsonlFile.path] ?? extractCwd(from: jsonlFile) {
                            cwdByFile[jsonlFile.path] = cwd
                            session.cwd = cwd
                        }
                        debugLog("[ClaudeCode] Terminal session: \(session.displayName) [id: \(sessionId.prefix(8))...]")
                        sessions.append(session)
                    }
                }
            } catch {
                debugLog("[ClaudeCode] Error scanning projects: \(error)")
            }
        }

        sessions.append(contentsOf: remoteSessions.values)

        // Keep working/waiting sessions and five minutes of idle activity.
        var activity: [String: Date] = [:]
        for s in sessions { activity[s.id] = lastActivityDate(for: s) }
        let ranked = sessions.sorted { (activity[$0.id] ?? .distantPast) > (activity[$1.id] ?? .distantPast) }
        var retainedIdleCount = 0
        sessions = ranked.filter { session in
            if let state = sessionStates[session.id], state.isActive || state.needsPermission || state.isAwaitingInput {
                return true
            }
            guard (activity[session.id] ?? .distantPast) > recentThreshold,
                  retainedIdleCount < maxRetainedSessions else { return false }
            retainedIdleCount += 1
            return true
        }

        let retainedIds = Set(sessions.map { $0.id })
        for (conversationId, remote) in remoteSessions where !retainedIds.contains(remote.id) {
            remoteSessions.removeValue(forKey: conversationId)
            sessionStates.removeValue(forKey: remote.id)
        }

        debugLog("[ClaudeCode] Total sessions found: \(sessions.count)")
        // A rescan that found the same sessions must not publish and rebuild the notch.
        if availableSessions != sessions { availableSessions = sessions }

        if let selected = selectedSession {
            if let current = sessions.first(where: { $0.id == selected.id }) {
                // Sessions are rebuilt each scan; keep the fresh copy, whose `cwd` may
                // only have become readable now.
                if current != selected { selectedSession = current }
            } else {
                selectedSession = nil
                state = ClaudeCodeState()
            }
        }

        // Watch ALL sessions for permission detection
        let currentSessionIds = Set(sessions.map { $0.id })

        var startedWatching = false
        for session in sessions where session.remoteHost == nil {
            if sessionWatchers[session.id] == nil {
                startWatchingSession(session)
                startedWatching = true
            }
        }
        // Note which new sessions are live when first seen, so a later exit can be told
        // apart from a host that never registers (see `clearEndedSessions`).
        if startedWatching, let live = liveSessionRecords() {
            seenLiveConversationIds.formUnion(live.keys)
        }

        let watchedIds = Array(sessionWatchers.keys)
        for watchedId in watchedIds where !currentSessionIds.contains(watchedId) {
            stopWatchingSession(id: watchedId)
        }

        followActiveSession()
    }

    /// The open notch's details (todos, context, tokens) show `selectedSession`. Keep the
    /// user's pick while it is working; otherwise follow the newest working session, so the
    /// details are neither blank nor stuck on a session that went quiet long ago.
    private func followActiveSession() {
        let isWorking = { (session: ClaudeSession) in
            self.sessionStates[session.id].map { $0.isActive || $0.needsPermission || $0.isAwaitingInput } ?? false
        }
        if let selected = selectedSession, isWorking(selected) { return }
        if let working = availableSessions.first(where: isWorking) {
            selectSession(working)
        } else if selectedSession == nil, let newest = availableSessions.first {
            selectSession(newest)
        }
    }

    /// Select a session to monitor
    func selectSession(_ session: ClaudeSession) {
        guard session != selectedSession else { return }

        debugLog("[ClaudeCode] Selecting session: \(session.displayName)")
        selectedSession = session
        if let sessionState = sessionStates[session.id] {
            state = sessionState
        } else {
            state = ClaudeCodeState()
            // `workspacePath`, not the raw folder: a terminal session's is "path#sessionId".
            state.cwd = session.workspacePath ?? ""
        }
    }

    /// Manually refresh state
    func refresh() {
        scanForSessions()
        if let selected = selectedSession {
            readNewSessionDataForSession(sessionId: selected.id)
        }
    }

    /// Bring the IDE running Claude Code to the front
    func focusIDE(for session: ClaudeSession? = nil) {
        guard let targetSession = session ?? selectedSession else {
            debugLog("[ClaudeCode] No session to focus")
            return
        }

        let entrypoint = sessionStates[targetSession.id]?.entrypoint ?? .unknown
        if let destination = SessionAppDestination.claude(entrypoint: entrypoint, ideName: targetSession.ideName) {
            // A CLI session started in a Warp tab goes back to that exact tab; anywhere else
            // (or when its process can't be found) the terminal app just comes forward.
            if destination == .terminal,
               let conversationId = conversationId(for: targetSession),
               let pid = liveSessionRecords()?[conversationId]?.pid,
               let url = SessionAppResolver.warpFocusURL(pid: pid_t(pid)) {
                NSWorkspace.shared.open(url)
                return
            }
            SessionAppLauncher.open(destination)
            return
        }
        // Preserve support for unrecognised IDEs with a known application PID.
        if let app = NSRunningApplication(processIdentifier: pid_t(targetSession.pid)) {
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }

    // MARK: - Session Scanning

    private func startSessionScanning() {
        // The demo never reads real transcripts or touches ~/.claude/settings.json.
        guard !DemoMode.isActive else { return }
        if AppSettings.shared.enableClaudeCodeJSONL,
           let port = UInt16(exactly: AppSettings.shared.hookPort) {
            do {
                try ClaudeQuestionHooks.install(in: claudeDir, port: port)
            } catch {
                debugLog("[ClaudeCode] Could not install question hooks: \(error.localizedDescription)")
            }
            do {
                try PermissionHooks.install(in: claudeDir.appendingPathComponent("settings.json"), port: port, maxTime: 600)
            } catch {
                debugLog("[ClaudeCode] Could not install permission hook: \(error.localizedDescription)")
            }
            do {
                try StatuslineBridge.install(in: claudeDir.appendingPathComponent("settings.json"), port: port)
            } catch {
                debugLog("[ClaudeCode] Could not wrap the status line: \(error.localizedDescription)")
            }
        }
        scanForSessions()
        startWatchingProjectsDirectory()
        // Folder-watcher catches NEW session files instantly, but appends to a pre-existing
        // (resumed) session file don't fire a directory vnode — so this poll is what picks up
        // resumed/dormant sessions. Kept short (3s) so that lag stays small.
        sessionScanTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.scanForSessions()
            }
        }
    }

    // MARK: - Directory Watching (instant new-session detection)

    /// Watch the projects dir + every project subdir so new sessions are picked up
    /// immediately instead of waiting for the 10s scan tick.
    private func startWatchingProjectsDirectory() {
        refreshProjectDirWatchers()

        guard projectsDirWatcher == nil else { return }
        let fd = open(projectsDir.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.scanForSessions()
            self.refreshProjectDirWatchers()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        projectsDirWatcher = source
    }

    /// Attach a watcher to every project subdir not already watched. A new .jsonl file
    /// inside a subdir fires the subdir's vnode, triggering an immediate scan.
    private func refreshProjectDirWatchers() {
        let fm = FileManager.default
        guard let subdirs = try? fm.contentsOfDirectory(
            at: projectsDir,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }

        for dir in subdirs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let key = dir.path
            guard projectDirWatchers[key] == nil else { continue }

            let fd = open(dir.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .extend],
                queue: .main
            )
            source.setEventHandler { [weak self] in
                self?.scanForSessions()
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            projectDirWatchers[key] = source
        }
    }

    private func stopWatchingProjectsDirectory() {
        projectsDirWatcher?.cancel()
        projectsDirWatcher = nil
        for (_, source) in projectDirWatchers {
            source.cancel()
        }
        projectDirWatchers.removeAll()
    }

    private func isProcessRunning(pid: Int) -> Bool {
        let runningApps = NSWorkspace.shared.runningApplications
        if runningApps.contains(where: { $0.processIdentifier == Int32(pid) }) {
            return true
        }

        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, Int32(pid)]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        let result = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
        return result == 0 && size > 0
    }

    private func stopWatching() {
        sessionScanTimer?.invalidate()
        sessionScanTimer = nil
        idleCheckTimer?.invalidate()
        idleCheckTimer = nil
        toolIdleTimer?.invalidate()
        toolIdleTimer = nil
        stopWatchingProjectsDirectory()

        for sessionId in sessionWatchers.keys {
            stopWatchingSession(id: sessionId)
        }
    }

    // MARK: - Multi-Session Watching

    /// Claude Code's own session UUID (the tailed JSONL's file name), as used by `claude --resume`.
    /// The watched session a hook's `transcript_path` belongs to.
    func sessionId(forTranscript path: String) -> String? {
        sessionJSONLPaths.first(where: { $0.value == path })?.key
    }

    func conversationId(for session: ClaudeSession) -> String? {
        session.terminalSessionId ?? sessionJSONLPaths[session.id].map {
            URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent
        }
    }

    private func startWatchingSession(_ session: ClaudeSession) {
        debugLog("[ClaudeCode] startWatchingSession: \(session.displayName)")
        guard sessionWatchers[session.id] == nil else {
            debugLog("[ClaudeCode]   - Already watching")
            return
        }

        // Try to find the project directory
        var projectDir: URL?
        var jsonlFile: URL?

        // First try direct projectKey match
        if let projectKey = session.projectKey {
            debugLog("[ClaudeCode]   - Project key: \(projectKey)")
            let directPath = projectsDir.appendingPathComponent(projectKey)

            // For terminal sessions, use the specific session file
            if let terminalId = session.terminalSessionId {
                let specificFile = directPath.appendingPathComponent("\(terminalId).jsonl")
                if FileManager.default.fileExists(atPath: specificFile.path) {
                    projectDir = directPath
                    jsonlFile = specificFile
                    debugLog("[ClaudeCode]   - Found terminal session file: \(terminalId).jsonl")
                }
            } else if let file = findActiveSessionFiles(in: directPath).first {
                projectDir = directPath
                jsonlFile = file
                debugLog("[ClaudeCode]   - Found via direct match: \(directPath.path)")
            }
        }

        // Fallback: scan all project directories for a match
        if jsonlFile == nil, let workspace = session.workspaceFolders.first {
            debugLog("[ClaudeCode]   - Direct match failed, scanning all projects...")
            let fm = FileManager.default

            // Strip session fragment for comparison
            let cleanWorkspace = workspace.components(separatedBy: "#").first ?? workspace
            let normalizedWorkspace = cleanWorkspace.lowercased()

            if let projectDirs = try? fm.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: nil) {
                // Look for directory that matches the workspace path
                for dir in projectDirs {
                    // Convert dir name back to path: "-Users-foo-project" -> "/Users/foo/project"
                    let dirName = dir.lastPathComponent
                    let dirPath = dirName.replacingOccurrences(of: "-", with: "/")
                    // Handle leading dash correctly (absolute paths start with /)
                    let normalizedDirPath = dirPath.hasPrefix("/") ? dirPath : "/" + dirPath
                    if normalizedDirPath.lowercased() == normalizedWorkspace {
                        // For terminal sessions, use the specific session file
                        if let terminalId = session.terminalSessionId {
                            let specificFile = dir.appendingPathComponent("\(terminalId).jsonl")
                            if fm.fileExists(atPath: specificFile.path) {
                                projectDir = dir
                                jsonlFile = specificFile
                                debugLog("[ClaudeCode]   - Found terminal session via scan: \(terminalId).jsonl")
                                break
                            }
                        } else if let file = findActiveSessionFiles(in: dir).first {
                            projectDir = dir
                            jsonlFile = file
                            debugLog("[ClaudeCode]   - Found via scan: \(dir.path)")
                            break
                        }
                    }
                }
            }
        }

        guard let jsonlFile = jsonlFile else {
            debugLog("[ClaudeCode]   - No JSONL file found!")
            return
        }

        debugLog("[ClaudeCode]   - Found JSONL: \(jsonlFile.lastPathComponent)")

        var sessionState = ClaudeCodeState()
        sessionState.cwd = session.workspacePath ?? ""
        sessionState.isConnected = true
        sessionStates[session.id] = sessionState

        do {
            let handle = try FileHandle(forReadingFrom: jsonlFile)
            handle.seekToEndOfFile()
            sessionFileHandles[session.id] = handle
            sessionReadPositions[session.id] = handle.offsetInFile
            sessionJSONLPaths[session.id] = jsonlFile.path
            loadRecentHistoryForSession(from: jsonlFile, sessionId: session.id)
        } catch {
            return
        }

        let fd = open(jsonlFile.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend],
            queue: .main
        )

        source.setEventHandler { [weak self] in
            self?.readNewSessionDataForSession(sessionId: session.id)
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
        sessionWatchers[session.id] = source
        readNewSessionDataForSession(sessionId: session.id)
    }

    private func stopWatchingSession(id sessionId: String) {
        debugLog("[ClaudeCode] [\(Date())] stopWatchingSession: \(sessionId.prefix(8))...")
        sessionWatchers[sessionId]?.cancel()
        sessionWatchers.removeValue(forKey: sessionId)
        sessionFileHandles[sessionId]?.closeFile()
        sessionFileHandles.removeValue(forKey: sessionId)
        sessionReadPositions.removeValue(forKey: sessionId)
        sessionLineBuffers.removeValue(forKey: sessionId)
        sessionJSONLPaths.removeValue(forKey: sessionId)
        completedQuestionHookIDs.removeValue(forKey: sessionId)
        completedTurnMessageIDs.removeValue(forKey: sessionId)
        sessionStates.removeValue(forKey: sessionId)
        isLoadingHistoryBySession.removeValue(forKey: sessionId)
        sessionsNeedingPermission.removeAll { $0.id == sessionId }
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
        let linesToProcess = buffer.append(data).suffix(50)
        sessionLineBuffers[sessionId] = buffer

        isLoadingHistoryBySession[sessionId] = true
        for line in linesToProcess where !line.isEmpty {
            parseJSONLLineForSession(line, sessionId: sessionId)
        }
        isLoadingHistoryBySession[sessionId] = false

        // Restore the latest state only while the transcript is recent.
        let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let lastActivity = sessionStates[sessionId]?.lastUpdateTime
        let isLive = modified.map { Date().timeIntervalSince($0) < questionWaitStaleAfter } == true
            && lastActivity.map { Date().timeIntervalSince($0) < questionWaitStaleAfter } == true
        if var sessionState = sessionStates[sessionId] {
            if !isLive {
                sessionState.activeTools.removeAll()
                // A next-step box waits for the user however long it takes.
                sessionState.pendingInputRequests.removeAll { !$0.isWrapUp }
                sessionState.isThinking = false
                sessionState.turnStartTime = nil
            } else if sessionState.turnStartTime != nil {
                sessionState.turnStartTime = lastActivity
            }
            sessionStates[sessionId] = sessionState

            // Also sync to main state if this is the selected session
            if selectedSession?.id == sessionId {
                state = sessionState
            }
        }
        updateSessionsNeedingPermission()

        // Start idle timer to ensure UI updates
        resetIdleTimer()
    }

    private func readNewSessionDataForSession(sessionId: String) {
        guard let handle = sessionFileHandles[sessionId],
              let lastPosition = sessionReadPositions[sessionId] else { return }

        handle.seek(toFileOffset: lastPosition)
        let newData = handle.readDataToEndOfFile()
        sessionReadPositions[sessionId] = handle.offsetInFile

        guard !newData.isEmpty else { return }
        let lines = sessionLineBuffers[sessionId, default: JSONLLineBuffer()].append(newData)
        for line in lines {
            parseJSONLLineForSession(line, sessionId: sessionId)
        }

        resetIdleTimer()
    }

    /// `state` mirrors `sessionStates[id]` for the selected session — always a full
    /// struct copy, never a field-by-field sync, so the two can't drift apart.
    private func syncStateIfSelected(_ sessionId: String) {
        guard selectedSession?.id == sessionId, let sessionState = sessionStates[sessionId] else { return }
        state = sessionState
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
            guard var sessionState = sessionStates[sessionId] else { continue }
            // A remote session has no JSONL to reveal an Esc-interrupted turn (which sends
            // neither PostToolUse nor Stop), so its tools and prompts time out too.
            guard !sessionState.isAwaitingInput else { continue }
            let isRemote = sessionState.entrypoint == .ssh
            guard isRemote || (!sessionState.needsPermission && sessionState.activeTools.isEmpty),
                  sessionState.isActive || sessionState.needsPermission || sessionState.isAwaitingInput else { continue }
            let lastActivity = sessionState.lastUpdateTime ?? sessionState.turnStartTime ?? .distantPast
            let remaining = turnSafetyTimeout - now.timeIntervalSince(lastActivity)
            if remaining > 0 {
                nextCheck = min(nextCheck ?? remaining, remaining)
                continue
            }
            sessionState.isThinking = false
            sessionState.turnStartTime = nil
            if isRemote {
                sessionState.activeTools.removeAll()
                sessionState.pendingInputRequests.removeAll()
                sessionState.needsPermission = false
                sessionState.needsPermissionConfirmed = false
                sessionState.pendingPermissionTool = nil
            }
            sessionStates[sessionId] = sessionState
        }
        updateSessionsNeedingPermission()
        if let selectedId = selectedSession?.id { syncStateIfSelected(selectedId) }
        if let nextCheck { resetIdleTimer(after: nextCheck) }
    }

    /// Reset the tool idle timer - called when any tool activity is detected
    private func resetToolIdleTimer() {
        toolIdleTimer?.invalidate()
        toolIdleTimer = Timer.scheduledTimer(withTimeInterval: toolIdleDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.markSessionDoneAfterToolIdle()
            }
        }
    }

    private func markSessionDoneAfterToolIdle() {
        markAllSessionsIdle()
    }

    private func parseJSONLLineForSession(_ line: String, sessionId: String) {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        // Not a transcript event: the whole outgoing prompt, earlier tool_use blocks included,
        // with no timestamp. Parsing it re-added finished tools as running after the turn ended.
        guard json["type"] as? String != "api-request-blob" else { return }

        let isLoadingHistory = isLoadingHistoryBySession[sessionId] == true
        let lineDate = (json["timestamp"] as? String).flatMap { raw in
            Self.lineTimestampFormatters.lazy.compactMap { $0.date(from: raw) }.first
        } ?? (isLoadingHistory ? .distantPast : Date())
        let isStale = (!isLoadingHistory && Date().timeIntervalSince(lineDate) > staleLineAfter)
            || lineDate < (sessionStates[sessionId]?.lastUpdateTime ?? .distantPast)
        if isStale {
            // Replayed history can update the preview, but must not change a live turn.
            if let message = json["message"] as? [String: Any], var sessionState = sessionStates[sessionId] {
                captureConversation(from: message, into: &sessionState)
                sessionStates[sessionId] = sessionState
                syncStateIfSelected(sessionId)
                objectWillChange.send()
            }
            return
        }

        // Check for interruption in toolUseResult
        if let toolUseResult = json["toolUseResult"] {
            let resultStr = "\(toolUseResult)"
            if resultStr.contains("interrupted by user") || resultStr.contains("Request interrupted") {
                debugLog("[ClaudeCode] Detected user interruption in toolUseResult for session \(sessionId.prefix(8))...")
                if var sessionState = sessionStates[sessionId] {
                    sessionState.isThinking = false
                    sessionState.lastStopReason = "interrupted"
                    sessionState.activeTools.removeAll()
                    sessionState.pendingInputRequests.removeAll()
                    sessionState.turnStartTime = nil
                    sessionStates[sessionId] = sessionState
                    syncStateIfSelected(sessionId)
                }
                // Clear any pending permission checks
                updateSessionsNeedingPermission()
            }
        }

        if let entrypoint = json["entrypoint"] as? String, var sessionState = sessionStates[sessionId] {
            sessionState.entrypoint = ClaudeEntrypoint(raw: entrypoint)
            sessionStates[sessionId] = sessionState
            syncStateIfSelected(sessionId)
        }

        // A message typed while the turn is still running lands as a queued_command
        // attachment, not a user line; it answers the box all the same.
        if json["type"] as? String == "attachment",
           let attachment = json["attachment"] as? [String: Any],
           attachment["type"] as? String == "queued_command",
           (attachment["origin"] as? [String: Any])?["kind"] as? String == "human",
           var sessionState = sessionStates[sessionId],
           sessionState.pendingInputRequests.contains(where: \.isWrapUp) {
            sessionState.pendingInputRequests.removeAll { $0.isWrapUp }
            sessionStates[sessionId] = sessionState
            syncStateIfSelected(sessionId)
            objectWillChange.send()
        }

        if let message = json["message"] as? [String: Any] {
            parseMessageForSession(message, sessionId: sessionId, lineDate: lineDate, isStale: isStale,
                                   isMeta: json["isMeta"] as? Bool == true)
        }
    }

    /// Capture conversation text (user prompts + assistant responses) into session state.
    private func captureConversation(from message: [String: Any], into sessionState: inout ClaudeCodeState) {
        let role = message["role"] as? String

        // User prompt: `content` is a plain String. Tool-result feedback arrives as an
        // array instead, so this naturally skips it.
        if role == "user", let text = message["content"] as? String {
            if let prompt = displayableUserPrompt(text) {
                appendConversationMessage(ClaudeMessage(role: .user, text: prompt), into: &sessionState)
            }
            return
        }

        // Assistant response: join all "text" content blocks into one message.
        if role == "assistant", let content = message["content"] as? [[String: Any]] {
            var parts: [String] = []
            for item in content {
                guard (item["type"] as? String) == "text",
                      let text = item["text"] as? String,
                      !text.contains("[Request interrupted") else { continue }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { parts.append(trimmed) }
            }
            let joined = parts.joined(separator: "\n")
            if !joined.isEmpty {
                appendConversationMessage(ClaudeMessage(role: .assistant, text: joined), into: &sessionState)
            }
        }
    }

    /// Returns a cleaned user prompt, or nil for command/system wrappers that shouldn't show.
    private func displayableUserPrompt(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if t.hasPrefix("<") { return nil }          // system-reminder / command tags
        if t.hasPrefix("Caveat:") { return nil }
        if t.contains("[Request interrupted") { return nil }
        return t
    }

    private func appendConversationMessage(_ message: ClaudeMessage, into sessionState: inout ClaudeCodeState) {
        // Dedup consecutive identical entries (same role + text)
        if let last = sessionState.recentMessages.last,
           last.role == message.role, last.text == message.text {
            return
        }
        sessionState.recentMessages.append(message)
        let maxMessages = 30
        if sessionState.recentMessages.count > maxMessages {
            sessionState.recentMessages.removeFirst(sessionState.recentMessages.count - maxMessages)
        }
    }

    private func parseMessageForSession(_ message: [String: Any], sessionId: String, lineDate: Date? = nil, isStale: Bool = false,
                                        isMeta: Bool = false) {
        guard var sessionState = sessionStates[sessionId] else { return }

        if let model = message["model"] as? String {
            sessionState.model = model
        }

        // Track stop_reason for session completion detection
        if let stopReason = message["stop_reason"] as? String {
            sessionState.lastStopReason = stopReason
            if stopReason == "end_turn" {
                sessionState.isThinking = false
            }
        }

        if let role = message["role"] as? String {
            if role == "user" || role == "assistant" {
                if !isStale {
                    sessionState.pendingInputRequests.removeAll { $0.id == "notification" }
                }
                // Activity is dated by the line itself, so a replayed old line can't extend
                // the idle timeout, and it never starts a turn.
                sessionState.lastUpdateTime = lineDate ?? Date()
                if !isStale {
                    sessionState.isThinking = true
                    // Reset stop_reason when new activity starts
                    sessionState.lastStopReason = nil
                    if sessionState.turnStartTime == nil { sessionState.turnStartTime = lineDate ?? Date() }
                }
            }
        }

        if let content = message["content"] as? [[String: Any]] {
            for item in content {
                if let type = item["type"] as? String {
                    switch type {
                    case "thinking":
                        if !isStale { sessionState.isThinking = true }

                    case "text":
                        // Text and thinking can both continue after a tool result.
                        // Check for interruption message
                        if let text = item["text"] as? String,
                           text.contains("[Request interrupted by user") {
                            debugLog("[ClaudeCode] Detected user interruption for session \(sessionId.prefix(8))...")
                            sessionState.isThinking = false
                            sessionState.lastStopReason = "interrupted"
                            sessionState.activeTools.removeAll()
                            sessionState.pendingInputRequests.removeAll()
                            sessionState.turnStartTime = nil
                        }

                    case "tool_use":
                        // Tool use means thinking is done, now acting
                        sessionState.isThinking = false
                        // Reset tool idle timer - new tool activity detected
                        resetToolIdleTimer()

                        if let toolId = item["id"] as? String,
                           let toolName = item["name"] as? String {
                            if toolName == questionToolName,
                               completedQuestionHookIDs[sessionId]?.contains(toolId) == true { continue }

                            var toolDescription: String?
                            var toolTimeout: Int?

                            if let input = item["input"] as? [String: Any] {
                                toolDescription = input["description"] as? String
                                toolTimeout = input["timeout"] as? Int
                            }

                            // Parse TodoWrite tool to extract todos
                            if toolName == "TodoWrite",
                               let input = item["input"] as? [String: Any],
                               let todos = input["todos"] as? [[String: Any]] {
                                sessionState.todos = parseTodosFromArray(todos)
                            }

                            var tool = ClaudeToolExecution(
                                id: toolId,
                                toolName: toolName,
                                argument: extractToolArgument(from: item["input"]),
                                // The line's own time: a fast Bash's tool_use and result often land in one read.
                                startTime: lineDate ?? Date()
                            )
                            tool.description = toolDescription
                            tool.timeout = toolTimeout
                            tool.change = ToolChange.claude(toolName: toolName, input: item["input"])

                            // Shown until the user's next message, even when loaded from history.
                            if toolName == wrapUpToolName {
                                // A newer box, even one with no question, retires the older one.
                                sessionState.pendingInputRequests.removeAll { $0.isWrapUp && $0.id != toolId }
                                if !dismissedInputRequestIDs.contains(toolId),
                                   !sessionState.pendingInputRequests.contains(where: { $0.id == toolId }),
                                   let request = ClaudeInputRequest.wrapUp(id: toolId, input: item["input"]) {
                                    sessionState.pendingInputRequests.append(request)
                                }
                            }

                            if isStale {
                                // Old line: remember the tool, but never show it as running.
                                if !sessionState.recentTools.contains(where: { $0.id == toolId }) {
                                    tool.endTime = tool.startTime
                                    sessionState.recentTools.insert(tool, at: 0)
                                    if sessionState.recentTools.count > 10 { sessionState.recentTools.removeLast() }
                                }
                            } else if !sessionState.activeTools.contains(where: { $0.id == toolId }) {
                                debugLog("[ClaudeCode] Tool started: \(toolName) (id: \(toolId.prefix(8))...) desc: \(toolDescription ?? "-")")
                                sessionState.activeTools.append(tool)
                                if toolName == questionToolName, !dismissedInputRequestIDs.contains(toolId) {
                                    sessionState.pendingInputRequests.append(ClaudeInputRequest(id: toolId, input: item["input"]))
                                }
                            }
                        }
                    default:
                        break
                    }
                }
            }
        }

        // Parse usage for token tracking
        if let usage = message["usage"] as? [String: Any] {
            sessionState.tokenUsage.inputTokens = usage["input_tokens"] as? Int ?? sessionState.tokenUsage.inputTokens
            sessionState.tokenUsage.outputTokens = usage["output_tokens"] as? Int ?? sessionState.tokenUsage.outputTokens
            sessionState.tokenUsage.cacheReadInputTokens = usage["cache_read_input_tokens"] as? Int ?? sessionState.tokenUsage.cacheReadInputTokens
            sessionState.tokenUsage.cacheCreationInputTokens = usage["cache_creation_input_tokens"] as? Int ?? sessionState.tokenUsage.cacheCreationInputTokens
        }

        // The user wrote (or pressed a box button, which sends its message): the box is answered.
        if message["role"] as? String == "user", !isMeta,
           message["content"] is String
            || (message["content"] as? [[String: Any]])?.contains(where: { $0["type"] as? String == "text" }) == true {
            sessionState.pendingInputRequests.removeAll { $0.isWrapUp }
        }

        if let role = message["role"] as? String, role == "user",
           let content = message["content"] as? [[String: Any]] {
            for item in content {
                if let type = item["type"] as? String, type == "tool_result",
                   let toolUseId = item["tool_use_id"] as? String {
                    sessionState.pendingInputRequests.removeAll { $0.id == toolUseId && !$0.isWrapUp }
                    clearPermissionCheckForSession(sessionId: sessionId)
                    // Re-sync from the dict: `sessionState` here is a local copy taken at
                    // the top of this function, so the write above (inside
                    // clearPermissionCheckForSession) is invisible to it — without this,
                    // the blind `sessionStates[sessionId] = sessionState` at the end of
                    // this function would clobber the clear with this copy's stale (still
                    // "true") permission fields the instant they were reset.
                    if let refreshed = sessionStates[sessionId] {
                        sessionState.needsPermission = refreshed.needsPermission
                        sessionState.needsPermissionConfirmed = refreshed.needsPermissionConfirmed
                        sessionState.pendingPermissionTool = refreshed.pendingPermissionTool
                    }

                    // Move tool to recentTools instead of just removing
                    if let index = sessionState.activeTools.firstIndex(where: { $0.id == toolUseId }) {
                        var tool = sessionState.activeTools.remove(at: index)
                        tool.endTime = max(lineDate ?? Date(), tool.startTime)
                        // Attach current token usage to the completed tool
                        tool.inputTokens = sessionState.tokenUsage.inputTokens
                        tool.outputTokens = sessionState.tokenUsage.outputTokens
                        tool.cacheReadTokens = sessionState.tokenUsage.cacheReadInputTokens
                        tool.cacheWriteTokens = sessionState.tokenUsage.cacheCreationInputTokens
                        debugLog("[ClaudeCode] Tool completed: \(tool.toolName) (id: \(toolUseId.prefix(8))...) in:\(tool.inputTokens ?? 0) out:\(tool.outputTokens ?? 0)")
                        sessionState.recentTools.insert(tool, at: 0)
                        if sessionState.recentTools.count > 10 {
                            sessionState.recentTools.removeLast()
                        }
                    }

                    if !isStale { sessionState.isThinking = true }
                }
            }
        }

        // Terminal stop reasons clear thinking + the turn marker authoritatively,
        // overriding any re-activation from the role/content branches above.
        if let stopReason = message["stop_reason"] as? String,
           ["end_turn", "stop_sequence", "max_tokens"].contains(stopReason) {
            sessionState.lastStopReason = stopReason
            sessionState.isThinking = false
            let turnStart = sessionState.turnStartTime
            sessionState.turnStartTime = nil

            // The final message is written as several lines (thinking, server tools, text),
            // each already carrying end_turn, some minutes apart; its text line is the end.
            let content = message["content"] as? [[String: Any]] ?? []
            let hasAnswerText = content.contains { $0["type"] as? String == "text" }
            if stopReason == "end_turn", hasAnswerText, !isStale,
               isLoadingHistoryBySession[sessionId] != true,
               let messageId = message["id"] as? String,
               completedTurnMessageIDs[sessionId] != messageId {
                completedTurnMessageIDs[sessionId] = messageId
                let answer = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                lastCompletedTurn = CompletedTurn(sessionId: sessionId, answer: answer.joined(separator: "\n"),
                                                  elapsed: turnStart.map { Date().timeIntervalSince($0) })
            }
        }

        // Capture conversation text (user prompts + assistant responses)
        captureConversation(from: message, into: &sessionState)

        sessionStates[sessionId] = sessionState
        syncStateIfSelected(sessionId)

        objectWillChange.send()
    }

    /// Helper to parse todos array into ClaudeTodoItem array
    private func parseTodosFromArray(_ todosArray: [[String: Any]]) -> [ClaudeTodoItem] {
        var newTodos: [ClaudeTodoItem] = []

        for todoDict in todosArray {
            guard let content = todoDict["content"] as? String,
                  let statusStr = todoDict["status"] as? String else {
                continue
            }

            let status: ClaudeTodoItem.TodoStatus
            switch statusStr {
            case "pending":
                status = .pending
            case "in_progress":
                status = .inProgress
            case "completed":
                status = .completed
            default:
                status = .pending
            }

            newTodos.append(ClaudeTodoItem(content: content, status: status))
        }

        return newTodos
    }

    /// The NEEDS YOU 카드's X for a tool approval the notch can't see the end of.
    func dismissPermission(sessionId: String) {
        clearPermissionCheckForSession(sessionId: sessionId)
    }

    private func clearPermissionCheckForSession(sessionId: String) {
        if var sessionState = sessionStates[sessionId], sessionState.needsPermission {
            sessionState.needsPermission = false
            sessionState.needsPermissionConfirmed = false
            sessionState.pendingPermissionTool = nil
            sessionStates[sessionId] = sessionState
            syncStateIfSelected(sessionId)
            objectWillChange.send()
        }
        updateSessionsNeedingPermission()
    }

    /// Question hooks carry the body before Claude writes its delayed transcript.
    func handleLocalQuestionHook(json: [String: Any]) {
        guard sessionScanTimer != nil,
              json["tool_name"] as? String == questionToolName,
              let event = json["hook_event_name"] as? String,
              ["PreToolUse", "PostToolUse", "PostToolUseFailure"].contains(event),
              let toolId = json["tool_use_id"] as? String,
              let transcriptPath = json["transcript_path"] as? String else { return }

        // A first question may beat the directory watcher for a brand-new session.
        if !sessionJSONLPaths.values.contains(transcriptPath) { scanForSessions() }
        guard let sessionId = sessionJSONLPaths.first(where: { $0.value == transcriptPath })?.key else { return }

        if event == "PreToolUse" {
            guard completedQuestionHookIDs[sessionId]?.contains(toolId) != true else { return }
            clearPermissionCheckForSession(sessionId: sessionId)
            parseMessageForSession(["role": "assistant", "content": [[
                "type": "tool_use", "id": toolId, "name": questionToolName,
                "input": json["tool_input"] ?? [:]
            ]]], sessionId: sessionId)
        } else {
            completedQuestionHookIDs[sessionId, default: []].insert(toolId)
            parseMessageForSession(["role": "user", "content": [[
                "type": "tool_result", "tool_use_id": toolId
            ]]], sessionId: sessionId)
        }
        updateSessionsNeedingPermission()
        resetIdleTimer()
    }

    /// Handles a `Notification` hook event POSTed by Claude Code (see .claude/settings.json
    /// hook config) — a deterministic signal that Claude is waiting on the user, instead of
    /// the fragile fallback heuristic of inferring it from tool_use/tool_result timing.
    func handleNotificationHook(transcriptPath: String, notificationType: String) {
        debugLog("[ClaudeCode] [\(Date())] Notification hook received: \(notificationType) for \(transcriptPath)")
        // `idle_prompt` is deliberately NOT here: Claude Code emits it ("Claude is waiting
        // for your input") merely because the prompt sat idle past its threshold, so any
        // finished session the user hasn't replied to yet would falsely light up as a
        // permission request and pop the notch dropdown.
        guard Self.attentionNotificationTypes.contains(notificationType) else { return }
        guard let sessionId = sessionJSONLPaths.first(where: { $0.value == transcriptPath })?.key,
              var sessionState = sessionStates[sessionId] else {
            debugLog("[ClaudeCode] Notification hook: no matching watched session for \(transcriptPath)")
            return
        }

        guard !sessionState.isAwaitingInput else { return }

        if notificationType != "permission_prompt" {
            let id = sessionState.activeTools.first?.id ?? "notification"
            sessionState.pendingInputRequests.append(ClaudeInputRequest(id: id, input: nil))
            sessionStates[sessionId] = sessionState
            syncStateIfSelected(sessionId)
            objectWillChange.send()
            return
        }

        debugLog("[ClaudeCode] [\(Date())] Notification hook: session \(sessionId.prefix(8))... needs permission (\(notificationType))")
        sessionState.needsPermission = true
        sessionState.needsPermissionConfirmed = true
        if sessionState.pendingPermissionTool == nil {
            sessionState.pendingPermissionTool = sessionState.activeTools.first?.toolName ?? "Claude"
        }
        sessionStates[sessionId] = sessionState
        syncStateIfSelected(sessionId)
        updateSessionsNeedingPermission()
        objectWillChange.send()
    }

    private static let attentionNotificationTypes: Set<String> = [
        "permission_prompt",       // tool permission dialog
        "elicitation_dialog",      // MCP elicitation ("Claude Code needs your input")
        "elicitation_url_dialog",
        "agent_needs_input"        // background agent blocked on input
    ]

    // MARK: - Ended Sessions

    /// Clears the working/waiting state of local sessions whose turn is over although the
    /// transcript never said so: Claude Code reports itself idle (a turn ended by an API
    /// error, e.g. while offline, writes no line), or its process has exited (a transcript
    /// closed mid-tool or mid-question never gets its tool_result). Tools and questions are
    /// exempt from the silence timeout, and a plain turn would otherwise read as working for
    /// the full five minutes of it.
    private func clearEndedSessions() {
        let now = Date()
        let candidates = sessionStates.compactMap { id, state -> (id: String, conversationId: String)? in
            guard state.isActive || state.needsPermission || state.isAwaitingInput,
                  now.timeIntervalSince(state.lastUpdateTime ?? .distantPast) > idleStatusGrace,
                  let path = sessionJSONLPaths[id] else { return nil }
            return (id, URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)
        }
        guard !candidates.isEmpty, let live = liveSessionRecords() else { return }
        seenLiveConversationIds.formUnion(live.keys)

        var changed = false
        for candidate in candidates {
            guard var state = sessionStates[candidate.id] else { continue }
            let lastActivity = state.lastUpdateTime ?? .distantPast
            if let record = live[candidate.conversationId] {
                // Busy (running or retrying) and waiting (a permission prompt or question is
                // open) are real; only an idle state entered after our last activity ends it.
                guard record.isIdle, let changedAt = record.statusChangedAt,
                      changedAt >= lastActivity.addingTimeInterval(-1) else { continue }
                // Idle is exactly how a session waits on its next-step box: nothing to clear.
                if !state.isActive, !state.needsPermission,
                   state.pendingInputRequests.allSatisfy(\.isWrapUp) { continue }
                debugLog("[ClaudeCode] Session \(candidate.conversationId.prefix(8))... reports idle; clearing its working state")
            } else {
                // A missing record only proves an exit for a session known to register: one seen
                // live before (this also covers /clear and /resume moving the process to a new
                // id) or a CLI session. Other hosts might not register at all.
                guard now.timeIntervalSince(lastActivity) > endedSessionGrace,
                      seenLiveConversationIds.contains(candidate.conversationId) || state.entrypoint == .terminal
                else { continue }
                debugLog("[ClaudeCode] Session \(candidate.conversationId.prefix(8))... has no live process; clearing its working state")
            }
            state.activeTools.removeAll()
            // A next-step box outlives idle; only an exit drops it.
            let exited = live[candidate.conversationId] == nil
            state.pendingInputRequests.removeAll { exited || !$0.isWrapUp }
            state.isThinking = false
            state.turnStartTime = nil
            state.needsPermission = false
            state.needsPermissionConfirmed = false
            state.pendingPermissionTool = nil
            sessionStates[candidate.id] = state
            syncStateIfSelected(candidate.id)
            changed = true
        }
        if changed { updateSessionsNeedingPermission() }
    }

    /// A running Claude Code process as its registry record describes it.
    private struct LiveSessionRecord {
        let pid: Int
        /// Not running a turn: `idle`, or `shell` (idle while the user's `!` command runs).
        /// The others are `busy` (running, including API retries) and `waiting` (a prompt is open).
        let isIdle: Bool
        let statusChangedAt: Date?
    }

    /// Conversation ids held by a running Claude Code process, from Claude Code's own registry
    /// (`~/.claude/sessions/<pid>.json`, rewritten on /clear and /resume and on every turn state
    /// change). nil when the registry doesn't exist or a live process's record can't be read;
    /// empty when no Claude Code process is running.
    private func liveSessionRecords() -> [String: LiveSessionRecord]? {
        let registryDir = claudeDir.appendingPathComponent("sessions")
        guard let files = try? FileManager.default.contentsOfDirectory(at: registryDir, includingPropertiesForKeys: nil) else {
            return nil
        }
        var live: [String: LiveSessionRecord] = [:]
        for file in files where file.pathExtension == "json" {
            guard let filePid = Int(file.deletingPathExtension().lastPathComponent) else { continue }
            guard let data = try? Data(contentsOf: file),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = record["pid"] as? Int else {
                // A live process's record caught mid-rewrite would read as a missing session:
                // judge on the next scan. A dead process's broken leftover never heals: skip it.
                if isProcessRunning(pid: filePid) { return nil }
                continue
            }
            guard let conversationId = record["sessionId"] as? String, isProcessRunning(pid: pid) else { continue }
            let status = record["status"] as? String
            live[conversationId] = LiveSessionRecord(
                pid: pid,
                isIdle: status == "idle" || status == "shell",
                statusChangedAt: (record["statusUpdatedAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
            )
        }
        return live
    }

    // MARK: - Remote (SSH) Sessions

    /// Applies one Claude Code hook event forwarded from an SSH host by the hook script
    /// RemoteClaudeManager installs there. A remote session has no JSONL to tail, so its
    /// state is driven only by these events: prompt → tool start/end → stop.
    /// Each session's real context window, from its status line (`StatuslineBridge`).
    @Published private(set) var contextWindowSizes: [String: Int] = [:]

    func receiveStatusline(sessionId: String, contextWindowSize: Int) {
        guard contextWindowSizes[sessionId] != contextWindowSize else { return }
        contextWindowSizes[sessionId] = contextWindowSize
    }

    /// The X on the 다음 단계 드롭다운 and the NEEDS YOU 카드. A request can outlive its answer:
    /// the desktop app copies an SSH session's transcript here only when a turn ends, so the
    /// answer shows up minutes late, and a missed tool_result leaves a question up for good.
    func dismissInputRequest(id: String) {
        dismissedInputRequestIDs.insert(id)
        for (sessionId, var sessionState) in sessionStates
        where sessionState.pendingInputRequests.contains(where: { $0.id == id }) {
            sessionState.pendingInputRequests.removeAll { $0.id == id }
            sessionStates[sessionId] = sessionState
            syncStateIfSelected(sessionId)
        }
        objectWillChange.send()
    }

    func handleRemoteHook(host: String, json: [String: Any]) {
        guard sessionScanTimer != nil,
              let conversationId = json["session_id"] as? String,
              let event = json["hook_event_name"] as? String else { return }

        if event == "SessionEnd" {
            if let session = remoteSessions.removeValue(forKey: conversationId) {
                sessionStates.removeValue(forKey: session.id)
                scanForSessions()
                updateSessionsNeedingPermission()
            }
            return
        }

        // Keyed by conversation, so a `cd` inside the session doesn't fork a second row.
        let session = remoteSessions[conversationId] ?? ClaudeSession(
            pid: 0,
            workspaceFolders: ["\(json["cwd"] as? String ?? "")#\(conversationId)"],
            ideName: "SSH \(host)",
            transport: nil,
            runningInWindows: nil,
            remoteHost: host
        )
        var sessionState = sessionStates[session.id] ?? ClaudeCodeState()
        sessionState.sessionId = conversationId
        sessionState.cwd = json["cwd"] as? String ?? sessionState.cwd
        sessionState.entrypoint = .ssh
        sessionState.isConnected = true

        let now = Date()
        // Any event after a prompt means the user answered it (a denied permission never
        // sends PostToolUse, so this can't wait for the tool's own end).
        if event != "Notification" {
            sessionState.pendingInputRequests.removeAll { $0.id == "notification" }
            sessionState.needsPermission = false
            sessionState.needsPermissionConfirmed = false
            sessionState.pendingPermissionTool = nil
        }

        switch event {
        case "UserPromptSubmit":
            sessionState.activeTools.removeAll()
            sessionState.pendingInputRequests.removeAll()
            sessionState.isThinking = true
            sessionState.lastStopReason = nil
            sessionState.turnStartTime = now
            if let prompt = json["prompt"] as? String, let text = displayableUserPrompt(prompt) {
                appendConversationMessage(ClaudeMessage(role: .user, text: text), into: &sessionState)
            }
        case "PreToolUse":
            let toolName = json["tool_name"] as? String ?? "Tool"
            var tool = ClaudeToolExecution(
                id: json["tool_use_id"] as? String ?? UUID().uuidString,
                toolName: toolName,
                argument: extractToolArgument(from: json["tool_input"]),
                startTime: now
            )
            tool.description = (json["tool_input"] as? [String: Any])?["description"] as? String
            tool.change = ToolChange.claude(toolName: toolName, input: json["tool_input"])
            sessionState.activeTools.append(tool)
            sessionState.isThinking = false
            if sessionState.turnStartTime == nil { sessionState.turnStartTime = now }
            if toolName == questionToolName, !dismissedInputRequestIDs.contains(tool.id) {
                sessionState.pendingInputRequests.append(ClaudeInputRequest(id: tool.id, input: json["tool_input"]))
            }
        case "PostToolUse":
            let toolId = json["tool_use_id"] as? String
            let toolName = json["tool_name"] as? String
            if let index = sessionState.activeTools.firstIndex(where: { toolId != nil ? $0.id == toolId : $0.toolName == toolName }) {
                var tool = sessionState.activeTools.remove(at: index)
                sessionState.pendingInputRequests.removeAll { $0.id == tool.id }
                tool.endTime = now
                sessionState.recentTools.insert(tool, at: 0)
                if sessionState.recentTools.count > 10 { sessionState.recentTools.removeLast() }
            }
            // A background tool can finish after Stop; that isn't the turn resuming.
            if sessionState.turnStartTime != nil { sessionState.isThinking = true }
        case "Stop":
            sessionState.activeTools.removeAll()
            sessionState.pendingInputRequests.removeAll()
            sessionState.isThinking = false
            let turnStart = sessionState.turnStartTime
            sessionState.turnStartTime = nil
            sessionState.lastStopReason = "end_turn"
            lastCompletedTurn = CompletedTurn(sessionId: session.id, answer: json["last_assistant_message"] as? String ?? "",
                                              elapsed: turnStart.map { now.timeIntervalSince($0) })
        case "Notification":
            guard let type = json["notification_type"] as? String,
                  Self.attentionNotificationTypes.contains(type) else { return }
            if sessionState.isAwaitingInput { break }
            if type != "permission_prompt" {
                let id = sessionState.activeTools.first?.id ?? "notification"
                sessionState.pendingInputRequests.append(ClaudeInputRequest(id: id, input: nil))
                break
            }
            sessionState.needsPermission = true
            sessionState.needsPermissionConfirmed = true
            if sessionState.pendingPermissionTool == nil {
                sessionState.pendingPermissionTool = sessionState.activeTools.first?.toolName ?? "Claude"
            }
        default:
            return
        }

        sessionState.lastUpdateTime = now
        remoteSessions[conversationId] = session
        sessionStates[session.id] = sessionState
        if !availableSessions.contains(session) { scanForSessions() }
        syncStateIfSelected(session.id)
        updateSessionsNeedingPermission()
        objectWillChange.send()
        resetIdleTimer()
    }

    /// Drops every session of `host` — called when its tunnel closes, since no further
    /// events (not even Stop) can arrive and the rows would otherwise read as working forever.
    func removeRemoteSessions(host: String) {
        let dropped = remoteSessions.filter { $0.value.remoteHost == host }
        guard !dropped.isEmpty else { return }
        for (conversationId, session) in dropped {
            remoteSessions.removeValue(forKey: conversationId)
            sessionStates.removeValue(forKey: session.id)
        }
        scanForSessions()
        updateSessionsNeedingPermission()
        objectWillChange.send()
    }

    private func updateSessionsNeedingPermission() {
        var needingPermission: [ClaudeSession] = []
        var confirmedNeedingPermission: [ClaudeSession] = []

        for session in availableSessions {
            if let sessionState = sessionStates[session.id], sessionState.needsPermission == true {
                needingPermission.append(session)
                if sessionState.needsPermissionConfirmed {
                    confirmedNeedingPermission.append(session)
                }
            }
        }

        sessionsNeedingPermission = needingPermission
        sessionsConfirmedNeedingPermission = confirmedNeedingPermission
        debugLog("[ClaudeCode] [\(Date())] updateSessionsNeedingPermission: \(needingPermission.map { $0.displayName }), confirmed: \(confirmedNeedingPermission.map { $0.displayName })")
    }

    /// Read the real working directory from a session JSONL's top-level `cwd` field.
    /// Reads only a bounded prefix — `cwd` appears on the first message line. Returns
    /// nil if not found (e.g. the file starts with a summary-only line and is short).
    private func extractCwd(from jsonlFile: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: jsonlFile) else { return nil }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: 32_768)
        // Decode leniently: the 32 KB cut can split a multi-byte character, and a strict
        // decode would then fail and lose the path.
        let text = String(decoding: data, as: UTF8.self)
        guard let start = text.range(of: "\"cwd\":\"") else { return nil }
        let rest = text[start.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        let path = String(rest[..<end])
        return path.isEmpty ? nil : path
    }

    /// Last-activity time for ranking: the mtime of the session's own JSONL (a terminal
    /// session) or of the project's most-recent JSONL (an IDE lock).
    /// Returns `.distantPast` when there's no JSONL (e.g. an IDE lock with no Claude
    /// history) so real sessions win the limited slots over an empty editor window.
    private func lastActivityDate(for session: ClaudeSession) -> Date {
        if session.remoteHost != nil { return sessionStates[session.id]?.lastUpdateTime ?? .distantPast }
        guard let key = session.projectKey else { return .distantPast }
        let dir = projectsDir.appendingPathComponent(key)
        guard let file = session.terminalSessionId.map({ dir.appendingPathComponent("\($0).jsonl") })
                ?? findActiveSessionFiles(in: dir).first,
              let mod = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        else { return .distantPast }
        return mod
    }

    private func findActiveSessionFiles(in projectDir: URL) -> [URL] {
        let fm = FileManager.default

        guard fm.fileExists(atPath: projectDir.path) else {
            debugLog("[ClaudeCode] findActiveSessionFiles: directory does not exist: \(projectDir.path)")
            return []
        }

        do {
            let allFiles = try fm.contentsOfDirectory(at: projectDir, includingPropertiesForKeys: [.contentModificationDateKey])
            debugLog("[ClaudeCode] findActiveSessionFiles: \(allFiles.count) files in \(projectDir.lastPathComponent)")

            let files = allFiles
                .filter { $0.pathExtension == "jsonl" && !$0.lastPathComponent.hasPrefix("agent-") }
                .sorted { url1, url2 in
                    let date1 = (try? url1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                    let date2 = (try? url2.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                    return date1 > date2
                }

            debugLog("[ClaudeCode] findActiveSessionFiles: \(files.count) JSONL files found")

            // Return all recent files, not just the first one
            return files
        } catch {
            debugLog("[ClaudeCode] findActiveSessionFiles: error: \(error)")
            return []
        }
    }

    private func extractToolArgument(from input: Any?) -> String? {
        guard let input = input as? [String: Any] else { return nil }

        if let pattern = input["pattern"] as? String { return pattern }
        if let command = input["command"] as? String { return String(command.prefix(50)) }
        if let filePath = input["file_path"] as? String { return URL(fileURLWithPath: filePath).lastPathComponent }
        if let query = input["query"] as? String { return String(query.prefix(50)) }
        if let prompt = input["prompt"] as? String { return String(prompt.prefix(50)) }

        return nil
    }
}

// MARK: - Demo

extension ClaudeCodeManager {
    /// `--demo`: every session comes from `DemoDriver` instead of a transcript.
    func demoApply(sessions: [ClaudeSession], states: [String: ClaudeCodeState]) {
        availableSessions = sessions
        sessionStates = states
        selectedSession = sessions.first
        state = sessions.first.flatMap { states[$0.id] } ?? ClaudeCodeState()
    }

    func demoComplete(_ turn: CompletedTurn) {
        lastCompletedTurn = turn
    }
}
