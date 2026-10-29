"""Compile the production sizing/state machine without launching app managers."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
view = (root / "ClangNotch/Views/Notch/ClangNotchContentView.swift").read_text()
# Compile the exact production enum, not a test reimplementation of its policy.
mode = view[view.index("enum NotchMode:"):view.index("struct ClangNotchContentView:")]

def block(signature):
    start = view.index("    " + signature)
    end = view.index("\n    }", start) + len("\n    }")
    return view[start:end]

# Keep the actual views, sizing and timers; agent state and navigation are stubbed.
questions = '''
@MainActor final class CodexQuestionLayoutFixture {
    let notchVM: NotchViewModel
    var codexInputRequest: CodexInputRequest?
    var claudeInputRequest: ClaudeInputRequest?
    var showQuestionNotice = false
    var questionExpanded = false
    var questionScale: CGFloat { questionExpanded ? 1.4 : 1 }
    var showPermissionNotice = false
    var claudeQuestionAnswer: (([String: Any]) -> Void)? = nil
    var askingSessionOpenTitle = "Go"
    let codexGlowColor = Color.blue
    init(notchVM: NotchViewModel) { self.notchVM = notchVM }
    func goToAskingSession() {}
    // The 다음 단계 드롭다운 has its own view; this fixture checks the plain question.
    func wrapUpDropdown(_ request: ClaudeInputRequest) -> some View { EmptyView() }
    func peekHeight<V: View>(for view: V, width: CGFloat) -> CGFloat { 0 }
    func resetClosedJellyReveal() {}
    // Nothing else holds the dropdown here, so restoring it means closing it.
    func restorePeek() { notchVM.close() }
'''
for signature in ["private var questionNoticeColor:",
                  "private var questionContent:", "private var plainQuestionContent:",
                  "private struct QuestionOptionsView:"]:
    questions += block(signature) + "\n"
if "private var questionHeader:" in view:
    header = block("private var questionHeader:")
    questions += header.replace("goToAskingSession()", "self.goToAskingSession()").replace("dismissQuestionNotice()", "self.dismissQuestionNotice()") + "\n"
for signature in ["private func triggerCodexInputNotice(", "private func triggerClaudeInputNotice(",
                  "private func showInputNotice(",
                  "private func dismissQuestionNotice("]:
    questions += block(signature).replace("private func", "func", 1) + "\n"
questions += "}\n"
questions += '''
@MainActor final class NotchChromeFixture {
    struct State {
        var isLocked = false
        var activePlaceName: String?
        var sessionsNeedingPermission: [Int] = []
        var sessionsAwaitingInput: [Int] = []
        var closedNotchLowBattery: Int?
        var pendingInputRequests: [CodexInputRequest] = []
        var showSourceCodex = true
    }
    let notchVM = NotchViewModel()
    var anyAIActive = false
    var keyboardLockManager = State()
    var tetherMonitor = State()
    var claudeCodeManager = State()
    var codexManager = State()
    var batteryManager = State()
    var settings = State()
    var doneFlash: Int?
'''
questions += block("private var baseNotchActive:").replace("private var", "var", 1) + "\n}\n"
questions += '''
enum ClosedLowBatteryBadge {
    static func width(for device: Int) -> CGFloat { 0 }
}
@MainActor final class ClosedWingFixture {
    struct Claude {
        var state = ClaudeCodeState()
        var sessionStates: [String: ClaudeCodeState] = [:]
        var pendingInputRequests: [ClaudeInputRequest] = []
        var sessionsNeedingPermission: [Int] = []
        var hasAnySessionActivity: Bool { state.isActive }
    }
    struct Codex {
        var state = CodexState()
        var sessionStates: [String: CodexState] = [:]
        var pendingInputRequests: [CodexInputRequest] = []
        var hasAnySessionActivity: Bool { state.isActive }
    }
    struct Settings {
        var showSourceCodex = true
        var showSourceClaudeCode = true
        var showPermissionIndicator = true
    }
    struct Tether {
        var activePlaceName: String?
        var connectedLabel = ""
    }
    var claudeCodeManager = Claude()
    var codexManager = Codex()
    var settings = Settings()
    var keyboardLockManager = NotchChromeFixture.State()
    var batteryManager = NotchChromeFixture.State()
    var tetherMonitor = Tether()
    let notchVM = NotchViewModel()
    var closedDisplayedLabel = ""
    struct DoneFlash { enum Source { case claude, codex }; let id = UUID(); let source: Source }
    var doneFlash: DoneFlash?
    var claudeHasRealActivity: Bool { claudeCodeManager.state.isActive }
    var codexHasRealActivity: Bool { settings.showSourceCodex && codexManager.state.isActive }
    func extractCodexModelName(_ value: String) -> String? { nil }
    func extractModelName(_ value: String) -> String? { nil }
    func layout() -> (leftVisible: Bool, claudeOnRight: Bool, leftWidth: CGFloat, rightWidth: CGFloat) {
'''
# Run the exact closed-header decisions and width calculations, without its view rendering.
questions += block("private var closedHeader:").split("{", 1)[1].split("        if !hasAnyContent {")[0]
questions += '''
        return (hasLeftWing, showsSimultaneousClaudeWing, leftWingWidth, baseRightWingWidth)
    }
}
'''
with tempfile.TemporaryDirectory(prefix="clangnotch-layout-checks-") as folder:
    temp = Path(folder)
    enum_file = temp / "NotchMode.swift"
    enum_file.write_text("import SwiftUI\nimport AppKit\nfunc L(_ korean: String, _ english: String) -> String { korean }\n" + mode + questions)
    binary = temp / "checks"
    subprocess.run([
        "xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
        str(root / "ClangNotch/Models/NotchSizing.swift"),
        str(root / "ClangNotch/Models/NotchViewModel.swift"),
        str(root / "ClangNotch/Models/CodexModels.swift"),
        str(root / "ClangNotch/Models/AgentInputModels.swift"),
        str(root / "ClangNotch/Models/ClaudeCodeModels.swift"),
        str(root / "ClangNotch/Views/Notch/NotchShape.swift"),
        str(root / "ClangNotch/Views/Notch/DoneCheckmarkView.swift"),
        str(root / "ClangNotch/Views/Notch/NotchMotion.swift"),
        str(root / "ClangNotch/Views/Notch/ThinScrollers.swift"),
        str(root / "ClangNotch/Window/NotchDetector.swift"),
        str(enum_file), str(root / "tests/NotchLayoutChecks.swift"),
        "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary)], check=True)
