import SwiftUI

/// The agent's logo at wing size: Claude in its own colours, Codex tinted white.
private struct AgentIcon: View {
    let agent: PermissionRequestItem.Agent

    var body: some View {
        Group {
            if agent == .claude {
                Image("ClaudeIcon").resizable()
            } else {
                Image("ChatGPTIcon").resizable().foregroundColor(NotchPalette.ink)
            }
        }
        .frame(width: 13, height: 13)
    }
}

struct DropdownButton: View {
    let title: String
    let tint: Color
    var filled = false
    /// The enlarged 질문 드롭다운 draws everything this much bigger.
    var scale: CGFloat = 1
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11 * scale, weight: .semibold))
                .foregroundColor(filled ? .black : tint)
                .padding(.horizontal, 12 * scale)
                .padding(.vertical, 5 * scale)
                .background(Capsule().fill(filled ? tint.opacity(hovering ? 1 : 0.9) : NotchPalette.ink.opacity(hovering ? 0.16 : 0.09)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// 닫기 알약: a dropdown's X. The first click closes nothing; it opens leftward into a
/// capsule with two choices. 창만 닫기 lands where the X was, so clicking twice in place
/// still just folds the dropdown. Moving the cursor off the capsule folds it back into the X.
/// The X takes the caller's foreground colour.
struct DismissPill: View {
    @Binding var expanded: Bool
    /// The enlarged 질문 드롭다운 draws everything this much bigger.
    var scale: CGFloat = 1
    /// 창만 닫기: folds the dropdown, the notice stays.
    let onCollapse: () -> Void
    /// 알림도 지우기: drops the notice as well.
    let onClear: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .trailing) {
            if expanded {
                HStack(spacing: 0) {
                    DismissPillOption(title: L("알림도 지우기", "Clear notice too"), scale: scale, action: onClear)
                        .help(L("알림도 지웁니다 — 다시 뜨지 않습니다", "Clears the notice too — it won't come back"))
                    Rectangle()
                        .fill(NotchPalette.ink.opacity(0.14))
                        .frame(width: 1, height: 12 * scale)
                    DismissPillOption(title: L("창만 닫기", "Close only"), scale: scale, action: onCollapse)
                        .help(L("알림 접기 — 질문 대기는 유지됩니다", "Collapse — the question stays pending"))
                }
                .background(NotchPalette.ink.opacity(0.09))
                .clipShape(Capsule())
                // Leaving the capsule without choosing puts the X back.
                .onHover { inside in
                    guard !inside else { return }
                    withAnimation(reduceMotion ? .easeOut(duration: 0.12) : notchCloseAnimation) { expanded = false }
                }
                .transition(reduceMotion ? .opacity : .scale(scale: 0.4, anchor: .trailing).combined(with: .opacity))
            } else {
                Button {
                    withAnimation(reduceMotion ? .easeOut(duration: 0.12) : notchOpenSpring) { expanded = true }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10 * scale))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("닫기", "Dismiss"))
                .transition(.opacity)
            }
        }
    }
}

/// One half of the open 닫기 알약. At the usual size it is as tall as the X's frame, so
/// the header keeps its height.
private struct DismissPillOption: View {
    let title: String
    let scale: CGFloat
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10 * scale, weight: .medium))
                .foregroundColor(NotchPalette.ink.opacity(0.85))
                .fixedSize()
                .padding(.horizontal, 9 * scale)
                .frame(height: 22 * scale)
                .background(NotchPalette.ink.opacity(hovering ? 0.08 : 0))
                .contentShape(Rectangle())
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
                    .foregroundColor(NotchPalette.ink)
                Text(item.projectName)
                    .font(.system(size: 11))
                    .foregroundColor(NotchPalette.ink.opacity(0.55))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if total > 1 {
                    Text("\(position)/\(total)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(NotchPalette.ink.opacity(0.55))
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
                        .foregroundColor(NotchPalette.ink.opacity(0.88))
                        .lineLimit(3)
                        .truncationMode(.middle)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(NotchPalette.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .popIn(delay: 0.035)

            HStack(spacing: 8) {
                Button { onDecide(.terminal) } label: {
                    Label(inTerminal ? L("터미널에서", "In terminal") : L("GUI에서", "In app"),
                          systemImage: inTerminal ? "terminal" : "macwindow")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(NotchPalette.ink.opacity(0.6))
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("노치에서 답하지 않고 에이전트의 승인 창으로 넘기기", "Leave this one to the agent's own approval prompt"))
                Spacer(minLength: 0)
                DropdownButton(title: L("거부", "Deny"), tint: NotchPalette.ink.opacity(0.85)) { onDecide(.deny) }
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
    /// The 닫기 알약: whether it is open, its 창만 닫기 and its 알림도 지우기.
    @Binding var dismissOpen: Bool
    let onDismiss: () -> Void
    let onClear: () -> Void

    var body: some View {
        let question = request.questions.first
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                AgentIcon(agent: .claude)
                Text("Next step")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(NotchPalette.ink)
                Text(projectName)
                    .font(.system(size: 11))
                    .foregroundColor(NotchPalette.ink.opacity(0.55))
                    .lineLimit(1)
                Spacer(minLength: 0)
                DismissPill(expanded: $dismissOpen, onCollapse: onDismiss, onClear: onClear)
                    .foregroundColor(NotchPalette.ink.opacity(0.55))
            }
            .popIn()

            VStack(alignment: .leading, spacing: 4) {
                if let recap = request.recap, !recap.isEmpty {
                    Text(recap)
                        .font(.system(size: 11))
                        .foregroundColor(NotchPalette.ink.opacity(0.6))
                        .lineLimit(3)
                }
                Text(question?.question ?? "")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(NotchPalette.ink.opacity(0.92))
                    .lineLimit(3)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(NotchPalette.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .popIn(delay: 0.035)

            HStack(spacing: 6) {
                // The app's buttons, as labels: hovering shows the message each one sends.
                ForEach(Array((question?.options ?? []).enumerated()), id: \.offset) { _, option in
                    Text(option.label)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(NotchPalette.ink.opacity(0.7))
                        .lineLimit(1)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .overlay(Capsule().stroke(NotchPalette.ink.opacity(0.18)))
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
                            .foregroundColor(NotchPalette.ink.opacity(0.55))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if let elapsedText {
                            Text(elapsedText)
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundColor(NotchPalette.ink.opacity(0.55))
                        }
                    }
                    Text(turn.headline ?? L("작업을 마쳤습니다.", "Finished."))
                        .font(.system(size: 12))
                        .foregroundColor(NotchPalette.ink.opacity(0.88))
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
