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
    let codexGlowColor = Color.blue
    init(notchVM: NotchViewModel) { self.notchVM = notchVM }
    func goToAskingSession() {}
    func resetClosedJellyReveal() {}
'''
for signature in ["private var questionNoticeColor:",
                  "private var questionContent:", "private struct QuestionOptionsView:"]:
    questions += block(signature) + "\n"
if "private var questionHeader:" in view:
    header = block("private var questionHeader:")
    questions += header.replace("goToAskingSession()", "self.goToAskingSession()").replace("dismissQuestionNotice()", "self.dismissQuestionNotice()") + "\n"
for signature in ["private func triggerCodexInputNotice(", "private func triggerClaudeInputNotice(",
                  "private func showInputNotice(",
                  "private func dismissQuestionNotice("]:
    questions += block(signature).replace("private func", "func", 1) + "\n"
questions += "}\n"
with tempfile.TemporaryDirectory(prefix="clangnotch-layout-checks-") as folder:
    temp = Path(folder)
    enum_file = temp / "NotchMode.swift"
    enum_file.write_text("import SwiftUI\nimport AppKit\n" + mode + questions)
    binary = temp / "checks"
    subprocess.run([
        "xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
        str(root / "ClangNotch/Models/NotchSizing.swift"),
        str(root / "ClangNotch/Models/NotchViewModel.swift"),
        str(root / "ClangNotch/Models/CodexModels.swift"),
        str(root / "ClangNotch/Models/AgentInputModels.swift"),
        str(root / "ClangNotch/Models/ClaudeCodeModels.swift"),
        str(root / "ClangNotch/Views/Notch/NotchShape.swift"),
        str(root / "ClangNotch/Window/NotchDetector.swift"),
        str(enum_file), str(root / "tests/NotchLayoutChecks.swift"),
        "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary)], check=True)
