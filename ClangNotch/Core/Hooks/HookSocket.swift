import Foundation

/// Where the agents' hooks reach this app: a Unix socket in a folder only this user can open.
///
/// Until 2026-11-21 it was `127.0.0.1:4318`. Any account on the Mac, or a sandboxed app, could
/// post to that port, and while this app wasn't listening (quit, relaunching for an update, not
/// yet started at login) whatever took the port got every tool input and could answer "allow".
/// 4318 is also OTLP's standard port, so a telemetry collector could hold it by accident. The
/// SSH tunnel's host end was already a socket.
enum HookSocket {
    /// `~/Library/Application Support/ClangNotch/hook.sock`: this Mac's own agents.
    static let path = socket("hook.sock")

    /// Where the SSH tunnels end (`RemoteClaudeManager`). Everything there came from a host, so it
    /// can only be that host's events and questions: posted to `path`, a host's `/permission-hook`
    /// looked like an approval for this Mac (2026-11-22).
    static let remotePath = socket("remote-hook.sock")

    /// In the app's folder, or the user's temporary folder when a long home path would pass a
    /// socket path's 104 bytes.
    private static func socket(_ name: String) -> String {
        let preferred = NSHomeDirectory() + "/Library/Application Support/ClangNotch/" + name
        if preferred.utf8.count < 104 { return preferred }
        return FileManager.default.temporaryDirectory.appendingPathComponent("clangnotch-" + name).path
    }

    /// The curl a hook command runs: its stdin posted to `route`. The path goes in single quotes:
    /// it has a space in it, and the command is a shell line.
    static func curl(_ route: String, socket: String, maxTime: Int) -> String {
        "curl -s --unix-socket \(quoted(socket)) --connect-timeout 0.2 --max-time \(maxTime) -X POST http://localhost\(route) -H 'Content-Type: application/json' --data-binary @-"
    }

    static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
