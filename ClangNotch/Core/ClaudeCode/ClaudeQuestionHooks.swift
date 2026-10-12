import Foundation

/// Installs only the question lifecycle hooks; existing Claude settings stay intact.
enum ClaudeQuestionHooks {
    static func install(in directory: URL, port: UInt16) throws {
        let file = directory.appendingPathComponent("settings.json")
        let existing = FileManager.default.fileExists(atPath: file.path) ? try Data(contentsOf: file) : nil
        var settings: [String: Any] = [:]
        if let existing {
            guard let parsed = try JSONSerialization.jsonObject(with: existing) as? [String: Any] else {
                throw CocoaError(.propertyListReadCorrupt)
            }
            settings = parsed
        }

        let marker = "# ClangNotch AskUserQuestion"
        let command = "curl -s --connect-timeout 0.2 --max-time 1 -X POST http://127.0.0.1:\(port)/claude-hook -H 'Content-Type: application/json' --data-binary @- >/dev/null 2>&1 || true \(marker)"
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        var changed = false
        for event in ["PreToolUse", "PostToolUse", "PostToolUseFailure"] {
            var groups = hooks[event] as? [[String: Any]] ?? []
            var installed = false
            for index in groups.indices where groups[index]["matcher"] as? String == "AskUserQuestion" {
                var handlers = groups[index]["hooks"] as? [[String: Any]] ?? []
                for handler in handlers.indices {
                    guard let current = handlers[handler]["command"] as? String, current.hasSuffix(marker) else { continue }
                    installed = true
                    if current != command {
                        handlers[handler]["command"] = command
                        groups[index]["hooks"] = handlers
                        changed = true
                    }
                }
            }
            if !installed {
                groups.append(["matcher": "AskUserQuestion", "hooks": [["type": "command", "command": command]]])
                changed = true
            }
            hooks[event] = groups
        }
        guard changed else { return }
        settings["hooks"] = hooks
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let backup = file.appendingPathExtension("clangnotch-question-bak")
        if let existing, !FileManager.default.fileExists(atPath: backup.path) {
            try existing.write(to: backup, options: .atomic)
        }
        try data.write(to: file.resolvingSymlinksInPath(), options: .atomic)
    }
}
