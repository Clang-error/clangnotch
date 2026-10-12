import SwiftUI
import AppKit

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
            precondition(mode.expandedSize == CGSize(width: width, height: 540))
        }
        precondition(NotchMode.order(from: "battery,ai").prefix(2) == [.battery, .ai])
        precondition(Set(NotchMode.order(from: "battery,ai")) == Set(NotchMode.allCases))
        precondition(NotchMode.order(from: "folder,battery,ai").prefix(2) == [.battery, .ai])
        precondition(Set(NotchMode.order(from: "folder,battery,ai")) == Set(NotchMode.allCases))

        let surface = NotchShape(topCornerRadius: 19, bottomCornerRadius: 24)
            .path(in: CGRect(x: 0, y: 0, width: 420, height: 340))
        precondition(surface.contains(CGPoint(x: 210, y: 100)))
        precondition(!surface.contains(CGPoint(x: 5, y: 100)), "Transparent shoulders must pass clicks through")
        precondition(!surface.contains(CGPoint(x: 20, y: 339)), "Transparent bottom corners must pass through")

        let model = NotchViewModel()
        let closed = model.closedNotchSize
        model.open(size: NotchMode.ai.expandedSize)
        model.resizeOpen(to: NotchMode.keyboardLock.expandedSize)
        precondition(model.notchState == .open && model.notchSize.width == 600)
        model.peek(duration: nil, additionalHeight: 1000)
        precondition(model.notchState == .open, "A notification must not replace an open tab")
        model.close()

        model.peek(duration: nil, additionalHeight: 1000, width: openNotchSize.width)
        precondition(model.notchSize == CGSize(width: 600, height: 340), "Codex questions need the expanded tab width")
        model.close()
        model.peek(duration: nil)
        precondition(model.notchSize.width == 420, "Other dropdowns must keep their existing width")
        model.close()

        model.peek(duration: 0.04, additionalHeight: 70)
        model.peek(duration: nil, additionalHeight: 1000)
        try await Task.sleep(for: .milliseconds(100))
        precondition(model.notchState == .peeking, "A replaced peek must cancel its old timer")
        precondition(model.notchSize == CGSize(width: 420, height: 340))
        model.resizeOpen(to: NotchMode.ai.expandedSize)
        precondition(model.notchSize.width == 420, "Selected tab width must not leak into a question")
        model.close()

        model.peek(duration: 0.04, additionalHeight: 110)
        model.pausePeekDismissal()
        try await Task.sleep(for: .milliseconds(100))
        precondition(model.notchState == .peeking, "Reading must cancel automatic dismissal")
        model.close()
        precondition(model.notchSize == closed)

        model.peek(duration: 0.04)
        model.open(size: NotchMode.sidecar.expandedSize)
        try await Task.sleep(for: .milliseconds(100))
        precondition(model.notchState == .open && model.notchSize.width == 600)
        model.close()
        model.peek(duration: 0.04)
        try await Task.sleep(for: .milliseconds(100))
        precondition(model.notchState == .closed && model.notchSize == closed)

        let questions = CodexQuestionLayoutFixture(notchVM: NotchViewModel())
        func request(_ text: String, options: [AgentInputOption] = []) -> CodexInputRequest {
            CodexInputRequest(id: "layout", questions: [AgentInputQuestion(header: "Question", question: text, options: options)])
        }
        questions.triggerCodexInputNotice(request("짧은 질문"))
        let shortHeight = questions.notchVM.notchSize.height
        precondition(shortHeight < 170, "A short question must not leave a large empty band")
        let options = ["첫 번째", "두 번째", "세 번째"].map { AgentInputOption(label: $0, description: "") }
        questions.triggerCodexInputNotice(request("짧은 질문", options: options))
        let choicesHeight = questions.notchVM.notchSize.height
        precondition(choicesHeight > shortHeight && choicesHeight < 230, "Compact options need their actual line heights")
        questions.triggerCodexInputNotice(request(String(repeating: "여러 줄로 표시해야 하는 긴 질문입니다. ", count: 5), options: options))
        precondition(questions.notchVM.notchSize.height > choicesHeight, "Wrapped question text must increase the dropdown height")
        let described = options.map { AgentInputOption(label: $0.label, description: "선택지에 대한 추가 설명입니다.") }
        questions.triggerCodexInputNotice(request("짧은 질문", options: described))
        precondition(questions.notchVM.notchSize.height > choicesHeight, "Option descriptions must contribute their rendered height")
        questions.triggerCodexInputNotice(request("긴 내용", options: [AgentInputOption(label: "선택", description: String(repeating: "아주 긴 설명을 모두 읽을 수 있어야 합니다. ", count: 100))]))
        precondition(questions.notchVM.notchSize == CGSize(width: 600, height: maximumPeekHeight), "Long content must use the capped scroll viewport")
        questions.triggerCodexInputNotice(request("짧은 질문"))
        precondition(questions.notchVM.notchSize.height == shortHeight, "A shorter replacement must shrink again")

        let claudeQuestion = CodexQuestionLayoutFixture(notchVM: NotchViewModel())
        claudeQuestion.triggerCodexInputNotice(request("이전 질문"))
        let claudeInput = ClaudeInputRequest(id: "claude", input: ["questions": [["header": "질문", "question": "선택지를 골라 주세요", "options": [["label": "선택", "description": "자세한 설명"]]]]])
        claudeQuestion.triggerClaudeInputNotice(claudeInput)
        precondition(claudeQuestion.notchVM.notchSize.width == 600)
        precondition(claudeQuestion.codexInputRequest == nil && claudeQuestion.claudeInputRequest == claudeInput, "Replacing a question must use the new source")
        try await Task.sleep(for: .seconds(13))
        precondition(claudeQuestion.showQuestionNotice && claudeQuestion.notchVM.notchState == .peeking, "An unanswered question must remain after 12 seconds")
        claudeQuestion.dismissQuestionNotice()
        precondition(!claudeQuestion.showQuestionNotice && claudeQuestion.notchVM.notchState == .closed)
        precondition(claudeQuestion.claudeInputRequest == claudeInput, "Manual collapse must keep the question pending")
        print("PASS: question layout, Claude waiting past 12s, source replacement and manual collapse")
    }
}
