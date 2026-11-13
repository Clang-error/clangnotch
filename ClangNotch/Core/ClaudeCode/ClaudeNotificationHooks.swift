import Foundation

/// Adds the `Notification` hook that tells the notch a session is waiting for an approval or
/// for input (`ClaudeCodeManager.handleNotificationHook`): the "Needs OK" wing and the
/// NEEDS YOU 카드. Everything else in `~/.claude/settings.json` stays as it was.
///
/// Until 2026-11-13 this hook was only ever put there by hand, so a fresh install showed
/// neither for an approval.
enum ClaudeNotificationHooks {
    static let marker = "# ClangNotch Notification"

    /// `types` are the notification kinds the notch acts on; they become the matcher, so
    /// Claude Code runs the hook for those only.
    static func install(in file: URL, port: UInt16, types: [String]) throws {
        let existing = FileManager.default.fileExists(atPath: file.path) ? try Data(contentsOf: file) : nil
        var settings: [String: Any] = [:]
        if let existing {
            guard let parsed = try JSONSerialization.jsonObject(with: existing) as? [String: Any] else {
                throw CocoaError(.propertyListReadCorrupt)
            }
            settings = parsed
        }

        let command = "curl -s --connect-timeout 0.2 --max-time 1 -X POST http://127.0.0.1:\(port)/claude-hook -H 'Content-Type: application/json' --data-binary @- >/dev/null 2>&1 || true \(marker)"
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        var groups = hooks["Notification"] as? [[String: Any]] ?? []
        var installed = false
        var changed = false
        for index in groups.indices {
            var handlers = groups[index]["hooks"] as? [[String: Any]] ?? []
            for handler in handlers.indices {
                guard let current = handlers[handler]["command"] as? String else { continue }
                if current.hasSuffix(marker) {
                    installed = true
                    if current != command {
                        handlers[handler]["command"] = command
                        groups[index]["hooks"] = handlers
                        changed = true
                    }
                } else if current.contains("/claude-hook") {
                    // A hook set up by hand already posts here: a second one would report
                    // every prompt twice. It is the user's, so it is left as it is.
                    installed = true
                }
            }
        }
        if !installed {
            groups.append(["matcher": types.joined(separator: "|"), "hooks": [["type": "command", "command": command]]])
            changed = true
        }
        guard changed else { return }
        hooks["Notification"] = groups
        settings["hooks"] = hooks
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let backup = file.appendingPathExtension("clangnotch-notification-bak")
        if let existing, !FileManager.default.fileExists(atPath: backup.path) {
            try existing.write(to: backup, options: .atomic)
        }
        try data.write(to: file.resolvingSymlinksInPath(), options: .atomic)
    }
}
