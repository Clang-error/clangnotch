import Foundation

/// What a notch dropdown can be down for, highest priority first.
enum DropdownNotice: Equatable {
    case permission, claudeQuestion, codexQuestion, speed, tether, done, pendingDone, media
}

/// Which notices want the notch dropdown right now, and the rules over them that the dropdown
/// handlers in `ClangNotchContentView` go by: which one comes down next, whether any is left
/// once one goes, and which ones a Done, tethering or the cursor give way to.
/// `tests/NotchDropdownModelChecks.swift` compiles this file, so the model it explores runs
/// these rules, not a copy of them.
struct DropdownNotices {
    /// A request waits in the queue, shown or not: one that came while the panel was open was never shown.
    var permissionWaiting = false
    /// The 권한 드롭다운 is showing.
    var permissionShown = false
    /// The 질문 드롭다운 is showing (or folded away, to come back).
    var questionShown = false
    var claudeQuestion = false
    var codexQuestion = false
    var speed = false
    var tether = false
    var done = false
    /// A Done that came while another dropdown held the notch, waiting its turn.
    var pendingDone = false
    var media = false

    /// The notice the dropdown re-fits to, or nil: nothing wants it, it folds.
    var next: DropdownNotice? {
        if permissionWaiting { return .permission }
        if questionShown, claudeQuestion { return .claudeQuestion }
        if questionShown, codexQuestion { return .codexQuestion }
        if speed { return .speed }
        if tether { return .tether }
        if done { return .done }
        if pendingDone { return .pendingDone }
        if media { return .media }
        return nil
    }

    /// An agent waits on an answer from the notch: its dropdown glows though the session sits
    /// idle, and stays down until answered or dismissed.
    var waitsOnAnswer: Bool { permissionShown || questionShown }

    /// A Done that comes now waits behind these (`pendingDone`) instead of dropping over them.
    var holdsDoneBack: Bool { waitsOnAnswer || speed || tether }

    /// Tethering doesn't drop over these, and when it goes while one is down that one owns the
    /// dropdown, so tethering leaves it alone.
    var keepsTetherOut: Bool { waitsOnAnswer || speed || done }

    /// A dropdown down for one of these stays a dropdown when the cursor rests on it, and stays
    /// down when it leaves: it is being read. Speed and tethering open into the panel.
    var holdsAgainstHover: Bool { waitsOnAnswer || done || media }

    /// Whether anything still wants the dropdown once `leaving` is gone (nil: anything at all).
    /// Only `.permission`, `.done` and `.media` leave this way; a question or tethering goes
    /// through its own dismiss.
    func hasNotice(besides leaving: DropdownNotice? = nil) -> Bool {
        (leaving != .permission && permissionShown) || questionShown || speed || tether
            || (leaving != .done && done) || pendingDone || (leaving != .media && media)
    }
}
