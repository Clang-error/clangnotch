import Foundation

/// Listens on `HookSocket.path` for what the agents post: Claude Code's
/// `Notification` and AskUserQuestion hooks, the status line bridge, the permission and
/// next-step hooks (held open until the notch answers). Hooks forwarded from SSH hosts come
/// in on `HookSocket.remotePath`.
@MainActor
final class HookReceiver {
    static let shared = HookReceiver()

    private let server = HookHTTPServer()
    private let remoteServer = HookHTTPServer()

    private init() {
        server.onRequest = { [weak self] request in
            Task { @MainActor in self?.handle(request) }
        }
        remoteServer.onRequest = { [weak self] request in
            Task { @MainActor in self?.handleRemote(request) }
        }
        for each in [server, remoteServer] {
            each.onError = { message in
                debugLog("[Hooks] server error: \(message)")
            }
        }
    }

    private var retry: Task<Void, Never>?

    /// The copy this one replaces (`SingleInstance`) may take a moment to quit and let go of the
    /// socket: tried again every 2 s for a minute instead of going without hooks until a relaunch.
    func start() {
        retry?.cancel()
        retry = Task { @MainActor [server, remoteServer] in
            for _ in 0..<30 {
                do {
                    if !server.isListening { try server.start(socketPath: HookSocket.path) }
                    if !remoteServer.isListening { try remoteServer.start(socketPath: HookSocket.remotePath) }
                    return
                } catch {
                    debugLog("[Hooks] could not listen: \(error)")
                }
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { return }
            }
        }
    }

    func stop() {
        retry?.cancel()
        server.stop()
        remoteServer.stop()
    }

    private func handle(_ request: HookHTTPServer.Request) {
        switch request.route {
        case .claudeHook:
            handleClaudeHook(request.body)
        case .permissionHook:
            if let reply = request.reply {
                PermissionRequestCenter.shared.receive(request.body, reply: reply)
            }
        case .nextStepHook:
            if let reply = request.reply {
                PermissionRequestCenter.shared.receiveNextStep(request.body, reply: reply)
            }
        case .other:
            break
        }
    }

    /// From an SSH host, through its tunnel: the host's own events and its AskUserQuestion, only
    /// for a host the user set up, with the feature on. Anything else gets no answer, so a host
    /// can't raise an approval or a next-step box that looks like this Mac's.
    private func handleRemote(_ request: HookHTTPServer.Request) {
        let settings = AppSettings.shared
        guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let host = json["clangnotch_host"] as? String,
              settings.remoteClaudeEnabled, SSHHost.list(settings.remoteClaudeHosts).contains(host) else {
            request.reply?.send(nil)
            return
        }
        switch request.route {
        case .claudeHook:
            ClaudeCodeManager.shared.handleRemoteHook(host: host, json: json)
        case .permissionHook:
            if let reply = request.reply { PermissionRequestCenter.shared.receiveRemoteQuestion(json, reply: reply) }
        case .nextStepHook, .other:
            request.reply?.send(nil)
        }
    }

    /// Handles a `Notification` hook POST from Claude Code (configured in
    /// `~/.claude/settings.json`) — a deterministic signal that Claude is waiting on
    /// the user (permission prompt, or a blocked background agent), instead of inferring
    /// it from JSONL tool_use/tool_result timing.
    private func handleClaudeHook(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let sessionId = json["session_id"] as? String,
           let size = (json["context_window"] as? [String: Any])?["context_window_size"] as? Int {
            ClaudeCodeManager.shared.receiveStatusline(sessionId: sessionId, contextWindowSize: size,
                                                       model: (json["model"] as? [String: Any])?["id"] as? String)
            return
        }
        if json["tool_name"] as? String == "AskUserQuestion" {
            ClaudeCodeManager.shared.handleLocalQuestionHook(json: json)
            return
        }
        guard let transcriptPath = json["transcript_path"] as? String,
              let notificationType = json["notification_type"] as? String else { return }
        ClaudeCodeManager.shared.handleNotificationHook(transcriptPath: transcriptPath, notificationType: notificationType)
    }
}
