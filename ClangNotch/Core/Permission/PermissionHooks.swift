import Foundation

/// Adds the `PermissionRequest` hook that sends approvals to the 권한 드롭다운. Claude Code
/// (`~/.claude/settings.json`) and Codex (`~/.codex/hooks.json`) share the file shape;
/// everything else in the file stays as it was.
enum PermissionHooks {
    static let marker = "# ClangNotch PermissionRequest"

    /// curl prints the decision on stdout for the agent; with ClangNotch not running it
    /// fails at once and the agent asks in its own dialog. `maxTime` outlasts the longest
    /// hold: 35s fits Codex's 30s permission wait; Claude gets 600s because a question can
    /// sit open for minutes while its own picker shows alongside.
    static func command(port: UInt16, maxTime: Int) -> String {
        "curl -s --connect-timeout 0.2 --max-time \(maxTime) -X POST http://127.0.0.1:\(port)/permission-hook -H 'Content-Type: application/json' --data-binary @- 2>/dev/null || true \(marker)"
    }

    static func install(in file: URL, port: UInt16, maxTime: Int) throws {
        let existing = FileManager.default.fileExists(atPath: file.path) ? try Data(contentsOf: file) : nil
        var settings: [String: Any] = [:]
        if let existing {
            guard let parsed = try JSONSerialization.jsonObject(with: existing) as? [String: Any] else {
                throw CocoaError(.propertyListReadCorrupt)
            }
            settings = parsed
        }

        let command = command(port: port, maxTime: maxTime)
        let timeout = maxTime + 5
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        var groups = hooks["PermissionRequest"] as? [[String: Any]] ?? []
        var installed = false
        var changed = false
        for index in groups.indices {
            var handlers = groups[index]["hooks"] as? [[String: Any]] ?? []
            for handler in handlers.indices {
                guard let current = handlers[handler]["command"] as? String, current.hasSuffix(marker) else { continue }
                installed = true
                if current != command || handlers[handler]["timeout"] as? Int != timeout {
                    handlers[handler]["command"] = command
                    handlers[handler]["timeout"] = timeout
                    groups[index]["hooks"] = handlers
                    changed = true
                }
            }
        }
        if !installed {
            groups.append(["hooks": [["type": "command", "command": command, "timeout": timeout]]])
            changed = true
        }
        guard changed else { return }
        hooks["PermissionRequest"] = groups
        settings["hooks"] = hooks
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let backup = file.appendingPathExtension("clangnotch-permission-bak")
        if let existing, !FileManager.default.fileExists(atPath: backup.path) {
            try existing.write(to: backup, options: .atomic)
        }
        try data.write(to: file.resolvingSymlinksInPath(), options: .atomic)
    }
}
