import Foundation

/// What a notch dropdown can be down for, highest priority first.
enum DropdownNotice: Equatable {
    case permission, claudeQuestion, codexQuestion, speed, tether, done, pendingDone, media
}

/// Which notices want the notch dropdown right now, and the two rules over them that every
/// dropdown handler in `ClangNotchContentView` goes by: which one comes down next, and whether
/// any is left once one goes. `tests/NotchDropdownModelChecks.swift` compiles this file, so the
/// model it explores runs these rules, not a copy of them.
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

    /// Whether anything still wants the dropdown once `leaving` is gone (nil: anything at all).
    /// Only `.permission`, `.done` and `.media` leave this way; a question or tethering goes
    /// through its own dismiss.
    func hasNotice(besides leaving: DropdownNotice? = nil) -> Bool {
        (leaving != .permission && permissionShown) || questionShown || speed || tether
            || (leaving != .done && done) || pendingDone || (leaving != .media && media)
    }
}
