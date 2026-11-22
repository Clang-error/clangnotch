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
    /// In the wing header the capsule can't open leftward (the camera is there): it hangs under
    /// the X instead, 창만 닫기 at its right end (user, 2026-11-18: the capsule, not a menu).
    var dropsDown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if dropsDown { droppingDown } else { openingLeft }
    }

    private var xButton: some View {
        Button {
            withAnimation(reduceMotion ? .easeOut(duration: 0.12) : notchOpenSpring) { expanded.toggle() }
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 10 * scale, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(NotchPalette.ink.opacity(expanded ? 0.14 : 0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(L("닫기", "Dismiss"))
    }

    private var droppingDown: some View {
        xButton
            .overlay(alignment: .topTrailing) {
                if expanded {
                    // The capsule as it opens leftward, hung under the X: 창만 닫기 right under it.
                    HStack(spacing: 0) {
                        DismissPillOption(title: L("알림도 지우기", "Clear notice too"), scale: scale, action: onClear)
                        Rectangle()
                            .fill(NotchPalette.ink.opacity(0.14))
                            .frame(width: 1, height: 12 * scale)
                        DismissPillOption(title: L("창만 닫기", "Close only"), scale: scale, action: onCollapse)
                    }
                    .fixedSize()
                    // Opaque over the body text under it.
                    .background(Capsule().fill(NotchPalette.ink.opacity(0.09)).background(Capsule().fill(NotchPalette.inkInverse)))
                    .overlay(Capsule().stroke(NotchPalette.ink.opacity(0.14)))
                    .clipShape(Capsule())
                    // Laid out under the X, not offset there: an offset left its hover area over
                    // the X, so moving off the X toward it read as leaving it and folded it.
                    .alignmentGuide(.top) { $0[.top] - 26 }
                    .onHover { inside in
                        guard !inside else { return }
                        withAnimation(reduceMotion ? .easeOut(duration: 0.12) : notchCloseAnimation) { expanded = false }
                    }
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.4, anchor: .topTrailing).combined(with: .opacity))
                }
            }
    }

    private var openingLeft: some View {
        ZStack(alignment: .trailing) {
            if expanded {
                HStack(spacing: 0) {
                    DismissPillOption(title: L("알림도 지우기", "Clear notice too"), scale: scale, action: onClear)
                    Rectangle()
                        .fill(NotchPalette.ink.opacity(0.14))
                        .frame(width: 1, height: 12 * scale)
                    DismissPillOption(title: L("창만 닫기", "Close only"), scale: scale, action: onCollapse)
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
    /// When this request was first drawn. A click meant for the one before it (gone by timeout
    /// or answered in the terminal) can land on 허용 right after it is replaced.
    @State private var shownAt = Date()
    static let clickGuard: TimeInterval = 0.5
    /// 설정 -> 보안 can let a flagged or unread command through for someone who knows the risk.
    @ObservedObject private var settings = AppSettings.shared

    /// Shorter under the risk banner, so the dropdown stays under `maximumPeekHeight`.
    private var expandedHeight: CGFloat { item.risks.isEmpty ? 150 : 90 }
    private var text: PermissionText { item.text }
    private var blockedByRisk: Bool { !item.risks.isEmpty && !settings.permissionAllowFlagged }
    private var canAllow: Bool {
        !blockedByRisk && (text.isWhole || settings.permissionAllowUnread || (expanded && seenEnd && !text.isTooLong))
    }
    static let warning = Color(red: 1, green: 0.42, blue: 0.36)
    /// 허용's blue (the user's pick, Claude draft 1), whichever agent asks.
    static let allowBlue = Color(red: 0.04, green: 0.52, blue: 1.0)

    /// Who asks, which of how many and the time left are in the wing header (`PermissionPeekHeader`).
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(item.toolName)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundColor(NotchPalette.ink)
                Text(item.projectName)
                    .font(.system(size: 12))
                    .foregroundColor(NotchPalette.ink.opacity(0.5))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .popIn()

            if !item.risks.isEmpty { riskBanner }

            if !text.full.isEmpty {
                VStack(alignment: .leading, spacing: 3) { detailText }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(NotchPalette.ink.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .popIn(delay: 0.035)
            }

            HStack(spacing: 6) {
                PeekBarButton(title: inTerminal ? L("터미널에서", "In terminal") : L("GUI에서", "In app"),
                              icon: inTerminal ? "terminal" : "macwindow", style: .ghost) { onDecide(.terminal) }
                    .help(L("노치에서 답하지 않고 에이전트의 승인 창으로 넘기기", "Leave this one to the agent's own approval prompt"))
                PeekBarButton(title: L("거부", "Deny")) { onDecide(.deny) }
                allowButton
                    .frame(minWidth: 160)
            }
            .popIn(delay: 0.07)
        }
        .padding(.top, 6)
    }

    /// 허용, filled for the time left (it drains to empty when the request goes back to the
    /// agent's prompt), or locked with the reason in two or three words.
    private var allowButton: some View {
        Button { if canAllow, Date().timeIntervalSince(shownAt) >= Self.clickGuard { onDecide(.allow) } } label: {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(canAllow ? Self.allowBlue.opacity(0.35) : NotchPalette.ink.opacity(0.07))
                if canAllow {
                    GeometryReader { geometry in
                        Rectangle().fill(Self.allowBlue).frame(width: geometry.size.width * timeLeft)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                HStack(spacing: 5) {
                    if !canAllow { Image(systemName: "lock.fill").font(.system(size: 10, weight: .semibold)) }
                    if canAllow {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let left = Int(max(0, PermissionRequestCenter.waitLimit - context.date.timeIntervalSince(item.receivedAt)).rounded(.up))
                            Text(L("허용 · \(left)초", "Allow · \(left)s")).monospacedDigit()
                        }
                    } else {
                        Text(lockReason)
                    }
                }
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(canAllow ? .white : NotchPalette.ink.opacity(0.4))
                .frame(maxWidth: .infinity)
            }
            .frame(height: 32)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!canAllow)
        .help(canAllow ? "" : blockedByRisk
              ? L("터미널에서 확인", "Check it in the terminal")
              : text.isTooLong
              ? L("노치에서 허용하기엔 긴 명령 (보안)", "Too long to allow from the notch (security)")
              : L("전체 보기로 끝까지 본 뒤 허용", "Show all of it before allowing"))
        .onAppear {
            let remaining = max(0, PermissionRequestCenter.waitLimit - Date().timeIntervalSince(item.receivedAt))
            timeLeft = remaining / PermissionRequestCenter.waitLimit
            withAnimation(.linear(duration: remaining)) { timeLeft = 0 }
        }
    }

    /// Why 허용 is off, as short as the button allows; the tooltip says it in full.
    private var lockReason: String {
        if blockedByRisk { return L("터미널에서 확인", "Check in terminal") }
        if text.isTooLong { return L("너무 길어 불가", "Too long") }
        return L("끝까지 보면 허용", "Read it all first")
    }

    /// Why this one is risky, one red chip per sign.
    private var riskBanner: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(item.risks, id: \.self) { risk in
                Label(risk.reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(Self.warning)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Self.warning.opacity(0.16), in: Capsule())
            }
        }
        .popIn(delay: 0.02)
    }

    @ViewBuilder
    private var detailText: some View {
        let font = Font.system(size: 11.5, design: .monospaced)
        let ink = NotchPalette.ink.opacity(0.9)
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
            Text(L("↓ 끝까지 내리면 허용", "↓ Scroll to the end to allow"))
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

    /// The agent, "다음 단계" and the 닫기 알약 are in the wing header (`AskPeekHeader`).
    var body: some View {
        let question = request.questions.first
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                if let recap = request.recap, !recap.isEmpty {
                    (Text(projectName.isEmpty ? "" : projectName + " · ").foregroundColor(NotchPalette.ink).fontWeight(.semibold)
                        + Text(recap).foregroundColor(NotchPalette.ink.opacity(0.55)))
                        .font(.system(size: 12.5))
                        .lineSpacing(2)
                        .lineLimit(3)
                }
                Text(question?.question ?? "")
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundColor(NotchPalette.ink)
                    .lineLimit(3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .popIn(delay: 0.035)

            HStack(spacing: 6) {
                // The app's buttons: hovering shows the message each one sends. They are
                // labels until the notch can answer, then buttons in the agent's colour.
                ForEach(Array((question?.options ?? []).enumerated()), id: \.offset) { _, option in
                    PeekBarButton(title: option.label, style: onPick == nil ? .locked : .tint(accent)) { onPick?(option) }
                        .disabled(onPick == nil)
                        .help(option.description)
                }
                PeekBarButton(title: openTitle, style: .ghost, action: onOpen)
                    .frame(maxWidth: 96)
            }
            .popIn(delay: 0.07)
        }
        .padding(.top, 6)
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


    /// The agent, 완료 and the time it took are in the wing header (`DonePeekHeader`). The body is
    /// laid out like the others: the drawn Done mark, where and what, and the way back; no card
    /// around it (user, 2026-11-18).
    var body: some View {
        // Room under the header and above the button (user, 2026-11-18: it was all packed tight).
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                // The wing's Done mark, drawn large: ring, tick, one pop.
                DoneCheckmarkView(color: accent, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(projectName)
                        .font(.system(size: 12))
                        .foregroundColor(NotchPalette.ink.opacity(0.5))
                        .lineLimit(1)
                    Text(turn.headline ?? L("작업 완료", "Finished"))
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundColor(NotchPalette.ink)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .popIn()
            // On its own line, as wide as the dropdown, like the others' bottom bar: Done is read
            // at a glance and the way back should be easy to hit (user, 2026-11-18).
            PeekBarButton(title: openTitle, icon: "terminal", action: onOpen)
                .newHighlight(cornerRadius: 10, delay: 0.25)
                .popIn(delay: 0.07)
        }
        .padding(.top, 14)
        .id(turn.id)
    }
}


// MARK: - Wing header layout (2026-11-18, the user's pick: Claude draft 1, Done from Gemini draft 3)

/// A dropdown's first row, beside the camera: `left` in the space left of the physical notch,
/// `right` in the space right of it, each `side` wide. Nothing goes over the housing.
struct WingHeader<Left: View, Right: View>: View {
    let side: CGFloat
    @ViewBuilder let left: Left
    @ViewBuilder let right: Right

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) { left }
                .frame(width: max(0, side), alignment: .leading)
            Spacer(minLength: 0)
            HStack(spacing: 6) { right }
                .frame(width: max(0, side), alignment: .trailing)
        }
        .lineLimit(1)
    }
}

/// The 권한 드롭다운's wing header: the agent, 권한 and which of how many on the left; "위험한 명령"
/// when it is, and an X, on the right. The time left is on 허용 itself (user, 2026-11-18: not twice).
struct PermissionPeekHeader: View {
    let item: PermissionRequestItem
    let position: Int
    let total: Int
    let accent: Color
    let side: CGFloat
    /// The X: no answer from the notch, the agent asks in its own prompt.
    let onClose: () -> Void

    var body: some View {
        WingHeader(side: side) {
            AgentIcon(agent: item.agent)
            Text(L("권한", "Permission"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(accent)
            if total > 1 {
                Text("\(position)/\(total)")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundColor(NotchPalette.ink.opacity(0.5))
            }
        } right: {
            // On the right: the left side has no room for it beside 권한 (user, 2026-11-18).
            if !item.risks.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text(L("위험한 명령", "Risky"))
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(PermissionDropdownView.warning)
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(NotchPalette.ink.opacity(0.7))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(NotchPalette.ink.opacity(0.08)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(L("노치에서 답하지 않고 에이전트의 승인 창으로 넘기기", "Leave this one to the agent's own approval prompt"))
        }
        .popIn()
    }
}

/// The question and next-step dropdowns' wing header: the agent and what it is, and the 닫기 알약.
struct AskPeekHeader: View {
    let agent: PermissionRequestItem.Agent
    let title: String
    let accent: Color
    let side: CGFloat
    @Binding var dismissOpen: Bool
    var scale: CGFloat = 1
    let onDismiss: () -> Void
    let onClear: () -> Void

    var body: some View {
        WingHeader(side: side) {
            AgentIcon(agent: agent)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(accent)
        } right: {
            DismissPill(expanded: $dismissOpen, scale: scale, onCollapse: onDismiss, onClear: onClear, dropsDown: true)
                .foregroundColor(NotchPalette.ink.opacity(0.7))
        }
        .popIn()
    }
}

/// The 완료 드롭다운's wing header, as the others: the agent and 완료 on the left, the time it took
/// and an X on the right.
struct DonePeekHeader: View {
    let agent: PermissionRequestItem.Agent
    let elapsed: TimeInterval?
    let accent: Color
    let side: CGFloat
    let onClose: () -> Void

    var body: some View {
        WingHeader(side: side) {
            AgentIcon(agent: agent)
            Text(L("완료", "Done"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(accent)
        } right: {
            if let elapsed, elapsed >= 1 {
                let seconds = Int(elapsed.rounded())
                Text(seconds < 60 ? L("\(seconds)초", "\(seconds)s") : L("\(seconds / 60)분 \(seconds % 60)초", "\(seconds / 60)m \(seconds % 60)s"))
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundColor(NotchPalette.ink.opacity(0.55))
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(NotchPalette.ink.opacity(0.7))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(NotchPalette.ink.opacity(0.08)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(L("닫기", "Dismiss"))
        }
        .popIn()
    }
}

/// A button in a dropdown's bottom bar: as tall as the bar, filling its share of the width.
struct PeekBarButton: View {
    enum Style { case ghost, grey, tint(Color), locked }
    let title: String
    var icon: String? = nil
    var style: Style = .grey
    var height: CGFloat = 32
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon).font(.system(size: 11, weight: .semibold)) }
                Text(title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
            }
            .foregroundColor(foreground)
            // Room either side, so a button sized to its words (터미널 열기) isn't tight.
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(fill))
            .overlay {
                if case .ghost = style {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(NotchPalette.ink.opacity(0.22))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var foreground: Color {
        switch style {
        case .ghost: NotchPalette.ink.opacity(0.75)
        case .grey: NotchPalette.ink
        case .tint(let color): color
        case .locked: NotchPalette.ink.opacity(0.38)
        }
    }

    private var fill: Color {
        switch style {
        case .ghost: NotchPalette.ink.opacity(hovering ? 0.06 : 0)
        case .grey: NotchPalette.ink.opacity(hovering ? 0.18 : 0.12)
        case .tint(let color): color.opacity(hovering ? 0.28 : 0.2)
        case .locked: NotchPalette.ink.opacity(0.07)
        }
    }
}
