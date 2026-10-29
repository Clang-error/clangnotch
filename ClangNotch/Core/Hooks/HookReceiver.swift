import Foundation

/// Listens on 127.0.0.1 (port 4318 unless changed) for what the agents post: Claude Code's
/// `Notification` and AskUserQuestion hooks, the status line bridge, the permission hook
/// (held open until the notch answers) and hooks forwarded from SSH hosts.
@MainActor
final class HookReceiver {
    static let shared = HookReceiver()

    private let server = HookHTTPServer()

    private init() {
        server.onRequest = { [weak self] request in
            Task { @MainActor in self?.handle(request) }
        }
        server.onError = { message in
            debugLog("[Hooks] server error: \(message)")
        }
    }

    func start() {
        guard let port = UInt16(exactly: AppSettings.shared.hookPort) else { return }
        do {
            try server.start(port: port)
        } catch {
            debugLog("[Hooks] could not listen on \(port): \(error)")
        }
    }

    func stop() {
        server.stop()
    }

    private func handle(_ request: HookHTTPServer.Request) {
        switch request.route {
        case .claudeHook:
            handleClaudeHook(request.body)
        case .permissionHook:
            if let reply = request.reply {
                PermissionRequestCenter.shared.receive(request.body, reply: reply)
            }
        case .other:
            break
        }
    }

    /// Handles a `Notification` hook POST from Claude Code (configured in
    /// `~/.claude/settings.json`) — a deterministic signal that Claude is waiting on
    /// the user (permission prompt, or a blocked background agent), instead of inferring
    /// it from JSONL tool_use/tool_result timing.
    private func handleClaudeHook(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        // Events forwarded from an SSH host carry the host alias the hook script was installed with.
        if let host = json["clangnotch_host"] as? String {
            ClaudeCodeManager.shared.handleRemoteHook(host: host, json: json)
            return
        }
        if let sessionId = json["session_id"] as? String,
           let size = (json["context_window"] as? [String: Any])?["context_window_size"] as? Int {
            ClaudeCodeManager.shared.receiveStatusline(sessionId: sessionId, contextWindowSize: size)
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
