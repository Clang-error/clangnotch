import Foundation

@main
struct SessionOfferChecks {
    static func main() throws {
        // The hook: beside another PreToolUse hook, only on start_session, gone cleanly.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("settings.json")
        let socket = "/Users/me/Library/Application Support/ClangNotch/hook.sock"
        let original = Data(#"{"hooks":{"PreToolUse":[{"matcher":"AskUserQuestion","hooks":[{"type":"command","command":"echo ask"}]}]},"keep":"me"}"#.utf8)
        try original.write(to: file)
        func json() throws -> [String: Any] { try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any] }
        let before = try json()
        try SessionOffer.sync(in: file, socket: socket, enabled: true)
        let pre = (try json()["hooks"] as! [String: Any])["PreToolUse"] as! [[String: Any]]
        precondition(pre.count == 2 && pre[1]["matcher"] as? String == SessionOffer.toolName, "ours is added, only for start_session")
        let ours = (pre[1]["hooks"] as! [[String: Any]])[0]
        let command = ours["command"] as! String
        precondition(ours["timeout"] as? Int == SessionOffer.maxTime + 5 && command.hasSuffix(SessionOffer.marker)
                     && command.contains("/session-offer-hook") && command.contains("|| true"), "ClangNotch not running lets the tool go on")
        let installed = try Data(contentsOf: file)
        try SessionOffer.sync(in: file, socket: socket, enabled: true)
        let again = try Data(contentsOf: file)
        precondition(again == installed, "a second sync must not rewrite the file")
        precondition((try? Data(contentsOf: file.appendingPathExtension("clangnotch-offer-bak"))) == original)
        try SessionOffer.sync(in: file, socket: socket, enabled: false)
        let after = try json()
        precondition(NSDictionary(dictionary: after).isEqual(to: before), "turning it off leaves the file as it was")

        // What is an offer, and the start a 새 세션 pick leads to.
        precondition(SessionOffer.offerTitle(["initiation": "offer", "title": "로그 분석"]) == "로그 분석")
        precondition(SessionOffer.offerTitle(["initiation": "offer", "title": ""]) == nil)
        precondition(SessionOffer.offerTitle(["initiation": "own_initiative", "title": "x", "prompt": "y"]) == nil, "a proposal waits on nothing")
        precondition(SessionOffer.offerTitle(["proposal_id": "task_1", "prompt": "y"]) == nil, "the brief after the app's card")
        precondition(SessionOffer.isStart(["initiation": "user_asked", "title": "로그 분석", "prompt": "p"], of: "로그 분석"))
        precondition(!SessionOffer.isStart(["initiation": "user_asked", "title": "다른 일"], of: "로그 분석"))
        let picked = SessionOffer.FollowUp(transcript: "t", title: "로그 분석", newSession: true)
        precondition(picked.matches(["initiation": "user_asked", "title": "로그 분석"]) && !picked.matches(["initiation": "offer", "title": "로그 분석"]),
                     "after 새 세션, only Claude's own start goes through")
        let toApp = SessionOffer.FollowUp(transcript: "t", title: "로그 분석", newSession: false)
        precondition(toApp.matches(["initiation": "offer", "title": "로그 분석"]) && !toApp.matches(["initiation": "user_asked", "title": "로그 분석"]),
                     "after 앱에서 고르기, only the offer going on to draw the card")

        // Replies in PreToolUse's shape.
        func output(_ data: Data?) throws -> [String: Any] {
            (try JSONSerialization.jsonObject(with: data!) as! [String: Any])["hookSpecificOutput"] as! [String: Any]
        }
        for newSession in [true, false] {
            let deny = try output(SessionOffer.deny(newSession: newSession, title: "로그 \"분석\""))
            let reason = deny["permissionDecisionReason"] as! String
            let context = deny["additionalContext"] as! String
            precondition(deny["hookEventName"] as? String == "PreToolUse" && deny["permissionDecision"] as? String == "deny"
                         && reason.contains(newSession ? "user_asked" : "Do it here") && context.contains("로그 \"분석\""))
            precondition(!reason.contains("\n") && reason.count < 120, "the app shows the reason in the session: one short line")
        }
        print("PASS: session offer hook installs beside other PreToolUse hooks and comes out cleanly; offers and the calls they lead to, deny replies")
    }
}
