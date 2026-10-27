import SwiftUI
import AppKit

func check(_ condition: @autoclosure () -> Bool, _ message: String = "Check failed") {
    guard condition() else {
        print("FAIL: \(message)")
        exit(1)
    }
}

@main
struct NotchLayoutChecks {
    @MainActor
    static func main() async throws {
        _ = NSApplication.shared
        let expected: [NotchMode: CGFloat] = [
            .ai: 600, .clipboard: 600,
            .volume: 600, .battery: 600, .speed: 600,
            .sidecar: 600, .keyboardLock: 600
        ]
        for (mode, width) in expected {
            check(mode.expandedSize == CGSize(width: width, height: 540))
        }
        check(NotchMode.order(from: "battery,ai").prefix(2) == [.battery, .ai])
        check(Set(NotchMode.order(from: "battery,ai")) == Set(NotchMode.allCases))
        check(NotchMode.order(from: "folder,battery,ai").prefix(2) == [.battery, .ai])
        check(Set(NotchMode.order(from: "folder,battery,ai")) == Set(NotchMode.allCases))

        let surface = NotchShape(topCornerRadius: 19, bottomCornerRadius: 24)
            .path(in: CGRect(x: 0, y: 0, width: 420, height: 340))
        check(surface.contains(CGPoint(x: 210, y: 100)))
        check(!surface.contains(CGPoint(x: 5, y: 100)), "Transparent shoulders must pass clicks through")
        check(!surface.contains(CGPoint(x: 20, y: 339)), "Transparent bottom corners must pass through")

        let model = NotchViewModel()
        let closed = model.closedNotchSize
        model.open(size: NotchMode.ai.expandedSize)
        model.resizeOpen(to: NotchMode.keyboardLock.expandedSize)
        check(model.notchState == .open && model.notchSize.width == 600)
        model.peek(duration: nil, additionalHeight: 1000)
        check(model.notchState == .open, "A notification must not replace an open tab")
        model.close()

        model.peek(duration: nil, additionalHeight: 1000, width: openNotchSize.width)
        check(model.notchSize == CGSize(width: 600, height: 340), "Codex questions need the expanded tab width")
        model.close()
        model.peek(duration: nil)
        check(model.notchSize.width == 420, "Other dropdowns must keep their existing width")
        model.close()

        model.peek(duration: 0.04, additionalHeight: 70)
        model.peek(duration: nil, additionalHeight: 1000)
        try await Task.sleep(for: .milliseconds(100))
        check(model.notchState == .peeking, "A replaced peek must cancel its old timer")
        check(model.notchSize == CGSize(width: 420, height: 340))
        model.resizeOpen(to: NotchMode.ai.expandedSize)
        check(model.notchSize.width == 420, "Selected tab width must not leak into a question")
        model.close()

        model.peek(duration: 0.04, additionalHeight: 110)
        model.pausePeekDismissal()
        try await Task.sleep(for: .milliseconds(100))
        check(model.notchState == .peeking, "Reading must cancel automatic dismissal")
        model.close()
        check(model.notchSize == closed)

        model.peek(duration: 0.04)
        model.open(size: NotchMode.sidecar.expandedSize)
        try await Task.sleep(for: .milliseconds(100))
        check(model.notchState == .open && model.notchSize.width == 600)
        model.close()
        model.peek(duration: 0.04)
        try await Task.sleep(for: .milliseconds(100))
        check(model.notchState == .closed && model.notchSize == closed)

        let questions = CodexQuestionLayoutFixture(notchVM: NotchViewModel())
        func request(_ text: String, options: [AgentInputOption] = []) -> CodexInputRequest {
            CodexInputRequest(id: "layout", questions: [AgentInputQuestion(header: "Question", question: text, options: options)])
        }
        let chrome = NotchChromeFixture()
        check(!chrome.baseNotchActive, "A closed idle notch must remain transparent")
        chrome.codexManager.pendingInputRequests = [request("답변 대기")]
        check(chrome.baseNotchActive, "A Codex question must keep the closed notch background visible without active work")
        chrome.settings.showSourceCodex = false
        check(!chrome.baseNotchActive, "A hidden Codex source must not keep the background visible")
        chrome.settings.showSourceCodex = true
        chrome.codexManager.pendingInputRequests.removeAll()
        check(!chrome.baseNotchActive, "Finishing the question must release the idle background")
        chrome.doneFlash = 1
        check(chrome.baseNotchActive, "A Done flash must draw the closed notch background after work ends")
        chrome.doneFlash = nil
        let wings = ClosedWingFixture()
        wings.codexManager.pendingInputRequests = [request("Codex 답변 대기")]
        check(!wings.layout().leftVisible && wings.layout().rightWidth == 58, "A lone question keeps the compact Answer wing")
        wings.claudeCodeManager.state.isThinking = true
        let waitingWithClaude = wings.layout()
        check(waitingWithClaude.leftVisible && waitingWithClaude.claudeOnRight, "A waiting Codex question must not hide Claude's normal right wing")
        check(waitingWithClaude.leftWidth == 58 && waitingWithClaude.rightWidth > 58, "Answer and Claude must each reserve their own content width")
        wings.settings.showSourceCodex = false
        check(wings.layout().leftVisible && !wings.layout().claudeOnRight, "A hidden Codex source must leave Claude in its single-agent layout")
        wings.settings.showSourceCodex = true
        wings.codexManager.pendingInputRequests.removeAll()
        wings.codexManager.state.isThinking = true
        check(wings.layout().leftVisible && wings.layout().claudeOnRight, "The existing two-active-agent layout must stay intact")
        let claudeWait = ClaudeInputRequest(id: "claude-wait", input: ["questions": [["question": "Claude 답변 대기"]]])
        wings.claudeCodeManager.pendingInputRequests = [claudeWait]
        wings.claudeCodeManager.state.activeTools = [ClaudeToolExecution(id: "claude-wait", toolName: "AskUserQuestion", argument: nil, startTime: Date())]
        check(wings.layout().leftVisible && !wings.layout().claudeOnRight && wings.layout().rightWidth == 58, "A Claude question must show Answer on the right while Codex keeps its left wing")
        wings.codexManager.pendingInputRequests = [request("Codex 답변 대기")]
        check(wings.layout().leftVisible && wings.layout().leftWidth == 58 && wings.layout().rightWidth == 58 && !wings.layout().claudeOnRight, "Two waiting agents must each show a compact Answer instead of AskUserQuestion")
        wings.codexManager.pendingInputRequests.removeAll()
        wings.codexManager.state.isThinking = false
        check(!wings.layout().leftVisible && wings.layout().rightWidth == 58, "A lone Claude question must keep its compact right Answer")
        wings.doneFlash = .init(source: .claude)
        check(!wings.layout().leftVisible && wings.layout().rightWidth == 58, "A waiting question must keep Answer over Done")
        wings.claudeCodeManager.pendingInputRequests.removeAll()
        wings.claudeCodeManager.state.activeTools.removeAll()
        let done = wings.layout()
        check(done.leftVisible && done.rightWidth == DoneCheckmarkView.size && done.leftWidth > 18, "Done takes the left wing and the check the right wing on an idle notch")
        wings.claudeCodeManager.state.isThinking = true
        wings.codexManager.state.isThinking = true
        check(!wings.layout().claudeOnRight && wings.layout().rightWidth == DoneCheckmarkView.size, "Done replaces the two-agent layout for its moment")
        wings.claudeCodeManager.state.isThinking = false
        wings.codexManager.state.isThinking = false
        wings.doneFlash = nil
        questions.triggerCodexInputNotice(request("짧은 질문"))
        let shortHeight = questions.notchVM.notchSize.height
        check(shortHeight < 170, "A short question must not leave a large empty band")
        let options = ["첫 번째", "두 번째", "세 번째"].map { AgentInputOption(label: $0, description: "") }
        questions.triggerCodexInputNotice(request("짧은 질문", options: options))
        let choicesHeight = questions.notchVM.notchSize.height
        check(choicesHeight > shortHeight && choicesHeight < 230, "Compact options need their actual line heights")
        questions.triggerCodexInputNotice(request(String(repeating: "여러 줄로 표시해야 하는 긴 질문입니다. ", count: 5), options: options))
        check(questions.notchVM.notchSize.height > choicesHeight, "Wrapped question text must increase the dropdown height")
        let described = options.map { AgentInputOption(label: $0.label, description: "선택지에 대한 추가 설명입니다.") }
        questions.triggerCodexInputNotice(request("짧은 질문", options: described))
        check(questions.notchVM.notchSize.height > choicesHeight, "Option descriptions must contribute their rendered height")
        questions.triggerCodexInputNotice(request("긴 내용", options: [AgentInputOption(label: "선택", description: String(repeating: "아주 긴 설명을 모두 읽을 수 있어야 합니다. ", count: 100))]))
        check(questions.notchVM.notchSize == CGSize(width: 600, height: maximumPeekHeight), "Long content must use the capped scroll viewport")
        questions.triggerCodexInputNotice(request("짧은 질문"))
        check(questions.notchVM.notchSize.height == shortHeight, "A shorter replacement must shrink again")

        let claudeQuestion = CodexQuestionLayoutFixture(notchVM: NotchViewModel())
        claudeQuestion.triggerCodexInputNotice(request("이전 질문"))
        let claudeInput = ClaudeInputRequest(id: "claude", input: ["questions": [["header": "질문", "question": "선택지를 골라 주세요", "options": [["label": "선택", "description": "자세한 설명"]]]]])
        claudeQuestion.triggerClaudeInputNotice(claudeInput)
        check(claudeQuestion.notchVM.notchSize.width == 600)
        check(claudeQuestion.codexInputRequest == nil && claudeQuestion.claudeInputRequest == claudeInput, "Replacing a question must use the new source")
        try await Task.sleep(for: .seconds(13))
        check(claudeQuestion.showQuestionNotice && claudeQuestion.notchVM.notchState == .peeking, "An unanswered question must remain after 12 seconds")
        claudeQuestion.dismissQuestionNotice()
        check(!claudeQuestion.showQuestionNotice && claudeQuestion.notchVM.notchState == .closed)
        check(claudeQuestion.claudeInputRequest == claudeInput, "Manual collapse must keep the question pending")
        print("PASS: question layout, Claude waiting past 12s, source replacement and manual collapse")
    }
}
