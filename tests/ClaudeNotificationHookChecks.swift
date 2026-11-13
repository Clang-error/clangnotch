import Foundation

@main
struct ClaudeNotificationHookChecks {
    static let types = ["agent_needs_input", "elicitation_dialog", "elicitation_url_dialog", "permission_prompt"]

    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("settings.json")
        let backup = file.appendingPathExtension("clangnotch-notification-bak")
        func groups() throws -> [[String: Any]] {
            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
            return (json["hooks"] as! [String: [[String: Any]]])["Notification"]!
        }
        func commands(_ group: [String: Any]) -> [String] {
            (group["hooks"] as! [[String: Any]]).compactMap { $0["command"] as? String }
        }

        // Someone else's Notification hook stays, and ours goes in beside it.
        let original = Data(#"{"permissions":{"allow":["Read"]},"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"echo custom"}]}],"Notification":[{"matcher":"idle_prompt","hooks":[{"type":"command","command":"echo idle"}]}]},"customSetting":"keep"}"#.utf8)
        try original.write(to: file)
        try ClaudeNotificationHooks.install(in: file, port: 4318, types: types)
        let installed = try Data(contentsOf: file)
        let json = try JSONSerialization.jsonObject(with: installed) as! [String: Any]
        let originalJSON = try JSONSerialization.jsonObject(with: original) as! [String: Any]
        precondition((json["permissions"] as! NSDictionary).isEqual(to: originalJSON["permissions"] as! [AnyHashable: Any]))
        precondition(json["customSetting"] as? String == "keep")
        precondition(((json["hooks"] as! [String: Any])["PreToolUse"] as! NSArray)
            .isEqual(to: (originalJSON["hooks"] as! [String: Any])["PreToolUse"] as! [Any]))
        var all = try groups()
        precondition(all.count == 2 && commands(all[0]) == ["echo idle"] && all[0]["matcher"] as? String == "idle_prompt")
        precondition(all[1]["matcher"] as? String == "agent_needs_input|elicitation_dialog|elicitation_url_dialog|permission_prompt")
        let command = commands(all[1])[0]
        precondition(command.contains("127.0.0.1:4318/claude-hook") && command.contains("--data-binary @-")
            && command.contains("--max-time 1") && command.hasSuffix(ClaudeNotificationHooks.marker))
        precondition(!(all[1]["matcher"] as! String).contains("idle_prompt"), "An idle prompt is not a request")
        precondition((try? Data(contentsOf: backup)) == original)

        try ClaudeNotificationHooks.install(in: file, port: 4318, types: types)
        precondition((try? Data(contentsOf: file)) == installed, "Repeated launches must not duplicate the hook or rewrite settings")
        try ClaudeNotificationHooks.install(in: file, port: 4320, types: types)
        all = try groups()
        precondition(all.count == 2 && commands(all[1]).count == 1 && commands(all[1])[0].contains("127.0.0.1:4320/claude-hook"))
        precondition((try? Data(contentsOf: backup)) == original, "Keep the original settings backup")

        // A hook put there by hand already posts to the receiver: nothing is added or rewritten.
        try FileManager.default.removeItem(at: backup)
        let byHand = Data(#"{"hooks":{"Notification":[{"matcher":"permission_prompt|agent_needs_input","hooks":[{"type":"command","command":"curl -s -m 2 -X POST http://127.0.0.1:4318/claude-hook -d @-"}]}]}}"#.utf8)
        try byHand.write(to: file)
        try ClaudeNotificationHooks.install(in: file, port: 4318, types: types)
        precondition((try? Data(contentsOf: file)) == byHand, "A hand-made hook must not be doubled or touched")
        precondition(!FileManager.default.fileExists(atPath: backup.path))

        // No settings file yet.
        try FileManager.default.removeItem(at: file)
        try ClaudeNotificationHooks.install(in: file, port: 4318, types: types)
        all = try groups()
        precondition(all.count == 1 && commands(all[0])[0].hasSuffix(ClaudeNotificationHooks.marker))
        precondition(!FileManager.default.fileExists(atPath: backup.path), "Nothing to back up")

        let malformed = Data("invalid settings".utf8)
        try malformed.write(to: file)
        do {
            try ClaudeNotificationHooks.install(in: file, port: 4318, types: types)
            preconditionFailure("Invalid settings must not be replaced")
        } catch {
            precondition((try? Data(contentsOf: file)) == malformed)
        }
        print("PASS: notification hook installs once beside other hooks, leaves a hand-made one alone, port update, backup")
    }
}
