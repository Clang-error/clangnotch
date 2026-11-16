import Foundation

// Model of the notch's dropdowns, mirroring ClangNotchContentView (handlePermissionQueue,
// showInputNotice, dismissQuestionNotice, handleCompletedTurn, show/dismissDoneNotice,
// trigger/dismissTetherNotice, foldPeek, restorePeek, handleHover, the 400 ms re-drop after close).
// Speed is left out (it only drops after the open panel closes mid-test).
// Every event order is tried, so a rule that breaks comes with the shortest path to it.
// It found a dropdown left down and empty, and a Done or question that never came down
// (2026-11-17). When those handlers change, change this the same way and run it.

enum Notch: Hashable { case closed, peeking, open }
enum FoldClear: Hashable { case none, permission, done }

struct S: Hashable {
    var notch = Notch.closed
    var queue = false          // permissionCenter.queue non-empty
    var showPerm = false
    var question = false       // a pending question exists
    var showQ = false
    var done = false           // doneNotice
    var pendingDone = false
    var tether = false
    var fold = FoldClear.none  // foldPeek's clear still to run
    var settle = false         // the 400 ms re-drop after the panel closed, still to run
}

enum E: String, CaseIterable {
    case permissionArrives = "a permission request arrives"
    case permissionAnswered = "the permission is answered"
    case questionArrives = "a question arrives"
    case questionAnswered = "the question is answered"
    case turnEnds = "a turn ends"
    case doneTimesOut = "the Done dropdown's time runs out"
    case tetherStarts = "tethering starts"
    case tetherTimesOut = "the tethering dropdown's time runs out"
    case foldLands = "a fold finishes"
    case settleRuns = "the panel's close settles"
    case youOpen = "you hover open"
    case youLeave = "you move away"
}

func peek(_ s: inout S) { if s.notch != .open { s.notch = .peeking } }
func fold(_ s: inout S) { if s.notch != .closed { s.settle = true }; s.notch = .closed }
func closeNotch(_ s: inout S) { if s.notch != .closed { s.settle = true }; s.notch = .closed }

func hasNoticeAfter(_ s: S, permission: Bool = false, done: Bool = false) -> Bool {
    (!permission && s.showPerm) || s.showQ || s.tether || (!done && s.done) || s.pendingDone
}

func handlePermissionQueue(_ s: inout S) {
    if s.queue {
        guard s.notch != .open else { return }
        s.showPerm = true
        peek(&s)
    } else if s.showPerm {
        if s.notch == .peeking, !hasNoticeAfter(s, permission: true) {
            fold(&s); s.fold = .permission; return
        }
        s.showPerm = false
        if s.notch != .open { restorePeek(&s) }
    }
}

func showInputNotice(_ s: inout S) {
    s.showQ = true
    guard !s.showPerm else { return }
    peek(&s)
}

func dismissQuestionNotice(_ s: inout S) {
    s.showQ = false
    if s.notch != .open { restorePeek(&s) }
}

func showDoneNotice(_ s: inout S) { s.done = true; peek(&s) }

func dismissDoneNotice(_ s: inout S) {
    guard s.done else { return }
    if s.notch == .peeking, !hasNoticeAfter(s, done: true) {
        fold(&s); s.fold = .done; return
    }
    s.done = false
    if s.notch != .open { restorePeek(&s) }
}

func dismissTetherNotice(_ s: inout S) {
    let was = s.tether
    s.tether = false
    if was, s.notch == .peeking, !s.showQ, !s.showPerm, !s.done { restorePeek(&s) }
}

func restorePeek(_ s: inout S) {
    if s.queue { handlePermissionQueue(&s) }
    else if s.showQ, s.question { showInputNotice(&s) }
    else if s.tether { peek(&s) }
    else if s.done { peek(&s) }
    else if s.pendingDone { s.pendingDone = false; showDoneNotice(&s) }
    else if s.notch == .peeking { fold(&s) }
}

func step(_ s0: S, _ e: E) -> S? {
    var s = s0
    switch e {
    case .permissionArrives:
        guard !s.queue else { return nil }
        s.queue = true; handlePermissionQueue(&s)
    case .permissionAnswered:
        guard s.queue else { return nil }
        s.queue = false; handlePermissionQueue(&s)
    case .questionArrives:
        guard !s.question else { return nil }
        s.question = true; showInputNotice(&s)
    case .questionAnswered:
        guard s.question else { return nil }
        s.question = false; dismissQuestionNotice(&s)
    case .turnEnds:
        guard s.notch != .open, !s.done, !s.pendingDone else { return nil }
        if s.showPerm || s.showQ || s.tether { s.pendingDone = true } else { showDoneNotice(&s) }
    case .doneTimesOut:
        guard s.done, s.fold != .done else { return nil }
        dismissDoneNotice(&s)
    case .tetherStarts:
        guard !s.tether, s.notch == .closed, !s.showQ, !s.showPerm, !s.done else { return nil }
        s.tether = true; peek(&s)
    case .tetherTimesOut:
        guard s.tether else { return nil }
        dismissTetherNotice(&s)
    case .foldLands:
        switch s.fold {
        case .none: return nil
        case .permission:
            s.fold = .none
            if !s.queue { s.showPerm = false }
            restorePeek(&s)
        case .done:
            s.fold = .none
            s.done = false
            restorePeek(&s)
        }
    case .settleRuns:
        guard s.settle else { return nil }
        s.settle = false
        if s.notch == .closed, s.fold == .none, s.queue || s.pendingDone { restorePeek(&s) }
    case .youOpen:
        guard s.notch != .open else { return nil }
        if s.notch == .peeking, s.showQ || s.showPerm || s.done { return nil }
        s.notch = .open
    case .youLeave:
        guard s.notch == .open || (s.notch == .peeking && !s.showQ && !s.showPerm && !s.done) else { return nil }
        dismissQuestionNotice(&s)
        s.tether = false
        closeNotch(&s)
    }
    return s
}

let rules: [(String, (S) -> Bool)] = [
    ("A dropdown that is down always shows a notice",
     { s in s.notch != .peeking || s.showPerm || s.showQ || s.tether || s.done }),
    ("A waiting permission, question or Done is on screen or about to come down",
     { s in
        let waiting = s.queue || (s.question && s.showQ) || s.pendingDone
        return !waiting || s.notch != .closed || s.fold != .none || s.settle
     }),
]

@main
struct NotchDropdownModelChecks {
    static func main() {
        // Breadth-first from a quiet closed notch: every reachable state, with the event path to it.
        var parent: [S: (S, E)] = [:]
        var order = [S()]
        var seen: Set<S> = [S()]
        var i = 0
        while i < order.count {
            let s = order[i]; i += 1
            for e in E.allCases {
                if let t = step(s, e), seen.insert(t).inserted { parent[t] = (s, e); order.append(t) }
            }
        }
        var broken = false
        for (name, holds) in rules {
            guard let bad = order.first(where: { !holds($0) }) else { continue }
            broken = true
            var path: [String] = []; var cur = bad
            while let (p, e) = parent[cur] { path.append(e.rawValue); cur = p }
            print("BREAKS: \(name)")
            for (n, e) in path.reversed().enumerated() { print("  \(n + 1). \(e)") }
        }
        precondition(!broken, "a dropdown rule breaks; see the path above")
        print("NotchDropdownModelChecks: \(order.count) states, all rules hold")
    }
}
