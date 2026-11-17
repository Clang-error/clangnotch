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

/// Where the bottom of the 권한 드롭다운's opened text sits in its scroll box.
private struct PermissionEndKey: PreferenceKey {
    static let space = "permissionText"
    static let defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = min(value, nextValue()) }
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
    /// 전체 보기 was pressed: the whole text shows, and 허용 works once it is read to the end.
    var expanded = false
    var onExpand: () -> Void = {}
    let onDecide: (PermissionRequestCenter.Decision) -> Void
    @State private var timeLeft: CGFloat = 1
    @State private var seenEnd = false
    /// 설정 -> 보안 can let a flagged or unread command through for someone who knows the risk.
    @ObservedObject private var settings = AppSettings.shared

    /// Shorter under the risk banner, so the dropdown stays under `maximumPeekHeight`.
    private var expandedHeight: CGFloat { item.risks.isEmpty ? 150 : 90 }
    private var text: PermissionText { item.text }
    private var blockedByRisk: Bool { !item.risks.isEmpty && !settings.permissionAllowFlagged }
    private var canAllow: Bool {
        !blockedByRisk && (text.isWhole || settings.permissionAllowUnread || (expanded && seenEnd && !text.isTooLong))
    }
    private static let warning = Color(red: 1, green: 0.42, blue: 0.36)

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

            if !item.risks.isEmpty { riskBanner }

            VStack(alignment: .leading, spacing: 3) {
                Text(item.toolName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(accent)
                if !text.full.isEmpty { detailText }
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
                DropdownButton(title: L("허용", "Allow"), tint: accent, filled: true) { if canAllow { onDecide(.allow) } }
                    .disabled(!canAllow)
                    .opacity(canAllow ? 1 : 0.35)
                    .help(canAllow ? "" : blockedByRisk
                          ? L("위험 표시가 뜬 요청은 터미널에서 확인해 주세요", "Check a flagged request in the terminal")
                          : text.isTooLong
                          ? L("명령이 너무 길어 노치에서는 허용할 수 없습니다 (보안)", "The command is too long to allow from the notch (security)")
                          : L("전체 보기로 끝까지 본 뒤 허용할 수 있습니다", "Show all of it, to the end, before allowing"))
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

    /// Why this one can't be allowed here, in plain words.
    private var riskBanner: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(item.risks, id: \.self) { risk in
                Label(risk.reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Self.warning)
            }
            if !settings.permissionAllowFlagged {
                Text(L("노치에서는 허용할 수 없습니다. 터미널에서 확인해 주세요.",
                       "Can't be allowed from the notch. Check it in the terminal."))
                    .font(.system(size: 10))
                    .foregroundColor(NotchPalette.ink.opacity(0.6))
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Self.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .popIn(delay: 0.02)
    }

    @ViewBuilder
    private var detailText: some View {
        let font = Font.system(size: 11, design: .monospaced)
        let ink = NotchPalette.ink.opacity(0.88)
        if text.isWhole {
            // No line limit: wrapping grows the box instead of hiding anything.
            Text(text.full)
                .font(font)
                .foregroundColor(ink)
                .fixedSize(horizontal: false, vertical: true)
        } else if expanded && !text.isTooLong {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(text.lines.enumerated()), id: \.offset) { number, line in
                        HStack(alignment: .top, spacing: 6) {
                            Text("\(number + 1)")
                                .foregroundColor(NotchPalette.ink.opacity(0.35))
                                .frame(width: 24, alignment: .trailing)
                            Text(line.isEmpty ? " " : line)
                                .foregroundColor(ink)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .font(font)
                    }
                    // Its bottom inside the box means the last line has been seen.
                    Color.clear.frame(height: 1)
                        .background(GeometryReader { proxy in
                            Color.clear.preference(key: PermissionEndKey.self,
                                                   value: proxy.frame(in: .named(PermissionEndKey.space)).maxY)
                        })
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.visible)
            .coordinateSpace(name: PermissionEndKey.space)
            .frame(height: expandedHeight)
            .onPreferenceChange(PermissionEndKey.self) { bottom in
                if bottom <= expandedHeight + 1 { seenEnd = true }
            }
            // Kept in place once read, so the dropdown's measured height still fits.
            Text(L("↓ 끝까지 내려 보면 허용할 수 있습니다", "↓ Scroll to the end to allow"))
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(NotchPalette.ink.opacity(0.5))
                .opacity(seenEnd || settings.permissionAllowUnread ? 0 : 1)
        } else {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(text.preview.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .font(font)
                        .foregroundColor(ink)
                        .lineLimit(1)
                }
                if text.isTooLong, settings.permissionAllowUnread {
                    EmptyView()
                } else if text.isTooLong {
                    Text(L("… 너무 길어 노치에서는 허용할 수 없음(보안) · 터미널에서 확인", "… Too long to allow here (security) · check in the terminal"))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(NotchPalette.ink.opacity(0.5))
                        .padding(.top, 2)
                } else {
                    Button(action: onExpand) {
                        Text(L("… \(text.lines.count > 1 ? "\(text.lines.count)줄" : "\(text.full.count)자") · 전체 보기",
                               "… \(text.lines.count > 1 ? "\(text.lines.count) lines" : "\(text.full.count) chars") · Show all"))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(accent)
                            .padding(.top, 2)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// 다음 단계 드롭다운: the Claude desktop app's next-step box, drawn like the 권한 드롭다운.
/// Its buttons send a prepared message in the app, so here they only show what each would
/// say and the way to answer is the app itself, unless `onPick` is set.
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
    /// Set while the session's next-step hook waits on the notch (설정 › 실험 기능): the
    /// buttons can be pressed, and the pick goes to Claude.
    var onPick: ((AgentInputOption) -> Void)? = nil

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
                // The app's buttons: hovering shows the message each one sends. They are
                // labels until the notch can answer, then buttons in the agent's colour.
                ForEach(Array((question?.options ?? []).enumerated()), id: \.offset) { _, option in
                    Button { onPick?(option) } label: {
                        Text(option.label)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(onPick == nil ? NotchPalette.ink.opacity(0.7) : accent)
                            .lineLimit(1)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(onPick == nil ? .clear : accent.opacity(0.14)))
                            .overlay(Capsule().stroke(onPick == nil ? NotchPalette.ink.opacity(0.18) : accent.opacity(0.55)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(onPick == nil)
                    .help(option.description)
                }
                Spacer(minLength: 0)
                // Filled as in the 완료 드롭다운, unless the buttons beside it are the ones to press.
                DropdownButton(title: openTitle, tint: accent, filled: onPick == nil, action: onOpen)
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
