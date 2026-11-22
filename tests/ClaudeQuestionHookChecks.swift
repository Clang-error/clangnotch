import Foundation

@main
struct ClaudeQuestionHookChecks {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("settings.json")
        let original = Data(#"{"permissions":{"defaultMode":"auto","allow":["Read"]},"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"echo custom"}]}],"Notification":[{"matcher":"permission_prompt","hooks":[{"type":"command","command":"echo notification"}]}]},"customSetting":"keep"}"#.utf8)
        try original.write(to: file)
        try ClaudeQuestionHooks.install(in: directory, socket: "/Users/me/Library/Application Support/ClangNotch/hook.sock")
        let installed = try Data(contentsOf: file)
        let json = try JSONSerialization.jsonObject(with: installed) as! [String: Any]
        let originalJSON = try JSONSerialization.jsonObject(with: original) as! [String: Any]
        precondition((json["permissions"] as! NSDictionary).isEqual(to: originalJSON["permissions"] as! [AnyHashable: Any]))
        precondition(json["customSetting"] as? String == "keep")
        let hooks = json["hooks"] as! [String: [[String: Any]]]
        precondition((hooks["Notification"]! as NSArray).isEqual(to: (originalJSON["hooks"] as! [String: Any])["Notification"] as! [Any]))
        precondition(hooks["PreToolUse"]?.first?["matcher"] as? String == "Bash")
        for event in ["PreToolUse", "PostToolUse", "PostToolUseFailure"] {
            let question = hooks[event]!.filter { $0["matcher"] as? String == "AskUserQuestion" }
            precondition(question.count == 1)
            let command = (question[0]["hooks"] as! [[String: Any]])[0]["command"] as! String
            precondition(command.contains("--unix-socket '/Users/me/Library/Application Support/ClangNotch/hook.sock'") && command.contains("http://localhost/claude-hook") && command.contains("--data-binary @-") && command.contains("--max-time 1"))
        }
        let backup = file.appendingPathExtension("clangnotch-question-bak")
        precondition((try? Data(contentsOf: backup)) == original)
        try ClaudeQuestionHooks.install(in: directory, socket: "/Users/me/Library/Application Support/ClangNotch/hook.sock")
        precondition((try? Data(contentsOf: file)) == installed, "Repeated launches must not duplicate hooks or rewrite settings")
        try ClaudeQuestionHooks.install(in: directory, socket: "/Users/me/Library/Application Support/ClangNotch/other.sock")
        let moved = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        for event in ["PreToolUse", "PostToolUse", "PostToolUseFailure"] {
            let groups = (moved["hooks"] as! [String: [[String: Any]]])[event]!
            let question = groups.filter { $0["matcher"] as? String == "AskUserQuestion" }
            precondition(question.count == 1)
            precondition(((question[0]["hooks"] as! [[String: Any]])[0]["command"] as! String).contains("other.sock"))
        }
        precondition((try? Data(contentsOf: backup)) == original, "Keep the original settings backup")

        let linked = directory.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("actual-settings.json")
        try original.write(to: target)
        let link = linked.appendingPathComponent("settings.json")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
        try ClaudeQuestionHooks.install(in: linked, socket: "/Users/me/Library/Application Support/ClangNotch/hook.sock")
        precondition((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == target.path)
        precondition((try? Data(contentsOf: target)) != original)

        let malformed = Data("invalid settings".utf8)
        try malformed.write(to: file)
        do {
            try ClaudeQuestionHooks.install(in: directory, socket: "/Users/me/Library/Application Support/ClangNotch/hook.sock")
            preconditionFailure("Invalid settings must not be replaced")
        } catch {
            precondition((try? Data(contentsOf: file)) == malformed)
        }
        print("PASS: question hook installation, settings preservation, idempotency, port update, backup and symlink")
    }
}
