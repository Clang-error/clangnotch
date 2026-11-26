import Foundation

/// The Claude app's "New session / Do it here" card, answered from the 새 세션 드롭다운 (설정 ›
/// 실험 기능, 2026-11-24). A session in the app offers with `mcp__ccd_session__start_session` and
/// `initiation: "offer"`; once the tool runs the app draws the card and the tool waits for a click.
/// A `PreToolUse` hook holds the call before that: 앱에서 고르기 lets it go on and the card shows
/// as usual, the other two deny it with a reason that tells Claude what was picked.
/// A hook's allow doesn't stop the app asking for this tool's permission (seen 2026-11-25: the
/// start after a 새 세션 pick still came to the 권한 드롭다운 as a bare MCP call), so the call an
/// answer leads to is allowed in the permission hook instead (`FollowUp`).
/// The hook stays out of the way while held offers aren't wanted, and it must hold whichever app
/// is in front: standing aside while the Claude app was frontmost (the first version) meant
/// nearly always, as the offer comes while the user is in the app (user, 2026-11-25). The
/// permission hook can't do it instead: the app asks for this tool's permission only the first
/// time in a session (its log, 2026-11-25), so later offers never reach it.
/// Hooks in `~/.claude/settings.json` run in the app's sessions too (the next-step hook woke
/// them, 2026-11-11).
enum SessionOffer {
    static let marker = "# ClangNotch session offer"
    static let toolName = "mcp__ccd_session__start_session"
    /// Under the hook's curl limit; past it the card shows in the app.
    static let maxTime = 40
    /// How long an answered offer's next call is allowed without asking (`FollowUp`).
    static let followUpWindow: TimeInterval = 120

    /// The call an answer leads to, which the app may ask permission for: after 새 세션, Claude's
    /// own start (`user_asked`, the same title); after 앱에서 고르기, the offer itself going on to
    /// draw the card. Either was already said yes to in the notch.
    struct FollowUp {
        let transcript: String
        let title: String
        let newSession: Bool
        var at = Date()

        func matches(_ input: [String: Any]) -> Bool {
            newSession ? isStart(input, of: title) : offerTitle(input) == title
        }
    }

    /// curl prints the decision on stdout for Claude Code; with nothing held, or ClangNotch not
    /// running, it prints nothing and the tool goes on.
    static func command(socket: String) -> String {
        "\(HookSocket.curl("/session-offer-hook", socket: socket, maxTime: maxTime)) 2>/dev/null || true \(marker)"
    }

    static func sync(in file: URL, socket: String, enabled: Bool) throws {
        try HookSettingsFile.sync(file, event: "PreToolUse", marker: marker, backupSuffix: "clangnotch-offer-bak",
                                  group: enabled ? ["matcher": toolName, "hooks": [[
                                      "type": "command", "command": command(socket: socket), "timeout": maxTime + 5,
                                  ] as [String: Any]]] : nil)
    }

    /// The title when `input` is an offer, the call that would draw the card.
    static func offerTitle(_ input: [String: Any]) -> String? {
        guard input["initiation"] as? String == "offer", let title = input["title"] as? String, !title.isEmpty else { return nil }
        return title
    }

    /// The start a 새 세션 pick for `title` leads to.
    static func isStart(_ input: [String: Any], of title: String) -> Bool {
        input["initiation"] as? String == "user_asked" && input["title"] as? String == title
    }

    /// What goes back for 새 세션 or 여기서 하기. The app's own card answers "Do it here" with an
    /// instruction to carry on in the session, and "New session" with one to send the brief; a
    /// denied tool can't take the brief, so for 새 세션 Claude starts the session itself.
    /// The app shows the reason in the session as "PreToolUse:… hook error: <reason>", so it is one
    /// short line that still says what to do; the rest goes in `additionalContext`, which only
    /// Claude reads (user, 2026-11-25: the whole instruction read as a failure).
    static func deny(newSession: Bool, title: String) -> Data? {
        let reason = newSession
            ? "ClangNotch: the user chose \"New session\". Call start_session again with initiation \"user_asked\" and the same title."
            : "ClangNotch: the user chose \"Do it here\". Do the task in this session."
        let context = newSession
            ? "The user answered your offer \"\(title)\" from ClangNotch, the notch app they use instead of the app's card. "
                + "This is not an error. No card was shown, so there is no proposal_id: call start_session now with initiation "
                + "\"user_asked\", this title, a name, the prompt (the task as the user would send it to a fresh session) and "
                + "background, and nothing else in that message. Do not do the task here. When it returns, say in one line that "
                + "it runs in its own session, then end your turn."
            : "The user answered your offer \"\(title)\" from ClangNotch, the notch app they use instead of the app's card. "
                + "This is not an error: do the task in this session as usual."
        return try? JSONSerialization.data(withJSONObject: ["hookSpecificOutput": [
            "hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": reason,
            "additionalContext": context,
        ]])
    }
}
