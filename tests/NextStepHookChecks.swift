import Foundation
@main
struct NextStepHookChecks {
    static func main() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("settings.json")
        let original = Data(#"{"permissions":{"allow":["Read"]},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo mine"}]}],"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"echo pre"}]}]},"keep":"me"}"#.utf8)
        try original.write(to: file)
        func json() throws -> [String: Any] { try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any] }
        let before = try json()

        try NextStepHooks.sync(in: file, port: 4318, maxTime: 600, enabled: true)
        var stop = (try json()["hooks"] as! [String: Any])["Stop"] as! [[String: Any]]
        precondition(stop.count == 2, "the user's Stop hook stays, ours is added")
        let ours = (stop[1]["hooks"] as! [[String: Any]])[0]
        precondition(ours["asyncRewake"] as? Bool == true && ours["timeout"] as? Int == 605)
        precondition((ours["command"] as! String).hasSuffix(NextStepHooks.marker))
        let installed = try Data(contentsOf: file)
        try NextStepHooks.sync(in: file, port: 4318, maxTime: 600, enabled: true)
        let again = try Data(contentsOf: file)
        precondition(again == installed, "a second sync must not rewrite the file")
        precondition((try? Data(contentsOf: file.appendingPathExtension("clangnotch-nextstep-bak"))) == original)

        try NextStepHooks.sync(in: file, port: 4318, maxTime: 600, enabled: false)
        stop = (try json()["hooks"] as! [String: Any])["Stop"] as! [[String: Any]]
        let restored = try json()
        precondition(stop.count == 1 && NSDictionary(dictionary: restored).isEqual(to: before), "turning it off leaves the file as it was")

        // Only ours in Stop: turning it off removes the key again.
        let bare = dir.appendingPathComponent("bare.json")
        try Data(#"{"keep":"me"}"#.utf8).write(to: bare)
        try NextStepHooks.sync(in: bare, port: 4318, maxTime: 600, enabled: true)
        try NextStepHooks.sync(in: bare, port: 4318, maxTime: 600, enabled: false)
        let after = try JSONSerialization.jsonObject(with: Data(contentsOf: bare)) as! [String: Any]
        precondition(after["hooks"] == nil && after["keep"] as? String == "me")
        // No file and off: nothing is created.
        let none = dir.appendingPathComponent("none.json")
        try NextStepHooks.sync(in: none, port: 4318, maxTime: 600, enabled: false)
        precondition(!FileManager.default.fileExists(atPath: none.path))
        print("PASS: next-step hook installs once, keeps other hooks, and comes out cleanly")
    }
}
