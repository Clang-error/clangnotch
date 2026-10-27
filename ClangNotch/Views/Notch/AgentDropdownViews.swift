import SwiftUI

/// The agent's logo at wing size: Claude in its own colours, Codex tinted white.
private struct AgentIcon: View {
    let agent: PermissionRequestItem.Agent

    var body: some View {
        Group {
            if agent == .claude {
                Image("ClaudeIcon").resizable()
            } else {
                Image("ChatGPTIcon").resizable().foregroundColor(.white)
            }
        }
        .frame(width: 13, height: 13)
    }
}

private struct DropdownButton: View {
    let title: String
    let tint: Color
    var filled = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(filled ? .black : tint)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Capsule().fill(filled ? tint.opacity(hovering ? 1 : 0.9) : Color.white.opacity(hovering ? 0.16 : 0.09)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// 권한 드롭다운: one tool approval at a time, oldest first, with the time left before the
/// request goes back to the agent's own dialog.
struct PermissionDropdownView: View {
    let item: PermissionRequestItem
    let position: Int
    let total: Int
    let accent: Color
    /// Where the agent's own prompt shows: its terminal, or a GUI app.
    var inTerminal = true
    let onDecide: (PermissionRequestCenter.Decision) -> Void
    @State private var timeLeft: CGFloat = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                AgentIcon(agent: item.agent)
                Text("Permission")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                Text(item.projectName)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.55))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if total > 1 {
                    Text("\(position)/\(total)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.55))
                }
            }
            .popIn()

            VStack(alignment: .leading, spacing: 3) {
                Text(item.toolName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(accent)
                if !item.detail.isEmpty {
                    Text(item.detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white.opacity(0.88))
                        .lineLimit(3)
                        .truncationMode(.middle)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .popIn(delay: 0.035)

            HStack(spacing: 8) {
                Button { onDecide(.terminal) } label: {
                    Label(inTerminal ? L("터미널에서", "In terminal") : L("GUI에서", "In app"),
                          systemImage: inTerminal ? "terminal" : "macwindow")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("노치에서 답하지 않고 에이전트의 승인 창으로 넘기기", "Leave this one to the agent's own approval prompt"))
                Spacer(minLength: 0)
                DropdownButton(title: L("거부", "Deny"), tint: .white.opacity(0.85)) { onDecide(.deny) }
                DropdownButton(title: L("허용", "Allow"), tint: accent, filled: true) { onDecide(.allow) }
                    .newHighlight(cornerRadius: 12, delay: 0.25)
            }
            .popIn(delay: 0.07)

            // Drains over the wait; empty means the agent asks in its own prompt instead.
            Capsule()
                .fill(accent.opacity(0.55))
                .frame(height: 2)
                .scaleEffect(x: timeLeft, anchor: .leading)
                .onAppear {
                    let remaining = max(0, PermissionRequestCenter.waitLimit - Date().timeIntervalSince(item.receivedAt))
                    timeLeft = remaining / PermissionRequestCenter.waitLimit
                    withAnimation(.linear(duration: remaining)) { timeLeft = 0 }
                }
        }
        .padding(.top, 10)
        .id(item.id)
    }
}

/// 다음 단계 드롭다운: the Claude desktop app's next-step box, drawn like the 권한 드롭다운.
/// Its buttons send a prepared message in the app, so here they only show what each would
/// say; the way to answer is the app itself.
struct WrapUpDropdownView: View {
    let request: ClaudeInputRequest
    let projectName: String
    let accent: Color
    let openTitle: String
    let onOpen: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        let question = request.questions.first
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                AgentIcon(agent: .claude)
                Text("Next step")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                Text(projectName)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.55))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.55))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("닫기", "Dismiss"))
            }
            .popIn()

            VStack(alignment: .leading, spacing: 4) {
                if let recap = request.recap, !recap.isEmpty {
                    Text(recap)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.6))
                        .lineLimit(3)
                }
                Text(question?.question ?? "")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.92))
                    .lineLimit(3)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .popIn(delay: 0.035)

            HStack(spacing: 6) {
                // The app's buttons, as labels: hovering shows the message each one sends.
                ForEach(Array((question?.options ?? []).enumerated()), id: \.offset) { _, option in
                    Text(option.label)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                        .lineLimit(1)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .overlay(Capsule().stroke(Color.white.opacity(0.18)))
                        .help(option.description)
                }
                Spacer(minLength: 0)
                DropdownButton(title: openTitle, tint: accent, filled: true, action: onOpen)
                    .newHighlight(cornerRadius: 12, delay: 0.25)
            }
            .popIn(delay: 0.07)
        }
        .padding(.top, 10)
        .id(request.id)
    }
}

/// 완료 드롭다운: what a turn ended with, and the way back to its terminal or app.
struct DoneDropdownView: View {
    let agent: PermissionRequestItem.Agent
    let projectName: String
    let turn: CompletedTurn
    let accent: Color
    var openTitle = L("터미널 열기", "Open terminal")
    let onOpen: () -> Void

    private var elapsedText: String? {
        guard let elapsed = turn.elapsed, elapsed >= 1 else { return nil }
        let seconds = Int(elapsed.rounded())
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                // The wing's Done mark, drawn large: ring, tick, one pop.
                DoneCheckmarkView(color: accent, size: 34)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("Done")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(accent)
                        AgentIcon(agent: agent)
                        Text(projectName)
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.55))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if let elapsedText {
                            Text(elapsedText)
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundColor(.white.opacity(0.55))
                        }
                    }
                    Text(turn.headline ?? L("작업을 마쳤습니다.", "Finished."))
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.88))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .popIn()

            HStack {
                Spacer(minLength: 0)
                DropdownButton(title: openTitle, tint: accent, filled: true, action: onOpen)
                    .newHighlight(cornerRadius: 12, delay: 0.25)
            }
            .popIn(delay: 0.07)
        }
        .padding(.top, 10)
        .id(turn.id)
    }
}
