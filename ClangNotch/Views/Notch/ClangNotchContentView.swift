import SwiftUI
import Combine
import AppKit

enum NotchMode: String, CaseIterable, Identifiable {
    case ai, clipboard, volume, sidecar, keyboardLock, battery, speed

    var id: String { rawValue }

    var expandedSize: CGSize { openNotchSize }

    /// 탐색 메뉴와 설정에서 표시하는 이름.
    var label: String {
        switch self {
        case .ai:           return "Agents"
        case .clipboard:    return "Clipboard"
        case .volume:       return "Volume"
        case .sidecar:      return "Sidecar"
        case .keyboardLock: return "Keyboard"
        case .battery:      return "Battery"
        case .speed:        return "Speed"
        }
    }

    /// 저장은 rawValue 쉼표 나열. 저장값에 없는 케이스(나중에 추가된 탭)는 뒤에 붙인다.
    static func order(from stored: String) -> [NotchMode] {
        let saved = stored.split(separator: ",").compactMap { NotchMode(rawValue: String($0)) }
        return saved + allCases.filter { !saved.contains($0) }
    }

}

/// Lets the notch take the keyboard while a question's 직접 입력 is typed into
/// (`UICoordinator.notchTyping`). An environment value so the question views stay free of the
/// app's singletons (the layout check compiles them on their own).
private struct NotchTypingKey: EnvironmentKey {
    static let defaultValue: @MainActor (Bool) -> Void = { _ in }
}

extension EnvironmentValues {
    var notchTyping: @MainActor (Bool) -> Void {
        get { self[NotchTypingKey.self] }
        set { self[NotchTypingKey.self] = newValue }
    }
}

struct ClangNotchContentView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var notchVM = NotchViewModel()
    @StateObject private var settings = AppSettings.shared
    @StateObject private var appearance = NotchAppearance.shared
    @StateObject private var claudeCodeManager = ClaudeCodeManager.shared
    @StateObject private var codexManager = CodexManager.shared
    // Not observed: only the tabs they are handed to read what these publish, and a copy
    // or a change in the sounding apps would otherwise redraw the whole notch.
    private let clipboardManager = ClipboardManager.shared
    private let audioMixer = AudioMixerManager.shared
    private let sidecarManager = SidecarManager.shared
    @StateObject private var keyboardLockManager = KeyboardLockManager.shared
    @StateObject private var batteryManager = BatteryManager.shared
    @StateObject private var tetherMonitor = TetherPlaceMonitor.shared
    @StateObject private var nowPlayingMonitor = NowPlayingMonitor.shared
    @StateObject private var speedTest = SpeedTestManager.shared
    /// Which closed wing the cursor rests on (`wingFade`).
    @ObservedObject private var ui = UICoordinator.shared
    @State private var expandedMode: NotchMode = .ai
    @State private var hoverTask: Task<Void, Never>?
    /// Where the open notch's header row sits (`HeaderPlacement`), and the wait for a press to end
    /// before it moves.
    @State private var headerPlacement: HeaderPlacement = .rows
    @State private var headerPlacementTask: Task<Void, Never>?
    @State private var hoverExitNotBefore = Date.distantPast
    @State private var isMenuTracking = false
    @State private var showStartupGlow = false
    @State private var startupGlowTask: Task<Void, Never>?
    @State private var showQuestionNotice = false
    /// The 질문 드롭다운 grown with its 확대 버튼 (Claude questions only).
    @State private var questionExpanded = false
    /// The 닫기 알약 of the 질문 드롭다운 or 다음 단계 드롭다운 is open. Cleared as a dropdown
    /// comes in, not as one goes, so the one folding away keeps showing its capsule.
    @State private var questionDismissOpen = false
    @State private var codexInputRequest: CodexInputRequest?
    @State private var claudeInputRequest: ClaudeInputRequest?
    /// Which question of the dropdown's shows (one at a time), for the wing header's "질문 1/2".
    @State private var questionStep = 0
    /// ⌘ alone is held with the notch open: the 탭 막대 shows each tab's ⌘ number.
    @State private var commandHeld = false
    /// 노치 위치 알림 (user, 2026-11-18): the quiet notch draws its surface and breathes, so its
    /// place shows where nothing marks it (an external display) or where it is black on black
    /// (the camera housing). For a moment at launch, and while the cursor is on it with
    /// 누를 때만 열기 on, where hovering opens nothing. Drawn by `NotchPresenceLayer`.
    @State private var notchPresence = false
    @State private var presenceTask: Task<Void, Never>?
    /// A Claude or Codex turn that just finished normally; the closed wings show Done for 3s.
    @State private var doneFlash: DoneFlash?
    @State private var doneFlashTask: Task<Void, Never>?
    /// Bumped when a working session reaches the hard hat (아이콘 모자), to redraw the wing.
    @State private var hatClock = 0
    @StateObject private var permissionCenter = PermissionRequestCenter.shared
    @State private var showPermissionNotice = false
    /// A `foldPeek` whose clear hasn't run yet; the after-close look leaves the notch to it.
    @State private var foldingPeek = false
    /// The request on screen, kept so the dropdown still shows it while folding away.
    @State private var shownPermission: PermissionRequestItem?
    /// The request whose 전체 보기 was pressed.
    @State private var expandedPermission: UUID?
    /// The session the 세션 화면 shows, opened from a 세션 줄.
    @State private var sessionDetail: SessionDetailTarget?
    @State private var doneNotice: DoneNotice?
    /// The 미디어 드롭다운 attached to the notch (설정 -> 기능 -> 지금 재생 -> 노치에 붙음): the
    /// lowest dropdown, shown only into a closed notch, folding like the 완료 드롭다운.
    @State private var mediaNotice: NowPlaying?
    @State private var mediaNoticeTask: Task<Void, Never>?
    /// 날개에만: the 에어팟 드롭다운's card, laid out for the wings, while it is drawn there.
    @State private var airPodsWingContent: ClosedAirPodsWings?
    /// The cursor is on the notch: the attached player's close button shows only then.
    @State private var notchHovered = false
    /// The attached player's volume row (`MediaVolumeBand`), handed down from here: this view
    /// redraws at once for the notch's own size, and a reading observed further down came in a
    /// render or two later, the row about 0.7 s after the notch had grown for it (2026-11-18).
    @State private var mediaVolumeReading: SystemControlReading?
    /// While the cursor is on the attached player: whether it rests on the camera itself, which
    /// opens the notch as it always does (the player's body holds it instead).
    @State private var housingWatch: Task<Void, Never>?
    @State private var doneNoticeTask: Task<Void, Never>?
    /// A finish that came while another dropdown held the notch; shown once that one goes.
    @State private var pendingDoneNotice: DoneNotice?
    @State private var showSpeedNotice = false
    @State private var speedPeekTask: Task<Void, Never>?
    @State private var speedDismissTask: Task<Void, Never>?
    @State private var tetherPlaceName: String?
    @State private var tetherNoticeTask: Task<Void, Never>?
    @State private var closedJellyScaleX: CGFloat = 1
    @State private var closedJellyScaleY: CGFloat = 1
    @State private var closedJellyContentOpacity: Double = 1
    @State private var showClosedJellyRipple = false
    @State private var closedJellyTask: Task<Void, Never>?
    @State private var showClosedJellyDismiss = false
    @State private var closedJellyDismissTask: Task<Void, Never>?
    @State private var closedDisplayedLabel = ""
    @State private var pendingClosedLabel: String?
    @State private var closedLabelTransitionTask: Task<Void, Never>?
    /// False while the surface resizes between states; the glow waits for it.
    @State private var isGlowSettled = true
    @State private var glowSettleTask: Task<Void, Never>?
    /// Whether the current resize started from the closed notch.
    @State private var glowExpandsFromClosed = false

    private let animationSpring = Animation.interactiveSpring(response: 0.38, dampingFraction: 0.8, blendDuration: 0)
    private var sizeAnimation: Animation {
        guard notchVM.notchState == .closed else { return reduceMotion ? animationSpring : notchOpenSpring }
        // A collapse keeps its own curve until it lands; after that the size only changes
        // for the wings, which must match `closedWingResizeAnimation` on the wing content.
        return notchVM.isSettlingClosed ? notchVM.closeAnimation : closedWingResizeAnimation
    }
    private var modeSwitchAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.12) : .interactiveSpring(response: 0.3, dampingFraction: 0.86)
    }

    private var modeContentTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .blurFade(radius: 6).combined(with: .scale(scale: 0.985, anchor: .top))
    }

    private let errorGlowColor = Color(red: 0.9, green: 0.2, blue: 0.2)
    private let errorBrightColor = Color(red: 1.0, green: 0.3, blue: 0.3)
    private let claudeGlowColor = Color(red: 0.9, green: 0.4, blue: 0.1)
    private let claudeBrightColor = Color(red: 1.0, green: 0.55, blue: 0.2)
    // Raised to Claude-level luminance: the darker blue left the sweeping border
    // looking grainy and sluggish against the black notch.
    private let codexGlowColor = Color(red: 0.2, green: 0.5, blue: 1.0)
    private let codexBrightColor = Color(red: 0.5, green: 0.75, blue: 1.0)
    // The closed wing's GPT icon glow keeps the original Codex blue.
    private let codexIndicatorColor = Color(red: 0.1, green: 0.3, blue: 0.7)
    // Apple Pay's confirmation blue (dark-mode system blue).
    private let doneBlue = Color(red: 0.04, green: 0.52, blue: 1.0)

    private struct DoneFlash: Equatable {
        enum Source { case claude, codex }
        let id = UUID()
        let source: Source
        /// The finished turn; tapping the Done wing goes to its session.
        var turn: CompletedTurn?
    }

    private struct DoneNotice: Equatable {
        let source: DoneFlash.Source
        let turn: CompletedTurn
        let projectName: String
        let at = Date()
    }

    private var isExpanded: Bool {
        notchVM.notchState == .open || notchVM.notchState == .peeking
    }

    /// 설정 › 노치 › 노치 색, for the whole notch, closed wings included.
    private var theme: NotchTheme { appearance.theme(settings) }

    private var notchScheme: ColorScheme { theme.scheme }

    private var topCornerRadius: CGFloat {
        isExpanded ? cornerRadiusInsets.opened.top : cornerRadiusInsets.closed.top
    }

    private var bottomCornerRadius: CGFloat {
        isExpanded ? cornerRadiusInsets.opened.bottom : cornerRadiusInsets.closed.bottom
    }

    /// Determines if Claude Code has real activity (not just grace period)
    private var claudeHasRealActivity: Bool {
        claudeCodeManager.state.isActive
            || claudeCodeManager.sessionStates.values.contains { $0.isActive }
    }

    /// Determines if Codex has real activity (not just grace period)
    private var codexHasRealActivity: Bool {
        settings.showSourceCodex && (codexManager.state.isActive
            || codexManager.sessionStates.values.contains { $0.isActive })
    }

    private var hasSimultaneousClaudeCodexActivity: Bool {
        claudeHasRealActivity && codexHasRealActivity
    }

    /// Any AI source currently active.
    private var anyAIActive: Bool {
        claudeCodeManager.hasAnySessionActivity
            || (settings.showSourceCodex && codexManager.hasAnySessionActivity)
    }

    /// Real work state used for the one-shot closed-notch entrance. Retained idle
    /// sessions do not retrigger it, and tool changes keep the current panel steady.
    private var hasLiveAgentActivity: Bool {
        claudeHasRealActivity || codexHasRealActivity
    }

    private var hasClipboard: Bool {
        settings.enableClipboardHistory
    }

    private var hasVolume: Bool { settings.enableAudioMixer }

    private var hasSidecar: Bool { settings.enableSidecar }

    private var hasBattery: Bool { settings.enableBattery }

    private var hasSpeedTest: Bool { settings.enableSpeedTest }

    /// 열린 헤더는 요약 줄과 헤더 버튼이 물리 노치 아래에 한 줄 더 들어가야 한다. 노치 띠에 올라가
    /// 있으면(`HeaderPlacement.band`) 그 줄이 빠진다.
    private var headerHeight: CGFloat {
        guard notchVM.notchState == .open else { return notchVM.closedNotchSize.height }
        return notchVM.closedNotchSize.height + (headerPlacement == .rows ? openHeaderHeight : 0)
    }

    /// The open notch's header row (요약 줄, tethering, the device chip, the buttons): up in the
    /// 노치 띠 beside the camera while nothing plays there, the row under it otherwise (user's
    /// 시안 A, 2026-11-19). `compact` is the band's shorter form: the status capsule without its
    /// words, tethering without its words, earbuds with their lower side only.
    enum HeaderPlacement: Equatable { case band(compact: Bool), rows }

    /// Where the header row should sit now. Up in the band only when it fits beside the camera,
    /// with 4 pt to spare before going up, so a width right at the edge doesn't flap.
    private var desiredHeaderPlacement: HeaderPlacement {
        guard !nowPlayingMonitor.showsInBand else { return .rows }
        // The open width also while closed, so the placement is ready before the notch opens.
        let width = notchVM.notchState == .open ? notchVM.notchSize.width : openNotchSize.width
        let side = (width - 2 * expandedNotchInset - notchVM.closedNotchSize.width) / 2 - 10
        let room = side - (headerPlacement == .rows ? 4 : 0)
        let tethering = tetherMonitor.activePlaceName != nil
        for compact in [false, true] {
            let left = overviewWidth(compact: compact) + (tethering ? 10 + TetherHeaderChip.width(compact: compact) : 0)
            let chip = HeaderStatusChips.width(compact: compact)
            let right = (chip > 0 ? chip + 8 : 0) + NotchControlGroup.width
            if left <= room && right <= room { return .band(compact: compact) }
        }
        return .rows
    }

    /// Moves the header row. While the notch is open it glides with the notch's spring, but not
    /// under a press: whatever is held in the tab (a volume pill) would slide from under the pointer.
    private func placeHeader(_ placement: HeaderPlacement) {
        headerPlacementTask?.cancel()
        guard notchVM.notchState == .open else {
            headerPlacement = placement
            return
        }
        headerPlacementTask = Task { @MainActor in
            while NSEvent.pressedMouseButtons != 0 {
                try? await Task.sleep(for: .milliseconds(100))
                if Task.isCancelled { return }
            }
            guard headerPlacement != placement else { return }
            withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : notchOpenSpring) { headerPlacement = placement }
        }
    }

    /// 설정에서 지정한 순서대로, 지금 쓸 수 있는 탭만. 탭이 보이는지는 설정 › 기능의 스위치
    /// 하나로만 정한다(2026-11-12: 노치 › 탭의 체크박스와 둘이서 엇갈려 없앰).
    private var visibleModes: [NotchMode] {
        NotchMode.order(from: settings.notchModeOrder).filter(isAvailable)
    }

    /// 고른 탭이 숨겨지거나 사라졌으면 남은 첫 탭으로 넘어간다.
    private var activeMode: NotchMode {
        visibleModes.contains(expandedMode) ? expandedMode : (visibleModes.first ?? .ai)
    }

    private func isAvailable(_ mode: NotchMode) -> Bool {
        switch mode {
        case .ai:           return true
        case .clipboard:    return hasClipboard
        case .volume:       return hasVolume
        case .sidecar:      return hasSidecar
        case .keyboardLock: return hasKeyboardLock
        case .battery:      return hasBattery
        case .speed:        return hasSpeedTest
        }
    }

    /// Also true while actually locked, even if the setting was turned off mid-lock —
    /// the unlock control must never disappear while the keyboard is still blocked.
    private var hasKeyboardLock: Bool { settings.enableKeyboardLock || keyboardLockManager.isLocked }

    /// A collapse from the panel keeps the surface black until it lands on the physical notch,
    /// then drops it in one frame — it already sits under the camera housing, so no exit effect.
    private var notchBackground: Color {
        notchActive || notchVM.isSettlingClosed ? theme.surface ?? .black : .clear
    }

    /// Whether to draw the notch chrome at all. When fully idle (no AI, not
    /// expanded) the notch is invisible — no black bar under the physical notch.
    private var baseNotchActive: Bool {
        notchVM.notchState != .closed
            || anyAIActive
            || keyboardLockManager.isLocked
            || tetherMonitor.activePlaceName != nil
            || !claudeCodeManager.sessionsNeedingPermission.isEmpty
            || !claudeCodeManager.sessionsAwaitingInput.isEmpty
            || (settings.showSourceCodex && !codexManager.pendingInputRequests.isEmpty)
            || batteryManager.closedNotchLowBattery != nil
            || doneFlash != nil
            || nowPlayingMonitor.isShowing
            || airPodsWingContent != nil
    }

    private var notchActive: Bool {
        baseNotchActive || showClosedJellyDismiss
    }

    /// Activity-glow border condition (extracted to keep the body type-checkable).
    private var shouldShowActivityGlow: Bool {
        // Also traces the open panel's and the dropdown's outline while an agent works.
        guard doneFlash == nil else { return false }
        // A question or permission dropdown glows even though the asking session sits idle waiting.
        if notchVM.notchState == .peeking && dropdownNotices.waitsOnAnswer { return true }
        // The 완료 드롭다운 glows only for work still really going on: the finished session's
        // activity grace period lit it and then cut it off mid-dropdown.
        if notchVM.notchState == .peeking && doneNotice != nil {
            return claudeHasRealActivity || codexHasRealActivity
        }
        return claudeCodeManager.hasAnySessionActivity
            || (settings.showSourceCodex && codexManager.hasAnySessionActivity)
    }

    /// Opening from closed, the tethering glow is the same closed-sweep view it already was,
    /// so it resizes with the surface and needs no hiding — the warning never blinks out.
    /// A startup or error glow drawn while closed means the tethering glow is new: hide it.
    private var tetherGlowGrowsWithSurface: Bool {
        glowExpandsFromClosed && notchVM.notchState != .closed
            && tetherMonitor.activePlaceName != nil
            && !showStartupGlow
    }

    /// Glow border overlay (extracted from the body modifier chain for type-check speed).
    @ViewBuilder
    private var glowOverlay: some View {
        ZStack {
            if showStartupGlow && notchVM.notchState == .closed {
                // The startup glow is `NotchPresenceLayer`'s (`presenceLayer`); it holds the
                // other glows back while it lasts.
                EmptyView()
            } else if tetherMonitor.activePlaceName != nil {
                // Tethering at a saved place: the glow sweeps red, agents working or not.
                // Opening from closed, it keeps the closed sweep until the surface settles.
                NotchGlowBorder(topCornerRadius: topCornerRadius, bottomCornerRadius: bottomCornerRadius,
                                glowColor: errorGlowColor, brightColor: errorBrightColor,
                                tracesOutline: notchVM.notchState != .closed
                                    && (isGlowSettled || !glowExpandsFromClosed),
                                wingFade: wingFade)
            } else if shouldShowActivityGlow {
                let showBothSources = hasSimultaneousClaudeCodexActivity
                    && !(dropdownNotices.waitsOnAnswer && notchVM.notchState == .peeking)
                NotchGlowBorder(topCornerRadius: topCornerRadius, bottomCornerRadius: bottomCornerRadius,
                                glowColor: showBothSources ? codexGlowColor : currentGlowColor,
                                brightColor: showBothSources ? codexBrightColor : currentBrightColor,
                                secondaryGlowColor: showBothSources ? claudeGlowColor : nil,
                                secondaryBrightColor: showBothSources ? claudeBrightColor : nil,
                                tracesOutline: notchVM.notchState != .closed,
                                wingFade: wingFade)
            }

            if showClosedJellyRipple && notchVM.notchState == .closed {
                ClosedNotchJellyRipple(
                    topCornerRadius: topCornerRadius,
                    bottomCornerRadius: bottomCornerRadius,
                    // Music springing the wings out on a quiet notch ripples in the artwork's
                    // colour, not the agents' (it came out Claude orange, user 2026-11-12); the
                    // AirPods wings (날개에만) in the notch's own ink.
                    glowColor: hasLiveAgentActivity ? currentBrightColor
                        : airPodsWingContent != nil ? NotchPalette.ink
                        : nowPlayingMonitor.isShowing ? Color(nsColor: nowPlayingMonitor.nowPlaying?.accent ?? .white)
                        : currentBrightColor
                )
                // Past its edges too, where the ripple spreads.
                .mask { WingFadeMask(fade: wingFade).animation(WingFade.animation, value: wingFade).padding(-24) }
            }

            if notchVM.notchState == .closed && !closedDisplayedLabel.isEmpty {
                ClosedNotchToolTransitionWipe(
                    trigger: closedDisplayedLabel,
                    topCornerRadius: topCornerRadius,
                    bottomCornerRadius: bottomCornerRadius,
                    glowColor: hasSimultaneousClaudeCodexActivity ? codexBrightColor : currentBrightColor,
                    secondaryGlowColor: hasSimultaneousClaudeCodexActivity ? claudeBrightColor : nil
                )
                .mask { WingFadeMask(fade: wingFade).animation(WingFade.animation, value: wingFade).padding(-24) }
            }
        }
    }

    /// Tint of the selected tab chip.
    private let chipAccent = NotchPalette.accent
    /// Keyboard-lock indicator — amber, the app's "something is held" tone.
    private let lockedTint = Color(red: 1.0, green: 0.78, blue: 0.3)

    /// Cursor enter(true)/exit(false) over the notch, from the coordinator's monitor.
    private var cursorHoverPublisher: AnyPublisher<Bool, Never> {
        let enter = NotificationCenter.default.publisher(for: .notchCursorEntered).map { _ in true }
        let exit = NotificationCenter.default.publisher(for: .notchCursorExited).map { _ in false }
        return enter.merge(with: exit).eraseToAnyPublisher()
    }

    /// Determines which glow color to use based on active source
    private var currentGlowColor: Color {
        if showPermissionNotice && notchVM.notchState == .peeking {
            return permissionCenter.queue.first?.agent == .codex ? codexGlowColor : claudeGlowColor
        }
        if showQuestionNotice && notchVM.notchState == .peeking {
            return codexInputRequest == nil ? claudeGlowColor : codexGlowColor
        }
        if claudeHasRealActivity {
            return claudeGlowColor
        } else if codexHasRealActivity {
            return codexGlowColor
        } else if settings.showSourceCodex && codexManager.hasAnySessionActivity && !claudeCodeManager.hasAnySessionActivity {
            return codexGlowColor
        }
        return claudeGlowColor
    }

    /// Determines which bright color to use based on active source
    private var currentBrightColor: Color {
        if showPermissionNotice && notchVM.notchState == .peeking {
            return permissionCenter.queue.first?.agent == .codex ? codexBrightColor : claudeBrightColor
        }
        if showQuestionNotice && notchVM.notchState == .peeking {
            return codexInputRequest == nil ? claudeBrightColor : codexBrightColor
        }
        if claudeHasRealActivity {
            return claudeBrightColor
        } else if codexHasRealActivity {
            return codexBrightColor
        } else if settings.showSourceCodex && codexManager.hasAnySessionActivity && !claudeCodeManager.hasAnySessionActivity {
            return codexBrightColor
        }
        return claudeBrightColor
    }

    /// Visible notch outline for the current state; the closed body is one header tall.
    private var notchSurfaceSize: CGSize {
        CGSize(width: notchVM.notchSize.width,
               height: isExpanded ? notchVM.notchSize.height : notchVM.closedNotchSize.height)
    }

    /// With no wings the closed surface is the bare notch, and `NotchShape` sets its sides
    /// `topCornerRadius` in from the frame — 4pt inside the camera housing, so the startup
    /// glow traced a line inside the notch. Widen the glow by both flares so its sides land
    /// just outside the housing. With wings the sides are out in the menu bar anyway.
    private var glowSurfaceWidth: CGFloat {
        guard notchVM.notchState == .closed,
              notchVM.notchSize.width <= notchVM.closedNotchSize.width + 0.5 else { return notchSurfaceSize.width }
        return notchVM.closedNotchSize.width + topCornerRadius * 2
    }

    private var notchVisual: some View {
        notchBody
            .padding(.horizontal, isExpanded ? expandedNotchInset : cornerRadiusInsets.closed.bottom)
            .padding(.bottom, isExpanded ? 12 : 0)
            // Keep one centred frame identity through closed, peek, and open states.
            // Conditional insertion here made the open header lay out from one side first.
            .frame(width: notchVM.notchSize.width,
                   height: isExpanded ? notchVM.notchSize.height : nil, alignment: .top)
            .overlay(alignment: .bottomTrailing) {
                if showsQuestionResizeHandle {
                    CornerResizeHandle(cornerRadius: cornerRadiusInsets.opened.bottom) { toggleQuestionExpanded() }
                        // In the surface's own corner: its sides sit the top corner radius in.
                        .padding(.trailing, cornerRadiusInsets.opened.top)
                        .help(questionExpanded ? L("작게", "Smaller") : L("크게", "Larger"))
                        .transition(.opacity)
                }
            }
            .contentShape(
                NotchShape(
                    topCornerRadius: topCornerRadius,
                    bottomCornerRadius: bottomCornerRadius
                )
            )
            // The window is click-through except over the notch, so the coordinator's
            // cursor monitor drives hover (SwiftUI's own .onHover can't fire reliably).
            .onReceive(cursorHoverPublisher) { hovering in
                handleHover(hovering)
            }
            .onTapGesture(coordinateSpace: .local) { location in
                // Only open on tap. Don't close when tapping empty space while open —
                // a near-miss on a button shouldn't dismiss the notch (closing is
                // handled by the cursor leaving the notch region).
                // A dropdown opens the notch from its top row only (the camera and the wings
                // beside it): a click just under 터미널 열기 opened the whole notch (user, 2026-11-18).
                let onNotchRow = location.y <= notchVM.closedNotchSize.height
                if notchVM.notchState == .closed {
                    if let doneFlash, let turn = doneFlash.turn {
                        focusSession(doneFlash.source, turn.sessionId)
                        return
                    }
                    openSelectedMode()
                } else if notchVM.notchState == .peeking, onNotchRow, doneNotice != nil,
                          !showPermissionNotice, !showQuestionNotice {
                    // Hovering holds the 완료 드롭다운 to read it; a click opens the notch,
                    // which used to wait until the dropdown had folded away by itself.
                    doneNoticeTask?.cancel()
                    doneNotice = nil
                    openSelectedMode()
                } else if notchVM.notchState == .peeking, onNotchRow, mediaNotice != nil, doneNotice == nil,
                          !showPermissionNotice, !showQuestionNotice {
                    // The attached player opens the notch on a click the same way.
                    housingWatch?.cancel()
                    mediaNoticeTask?.cancel()
                    mediaNotice = nil
                    openSelectedMode()
                }
            }
            // The mask, glow and jelly scale sit on a fixed-width container, and only the
            // shapes inside them resize. With those effects on the resizing frame itself,
            // its content was drawn relative to the frame's moving left edge: opening slid
            // everything ~65pt sideways and the right side trailed in last.
            .frame(width: windowSize.width, alignment: .top)
            .background(alignment: .top) {
                // Both layers stay mounted so their frame animates in step with the mask.
                // Swapping views on close inserted the closed background at its final size
                // while the mask was still shrinking, and its square corners showed.
                ZStack {
                    notchBackground
                    // A chosen colour is flat everywhere; only the original dark look has
                    // the open notch's black-to-slate fade.
                    if theme.surface == nil {
                        LinearGradient(colors: [.black, NotchPalette.background], startPoint: .top, endPoint: .bottom)
                            .opacity(notchVM.notchState == .open ? 1 : 0)
                    }
                }
                .frame(width: notchSurfaceSize.width, height: notchSurfaceSize.height)
            }
            .mask(alignment: .top) {
                // The animation sits on the mask alone: on the whole notch it would also take over
                // a dropdown coming down while the cursor rests on a wing.
                WingFadeMask(fade: wingFade)
                    .animation(WingFade.animation, value: wingFade)
                    .clipShape(NotchShape(topCornerRadius: topCornerRadius, bottomCornerRadius: bottomCornerRadius))
                    .frame(width: notchSurfaceSize.width, height: notchSurfaceSize.height)
            }
            // The quiet notch's 위치 알림 and the startup glow, moved by the render server.
            .notchPresenceLayer(presenceLayer)
            // With the surface it hangs from, so it takes the closed notch's jelly scale too.
            .overlay(alignment: .top) {
                if settings.wingOpenHint {
                    WingOpenHint(notchHeight: notchVM.closedNotchSize.height, shown: !wingFade.isSolid,
                                 surface: theme.surface ?? .black)
                }
            }
            .overlay(alignment: .top) {
                glowOverlay
                    .frame(width: glowSurfaceWidth, height: notchSurfaceSize.height)
                    // Switching state swaps the glow for a new view that appears at its
                    // final size, ahead of the still-resizing surface; fade it in after.
                    .opacity(isGlowSettled || tetherGlowGrowsWithSurface ? 1 : 0)
            }
            .modifier(IdleLandingFade(height: notchSurfaceSize.height,
                                      closedHeight: notchVM.closedNotchSize.height,
                                      isLanding: notchVM.isSettlingClosed && !baseNotchActive))
            .onChange(of: notchVM.notchState) { oldState, newState in
                // Dropdown <-> open panel keeps the same outline-tracing glow, which resizes
                // with the surface; hiding it there only blinked it out for half a second.
                guard (oldState == .closed) != (newState == .closed) else { return }
                glowSettleTask?.cancel()
                var hide = Transaction(animation: nil)
                hide.disablesAnimations = true
                withTransaction(hide) {
                    isGlowSettled = false
                    glowExpandsFromClosed = oldState == .closed
                }
                // A collapse lands when its own curve ends; waiting the open spring's 450ms
                // there left the closed notch without its glow for a moment.
                let wait = newState == .closed ? notchVM.closeDuration : 0.45
                glowSettleTask = Task {
                    // The open spring is still settling at 300ms; a glow drawn then rides the bounce.
                    try? await Task.sleep(for: .seconds(wait))
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeIn(duration: 0.2)) { isGlowSettled = true }
                }
            }
            // Presentation-only deformation: layout and the panel's click-through
            // region stay fixed while the closed surface grows out from the camera.
            .scaleEffect(
                x: closedJellyScaleX,
                y: closedJellyScaleY,
                anchor: .top
            )
    }

    private var notchChangesA: some View {
        notchVisual
                .onChange(of: notchVM.notchState) { _, newState in
                    if newState != .closed {
                        resetClosedJellyReveal()
                        // Opened or a dropdown came: the breathing stops at once.
                        if notchPresence {
                            presenceTask?.cancel()
                            notchPresence = false
                        }
                    }
                    // Opening goes back to the tabs' size (a 세션 화면 left it wider).
                    if newState == .open {
                        notchVM.resizeOpen(to: activeMode.expandedSize)
                    }
                    updateInteractiveRegion()
                }
                .onChange(of: notchVM.notchSize) { _, _ in
                    updateInteractiveRegion()
                }
                // The attached player takes a volume key's row while it is down.
                .onChange(of: mediaNotice != nil) { _, down in
                    MediaVolumeBand.shared.attachedIsDown = down
                    if !down { mediaVolumeReading = nil }
                }
                .onReceive(MediaVolumeBand.shared.$reading) { reading in
                    mediaVolumeChanged(reading)
                }
                .onChange(of: settings.wingStepAside) { _, _ in
                    updateInteractiveRegion()
                }
                .onChange(of: settings.showSourceCodex) { _, enabled in
                    codexManager.setTrackingEnabled(enabled)
                }
    }

    private var layoutChanges: some View {
        notchChangesA
            // The mixer looks up audio processes often only while its tab is on screen.
            .onChange(of: notchVM.notchState == .open && activeMode == .volume, initial: true) { _, visible in
                audioMixer.setTabVisible(visible)
            }
            .onChange(of: activeMode) { _, mode in
                hoverExitNotBefore = Date().addingTimeInterval(0.55)
                sessionDetail = nil
                notchVM.resizeOpen(to: mode.expandedSize)
            }
            .onChange(of: permissionCenter.queue) { _, queue in
                handlePermissionQueue(queue)
            }
            // Answer buttons and Send are taller than the read-only list: re-fit.
            .onChange(of: permissionCenter.answerableQuestionSessions) { _, _ in
                if showQuestionNotice, !showPermissionNotice, let request = claudeInputRequest {
                    triggerClaudeInputNotice(request)
                }
            }
            .onChange(of: notchVM.notchState) { _, state in
                // A request that came while the panel was open, or a Done that waited its turn,
                // drops in once the notch closes. Waits out the close animation, like the speed
                // notice, so the two don't fight; a fold still under way checks on its own.
                if state == .closed { sessionDetail = nil }
                guard state == .closed else { return }
                Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    guard notchVM.notchState == .closed, !foldingPeek,
                          !permissionCenter.queue.isEmpty || pendingDoneNotice != nil else { return }
                    restorePeek()
                }
            }
    }

    private var decoratedNotch: some View {
        VStack(spacing: 0) {
            layoutChanges
                .onChange(of: hasLiveAgentActivity) { wasActive, isActive in
                    if !wasActive && isActive {
                        cancelClosedJellyDismiss()
                        triggerClosedJellyReveal()
                    } else if !isActive {
                        resetClosedJellyReveal()
                    }
                }
                // Music starting on a quiet notch springs out like the agents' wings do,
                // instead of the surface popping up at full size.
                .onChange(of: nowPlayingMonitor.isShowing) { wasShowing, isShowing in
                    guard !wasShowing, isShowing, !hasLiveAgentActivity, tetherMonitor.activePlaceName == nil else { return }
                    cancelClosedJellyDismiss()
                    triggerClosedJellyReveal()
                }
                // The AirPods wings (날개에만) spring out of a quiet notch the same way.
                .onChange(of: airPodsWingContent != nil) { wasShowing, isShowing in
                    guard !wasShowing, isShowing, !hasLiveAgentActivity, tetherMonitor.activePlaceName == nil,
                          !nowPlayingMonitor.isShowing else { return }
                    cancelClosedJellyDismiss()
                    triggerClosedJellyReveal()
                }
                .onChange(of: claudeCodeManager.lastCompletedTurn) { _, turn in
                    guard let turn, settings.showSourceClaudeCode else { return }
                    recordTurn(turn, .claude)
                    handleCompletedTurn(turn, .claude)
                }
                .onChange(of: codexManager.lastCompletedTurn) { _, turn in
                    guard let turn, settings.showSourceCodex else { return }
                    recordTurn(turn, .codex)
                    handleCompletedTurn(turn, .codex)
                }
                .onChange(of: baseNotchActive) { wasActive, isActive in
                    // A collapse from the panel lands on the notch and clears there instead.
                    if wasActive && !isActive && !notchVM.isSettlingClosed {
                        triggerClosedJellyDismiss()
                    } else if isActive {
                        cancelClosedJellyDismiss()
                    }
                }
                .onChange(of: notchVM.isSettlingClosed) { _, settling in
                    // A collapse that landed on an idle notch skipped the dismiss above, so its
                    // wide layout would make the next entrance grow the black surface behind
                    // an already-full-size glow. Reset it now, while the surface is clear.
                    guard !settling else { return }
                    var transaction = Transaction(animation: nil)
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        if !baseNotchActive, notchVM.notchState == .closed {
                            notchVM.resetClosedPresentationAfterDismiss()
                        }
                    }
                }
                .onChange(of: claudeCodeManager.pendingInputRequests, initial: true) { old, requests in
                    if let request = requests.first, request != claudeInputRequest {
                        // `old == requests` is the launch pass: a question already waiting stays quiet.
                        // A next-step box comes seconds before its turn's end, which plays the
                        // done sound; chiming for the box too made every such turn ring twice.
                        if old != requests, request.id != claudeInputRequest?.id, !request.isWrapUp {
                            let sessionId = claudeCodeManager.sessionStates.first { $0.value.pendingInputRequests.contains { $0.id == request.id } }?.key
                            NotchSounds.playAttention(for: sessionId)
                        }
                        triggerClaudeInputNotice(request)
                    } else if requests.isEmpty, claudeInputRequest != nil {
                        claudeInputRequest = nil
                        if let request = codexManager.pendingInputRequests.first {
                            triggerCodexInputNotice(request)
                        } else {
                            dismissQuestionNotice()
                        }
                    }
                }
                .onChange(of: codexManager.pendingInputRequests, initial: true) { old, requests in
                    if let request = requests.first, request != codexInputRequest {
                        if old != requests, request.id != codexInputRequest?.id {
                            let sessionId = codexManager.sessionStates.first { $0.value.pendingInputRequest?.id == request.id }?.key
                            NotchSounds.playAttention(for: sessionId)
                        }
                        triggerCodexInputNotice(request)
                    } else if requests.isEmpty, codexInputRequest != nil {
                        codexInputRequest = nil
                        if let request = claudeCodeManager.pendingInputRequests.first {
                            triggerClaudeInputNotice(request)
                        } else {
                            dismissQuestionNotice()
                        }
                    }
                }
                .onChange(of: notchVM.notchState) { _, newState in
                    handleSpeedNotchState(newState)
                    if newState != .peeking { dismissTetherNotice() }
                }
                .onChange(of: speedTest.phase) { _, newPhase in
                    handleSpeedPhase(newPhase)
                }
                .onChange(of: tetherMonitor.alert) { _, alert in
                    if let alert { triggerTetherNotice(alert.placeName) }
                }
                .shadow(
                    color: isExpanded ? .black.opacity(0.6) : .clear,
                    radius: 8
                )
                .animation(sizeAnimation, value: notchVM.notchState)
                .animation(sizeAnimation, value: notchVM.notchSize)
        }
    }

    var body: some View {
        decoratedNotch
        .padding(.bottom, isExpanded ? 8 : closedNotchGlowPadding)
        .frame(maxWidth: windowSize.width, maxHeight: windowSize.height, alignment: .top)
        .overlay(alignment: .top) {
            ClipboardOrbView(surfaceWidth: notchVM.notchSize.width, surfaceHeight: notchVM.closedNotchSize.height,
                             fromSurface: (NotchDetector.notchScreen?.safeAreaInsets.top ?? 0) > 0 || baseNotchActive,
                             enabled: notchVM.notchState == .closed && ui.isVisible,
                             showsCopies: settings.clipboardOrb && settings.enableClipboardHistory,
                             direction: settings.clipboardOrbDirection,
                             style: settings.clipboardOrbStyle,
                             holdSeconds: settings.foldSecondsCopy)
        }
        .compositingGroup()
        .environment(\.notchTyping, { UICoordinator.shared.notchTyping($0) })
        .environment(\.colorScheme, notchScheme)
        .preferredColorScheme(notchScheme)
        // ⌘1–⌘7 pick the nth visible tab, but only while open: the tap that supplies them
        // is created on open and torn down on close, so nothing is intercepted otherwise.
        .onChange(of: notchVM.notchState) { _, state in
            NotchTabShortcuts.shared.setActive(state == .open)
            AirPodsDropdown.shared.notchState = state
            AirPodsDropdown.media.notchState = state
            // 배경 따라: catches a wallpaper changed since the last look.
            if state != .closed { appearance.refreshWallpaper() }
        }
        .onChange(of: desiredHeaderPlacement, initial: true) { _, placement in placeHeader(placement) }
        // 날개에만: only the card, not the whole dropdown, whose hover and phase would redraw this view.
        .onReceive(AirPodsDropdown.shared.$card.combineLatest(AirPodsDropdown.shared.$inWings)
            .map { card, inWings in inWings ? card : nil }
            .removeDuplicates()) { card in
                // Laid out again only for a new card, whatever the subscription replays.
                guard card != airPodsWingContent?.card else { return }
                airPodsWingContent = card.map { ClosedAirPodsWings(card: $0, notchHeight: notchVM.closedNotchSize.height) }
            }
        .onChange(of: settings.notchAppearance) { appearance.refreshWallpaper() }
        // The 조절창 moves under the open notch instead of covering it.
        .onChange(of: notchVM.notchState == .open ? notchVM.notchSize.height : 0, initial: true) { _, depth in
            SystemControlOSD.shared.openNotchDepth = depth
        }
        // The 에어팟 드롭다운 stays up under a dropdown that comes down meanwhile.
        .onChange(of: notchVM.notchState == .peeking ? notchVM.notchSize.height : 0, initial: true) { _, depth in
            AirPodsDropdown.shared.peekDepth = depth
            AirPodsDropdown.media.peekDepth = depth
        }
        .onChange(of: settings.notchWallpaperSource) { appearance.refreshWallpaper() }
        .onAppear { appearance.refreshWallpaper() }
        .onReceive(NotificationCenter.default.publisher(for: .notchOpenBattery)) { _ in
            guard visibleModes.contains(.battery) else { return }
            expandedMode = .battery
            openSelectedMode()
        }
        .onReceive(NotificationCenter.default.publisher(for: .notchSelectTab)) { note in
            guard notchVM.notchState == .open, let index = note.userInfo?["index"] as? Int,
                  visibleModes.indices.contains(index) else { return }
            withAnimation(modeSwitchAnimation) { expandedMode = visibleModes[index] }
        }
        // Nag again while something keeps waiting: every N minutes, the attention sound for
        // the first waiting session that isn't muted. Next-step boxes don't count; they linger.
        .task(id: "\(waitingSessionIDs)-\(settings.attentionReminderMinutes)") {
            let minutes = settings.attentionReminderMinutes
            guard minutes > 0, !waitingSessionIDs.isEmpty else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(minutes * 60))
                guard !Task.isCancelled else { return }
                // Looking at the open notch already; no need to nag.
                if notchVM.notchState != .open,
                   let id = waitingSessionIDs.first(where: { !NotchSounds.isMuted($0) }) {
                    NotchSounds.playAttention(for: id)
                }
            }
        }
        // A context menu (세션 줄 right-click) draws outside the notch; leaving for it
        // mustn't close the notch under the menu. Re-check once the menu is gone.
        // Only while the notch is open: a Picker in the Settings window must not touch it.
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
            guard notchVM.notchState == .open else { return }
            isMenuTracking = true
            hoverTask?.cancel()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in
            guard isMenuTracking else { return }
            isMenuTracking = false
            // The cursor monitor sat idle while the menu tracked; read the cursor fresh.
            UICoordinator.shared.refreshClickThrough()
            if !UICoordinator.shared.cursorOverNotch { handleHover(false) }
        }
        .onAppear {
            NowPlayingMonitor.showAttached = { playing in showMediaNotice(playing) }
            triggerStartupGlow()
            announceNotch()
            if hasLiveAgentActivity {
                triggerClosedJellyReveal()
            }
            updateInteractiveRegion()
            // Start Claude Usage quota tracking if enabled (warms the webview session;
            // surfaces the inline login if not authenticated yet).
            if settings.enableClaudeUsage {
                ClaudeUsageManager.shared.startRefreshing()
            }
            NowPlayingMonitor.shared.sync()
            // Restores the T world session and starts its keep-alive without waiting for a card.
            Task { await TWorldSession.shared.prepare() }
            if settings.enableAudioMixer { audioMixer.start() }
            // 배터리 부족 알림은 탭을 열지 않아도 울려야 하므로 기동 시부터 감시한다.
            if settings.enableBattery { batteryManager.startMonitoring() }
            tetherMonitor.start()
        }
        .onDisappear {
            NotchTabShortcuts.shared.setActive(false)
            startupGlowTask?.cancel()
            speedPeekTask?.cancel()
            speedDismissTask?.cancel()
            tetherNoticeTask?.cancel()
            closedJellyTask?.cancel()
            closedJellyDismissTask?.cancel()
            closedLabelTransitionTask?.cancel()
            glowSettleTask?.cancel()
            doneFlashTask?.cancel()
            doneNoticeTask?.cancel()
        }
    }

    @ViewBuilder
    private var notchBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header - always visible
            notchHeader
                .frame(height: headerHeight)
                // Above the body: the 닫기 알약 hangs from the header over it.
                .zIndex(1)

            // Expanded content
            if notchVM.notchState == .open {
                expandedContent
                    .frame(height: max(0, notchVM.notchSize.height - headerHeight - 12))
                    .transition(reduceMotion ? .opacity : .blurFade(radius: 10))
            } else if notchVM.notchState == .peeking {
                peekContent
                    .frame(height: max(0, notchVM.notchSize.height - notchVM.closedNotchSize.height - 12))
                    .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private var notchHeader: some View {
        if notchVM.notchState == .closed {
            closedHeader
        } else if notchVM.notchState == .peeking {
            peekHeader
        } else {
            openHeader
        }
    }

    /// Widest a wing's tool name may get. Both wings take the wider one's width, so a long name
    /// comes back twice: 124 made a bar across the menu bar with a long command running (user,
    /// 2026-11-12). Longer text ends in "…".
    private static let wingLabelCap: CGFloat = 96

    /// A closed wing's Claude icons. With 설정 › 실험 기능 › "Claude 아이콘에 모자 씌우기" on,
    /// each wears its session's hat (아이콘 모자).
    private func claudeWingIcons(count: Int, spreadsLeading: Bool, glowColor: Color) -> some View {
        ClosedAgentIconStack(agent: .claude, count: count, hats: claudeWingHats,
                             spreadsLeading: spreadsLeading, glowColor: glowColor)
            // A turn that only thinks writes nothing for minutes, so nothing would redraw
            // the wing when it reaches the hard hat: sleep until then, once.
            .task(id: claudeHardhatDue) {
                guard let due = claudeHardhatDue else { return }
                try? await Task.sleep(for: .seconds(due.timeIntervalSinceNow + 0.2))
                if !Task.isCancelled { hatClock &+= 1 }
            }
    }

    /// The hat of every working Claude session, in the order the wing draws its icons. The
    /// front icon is the selected session while it works (the wing names its tool first);
    /// the others keep their places by turn start, so a hat doesn't hop between icons as
    /// sessions report in.
    private var claudeWingHats: [ClaudeIconHat?] {
        guard settings.experimentalClaudeIconHats else { return [] }
        _ = hatClock
        let now = Date()
        let selected = claudeCodeManager.selectedSession?.id
        return claudeCodeManager.availableSessions
            .compactMap { session in claudeCodeManager.sessionStates[session.id].map { (id: session.id, state: $0) } }
            .filter { $0.state.isActive }
            .sorted { a, b in
                if (a.id == selected) != (b.id == selected) { return a.id == selected }
                let (x, y) = (a.state.turnStartTime ?? .distantPast, b.state.turnStartTime ?? .distantPast)
                return x != y ? x < y : a.id < b.id
            }
            .prefix(ClosedAgentIconStack.maxIcons)
            .map { ClaudeIconHat.wearing($0.state, now: now) }
    }

    private var claudeHardhatDue: Date? {
        guard settings.experimentalClaudeIconHats else { return nil }
        let now = Date()
        return claudeCodeManager.sessionStates.values
            .filter(\.isActive)
            .compactMap { ClaudeIconHat.hardhatDue($0, now: now) }
            .min()
    }

    @ViewBuilder
    private var closedHeader: some View {
        // Claude Code active tool (from JSONL parsing) - check all sessions
        let claudeActiveTool = claudeCodeManager.state.activeTools.first
            ?? claudeCodeManager.sessionStates.values.compactMap { $0.activeTools.first }.first
            // A session that only waits on its subagents shows what one of them is running.
            ?? claudeCodeManager.sessionStates.values.compactMap { $0.subagents.compactMap(\.tool).first }.first
        // Recent completed Claude tool (within last 5 seconds).
        // Only while the session is still active — once activity ends, notchActive goes
        // false (clear background), so drawing wings here would ghost over the desktop.
        let recentClaudeTool: ClaudeToolExecution? = {
            // Back to thinking: the model line beats a finished tool's time.
            guard claudeCodeManager.hasAnySessionActivity,
                  !claudeCodeManager.state.isThinking,
                  let recent = claudeCodeManager.state.recentTools.first,
                  let endTime = recent.endTime,
                  Date().timeIntervalSince(endTime) < 5.0 else { return nil }
            return recent
        }()
        let isClaudeActive = claudeCodeManager.hasAnySessionActivity

        // Codex active tool (from JSONL parsing)
        let codexActiveTool: CodexToolExecution? = settings.showSourceCodex
            ? (codexManager.state.activeTools.first
                ?? codexManager.sessionStates.values.compactMap { $0.activeTools.first }.first)
            : nil
        // Recent completed Codex tool (within last 5 seconds) — same activity gate as above.
        let recentCodexTool: CodexToolExecution? = {
            guard settings.showSourceCodex,
                  codexManager.hasAnySessionActivity,
                  !codexManager.state.isThinking,
                  let recent = codexManager.state.recentTools.first,
                  let endTime = recent.endTime,
                  Date().timeIntervalSince(endTime) < 5.0 else { return nil }
            return recent
        }()
        let isCodexActive = settings.showSourceCodex && codexManager.hasAnySessionActivity
        let isClaudeQuestionWait = settings.showSourceClaudeCode && !claudeCodeManager.pendingInputRequests.isEmpty
        let isCodexQuestionWait = settings.showSourceCodex && !codexManager.pendingInputRequests.isEmpty
        let isSimultaneousClaudeCodex = (claudeHasRealActivity || isClaudeQuestionWait)
            && (codexHasRealActivity || isCodexQuestionWait)

        let hasPermissionNeeded = settings.showPermissionIndicator
            && (!claudeCodeManager.sessionsNeedingPermission.isEmpty || !codexManager.pendingInputRequests.isEmpty)
        // A system-wide keyboard block has to stay visible without opening anything.
        let isKeyboardLocked = keyboardLockManager.isLocked

        // Determine what tool to show (prefer active Codex, then active Claude, then recent)
        let currentClaudeTool: ClaudeToolExecution? = claudeActiveTool ?? recentClaudeTool
        let currentCodexTool: CodexToolExecution? = codexActiveTool ?? recentCodexTool
        let isThinking = (isClaudeActive && currentClaudeTool == nil) || (isCodexActive && currentCodexTool == nil)

        // Get current tool name (prefer Codex if active, otherwise Claude)
        let currentToolName: String? = {
            if let codexTool = currentCodexTool, isCodexActive || codexActiveTool != nil {
                return codexTool.toolName
            }
            return currentClaudeTool?.displayName
        }()
        let hasCurrentTool = currentToolName != nil

        // A lone question waiting on an answer is announced by the right wing's
        // "Answer". Its tool name on the left would say nothing new and blow the bar up:
        // "AskUserQuestion" alone claims 120pt, and since both wings must claim the same
        // width to stay centred, that is 240pt of empty black bar. The left wing shows a
        // short "Waiting" with the 날개 알약 line stopped instead.
        let isQuestionWait = isClaudeQuestionWait || isCodexQuestionWait
        // Keep Codex on the left and working Claude on the right, as when both work.
        let showsCodexQuestionOnLeft = isCodexQuestionWait && isSimultaneousClaudeCodex
        let showsClaudeQuestionOnRight = isClaudeQuestionWait && isSimultaneousClaudeCodex
        let showsQuestionOnRight = showsClaudeQuestionOnRight || (isQuestionWait && !isSimultaneousClaudeCodex)
        let showsQuestionWaitOnLeft = isQuestionWait && !isSimultaneousClaudeCodex

        // A finished turn takes both wings for a moment, but never over something that
        // waits on the user (Locked, Answer, Needs OK).
        let showsDone = doneFlash != nil && !isKeyboardLocked && !isQuestionWait && !hasPermissionNeeded
        // 날개에만: the 에어팟 드롭다운's card takes both wings for its time, over the agents,
        // Done, tethering and music, but, like Done, never over something that waits on the user.
        let airPodsWings = isKeyboardLocked || isQuestionWait || hasPermissionNeeded ? nil
            : airPodsWingContent
        let showsAirPodsWings = airPodsWings != nil

        // When fully idle (no tool/thinking), the closed notch shows nothing.
        let showLeftWing = showsDone
            || ((hasCurrentTool || isThinking) && (!isQuestionWait || isSimultaneousClaudeCodex))
            || showsCodexQuestionOnLeft
            || showsQuestionWaitOnLeft

        let measuredTextWidth: (String, CGFloat, NSFont.Weight) -> CGFloat = { text, size, weight in
            ceil((text as NSString).size(withAttributes: [
                .font: NSFont.systemFont(ofSize: size, weight: weight)
            ]).width)
        }
        // Durations draw in the monospaced design, which is wider than the proportional font
        // above; a wing sized to the narrower font wrapped "1.1s" as "1." over "1s".
        let measuredMonoTextWidth: (String, CGFloat) -> CGFloat = { text, size in
            ceil((text as NSString).size(withAttributes: [
                .font: NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            ]).width)
        }

        // The closed panel follows the content instead of reserving a full tool row.
        // Long commands still stop at the previous compact cap and truncate there.
        // With Claude and Codex both running, each wing takes one agent: Codex on the
        // left (the glow sweep starts blue), Claude on the right.
        let sourceLabel = showsQuestionWaitOnLeft ? "Waiting"
            : isSimultaneousClaudeCodex
            ? (currentCodexTool?.toolName ?? "Thinking")
            : (currentToolName ?? "Thinking")
        let closedLabel = closedDisplayedLabel.isEmpty ? sourceLabel : closedDisplayedLabel
        let labelCapsuleWidth = min(Self.wingLabelCap, measuredTextWidth(closedLabel, 10, .medium) + 12)
        let showsClaudeIcon = (hasCurrentTool || isThinking) && isClaudeActive && !isCodexActive
        let showsCodexIcon = (hasCurrentTool || isThinking) && isCodexActive
        // Working sessions per agent, counted like the 요약 줄's "작업 중 N"; the wing icon
        // gets one zigzag copy behind it per extra session.
        let claudeWorkingCount = claudeCodeManager.availableSessions
            .filter { claudeCodeManager.sessionStates[$0.id]?.isActive == true }.count
        let codexWorkingCount = codexManager.availableSessions
            .filter { codexManager.sessionStates[$0.id]?.isActive == true }.count
        let leftIconWidth: CGFloat = showsCodexIcon ? ClosedAgentIconStack.width(for: codexWorkingCount)
            : showsClaudeIcon ? ClosedAgentIconStack.width(for: claudeWorkingCount)
            : 8
        let leftWingWidth: CGFloat = showsDone ? 12 + 6 + measuredTextWidth("Done", 10, .medium)
            : showsCodexQuestionOnLeft ? 58
            : showsQuestionWaitOnLeft ? 12 + 6 + labelCapsuleWidth
            : (showLeftWing ? leftIconWidth + 6 + labelCapsuleWidth : 0)
        let simultaneousClaudeLabel = currentClaudeTool?.displayName ?? "Thinking"
        let showsSimultaneousClaudeWing = isSimultaneousClaudeCodex && !isClaudeQuestionWait
            && (isCodexQuestionWait || !hasPermissionNeeded) && !showsDone

        // A locked keyboard owns the right wing — while input is blocked, nothing else
        // there is worth reading.
        // "Answer" plus its dot is all the right wing carries while a question waits,
        // so it claims only that much rather than a tool row's full 120.
        // 경과 시간: the turn the wing speaks for is the shown session's, else the working
        // session's that started last.
        let claudeTurnStart = claudeCodeManager.state.turnStartTime
            ?? claudeCodeManager.sessionStates.values.compactMap(\.turnStartTime).max()
        let codexTurnStart = codexManager.state.turnStartTime
            ?? codexManager.sessionStates.values.compactMap(\.turnStartTime).max()
        let thinkingTurnStart = isCodexActive ? codexTurnStart : claudeTurnStart
        // The spinner alone, or the time, a gap and the spinner.
        let runningWidth: (Date?) -> CGFloat = { $0 == nil ? 8 : ClosedElapsedLabel.width + 4 + 8 }
        let agentRightWingWidth: CGFloat = {
            if isKeyboardLocked {
                return measuredTextWidth("Locked", 10, .semibold) + 18
            }
            if showsDone { return DoneCheckmarkView.size }
            if showsSimultaneousClaudeWing {
                return min(Self.wingLabelCap, measuredTextWidth(simultaneousClaudeLabel, 10, .medium) + 12) + 6
                    + ClosedAgentIconStack.width(for: claudeWorkingCount)
            }
            if showsQuestionOnRight || hasPermissionNeeded { return 58 }
            if let codexTool = currentCodexTool, isCodexActive || codexActiveTool != nil {
                if codexTool.isRunning { return runningWidth(codexTurnStart) }
                return measuredMonoTextWidth(codexTool.formattedDuration, 9)
            }
            if let claudeTool = currentClaudeTool {
                if claudeTool.isRunning { return runningWidth(claudeTurnStart) }
                return measuredMonoTextWidth(claudeTool.formattedDuration, 9)
            }
            if isThinking { return runningWidth(thinkingTurnStart) }
            return 0
        }()
        // Tethering at a saved place: with the agents quiet it takes both wings ("테더링" and
        // "집 · 12분"); while they work it shrinks to a red hotspot icon at the right edge.
        let tetherPlace = tetherMonitor.activePlaceName
        let showsTetherWings = tetherPlace != nil && !showLeftWing && agentRightWingWidth == 0 && !showsAirPodsWings
        let tetherRightLabel = tetherPlace.map { "\($0) · \(tetherMonitor.connectedLabel)" } ?? ""
        let tetherLeftWidth = 14 + 6 + measuredTextWidth(L("테더링", "Tethering"), 10, .semibold)
        let baseRightWingWidth = showsTetherWings ? measuredTextWidth(tetherRightLabel, 10, .medium) : agentRightWingWidth
        let showsTetherIcon = tetherPlace != nil && !showsTetherWings
        let tetherIconWidth: CGFloat = showsTetherIcon ? 14 + (baseRightWingWidth > 0 ? 6 : 0) : 0

        // 지금 재생 표시: with the agents quiet and no tethering it takes both wings (the artwork
        // on the left, bars on the right, as in the Dynamic Island); otherwise it shrinks to a
        // few bars at the right edge, like the tethering icon.
        let showsMediaWings = nowPlayingMonitor.isShowing && !showLeftWing && agentRightWingWidth == 0
            && tetherPlace == nil && !showsAirPodsWings
        let showsMediaMini = nowPlayingMonitor.isShowing && !showsMediaWings && settings.nowPlayingMiniWhileWorking
        let mediaArtSize: CGFloat = 20
        let mediaWingWidth: CGFloat = showsMediaWings ? MediaWaveform.Style.wing.width : 0
        let mediaMiniWidth: CGFloat = showsMediaMini
            ? MediaWaveform.Style.mini.width + (baseRightWingWidth > 0 || showsTetherIcon ? 6 : 0) : 0

        // A low priority battery rides at the outer edge of the right wing and stays there
        // whatever else the wing is showing, until it recovers or is switched off. With nothing
        // else on the wings it takes both: the device on the left, its battery on the right.
        let lowBattery = batteryManager.closedNotchLowBattery
        let showsBatteryWings = lowBattery != nil && !showLeftWing && agentRightWingWidth == 0
            && tetherPlace == nil && !nowPlayingMonitor.isShowing && !showsAirPodsWings
        let batteryBadgeWidth: CGFloat = lowBattery == nil ? 0
            : ClosedLowBatteryBadge.width(showsIcon: !showsBatteryWings)
                + (baseRightWingWidth > 0 || showsTetherIcon || showsMediaMini || showsMediaWings ? 6 : 0)
        let rightWingWidth = airPodsWings?.rightWidth
            ?? baseRightWingWidth + mediaWingWidth + tetherIconWidth + mediaMiniWidth + batteryBadgeWidth

        // Both wings have to claim the same width, otherwise this centred row slides
        // sideways by half the difference and the shorter side's content ends up under
        // the physical notch. The slots include each wing's edge padding.
        let hasLeftWing = showLeftWing || showsTetherWings || showsMediaWings || showsBatteryWings || showsAirPodsWings
        let leftContentWidth = airPodsWings?.leftWidth
            ?? (showsTetherWings ? tetherLeftWidth : showsMediaWings ? mediaArtSize
                : showsBatteryWings ? ClosedLowBatteryBadge.wingIconWidth : leftWingWidth)
        // Music alone on the wings sits as far from the surface's sides as from its top and
        // bottom, as in the Dynamic Island (user's photo, 2026-11-15): the 앨범 그림 6 pt in, the
        // 음파 막대 7. The header's own 14 pt and the usual 8 left the picture 16 pt in, adrift
        // of the side while 6 pt from the top. (The side is 6 pt inside the frame.)
        // The other wings follow the same rule (2026-11-16): an agent's 12 pt icon sits 10 pt
        // from the top and bottom, so 10 pt from the side, where the old 8 left it 16 pt in.
        let wingEdgePadding: CGFloat = 2
        let leftEdgePadding: CGFloat = showsMediaWings ? -2 : wingEdgePadding
        let rightEdgePadding: CGFloat = showsMediaWings && lowBattery == nil ? -1 : wingEdgePadding
        let leftSlot: CGFloat = hasLeftWing ? leftContentWidth + leftEdgePadding : 0
        let rightSlot: CGFloat = rightWingWidth > 0 ? rightWingWidth + rightEdgePadding : 0
        let wingWidth = max(leftSlot, rightSlot)

        // If nothing to show, just return the notch width
        let hasAnyContent = hasLeftWing || rightWingWidth > 0
        // Each wing occupies exactly `wingWidth`; the physical notch stays fixed between them.
        let totalWidth = notchVM.closedNotchSize.width + wingWidth * 2

        if !hasAnyContent {
            // Empty state - just the notch, no wings
            Spacer()
                .frame(width: notchVM.closedNotchSize.width)
                // The surface can stay drawn with nothing in it (the tethering glow), so give
                // back the width the wings last claimed instead of leaving an empty wide bar.
                .onAppear {
                    notchVM.updateClosedPresentationWidth(notchVM.closedNotchSize.width)
                    // Forget the last tool name so the next entrance sizes to its own label
                    // instead of the old one, then resizing and wiping again.
                    closedLabelTransitionTask?.cancel()
                    closedLabelTransitionTask = nil
                    pendingClosedLabel = nil
                    closedDisplayedLabel = ""
                }
        } else {
            HStack(spacing: 0) {
                // Left wing
                if hasLeftWing {
                    HStack(spacing: 6) {
                        if let airPodsWings {
                            ClosedAirPodsWings.Row(pieces: airPodsWings.left)
                                .transition(.scale(scale: 0.5).combined(with: .opacity))
                        } else if showsMediaWings, let playing = nowPlayingMonitor.nowPlaying {
                            MediaArtwork(playing: playing, size: mediaArtSize)
                                .transition(.scale(scale: 0.5).combined(with: .opacity))
                        } else if showsBatteryWings, let lowBattery {
                            Image(systemName: lowBattery.compactSymbol)
                                .font(.system(size: 15))
                                .foregroundColor(NotchPalette.ink.opacity(0.92))
                                .frame(width: ClosedLowBatteryBadge.wingIconWidth)
                                .transition(.scale(scale: 0.5).combined(with: .opacity))
                        } else if showsTetherWings {
                            Image(systemName: "personalhotspot")
                                .font(.system(size: 10, weight: .semibold))
                                .frame(width: 14)
                            Text(L("테더링", "Tethering"))
                                .font(.system(size: 10, weight: .semibold))
                                .lineLimit(1)
                                .fixedSize()
                        } else if showsCodexQuestionOnLeft {
                            HStack(spacing: 4) {
                                Image(systemName: "bubble.left.and.bubble.right")
                                    .font(.system(size: 8))
                                Text("Answer")
                                    .font(.system(size: 9, weight: .medium))
                            }
                            .foregroundColor(.blue)
                        } else if showsQuestionWaitOnLeft {
                            let waitColor = isCodexQuestionWait ? codexIndicatorColor : claudeGlowColor
                            Group {
                                if isCodexQuestionWait {
                                    Image("ChatGPTIcon")
                                        .resizable()
                                        .foregroundColor(NotchPalette.ink)
                                } else {
                                    Image("ClaudeIcon")
                                        .resizable()
                                }
                            }
                            .frame(width: 12, height: 12)
                            ClosedToolTransitionLabel(
                                label: closedLabel,
                                foregroundOpacity: 0.7,
                                glowColor: waitColor,
                                isPaused: true
                            )
                        } else if showsDone, let doneFlash {
                            if doneFlash.source == .claude {
                                Image("ClaudeIcon")
                                    .resizable()
                                    .frame(width: 12, height: 12)
                                    .overlay {
                                        if settings.experimentalClaudeIconHats { ClaudeIconHatView(hat: .crown) }
                                    }
                            } else {
                                Image("ChatGPTIcon")
                                    .resizable()
                                    .foregroundColor(NotchPalette.ink)
                                    .frame(width: 12, height: 12)
                            }
                            Text("Done")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(doneBlue)
                                .lineLimit(1)
                                .fixedSize()
                        } else if hasCurrentTool || isThinking {
                            // Source-specific indicator color
                            let indicatorColor = isCodexActive ? codexIndicatorColor : claudeGlowColor
                            let isActive = isCodexActive || isClaudeActive
                            if showsClaudeIcon {
                                claudeWingIcons(count: claudeWorkingCount, spreadsLeading: true, glowColor: indicatorColor)
                                    .matchedGeometryEffect(id: "claudeWingIcon", in: wingIconNamespace)
                            } else if showsCodexIcon {
                                ClosedAgentIconStack(agent: .codex, count: codexWorkingCount,
                                                     spreadsLeading: true, glowColor: indicatorColor)
                                    // Codex taking the left wing from Claude pops in there.
                                    .transition(reduceMotion ? .opacity : .scale(scale: 0.3).combined(with: .opacity))
                            } else {
                                Circle()
                                    .fill(indicatorColor)
                                    .frame(width: 8, height: 8)
                                    .shadow(color: indicatorColor.opacity(isActive ? 0.6 : 0.3), radius: isActive ? 3 : 1)
                            }

                            if hasCurrentTool || isThinking {
                                // Single Text so content changes crossfade instead of popping.
                                ClosedToolTransitionLabel(
                                    label: closedLabel,
                                    foregroundOpacity: currentToolName != nil ? 0.85 : 0.7,
                                    glowColor: indicatorColor
                                )
                            }
                        }
                    }
                    // The activity label anchors to the outer-left edge of its wing;
                    // only the right-side stats hug the physical notch.
                    .foregroundColor(showsTetherWings ? errorBrightColor : nil)
                    .frame(width: leftContentWidth, alignment: .leading)
                    .padding(.leading, leftEdgePadding)
                }

                // Unused width belongs between the outer-aligned content and the
                // physical notch, not before the content.
                if leftSlot < wingWidth {
                    Spacer().frame(width: wingWidth - leftSlot)
                }

                Spacer().frame(width: notchVM.closedNotchSize.width)

                if rightSlot < wingWidth {
                    Spacer().frame(width: wingWidth - rightSlot)
                }

                if let airPodsWings {
                    if rightWingWidth > 0 {
                        ClosedAirPodsWings.Row(pieces: airPodsWings.right)
                            .frame(width: rightWingWidth, alignment: .trailing)
                            .padding(.trailing, wingEdgePadding)
                            .transition(.scale(scale: 0.5).combined(with: .opacity))
                    }
                } else {
                    // Right wing - tool info or status
                    if baseRightWingWidth > 0 {
                        Group {
                            if isKeyboardLocked {
                                HStack(spacing: 4) {
                                    Image(systemName: "lock.fill")
                                        .font(.system(size: 10, weight: .semibold))
                                    Text("Locked")
                                        .font(.system(size: 10, weight: .semibold))
                                        .lineLimit(1)
                                        .fixedSize(horizontal: true, vertical: false)
                                }
                                .foregroundColor(lockedTint)
                            } else if showsDone, let doneFlash {
                                DoneCheckmarkView(color: doneBlue)
                                    .id(doneFlash.id)
                            } else if showsQuestionOnRight {
                                HStack(spacing: 4) {
                                    Image(systemName: "bubble.left.and.bubble.right")
                                        .font(.system(size: 8))
                                    Text("Answer")
                                        .font(.system(size: 9, weight: .medium))
                                }
                                .foregroundColor(showsClaudeQuestionOnRight || !isCodexQuestionWait ? .orange : .blue)
                            } else if showsSimultaneousClaudeWing {
                                // Mirror of the left wing: label, then the dot at the outer edge.
                                HStack(spacing: 6) {
                                    ClosedToolTransitionLabel(
                                        label: simultaneousClaudeLabel,
                                        foregroundOpacity: currentClaudeTool != nil ? 0.85 : 0.7,
                                        glowColor: claudeGlowColor
                                    )
                                    claudeWingIcons(count: claudeWorkingCount, spreadsLeading: false, glowColor: claudeGlowColor)
                                        // Same id as the left wing's Claude icon: when Codex joins,
                                        // Claude's icon glides across the notch instead of popping.
                                        .matchedGeometryEffect(id: "claudeWingIcon", in: wingIconNamespace)
                                }
                            } else if let codexTool = currentCodexTool, isCodexActive || codexActiveTool != nil {
                                // Codex tool info
                                HStack(spacing: 4) {
                                    if codexTool.isRunning {
                                        if let codexTurnStart { ClosedElapsedLabel(since: codexTurnStart) }
                                        ProgressView()
                                            .scaleEffect(0.3)
                                            .frame(width: 8, height: 8)
                                    } else {
                                        Text(codexTool.formattedDuration)
                                            .font(.system(size: 9, design: .monospaced))
                                            .foregroundColor(NotchPalette.ink.opacity(0.6))
                                            .lineLimit(1)
                                            .fixedSize(horizontal: true, vertical: false)
                                    }
                                }
                            } else if let claudeTool = currentClaudeTool, !hasPermissionNeeded {
                                // Claude Code tool info
                                HStack(spacing: 4) {
                                    if claudeTool.isRunning {
                                        if let claudeTurnStart { ClosedElapsedLabel(since: claudeTurnStart) }
                                        ProgressView()
                                            .scaleEffect(0.3)
                                            .frame(width: 8, height: 8)
                                    } else {
                                        Text(claudeTool.formattedDuration)
                                            .font(.system(size: 9, design: .monospaced))
                                            .foregroundColor(NotchPalette.ink.opacity(0.6))
                                            .lineLimit(1)
                                            .fixedSize(horizontal: true, vertical: false)
                                    }
                                }
                            } else if isThinking {
                                HStack(spacing: 4) {
                                    if let thinkingTurnStart { ClosedElapsedLabel(since: thinkingTurnStart) }
                                    ProgressView()
                                        .scaleEffect(0.3)
                                        .frame(width: 8, height: 8)
                                }
                            } else if hasPermissionNeeded {
                                HStack(spacing: 4) {
                                    NeedsOKDot()
                                    Text("Needs OK")
                                        .font(.system(size: 9, weight: .medium))
                                        .foregroundColor(.orange)
                                }
                            } else if showsTetherWings {
                                Text(tetherRightLabel)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(NotchPalette.ink.opacity(0.75))
                                    .lineLimit(1)
                                    .fixedSize()
                            }
                        }
                        .frame(width: baseRightWingWidth, alignment: .trailing)
                        .padding(.trailing, lowBattery == nil && !showsTetherIcon && !showsMediaMini ? wingEdgePadding : 6)
                    }
                    if showsMediaWings {
                        MediaWaveform(style: .wing, playing: nowPlayingMonitor.nowPlaying?.isPlaying ?? false,
                                      color: nowPlayingMonitor.nowPlaying?.accent)
                            .frame(width: mediaWingWidth, height: MediaWaveform.Style.wing.height)
                            .opacity(rightWingLayerOpacity)
                            .animation(WingFade.animation, value: rightWingLayerOpacity)
                            .padding(.trailing, lowBattery == nil ? rightEdgePadding : 6)
                            .transition(.opacity)
                    }
                    if showsTetherIcon {
                        Image(systemName: "personalhotspot")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(errorBrightColor)
                            .frame(width: 14)
                            .padding(.trailing, lowBattery == nil && !showsMediaMini ? wingEdgePadding : 6)
                    }
                    if showsMediaMini {
                        MediaWaveform(style: .mini, playing: nowPlayingMonitor.nowPlaying?.isPlaying ?? false,
                                      color: nowPlayingMonitor.nowPlaying?.accent)
                            .frame(width: MediaWaveform.Style.mini.width, height: MediaWaveform.Style.mini.height)
                            .opacity(rightWingLayerOpacity)
                            .animation(WingFade.animation, value: rightWingLayerOpacity)
                            .padding(.trailing, lowBattery == nil ? wingEdgePadding : 6)
                            .transition(.opacity.combined(with: .scale(scale: 0.5, anchor: .trailing)))
                    }
                    if let lowBattery {
                        ClosedLowBatteryBadge(device: lowBattery, showsIcon: !showsBatteryWings)
                            .frame(width: ClosedLowBatteryBadge.width(showsIcon: !showsBatteryWings), alignment: .trailing)
                            .padding(.trailing, wingEdgePadding)
                    }
                }
            }
            .frame(width: totalWidth)
            .onChange(of: totalWidth, initial: true) { _, width in
                notchVM.updateClosedPresentationWidth(
                    width + cornerRadiusInsets.closed.bottom * 2
                )
            }
            .onAppear {
                if closedDisplayedLabel.isEmpty {
                    closedDisplayedLabel = sourceLabel
                } else if closedDisplayedLabel != sourceLabel {
                    scheduleClosedLabelTransition(to: sourceLabel)
                }
            }
            .onChange(of: sourceLabel) { _, label in
                scheduleClosedLabelTransition(to: label)
            }
            .opacity(closedJellyContentOpacity)
            .animation(.easeInOut(duration: 0.18), value: closedDisplayedLabel)
            // Same curve as the surface, so the content moves with the black edge.
            .animation(closedWingResizeAnimation, value: totalWidth)
            // Codex joining or leaving moves Claude between the wings; animate it even if
            // the wings keep their width.
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.45, dampingFraction: 0.72),
                       value: isSimultaneousClaudeCodex)
            // The bars coming and going often leave the width as it is (the wings match the
            // wider side, the tool name while an agent works), and only a width change was
            // animated: music stopping dropped them in one frame (user, 2026-11-13).
            .animation(.easeOut(duration: 0.28), value: showsMediaMini)
            .animation(.easeOut(duration: 0.28), value: showsMediaWings)
            .animation(.easeOut(duration: 0.28), value: showsBatteryWings)
            .animation(.easeOut(duration: 0.28), value: showsAirPodsWings)
        }
    }

    /// Let each wipe finish. Events arriving during it are coalesced to the newest
    /// label so rapid tool bursts stay current without making the effect invisible.
    private func scheduleClosedLabelTransition(to label: String) {
        if closedLabelTransitionTask != nil {
            pendingClosedLabel = label
            return
        }

        guard label != closedDisplayedLabel else { return }

        closedLabelTransitionTask = Task { @MainActor in
            var nextLabel = label

            while !Task.isCancelled {
                closedDisplayedLabel = nextLabel
                try? await Task.sleep(for: .milliseconds(1500))
                guard !Task.isCancelled else { return }

                guard let pending = pendingClosedLabel,
                      pending != closedDisplayedLabel else {
                    pendingClosedLabel = nil
                    break
                }

                pendingClosedLabel = nil
                nextLabel = pending
            }

            closedLabelTransitionTask = nil
        }
    }

    private var openHeader: some View {
        let band = notchVM.closedNotchSize.height
        let row = HeaderChipMetrics.height
        let compact: Bool = { if case .band(let compact) = headerPlacement { return compact } else { return false } }()
        let inBand = headerPlacement != .rows
        // One row that only moves up or down: its left group hugs the left edge and its right
        // group the right edge in both places, so nothing crosses the camera. In the band it sits
        // a little below the housing's middle, as the band's player does.
        let top = inBand ? max(0, (band - row) / 2 + 2) : band + (openHeaderHeight - row) / 2
        return ZStack(alignment: .top) {
            // Beside the camera, the 노치 띠 shows what plays; the header row leaves it then.
            if !inBand && settings.enableNowPlaying {
                ZStack {
                    Color.clear
                    NotchBandNowPlaying(housingWidth: notchVM.closedNotchSize.width) { playing in
                        notchVM.close()
                        Task { @MainActor in
                            // Once the notch is back in place, so the card doesn't drop through it.
                            try? await Task.sleep(for: .seconds(notchCloseDuration))
                            let current = nowPlayingMonitor.nowPlaying ?? playing
                            if settings.mediaDropdownAttached {
                                _ = showMediaNotice(current)
                            } else {
                                AirPodsDropdown.media.showMedia(current)
                            }
                        }
                    }
                    // A little lower than the housing's middle, nearer the header under it
                    // (user, 2026-11-12: it floated too far above the settings buttons).
                    .offset(y: 5)
                }
                .frame(height: band)
                .transition(.opacity)
            }
            HStack(spacing: 10) {
                HStack(spacing: 10) {
                    agentOverview(compact: compact)
                    if tetherMonitor.activePlaceName != nil { TetherHeaderChip(compact: compact) }
                }
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    HeaderStatusChips(compact: compact)
                    NotchControlGroup(soundsOn: settings.notchSoundsEnabled,
                                      toggleSounds: { settings.notchSoundsEnabled.toggle() },
                                      openSettings: { openSettings() },
                                      quit: { confirmQuit() })
                }
            }
            .frame(height: row)
            // Padding, not an offset: an offset leaves the row's hover and click areas behind.
            .padding(.top, top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            selectedModeContent
                .id(activeMode)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .transition(modeContentTransition)
            // At the bottom, as a dock (user, 2026-11-18, from the open-notch drafts).
            if visibleModes.count > 1 { modeSwitcher }
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private var selectedModeContent: some View {
        if activeMode == .clipboard, settings.enableClipboardHistory {
            ClipboardHistoryView(manager: clipboardManager)
        } else if activeMode == .volume, hasVolume {
            AudioMixerView(manager: audioMixer)
        } else if activeMode == .sidecar, hasSidecar {
            SidecarView(manager: sidecarManager)
        } else if activeMode == .keyboardLock, hasKeyboardLock {
            ScrollView(.vertical) { KeyboardLockView(manager: keyboardLockManager) }
        } else if activeMode == .battery, hasBattery {
            BatteryView(manager: batteryManager)
        } else if activeMode == .speed, hasSpeedTest {
            ScrollView(.vertical) { SpeedTestView(manager: speedTest) }
        } else if let sessionDetail {
            SessionDetailView(
                target: sessionDetail, manager: claudeCodeManager, codexManager: codexManager,
                onBack: { showSessionDetail(nil) },
                openTitle: openTitle(sessionDetail.agent == .codex ? .codex : .claude, sessionDetail.sessionId),
                onOpenTerminal: {
                    // 확인 on an SSH host's session: back to the list.
                    if acknowledgesOnly(sessionDetail.agent == .codex ? .codex : .claude, sessionDetail.sessionId) {
                        showSessionDetail(nil)
                    } else {
                        focusSession(sessionDetail.agent == .codex ? .codex : .claude, sessionDetail.sessionId)
                        notchVM.close()
                    }
                }
            )
            .transition(modeContentTransition)
        } else {
            aiExpandedContent
        }
    }

    /// Centred when the chips fit; scrolls sideways only when they don't.
    /// 탭 막대 as a dock at the bottom of the open notch: the tabs spread over one dark panel,
    /// the picked one in its capsule with its name.
    private var modeSwitcher: some View {
        modeChips(matchID: "selectedChip-dock")
            .onReceive(NotificationCenter.default.publisher(for: .notchCommandHeld)) { note in
                commandHeld = note.userInfo?["held"] as? Bool ?? false
            }
            .padding(5)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(NotchPalette.ink.opacity(0.06)))
            .fixedSize(horizontal: false, vertical: true)
    }

    @Namespace private var chipNamespace
    /// Ties the left and right wings' Claude icons together so it moves between them.
    @Namespace private var wingIconNamespace

    /// Each `ViewThatFits` branch gets its own capsule id, in case both get measured at once.
    private func modeChips(matchID: String) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(visibleModes.enumerated()), id: \.element) { index, mode in
                NotchNavigationButton(mode: mode, selected: activeMode == mode,
                                      needsAttention: mode == .ai && attentionCount > 0,
                                      namespace: chipNamespace, matchID: matchID,
                                      shortcut: commandHeld && index < 7 ? index + 1 : nil) {
                    withAnimation(modeSwitchAnimation) {
                        expandedMode = mode
                    }
                }
                .frame(maxWidth: .infinity)
                .id(mode)
            }
        }
    }

    private var attentionCount: Int {
        (settings.showSourceClaudeCode ? claudeCodeManager.sessionsNeedingPermission.count : 0)
            + (settings.showSourceClaudeCode ? claudeCodeManager.sessionsAwaitingInput.count : 0)
            + (settings.showSourceCodex ? codexManager.pendingInputRequests.count : 0)
    }

    /// Sessions waiting on a permission or a real question (not a next-step box).
    private var waitingSessionIDs: [String] {
        var ids: [String] = []
        if settings.showSourceClaudeCode {
            if settings.showPermissionIndicator {
                ids += claudeCodeManager.sessionsNeedingPermission.map(\.id)
            }
            ids += claudeCodeManager.availableSessions
                .filter { claudeCodeManager.sessionStates[$0.id]?.pendingInputRequests.contains { !$0.isWrapUp } == true }
                .map(\.id)
        }
        if settings.showSourceCodex {
            ids += codexManager.sessionStates.filter { $0.value.pendingInputRequest != nil }.map(\.key).sorted()
        }
        return ids
    }

    private var overviewHasActivity: Bool {
        (settings.showSourceClaudeCode && claudeHasRealActivity)
            || codexHasRealActivity
    }

    /// The 상태 캡슐's words: 대기 중, or 작업 중 and how many sessions work.
    private var overviewStatusText: String {
        let working = (settings.showSourceClaudeCode
                       ? claudeCodeManager.availableSessions.filter { claudeCodeManager.sessionStates[$0.id]?.isActive == true }.count : 0)
            + (settings.showSourceCodex
               ? codexManager.availableSessions.filter { codexManager.sessionStates[$0.id]?.isActive == true }.count : 0)
        return !overviewHasActivity ? L("대기 중", "Quiet")
            : working > 0 ? L("작업 중 \(working)", "Working \(working)") : L("작업 중", "Working")
    }

    /// The 요약 줄's width as drawn, for deciding whether the header fits beside the camera.
    private func overviewWidth(compact: Bool) -> CGFloat {
        func text(_ string: String) -> CGFloat {
            ceil((string as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)]).width)
        }
        var parts: [CGFloat] = [compact ? 6 + StatusDotView.side + 6 : 10 + StatusDotView.side + 6 + text(overviewStatusText) + 10]
        let claudeCount = settings.showSourceClaudeCode ? claudeCodeManager.availableSessions.count : 0
        let codexCount = settings.showSourceCodex ? codexManager.availableSessions.count : 0
        if claudeCount > 0 { parts.append(12 + 4 + text("\(claudeCount)")) }
        if codexCount > 0 { parts.append(12 + 4 + text("\(codexCount)")) }
        // The bubble's symbol is about 20 pt wide at this size.
        if attentionCount > 0 { parts.append(10 + 20 + 6 + text("\(attentionCount)") + 10) }
        return parts.reduce(0, +) + CGFloat(parts.count - 1) * 12
    }

    /// 요약 줄, at the head of the open notch so it shows on every tab. `compact` (beside the
    /// camera, where room is short): the 상태 캡슐 is its lit dot alone; the counts beside it
    /// still say how many sessions there are.
    private func agentOverview(compact: Bool) -> some View {
        HStack(spacing: 12) {
            let glow = overviewGlow
            HStack(spacing: 6) {
                StatusDot(active: overviewHasActivity, color: glow.color, secondary: glow.secondary)
                if !compact {
                    // Lit by the glow while working; the grey only reaches the text when idle.
                    SweptText(text: overviewStatusText, glow: glow)
                        .foregroundStyle(NotchPalette.ink.opacity(0.55))
                }
            }
            .padding(.horizontal, compact ? 6 : 10)
            .frame(height: HeaderChipMetrics.height)
            .background(Capsule().fill(NotchPalette.ink.opacity(0.08)))
            // Compact, the words are only here.
            .help(overviewStatusText)
            // Sessions per agent, by logo; an agent with none is left out.
            let claudeCount = settings.showSourceClaudeCode ? claudeCodeManager.availableSessions.count : 0
            if claudeCount > 0 {
                let count = claudeCount
                overviewAgentCount(Image("ClaudeIcon").resizable(), count)
                    .help(L("Claude 세션 \(count)", "Claude sessions: \(count)"))
            }
            let codexCount = settings.showSourceCodex ? codexManager.availableSessions.count : 0
            if codexCount > 0 {
                let count = codexCount
                overviewAgentCount(Image("ChatGPTIcon").resizable().foregroundColor(NotchPalette.ink), count)
                    .help(L("Codex 세션 \(count)", "Codex sessions: \(count)"))
            }
            if attentionCount > 0 {
                Label("\(attentionCount)", systemImage: "bubble.left.and.exclamationmark.bubble.right")
                    .foregroundStyle(.red)
                    .padding(.horizontal, 10)
                    .frame(height: HeaderChipMetrics.height)
                    .background(Capsule().fill(Color.red.opacity(0.18)))
                    .modifier(Breathing(active: true))
                    .help(L("답변·승인 대기", "Waiting for your response"))
            }
        }
        .font(.system(size: 13, weight: .semibold))
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    private func overviewAgentCount(_ logo: some View, _ count: Int) -> some View {
        HStack(spacing: 4) {
            logo.frame(width: 12, height: 12)
            Text("\(count)")
        }
    }

    /// "작업 중" lit in the working agent's colour like the glow; both working → it alternates.
    private var overviewGlow: GlowSweepText {
        let claude = settings.showSourceClaudeCode && claudeHasRealActivity
        let codex = codexHasRealActivity
        if claude && codex {
            return GlowSweepText(active: true, color: codexGlowColor, bright: codexBrightColor,
                                 secondary: claudeGlowColor, secondaryBright: claudeBrightColor)
        }
        let useCodex = codex && !claude
        return GlowSweepText(active: overviewHasActivity,
                             color: useCodex ? codexGlowColor : claudeGlowColor,
                             bright: useCodex ? codexBrightColor : claudeBrightColor)
    }

    /// One of the Agents tab's cards under NEEDS YOU, in the order 설정 -> 에이전트 -> Agents 탭 카드
    /// keeps (`AgentsCard`).
    @ViewBuilder
    private func agentsCard(_ card: AgentsCard) -> some View {
        switch card {
        case .claudeUsage: claudeUsageCard
        case .codexUsage: codexUsageCard
        case .tasks:
            // Show todo list if enabled and has items
            if settings.showSourceClaudeCode && settings.showTodoList && !claudeCodeManager.state.todos.isEmpty {
                NotchSection(title: claudeCodeManager.selectedSession.map { "Current Tasks · \($0.displayName)" } ?? "Current Tasks") {
                    TodoListView(todos: claudeCodeManager.state.todos, maxItems: 4)
                }
            }
        case .sessions:
            // The outer AI scroll view owns scrolling, so the session list renders all rows.
            NotchSection(title: "Sessions") {
                ClaudeSessionListView(
                    manager: claudeCodeManager,
                    codexManager: codexManager,
                    onSelect: { showSessionDetail($0) }
                )
            }
        }
    }

    @ViewBuilder
    private var claudeUsageCard: some View {
        // The demo's Codex-only scene has no Claude card at all.
        if settings.showSourceClaudeCode && !(DemoMode.isActive && DemoMode.scene == .codex) {
            NotchSection {
                if settings.enableClaudeUsage {
                    ClaudeUsageNotchSection()
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Claude")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(NotchPalette.ink.opacity(0.55))
                        Text(L("사용량 조회가 꺼져 있습니다. 설정에서 켜면 5시간·7일 사용량을 확인할 수 있습니다.", "Usage tracking is off. Turn it on in Settings to see 5-hour and 7-day usage."))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(L("사용량 설정 열기", "Open usage settings")) { openSettings() }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(chipAccent)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var codexUsageCard: some View {
        // The demo's Claude-only scenes have no Codex card at all (it read "no usage data yet").
        if settings.showSourceCodex && settings.showCodexUsage,
           !(DemoMode.isActive && (DemoMode.scene == .claude || DemoMode.scene == .ssh)) {
            NotchSection {
                if codexManager.rateLimits.hasData {
                    CodexUsageNotchSection(rateLimits: codexManager.rateLimits)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Codex")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(NotchPalette.ink.opacity(0.55))
                        Text(L("아직 사용량 데이터가 없습니다. Codex 세션에서 한도 정보가 수신되면 표시됩니다.", "No usage data yet. It appears once a Codex session reports its limits."))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var aiExpandedContent: some View {
        ScrollView(.vertical) {
            VStack(spacing: 12) {
                if settings.showSourceCodex, let request = codexManager.pendingInputRequests.first {
                    let sessionId = codexManager.sessionStates.first { $0.value.pendingInputRequest?.id == request.id }?.key
                    NotchSection(title: "NEEDS YOU · Codex", rail: codexGlowColor, onDismiss: { codexManager.dismissInputRequest(id: request.id) }) {
                        QuestionOptionsView(questions: request.questions, sourceName: "Codex", accentColor: .blue,
                                            onSubmit: codexQuestionAnswer(for: request),
                                            openTitle: sessionId.map { openTitle(.codex, $0) },
                                            onOpen: sessionId.map { id in {
                                                if acknowledgesOnly(.codex, id) {
                                                    codexManager.dismissInputRequest(id: request.id)
                                                } else {
                                                    focusSession(.codex, id)
                                                    notchVM.close()
                                                }
                                            } })
                    }
                }
                if settings.showSourceClaudeCode && settings.showPermissionIndicator && !claudeCodeManager.sessionsNeedingPermission.isEmpty {
                    NotchSection(title: "NEEDS YOU · Claude", rail: claudeGlowColor, onDismiss: {
                        if let session = claudeCodeManager.sessionsNeedingPermission.first {
                            claudeCodeManager.dismissPermission(sessionId: session.id)
                        }
                    }) {
                        let permissionSession = claudeCodeManager.sessionsNeedingPermission.first
                        Button {
                            if let permissionSession {
                                if acknowledgesOnly(.claude, permissionSession.id) {
                                    claudeCodeManager.dismissPermission(sessionId: permissionSession.id)
                                } else {
                                    focusSession(.claude, permissionSession.id)
                                    notchVM.close()
                                }
                            }
                        } label: {
                            Label(permissionSession.map { openTitle(.claude, $0.id) } ?? L("에디터에서 권한 확인", "Review permission in your editor"),
                                  systemImage: permissionSession.map { acknowledgesOnly(.claude, $0.id) } == true ? "checkmark" : "arrow.up.forward.app")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.orange)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(NotchHoverButtonStyle())
                    }
                }
                if settings.showSourceClaudeCode, let request = claudeCodeManager.pendingInputRequests.first {
                    let sessionId = claudeCodeManager.sessionStates.first { $0.value.pendingInputRequests.contains { $0.id == request.id } }?.key
                    NotchSection(title: "NEEDS YOU · Claude", rail: claudeGlowColor, onDismiss: { claudeCodeManager.dismissInputRequest(id: request.id) }) {
                        QuestionOptionsView(questions: request.questions, sourceName: "Claude", accentColor: .orange,
                                            // A question or next-step box the notch can answer: its options are
                                            // buttons here too, as in the dropdown.
                                            onSubmit: request.isWrapUp ? nextStepSubmit(for: request, sessionId: sessionId)
                                                : claudeQuestionAnswer(for: request),
                                            openTitle: sessionId.map { openTitle(.claude, $0) },
                                            onOpen: sessionId.map { id in {
                                                if acknowledgesOnly(.claude, id) {
                                                    acknowledgeClaude(request.id, sessionId: id)
                                                } else {
                                                    focusSession(.claude, id)
                                                    notchVM.close()
                                                }
                                            } },
                                            allowsCustom: !request.isWrapUp)
                            .id(request.id)
                    }
                }

                ForEach(AgentsCard.order(from: settings.agentsCardOrder)) { agentsCard($0) }
            }
            .padding(.horizontal, 1)
            .padding(.top, 1)
            .padding(.bottom, 8)
        }
        .scrollIndicators(.visible)
    }

    @ViewBuilder
    /// Each side of the camera in the dropdown's first row (`WingHeader`): the row is the notch's
    /// width less its insets, the camera sits in its middle, 8 pt clear of either side.
    private var wingSide: CGFloat {
        (notchVM.notchSize.width - 2 * expandedNotchInset - notchVM.closedNotchSize.width) / 2 - 8
    }

    private var peekHeader: some View {
        Group {
            if showPermissionNotice, let item = permissionCenter.queue.first ?? shownPermission {
                PermissionPeekHeader(item: item, position: 1, total: permissionCenter.queue.count,
                                     accent: agentAccent(item.agent), side: wingSide) {
                    permissionCenter.decide(item.id, .terminal)
                }
            } else if showQuestionNotice {
                let wrapUp = claudeInputRequest?.isWrapUp == true
                let count = (codexInputRequest?.questions ?? claudeInputRequest?.questions ?? []).count
                AskPeekHeader(agent: codexInputRequest == nil ? .claude : .codex,
                              title: wrapUp ? L("다음 단계", "Next step")
                                  : count > 1 ? L("질문 \(min(questionStep, count - 1) + 1)/\(count)", "Question \(min(questionStep, count - 1) + 1)/\(count)")
                                  : L("질문", "Question"),
                              accent: questionNoticeColor, side: wingSide, dismissOpen: $questionDismissOpen,
                              scale: wrapUp ? 1 : questionScale,
                              onDismiss: { dismissQuestionNotice() }, onClear: { clearQuestionNotice() })
            } else if showPermissionNotice {
                Color.clear
            } else if showSpeedNotice {
                SpeedPeekHeader(manager: speedTest)
            } else if let tetherPlaceName {
                TetherPeekHeader(placeName: tetherPlaceName)
            } else if let doneNotice {
                DonePeekHeader(agent: doneNotice.source == .codex ? .codex : .claude,
                               elapsed: doneNotice.turn.elapsed, accent: doneBlue, side: wingSide) {
                    dismissDoneNotice()
                }
            } else if mediaNotice != nil {
                // The attached player's close button, in the free space right of the camera, on
                // the notch's own colour, while the cursor is on the notch (user, 2026-11-18).
                HStack {
                    Spacer()
                    Button { dismissMediaNotice() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(NotchPalette.ink.opacity(0.7))
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(theme.surface ?? .black))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(L("닫기", "Close"))
                    .scaleEffect(notchHovered ? 1 : 0.4)
                    .opacity(notchHovered ? 1 : 0)
                    .allowsHitTesting(notchHovered)
                    .animation(.spring(response: 0.3, dampingFraction: 0.65), value: notchHovered)
                }
            } else {
                Color.clear
            }
        }
    }

    @ViewBuilder
    private var peekContent: some View {
        Group {
            if showPermissionNotice, let item = permissionCenter.queue.first ?? shownPermission {
                permissionDropdown(item)
            } else if showQuestionNotice {
                questionContent
            } else if showSpeedNotice {
                SpeedPeekContent(manager: speedTest)
            } else if let tetherPlaceName {
                TetherPeekContent(placeName: tetherPlaceName)
            } else if let doneNotice {
                doneDropdown(doneNotice)
            } else if let mediaNotice {
                mediaDropdown(nowPlayingMonitor.nowPlaying ?? mediaNotice)
            }
        }
    }

    /// Set while the asking Claude session's hook waits on the notch, so picking an option
    /// answers the question from here.
    private var claudeQuestionAnswer: (([String: Any]) -> Void)? {
        claudeInputRequest.flatMap(claudeQuestionAnswer(for:))
    }

    /// The same for any Claude question: the 질문 드롭다운's and the NEEDS YOU 카드's, so a
    /// question still gets its answer after the notch was opened over the dropdown (user,
    /// 2026-11-12). The hook stays held while the notch is open.
    private func claudeQuestionAnswer(for request: ClaudeInputRequest) -> (([String: Any]) -> Void)? {
        // A next-step box's buttons send a message in the app; the notch can't press them.
        guard !request.isWrapUp, let sessionId = claudeSessionId(asking: request),
              permissionCenter.answerableQuestionSessions.contains(sessionId) else { return nil }
        let center = permissionCenter
        return { answers in center.answerQuestion(sessionId: sessionId, answers: answers) }
    }

    /// Set when the notch can answer the Codex question itself (`canAnswerFromNotch`); the
    /// rest are answered where they were asked.
    private var codexQuestionAnswer: (([String: Any]) -> Void)? {
        codexInputRequest.flatMap(codexQuestionAnswer(for:))
    }

    private func codexQuestionAnswer(for request: CodexInputRequest) -> (([String: Any]) -> Void)? {
        // 실험 기능: it rides Codex's internal sockets, which an update can change.
        // The demo shows it switched on without touching the saved setting.
        guard settings.experimentalCodexAppAnswers || DemoMode.isActive,
              let sessionId = codexManager.sessionStates.first(where: {
                  $0.value.pendingInputRequest?.id == request.id
              })?.key,
              codexManager.canAnswerFromNotch(request, sessionId: sessionId) else { return nil }
        let manager = codexManager
        return { answers in manager.answerInputRequest(request, sessionId: sessionId, answers: answers) }
    }

    private var questionNoticeColor: Color {
        codexInputRequest == nil ? .orange : codexGlowColor
    }

    /// Type size in the 질문 드롭다운: larger once it is enlarged, so the extra room reads.
    private var questionScale: CGFloat { questionExpanded ? 1.4 : 1 }

    /// Who asked and where from, as the 다음 단계 드롭다운 and 완료 드롭다운 say it: the session's
    /// name and folder, behind the SSH mark and host for a remote one. "질문" and the 닫기 알약 are in
    /// the wing header (`AskPeekHeader`).
    private var questionHeader: some View {
        HStack(spacing: 4) {
            Text(codexInputRequest == nil ? L("Claude가 질문했습니다", "Claude asked a question") : L("Codex가 질문했습니다", "Codex asked a question"))
            if let origin = askingSessionOrigin {
                if let host = origin.host {
                    Text("·")
                    // `SessionAppDestination.ssh`'s mark.
                    Image(systemName: "network")
                        .font(.system(size: 10 * questionScale, weight: .semibold))
                    Text(host)
                }
                if !origin.label.isEmpty {
                    Text("·")
                    Text(origin.label)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11.5 * questionScale))
        .foregroundColor(NotchPalette.ink.opacity(0.5))
        .lineLimit(1)
    }

    /// Where the question in the 질문 드롭다운 comes from: the asking session's name and folder,
    /// and its SSH host when it runs on one.
    private var askingSessionOrigin: (label: String, host: String?)? {
        if let request = codexInputRequest,
           let session = codexManager.availableSessions.first(where: {
               codexManager.sessionStates[$0.id]?.pendingInputRequest?.id == request.id
           }) {
            return (sessionLabel(.codex, session.id), session.remoteHost)
        }
        if let request = claudeInputRequest, let sessionId = claudeSessionId(asking: request) {
            return (sessionLabel(.claude, sessionId),
                    claudeCodeManager.availableSessions.first { $0.id == sessionId }?.remoteHost)
        }
        return nil
    }

    /// The session that holds a Claude question, by its request.
    private func claudeSessionId(asking request: ClaudeInputRequest) -> String? {
        claudeCodeManager.sessionStates.first { $0.value.pendingInputRequests.contains { $0.id == request.id } }?.key
    }

    /// Set while the session's next-step hook waits on the notch (설정 › 실험 기능), so a
    /// button in the 다음 단계 드롭다운 answers the box from here.
    private func nextStepAnswer(for request: ClaudeInputRequest, sessionId: String?) -> ((AgentInputOption) -> Void)? {
        guard let sessionId, permissionCenter.answerableNextStepSessions.contains(sessionId) else { return nil }
        let center = permissionCenter
        return { option in
            center.answerNextStep(sessionId: sessionId, requestId: request.id,
                                  label: option.label, message: option.description)
        }
    }

    /// The same answer from the NEEDS YOU 카드, whose options come back as `[question: label]`.
    private func nextStepSubmit(for request: ClaudeInputRequest, sessionId: String?) -> (([String: Any]) -> Void)? {
        guard let pick = nextStepAnswer(for: request, sessionId: sessionId),
              let question = request.questions.first else { return nil }
        return { answers in
            guard let label = answers[question.question] as? String,
                  let option = question.options.first(where: { $0.label == label }) else { return }
            pick(option)
        }
    }

    private func wrapUpDropdown(_ request: ClaudeInputRequest) -> some View {
        let sessionId = claudeSessionId(asking: request)
        return WrapUpDropdownView(
            request: request,
            projectName: sessionId.map { sessionLabel(.claude, $0) } ?? "",
            accent: agentAccent(.claude),
            openTitle: askingSessionOpenTitle,
            onOpen: { goToAskingSession() },
            dismissOpen: $questionDismissOpen,
            // Collapses only, like the 질문 드롭다운; Answer and the NEEDS YOU 카드 stay.
            onDismiss: { dismissQuestionNotice() },
            onClear: { clearQuestionNotice() },
            onPick: nextStepAnswer(for: request, sessionId: sessionId)
        )
    }

    private var questionContent: some View {
        Group {
            if let request = claudeInputRequest, request.isWrapUp {
                wrapUpDropdown(request)
            } else {
                plainQuestionContent
            }
        }
    }

    private var plainQuestionContent: some View {
        VStack(spacing: 6) {
            questionHeader

            if let request = codexInputRequest {
                ScrollView(.vertical) {
                    QuestionOptionsView(questions: request.questions, sourceName: "Codex", accentColor: .blue,
                                        onSubmit: codexQuestionAnswer, goTitle: askingSessionOpenTitle,
                                        onGo: { goToAskingSession() }, scale: questionScale,
                                        onStep: { questionStep = $0 })
                        .id(request.id)
                        .background(ThinScrollers())
                }
            } else if let request = claudeInputRequest {
                ScrollView(.vertical) {
                    QuestionOptionsView(questions: request.questions, sourceName: "Claude", accentColor: .orange,
                                        onSubmit: claudeQuestionAnswer, goTitle: askingSessionOpenTitle,
                                        onGo: { goToAskingSession() }, scale: questionScale,
                                        onStep: { questionStep = $0 }, allowsCustom: true)
                        .id(request.id)
                        .background(ThinScrollers())
                }
            }
        }
        .padding(.top, 4)
    }

    /// The 질문 드롭다운's 크기 손잡이, for Claude and Codex questions alike. The 다음 단계
    /// 드롭다운 has none.
    private var showsQuestionResizeHandle: Bool {
        notchVM.notchState == .peeking && showQuestionNotice && !showPermissionNotice
            && (codexInputRequest != nil || claudeInputRequest.map { !$0.isWrapUp } == true)
    }

    /// The enlarged 질문 드롭다운: as wide as `expandedQuestionSize`, as tall as its content at the
    /// enlarged size within that height. It stood at three fifths of the screen whatever it held,
    /// mostly empty (user, 2026-11-18).
    private func enlargedQuestionSize() -> CGSize {
        let limit = expandedQuestionSize()
        let content = VStack(spacing: 6) {
            questionHeader
            QuestionOptionsView(questions: codexInputRequest?.questions ?? claudeInputRequest?.questions ?? [],
                                sourceName: codexInputRequest == nil ? "Claude" : "Codex", accentColor: questionNoticeColor,
                                onSubmit: { _ in }, goTitle: askingSessionOpenTitle, onGo: {}, scale: 1.4,
                                allowsCustom: codexInputRequest == nil)
        }
        .padding(.top, 4)
        .frame(width: limit.width - expandedNotchInset * 2)
        .fixedSize(horizontal: false, vertical: true)
        let height = notchVM.closedNotchSize.height + ceil(NSHostingView(rootView: content).fittingSize.height) + 16
        return CGSize(width: limit.width, height: min(limit.height, height))
    }

    private func toggleQuestionExpanded() {
        questionExpanded.toggle()
        if questionExpanded {
            notchVM.resizePeek(to: enlargedQuestionSize())
        } else if let request = claudeInputRequest {
            triggerClaudeInputNotice(request)
        } else if let request = codexInputRequest {
            triggerCodexInputNotice(request)
        }
    }

    struct CodexUsageNotchSection: View {
        let rateLimits: CodexRateLimits
        @ObservedObject private var codexManager = CodexManager.shared
        @AppStorage("usagePaceEnabled") private var paceEnabled = true
        @AppStorage("showCodexPlan") private var showPlan = true

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Codex")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.8)
                        .foregroundColor(NotchPalette.ink.opacity(0.4))
                    // "plus", "pro"… as Codex reports it with the limits.
                    if showPlan, let plan = rateLimits.planType, !plan.isEmpty {
                        PlanBadge(text: plan.prefix(1).uppercased() + plan.dropFirst(),
                                  tint: Color(red: 0.2, green: 0.5, blue: 1.0))
                    }
                    if rateLimits.limitReached {
                        // A window can sit well under 100% while a different one
                        // is what's actually blocking, so say so outright.
                        Text(L("한도 도달", "Limit reached"))
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.red)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.red.opacity(0.18), in: Capsule())
                    }
                    Spacer()
                    if codexManager.isRefreshingRateLimits {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.clockwise")
                            Text(L("갱신 중", "Refreshing"))
                        }
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(NotchPalette.ink.opacity(0.5))
                    } else if let nextRefreshAt = codexManager.nextRateLimitRefreshAt {
                        // A spent weekly window pauses polling for days; "138:54:03" reads as
                        // nonsense, so use the same day/hour wording as the Claude card.
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let remaining = max(0, nextRefreshAt.timeIntervalSince(context.date))
                            HStack(spacing: 3) {
                                Image(systemName: "timer")
                                Text(remaining >= 1 ? ClaudeUsageNotchSection.formatCountdown(remaining) : L("곧", "soon"))
                            }
                            .font(.system(size: 10, weight: .medium).monospacedDigit())
                            .foregroundColor(NotchPalette.ink.opacity(0.5))
                        }
                    }
                    Button(action: codexManager.refresh) {
                        // One symbol name, as in the Claude card: a swap under the repeatForever
                        // below loops its replace transition forever, even in the closed popover.
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10))
                            .foregroundColor(NotchPalette.ink.opacity(0.55))
                            .rotationEffect(.degrees(codexManager.isRefreshingRateLimits ? 360 : 0))
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                            .animation(
                                codexManager.isRefreshingRateLimits
                                    ? .linear(duration: 1).repeatForever(autoreverses: false)
                                    : .default,
                                value: codexManager.isRefreshingRateLimits
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(codexManager.isRefreshingRateLimits)
                }
                if let primary = rateLimits.primary {
                    rateLimitRow(primary)
                }
                if let secondary = rateLimits.secondary {
                    rateLimitRow(secondary)
                }
            }
        }

        private func rateLimitRow(_ window: CodexRateLimitWindow) -> some View {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: window.windowMinutes >= 1_440 ? "calendar" : "clock")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text(windowLabel(window.windowMinutes))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(Int(window.usedPercent.rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(levelColor(window.usedPercent))
                        .contentTransition(.numericText(value: window.usedPercent))
                        .animation(.smooth, value: window.usedPercent)
                    if let resetsAt = window.resetsAt {
                        Text("• \(relativeResetText(resetsAt)) · \(resetsAt, format: .dateTime.hour().minute())")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                let length = TimeInterval(window.windowMinutes * 60)
                UsageBar(percent: window.usedPercent, color: levelColor(window.usedPercent),
                         projectedFraction: paceEnabled
                            ? UsagePace.projectedFraction(percent: window.usedPercent, resetsAt: window.resetsAt, window: length) : nil)
                if paceEnabled {
                    UsagePaceLine(percent: window.usedPercent, resetsAt: window.resetsAt, window: length)
                }
            }
        }

        private func relativeResetText(_ date: Date) -> String {
            let formatter = DateComponentsFormatter()
            formatter.allowedUnits = [.day, .hour, .minute]
            formatter.unitsStyle = .abbreviated
            formatter.maximumUnitCount = 2
            var calendar = Calendar.current
            calendar.locale = Locale(identifier: L("ko_KR", "en_US"))
            formatter.calendar = calendar
            return formatter.string(from: max(0, date.timeIntervalSinceNow)) ?? L("0분", "0m")
        }

        private func windowLabel(_ minutes: Int) -> String {
            if minutes % 1_440 == 0 { return L("\(minutes / 1_440)일", "\(minutes / 1_440)d") }
            if minutes % 60 == 0 { return L("\(minutes / 60)시간", "\(minutes / 60)h") }
            return L("\(minutes)분", "\(minutes)m")
        }

        private func levelColor(_ percentage: Double) -> Color {
            if percentage >= 80 { return .red }
            if percentage >= 50 { return .orange }
            return .green
        }
    }

    private struct QuestionOptionsView: View {
        let questions: [AgentInputQuestion]
        let sourceName: String
        let accentColor: Color
        /// Set while the agent's hook waits on the notch: options become buttons and the
        /// picks go back as `[question: label]` (a label list for multi-select).
        var onSubmit: (([String: Any]) -> Void)? = nil
        /// NEEDS YOU 카드: the footer becomes a button that goes to the session's GUI or
        /// terminal (it looked like one before and did nothing). `openTitle` names where.
        var openTitle: String? = nil
        var onOpen: (() -> Void)? = nil
        /// 질문 드롭다운: the 완료 드롭다운's go button (터미널 열기 / GUI 열기) at the bottom right.
        var goTitle: String? = nil
        var onGo: (() -> Void)? = nil
        /// The enlarged 질문 드롭다운 draws everything this much bigger.
        var scale: CGFloat = 1
        /// Which question shows, for the wing header's "질문 1/2".
        var onStep: ((Int) -> Void)? = nil
        /// 직접 입력 under the options (Claude questions, user 2026-11-19): a typed answer goes
        /// back as the answer, as Claude's own "Other" does.
        var allowsCustom = false
        @Environment(\.notchTyping) private var notchTyping
        /// Picks per question; `Self.custom` stands for the typed answer.
        @State private var picks: [Int: Set<Int>] = [:]
        @State private var customText: [Int: String] = [:]
        /// The question whose 직접 입력 is being typed into.
        @State private var editing: Int?
        @FocusState private var fieldFocused: Bool
        private static let custom = -1
        /// Answerable questions come one at a time (user, 2026-11-18): a pick shows for a moment,
        /// then the next one comes; ‹ 이전 goes back with the earlier pick still marked.
        @State private var step = 0
        @State private var advancing = false

        private var canSend: Bool {
            questions.indices.allSatisfy { picks[$0]?.isEmpty == false }
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 10 * scale) {
                if onSubmit != nil, !questions.isEmpty {
                    // All laid out, one shown: the dropdown is sized once for the tallest, and the
                    // next question can't push the buttons out of sight. It switches at once, the
                    // pick having shown; a crossfade showed both for a moment.
                    ZStack(alignment: .topLeading) {
                        ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
                            questionBlock(question, index: index)
                                .opacity(index == step ? 1 : 0)
                                .allowsHitTesting(index == step)
                                .accessibilityHidden(index != step)
                        }
                    }
                } else {
                    // Only to read (the answer is given in the agent): all of them, set apart.
                    ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
                        if index > 0 { Rectangle().fill(NotchPalette.ink.opacity(0.1)).frame(height: 1) }
                        questionBlock(question, index: index)
                    }
                }

                if questions.isEmpty {
                    Text(L("질문 내용은 \(sourceName)에서 확인해 주세요.", "See \(sourceName) for the question."))
                        .font(.system(size: 11 * scale))
                        .foregroundColor(NotchPalette.ink.opacity(0.7))
                }
                footer
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onAppear { onStep?(step) }
            .onChange(of: step) { _, now in onStep?(now) }
            // The keyboard goes back with the question (answered, folded, replaced).
            .onDisappear { if editing != nil { notchTyping(false) } }
        }

        /// The question in bold over a line, then its options: set apart from each other.
        private func questionBlock(_ question: AgentInputQuestion, index: Int) -> some View {
            VStack(alignment: .leading, spacing: 8 * scale) {
                VStack(alignment: .leading, spacing: 4 * scale) {
                    if question.multiSelect || (onSubmit == nil && questions.count > 1) {
                        Text(question.multiSelect ? L("\(question.header) · 복수 선택", "\(question.header) · multiple choice") : question.header)
                            .font(.system(size: 10.5 * scale, weight: .semibold))
                            .foregroundColor(accentColor)
                    }
                    Text(question.question)
                        .font(.system(size: 14.5 * scale, weight: .bold))
                        .foregroundColor(NotchPalette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Rectangle().fill(NotchPalette.ink.opacity(0.1)).frame(height: 1)
                VStack(alignment: .leading, spacing: 5 * scale) {
                    ForEach(Array(question.options.enumerated()), id: \.offset) { optionIndex, option in
                        if onSubmit != nil {
                            optionButton(option, picked: picks[index]?.contains(optionIndex) == true,
                                         multiSelect: question.multiSelect) {
                                pick(optionIndex, in: index, multiSelect: question.multiSelect)
                            }
                            .popIn(.rise, delay: Double(min(optionIndex, 6)) * 0.035)
                        } else {
                            HStack(alignment: .top, spacing: 5) {
                                Circle()
                                    .fill(NotchPalette.ink.opacity(0.5))
                                    .frame(width: 4, height: 4)
                                    .padding(.top, 5)
                                optionText(option)
                            }
                        }
                    }
                    if onSubmit != nil, allowsCustom {
                        customRow(index, multiSelect: question.multiSelect)
                            .popIn(.rise, delay: Double(min(question.options.count, 6)) * 0.035)
                    }
                }
            }
        }

        /// 직접 입력: a row like the options; clicked, it turns into a field (the notch takes the
        /// keyboard for it), and Return makes the text the answer. Esc leaves it.
        private func customRow(_ index: Int, multiSelect: Bool) -> some View {
            let picked = picks[index]?.contains(Self.custom) == true
            let text = customText[index] ?? ""
            return HStack(alignment: .firstTextBaseline, spacing: 8 * scale) {
                Image(systemName: picked ? (multiSelect ? "checkmark.square.fill" : "checkmark.circle.fill") : "pencil")
                    .font(.system(size: 12 * scale, weight: .medium))
                    .foregroundColor(picked ? accentColor : NotchPalette.ink.opacity(0.4))
                if editing == index {
                    TextField(L("직접 입력", "Type an answer"),
                              text: Binding(get: { customText[index] ?? "" }, set: { customText[index] = $0 }))
                        .textFieldStyle(.plain)
                        .font(.system(size: 13 * scale, weight: .medium))
                        .foregroundColor(NotchPalette.ink)
                        .focused($fieldFocused)
                        .onSubmit { commitCustom(index, multiSelect: multiSelect) }
                        .onExitCommand { stopTyping() }
                    Text(L("↩ 보내기", "↩ Send"))
                        .font(.system(size: 11 * scale))
                        .foregroundColor(NotchPalette.ink.opacity(0.35))
                } else {
                    Text(text.isEmpty ? L("직접 입력…", "Type an answer…") : text)
                        .font(.system(size: 13 * scale, weight: .medium))
                        .foregroundColor(NotchPalette.ink.opacity(text.isEmpty ? 0.5 : 1))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 12 * scale)
            .padding(.vertical, 8 * scale)
            .background(RoundedRectangle(cornerRadius: 10 * scale, style: .continuous)
                .fill(picked ? accentColor.opacity(0.2) : NotchPalette.ink.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 10 * scale, style: .continuous)
                .stroke(editing == index ? accentColor.opacity(0.7) : picked ? accentColor.opacity(0.7) : .clear, lineWidth: 1.2))
            .contentShape(Rectangle())
            .onTapGesture {
                guard editing != index else { return }
                editing = index
                notchTyping(true)
                // Once the field is there.
                DispatchQueue.main.async { fieldFocused = true }
            }
        }

        private func stopTyping() {
            editing = nil
            fieldFocused = false
            notchTyping(false)
        }

        /// Return in 직접 입력: the text is this question's answer (one of the answers, for a
        /// multiple-choice question), and a single choice goes on as a pick does.
        private func commitCustom(_ index: Int, multiSelect: Bool) {
            let text = (customText[index] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            customText[index] = text
            stopTyping()
            if multiSelect {
                picks[index, default: []].insert(Self.custom)
            } else {
                pick(Self.custom, in: index, multiSelect: false)
            }
        }

        private var footer: some View {
            HStack(spacing: 8) {
                if onSubmit != nil, step > 0 {
                    Button { step -= 1 } label: {
                        Label(L("이전", "Back"), systemImage: "chevron.left")
                            .font(.system(size: 12 * scale, weight: .semibold))
                            .foregroundColor(NotchPalette.ink.opacity(0.75))
                            .padding(.horizontal, 10)
                            .frame(height: 28 * scale)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(NotchPalette.ink.opacity(0.22)))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else if let onOpen {
                    Button(action: onOpen) {
                        Label(openTitle ?? L("\(sourceName)에서 응답", "Answer in \(sourceName)"),
                              systemImage: "arrow.up.right.square")
                            .font(.system(size: 11 * scale, weight: .semibold))
                            .foregroundColor(accentColor)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(NotchPalette.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else if onGo != nil {
                    // The go button beside it does the going; this only says where to answer.
                    // With 직접 입력 there are no other answers to give elsewhere.
                    if onSubmit == nil || !allowsCustom {
                        Text(onSubmit == nil ? L("\(sourceName)에서 응답", "Answer in \(sourceName)")
                                             : L("다른 답은 \(sourceName)에서", "Other answers in \(sourceName)"))
                            .font(.system(size: 11.5 * scale))
                            .foregroundColor(NotchPalette.ink.opacity(0.4))
                    }
                } else if onSubmit != nil && allowsCustom {
                    EmptyView()
                } else {
                    Label(onSubmit == nil ? L("\(sourceName)에서 응답", "Answer in \(sourceName)")
                                          : L("다른 답은 \(sourceName)에서", "Other answers in \(sourceName)"),
                          systemImage: "arrow.up.right.square")
                        .font(.system(size: 10 * scale, weight: .medium))
                        .foregroundColor(accentColor.opacity(0.8))
                }
                Spacer(minLength: 0)
                // A multiple-choice question goes on with a button; the last one sends them all.
                if onSubmit != nil, questions.indices.contains(step), questions[step].multiSelect {
                    let last = step == questions.count - 1
                    let ready = picks[step]?.isEmpty == false && (!last || canSend)
                    Button { if last { submit() } else { step += 1 } } label: {
                        Text(last ? L("보내기", "Send") : L("다음", "Next"))
                            .font(.system(size: 12 * scale, weight: .semibold))
                            .foregroundColor(ready ? .black : NotchPalette.ink.opacity(0.4))
                            .padding(.horizontal, 14)
                            .frame(height: 28 * scale)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(ready ? accentColor : NotchPalette.ink.opacity(0.08)))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!ready)
                }
                if let onGo, let goTitle {
                    PeekBarButton(title: goTitle, icon: "terminal", height: 28 * scale, action: onGo)
                        .fixedSize()
                        .newHighlight(cornerRadius: 10, delay: 0.25)
                        .help(L("질문한 에이전트가 실행 중인 터미널이나 앱으로 이동", "Go to the terminal or app running the agent that asked"))
                        // Clear of the 크기 손잡이 in the corner.
                        .padding(.trailing, onSubmit != nil ? 18 : 0)
                }
            }
        }

        private func optionText(_ option: AgentInputOption) -> some View {
            VStack(alignment: .leading, spacing: 2 * scale) {
                Text(option.label)
                    .font(.system(size: 10 * scale, weight: .semibold))
                    .foregroundColor(NotchPalette.ink.opacity(0.9))
                if !option.description.isEmpty {
                    Text(option.description)
                        .font(.system(size: 10 * scale))
                        .foregroundColor(NotchPalette.ink.opacity(0.6))
                }
            }
        }

        /// A row per option, its mark always there: an empty circle (or square for several),
        /// filled in the agent's colour with the row tinted once picked, so the pick shows.
        private func optionButton(_ option: AgentInputOption, picked: Bool, multiSelect: Bool,
                                  action: @escaping () -> Void) -> some View {
            Button(action: action) {
                HStack(alignment: .firstTextBaseline, spacing: 8 * scale) {
                    Image(systemName: multiSelect ? (picked ? "checkmark.square.fill" : "square")
                                                  : (picked ? "checkmark.circle.fill" : "circle"))
                        .font(.system(size: 12 * scale, weight: .medium))
                        .foregroundColor(picked ? accentColor : NotchPalette.ink.opacity(0.4))
                    (Text(option.label).font(.system(size: 13 * scale, weight: .medium)).foregroundColor(NotchPalette.ink)
                        + Text(option.description.isEmpty ? "" : "  " + option.description)
                            .font(.system(size: 12 * scale)).foregroundColor(NotchPalette.ink.opacity(0.5)))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12 * scale)
                .padding(.vertical, 8 * scale)
                .background(RoundedRectangle(cornerRadius: 10 * scale, style: .continuous)
                    .fill(picked ? accentColor.opacity(0.2) : NotchPalette.ink.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 10 * scale, style: .continuous)
                    .stroke(picked ? accentColor.opacity(0.7) : .clear, lineWidth: 1.2))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }

        /// A single choice is the answer: it shows picked for a moment, then the next question
        /// comes, or after the last all of them go.
        private func pick(_ option: Int, in question: Int, multiSelect: Bool) {
            if multiSelect {
                picks[question, default: []].formSymmetricDifference([option])
                return
            }
            // A second tap while the first pick is showing does nothing.
            guard !advancing else { return }
            picks[question] = [option]
            advancing = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                advancing = false
                if question < questions.count - 1 {
                    step = question + 1
                } else {
                    submit()
                }
            }
        }

        private func submit() {
            guard canSend, let onSubmit else { return }
            var answers: [String: Any] = [:]
            for (index, question) in questions.enumerated() {
                // The typed answer last, after the options picked with it.
                let labels = (picks[index] ?? []).sorted { $0 == Self.custom ? false : $1 == Self.custom ? true : $0 < $1 }
                    .map { $0 == Self.custom ? customText[index] ?? "" : question.options[$0].label }
                answers[question.question] = question.multiSelect ? labels : labels.first
            }
            onSubmit(answers)
        }
    }


    private struct NotchSection<Content: View>: View {
        let title: String?
        var rail: Color? = nil
        var onDismiss: (() -> Void)? = nil
        let content: Content

        init(title: String? = nil, rail: Color? = nil,
             onDismiss: (() -> Void)? = nil, @ViewBuilder content: () -> Content) {
            self.title = title
            self.rail = rail
            self.onDismiss = onDismiss
            self.content = content()
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                if let title {
                    HStack(spacing: 0) {
                        // Small tracked label, the way cyclop/Sapphire head their cards.
                        Text(title)
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.8)
                            .foregroundColor(NotchPalette.ink.opacity(0.4))
                            .lineLimit(1)
                        if let onDismiss {
                            Spacer(minLength: 0)
                            Button(action: onDismiss) {
                                Image(systemName: "xmark")
                                    .font(.system(size: 10))
                                    .foregroundColor(NotchPalette.ink.opacity(0.55))
                                    .frame(width: 22, height: 22)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(L("닫기", "Dismiss"))
                            .padding(.vertical, -5)
                        }
                    }
                }

                content
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .notchCard(rail: rail)
        }
    }

    /// 헤더 버튼: the bell (효과음), the gear (설정) and power (종료) in one capsule. Each cell is
    /// clickable whole and lights under the cursor.
    private struct NotchControlGroup: View {
        let soundsOn: Bool
        let toggleSounds: () -> Void
        let openSettings: () -> Void
        let quit: () -> Void

        private static let cell: CGFloat = 26
        private static let inset: CGFloat = 2
        static var width: CGFloat { 3 * cell + 2 * inset }

        var body: some View {
            HStack(spacing: 0) {
                // Apple's own mute look: the bell, struck through when the sounds are off.
                Cell(systemName: soundsOn ? "bell" : "bell.slash",
                     tint: soundsOn ? nil : NotchPalette.ink.opacity(0.45), action: toggleSounds)
                    .help(soundsOn ? L("효과음 끄기", "Mute sounds") : L("효과음 켜기", "Turn sounds on"))
                Cell(systemName: "gearshape", action: openSettings)
                    .help(L("설정", "Settings"))
                Cell(systemName: "power", tint: NotchPalette.ink.opacity(0.5), action: quit)
                    .help(L("ClangNotch 종료", "Quit ClangNotch"))
            }
            .padding(.horizontal, Self.inset)
            .frame(height: HeaderChipMetrics.height)
            .background(Capsule().fill(NotchPalette.ink.opacity(0.08)))
        }

        private struct Cell: View {
            let systemName: String
            var tint: Color? = nil
            let action: () -> Void
            @State private var hovering = false

            var body: some View {
                Button(action: action) {
                    Image(systemName: systemName)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(tint ?? NotchPalette.ink.opacity(0.75))
                        .frame(width: NotchControlGroup.cell, height: HeaderChipMetrics.height - 4)
                        .background(Capsule().fill(NotchPalette.ink.opacity(hovering ? 0.12 : 0)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(NotchPressButtonStyle())
                .onHover { hovering = $0 }
            }
        }
    }

    private func handleHover(_ hovering: Bool) {
        hoverTask?.cancel()
        notchHovered = hovering
        // The cursor on the attached player shows its volume row (left: the row goes as after a key).
        if mediaNotice != nil, notchVM.notchState == .peeking { MediaVolumeBand.shared.hover(hovering) }
        // 누를 때만 열기: hovering opens nothing, so the notch shows where to click instead.
        if settings.notchOpensOnClick, notchVM.notchState == .closed {
            presenceTask?.cancel()
            setPresence(hovering)
        }

        if hovering {
            if notchVM.notchState == .peeking && dropdownNotices.waitsOnAnswer {
                return
            }
            // Reading the 완료 드롭다운 holds it; it doesn't turn into the full panel.
            if notchVM.notchState == .peeking && doneNotice != nil {
                doneNoticeTask?.cancel()
                return
            }
            if notchVM.notchState == .peeking && mediaNotice != nil {
                mediaNoticeTask?.cancel()
                watchHousing()
                return
            }
            guard notchVM.notchState != .open, !settings.notchOpensOnClick else { return }

            hoverTask = Task {
                try? await Task.sleep(for: .seconds(settings.notchOpenDelay))
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    guard notchVM.notchState != .open,
                          !(notchVM.notchState == .peeking && dropdownNotices.holdsAgainstHover) else { return }
                    if settings.notchHapticsEnabled {
                        TrackpadHaptics.tap(strength: settings.notchHapticStrength)
                    }
                    openSelectedMode()
                }
            }
        } else {
            // Question and permission reading stays compact until answered or explicitly dismissed.
            if notchVM.notchState == .peeking && dropdownNotices.waitsOnAnswer {
                return
            }
            if notchVM.notchState == .peeking && doneNotice != nil {
                scheduleDoneNoticeDismiss(after: 1.5)
                return
            }
            if notchVM.notchState == .peeking && mediaNotice != nil {
                housingWatch?.cancel()
                // The volume row holds it; it folds after the row goes.
                if mediaVolumeReading == nil { scheduleMediaNoticeDismiss(after: 1.5) }
                return
            }
            guard !isMenuTracking else { return }
            let delay = max(0.15, hoverExitNotBefore.timeIntervalSinceNow)
            hoverTask = Task {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    // .peeking too, not just .open: a peek whose own timer was cancelled
                    // (by an open() that has since gone away) has nothing else left to close
                    // it, and it would sit there as an expanded rectangle indefinitely.
                    if notchVM.notchState == .open || notchVM.notchState == .peeking {
                        dismissQuestionNotice()
                        // Moving away closes the tethering dropdown too; left set, it took the
                        // re-drop's turn ahead of a Done that was waiting behind it.
                        tetherNoticeTask?.cancel()
                        tetherPlaceName = nil
                        notchVM.close()
                        updateInteractiveRegion()
                    }
                }
            }
        }
    }

    private func triggerClosedJellyReveal() {
        guard notchVM.notchState == .closed else { return }

        closedJellyTask?.cancel()
        showClosedJellyRipple = false

        if reduceMotion {
            closedJellyContentOpacity = 0
            withAnimation(.easeOut(duration: 0.2)) {
                closedJellyContentOpacity = 1
            }
            return
        }

        snapClosedJellyScale(x: 0.55, y: 0.78)
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            closedJellyContentOpacity = 0
        }

        closedJellyTask = Task {
            await Task.yield()
            guard !Task.isCancelled else { return }

            withAnimation(.spring(response: 0.62, dampingFraction: 0.58, blendDuration: 0)) {
                closedJellyScaleX = 1
                closedJellyScaleY = 1
            }

            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.18)) {
                closedJellyContentOpacity = 1
            }

            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            showClosedJellyRipple = true

            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled else { return }
            showClosedJellyRipple = false
        }
    }

    /// Puts the jelly scale somewhere at once. A write without an animation leaves the rest of a
    /// running one on top of the new value: the dismiss's 1 → 0.04, cut short by a Done, drew the
    /// closed notch at 1.93× and eased it down over the dismiss's remaining third of a second
    /// (seen in a screen recording, 2026-11-14). A zero-length animation replaces the running one.
    private func snapClosedJellyScale(x: CGFloat, y: CGFloat) {
        withAnimation(.linear(duration: 0)) {
            closedJellyScaleX = x
            closedJellyScaleY = y
        }
    }

    private func resetClosedJellyReveal() {
        closedJellyTask?.cancel()
        snapClosedJellyScale(x: 1, y: 1)
        closedJellyContentOpacity = 1
        showClosedJellyRipple = false
    }

    private func triggerClosedJellyDismiss() {
        guard notchVM.notchState == .closed else { return }

        closedJellyTask?.cancel()
        closedJellyDismissTask?.cancel()
        showClosedJellyRipple = false
        showClosedJellyDismiss = true

        if reduceMotion {
            withAnimation(.easeOut(duration: 0.12)) {
                closedJellyContentOpacity = 0
            }
        } else {
            withAnimation(.timingCurve(0.42, 0, 1, 1, duration: 0.38)) {
                closedJellyScaleX = 0.04
                closedJellyScaleY = 0.04
            }
        }

        closedJellyDismissTask = Task {
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 120 : 380))
            guard !Task.isCancelled else { return }

            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                showClosedJellyDismiss = false
                closedJellyScaleX = 1
                closedJellyScaleY = 1
                closedJellyContentOpacity = 1
                notchVM.resetClosedPresentationAfterDismiss()
            }
            closedJellyDismissTask = nil
        }
    }

    private func cancelClosedJellyDismiss() {
        guard showClosedJellyDismiss || closedJellyDismissTask != nil else { return }

        closedJellyDismissTask?.cancel()
        closedJellyDismissTask = nil
        snapClosedJellyScale(x: 1, y: 1)
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            showClosedJellyDismiss = false
            closedJellyContentOpacity = 1
        }
    }

    /// Only a closed notch shows it: the open panel already lists the session, and a
    /// dropdown covers the wings. A second finish within 3s replays it and restarts the clock.
    private func showDoneFlash(_ source: DoneFlash.Source, turn: CompletedTurn? = nil) {
        guard notchVM.notchState == .closed else { return }
        doneFlash = DoneFlash(source: source, turn: turn)
        // The turn's end can drop the surface a pass before doneFlash holds it up.
        cancelClosedJellyDismiss()
        doneFlashTask?.cancel()
        doneFlashTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.3)) { doneFlash = nil }
            }
        }
    }

    private func triggerCodexInputNotice(_ request: CodexInputRequest) {
        // A new question starts at the usual size.
        if request.id != codexInputRequest?.id { questionExpanded = false }
        // A dropdown that comes in, new or shown again, starts with the 닫기 알약 as a plain X.
        if request.id != codexInputRequest?.id || !showQuestionNotice { questionDismissOpen = false }
        codexInputRequest = request
        claudeInputRequest = nil

        showInputNotice(questions: request.questions, sourceName: "Codex", accentColor: .blue)
    }

    private func triggerClaudeInputNotice(_ request: ClaudeInputRequest) {
        // A new question starts at the usual size.
        if request.id != claudeInputRequest?.id { questionExpanded = false }
        // ...and with the 닫기 알약 as a plain X, also when the same question is shown again.
        if request.id != claudeInputRequest?.id || !showQuestionNotice { questionDismissOpen = false }
        claudeInputRequest = request
        codexInputRequest = nil

        if request.isWrapUp {
            showQuestionNotice = true
            guard !showPermissionNotice else { return }
            resetClosedJellyReveal()
            notchVM.peek(duration: nil, additionalHeight: peekHeight(for: wrapUpDropdown(request), width: permissionNotchWidth),
                         width: permissionNotchWidth)
            return
        }
        showInputNotice(questions: request.questions, sourceName: "Claude", accentColor: .orange)
    }

    private func showInputNotice(questions: [AgentInputQuestion], sourceName: String, accentColor: Color) {

        let content = VStack(spacing: 8) {
            questionHeader
            QuestionOptionsView(questions: questions, sourceName: sourceName, accentColor: accentColor,
                                onSubmit: sourceName == "Claude" ? claudeQuestionAnswer : codexQuestionAnswer,
                                goTitle: askingSessionOpenTitle, onGo: {}, allowsCustom: sourceName == "Claude")
        }
        .padding(.top, 10)
        .frame(width: openNotchSize.width - expandedNotchInset * 2)
        .fixedSize(horizontal: false, vertical: true)
        let additionalHeight = ceil(NSHostingView(rootView: content).fittingSize.height) + 12
        showQuestionNotice = true
        // The 권한 드롭다운 has a deadline; the question shows once it's gone.
        guard !showPermissionNotice else { return }
        resetClosedJellyReveal()
        // A re-fit (answer buttons arriving) keeps a dropdown the user made bigger.
        if questionExpanded, notchVM.notchState == .peeking {
            notchVM.resizePeek(to: enlargedQuestionSize())
            return
        }
        notchVM.peek(duration: nil, additionalHeight: additionalHeight, width: openNotchSize.width)
    }

    /// The 질문 드롭다운's go button reads like the session's: 터미널 열기 or GUI 열기.
    private var askingSessionOpenTitle: String {
        if let request = codexInputRequest,
           let session = codexManager.availableSessions.first(where: {
               codexManager.sessionStates[$0.id]?.pendingInputRequest?.id == request.id
           }) {
            return openTitle(.codex, session.id)
        }
        if let request = claudeInputRequest,
           let session = claudeCodeManager.sessionsAwaitingInput.first(where: {
               claudeCodeManager.sessionStates[$0.id]?.pendingInputRequests.contains { $0.id == request.id } == true
           }) {
            return openTitle(.claude, session.id)
        }
        return L("이동", "Go")
    }

    /// Brings the asking session's own app or terminal forward — the same destination as
    /// 터미널 열기 / GUI 열기 on its 세션 화면 — since the answer has to be typed there. Falls
    /// back to expanding the AI tab only when the asking session can't be identified.
    private func goToAskingSession() {
        if let request = codexInputRequest,
           let session = codexManager.availableSessions.first(where: {
               codexManager.sessionStates[$0.id]?.pendingInputRequest?.id == request.id
           }) {
            if acknowledgesOnly(.codex, session.id) {
                codexManager.dismissInputRequest(id: request.id)
            } else {
                codexManager.focusApp(for: session)
            }
            dismissQuestionNotice()
        } else if let request = claudeInputRequest,
                  let session = claudeCodeManager.sessionsAwaitingInput.first(where: {
                      claudeCodeManager.sessionStates[$0.id]?.pendingInputRequests.contains { $0.id == request.id } == true
                  }) {
            if acknowledgesOnly(.claude, session.id) {
                acknowledgeClaude(request.id, sessionId: session.id)
            } else {
                claudeCodeManager.focusIDE(for: session)
            }
            dismissQuestionNotice()
        } else {
            expandedMode = .ai
            resetClosedJellyReveal()
            notchVM.open(size: NotchMode.ai.expandedSize)
        }
    }

    /// Mirrors `dismissSpeedNotice()`: dropping the notice also has to collapse the peek it
    /// opened, otherwise the notch is left expanded with nothing in it.
    private func dismissQuestionNotice() {
        showQuestionNotice = false
        questionExpanded = false
        if notchVM.notchState != .open {
            restorePeek()
        }
    }

    /// The 닫기 알약's 알림도 지우기: what the NEEDS YOU 카드's X does, then the dropdown folds.
    private func clearQuestionNotice() {
        if let request = codexInputRequest {
            codexManager.dismissInputRequest(id: request.id)
        } else if let request = claudeInputRequest {
            claudeCodeManager.dismissInputRequest(id: request.id)
        }
        dismissQuestionNotice()
    }

    /// 측정 중에 노치를 빠져나오면, 진행 상황을 닫힌 노치 아래 드롭다운으로 이어 보여준다.
    /// 펼친 상태에선 Speed 탭이 같은 내용을 이미 보여주므로 띄우지 않는다.
    private func handleSpeedNotchState(_ state: NotchState) {
        switch state {
        case .open:
            speedPeekTask?.cancel()
            speedDismissTask?.cancel()
            showSpeedNotice = false
        case .closed:
            guard speedTest.isRunning else {
                showSpeedNotice = false
                return
            }
            guard !showSpeedNotice else { return }
            showSpeedNotice = true
            // 닫히는 애니메이션이 끝난 뒤에 내려와야 크기가 튀지 않는다.
            speedPeekTask?.cancel()
            speedPeekTask = Task {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard showSpeedNotice, notchVM.notchState == .closed else { return }
                    // 측정이 끝나면 직접 접으므로, 여기 시간제한은 멈춘 측정용 안전장치다.
                    resetClosedJellyReveal()
                    notchVM.peek(duration: 90)
                }
            }
        case .peeking:
            break
        }
    }

    private func handleSpeedPhase(_ phase: SpeedTestPhase) {
        guard showSpeedNotice else { return }
        switch phase {
        case .finished, .failed:
            scheduleSpeedNoticeDismiss()
        case .idle:
            // 사용자가 취소했다 — 결과가 없으니 곧장 접는다.
            dismissSpeedNotice()
        case .ping, .download, .upload:
            break
        }
    }

    /// 결과를 읽을 시간(설정 › 노치 › 드롭다운 머무는 시간)을 주고 드롭다운을 접는다.
    private func scheduleSpeedNoticeDismiss() {
        speedDismissTask?.cancel()
        speedDismissTask = Task {
            try? await Task.sleep(for: .seconds(Double(settings.foldSecondsSpeed)))
            guard !Task.isCancelled else { return }
            await MainActor.run { dismissSpeedNotice() }
        }
    }

    private func dismissSpeedNotice() {
        speedPeekTask?.cancel()
        speedDismissTask?.cancel()
        showSpeedNotice = false
        if notchVM.notchState == .peeking {
            restorePeek()
        }
    }

    /// Only drops from a closed notch: an open panel or another notice already owns the
    /// space, and the monitor repeats the alert while tethering continues.
    private func triggerTetherNotice(_ placeName: String) {
        guard notchVM.notchState == .closed, !dropdownNotices.keepsTetherOut else { return }
        tetherPlaceName = placeName
        resetClosedJellyReveal()
        notchVM.peek(duration: nil, additionalHeight: 64)
        tetherNoticeTask?.cancel()
        tetherNoticeTask = Task {
            try? await Task.sleep(for: .seconds(Double(settings.foldSecondsTether) + Self.peekSettleTime))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.3)) { dismissTetherNotice() }
            }
        }
    }

    private func dismissTetherNotice() {
        tetherNoticeTask?.cancel()
        let wasShowing = tetherPlaceName != nil
        tetherPlaceName = nil
        // A notice that dropped in on top owns the peek now; leave closing it to that notice.
        if wasShowing, notchVM.notchState == .peeking, !dropdownNotices.keepsTetherOut {
            restorePeek()
        }
    }

    // MARK: - 권한 드롭다운 / 완료 드롭다운

    private func agentAccent(_ agent: PermissionRequestItem.Agent) -> Color {
        agent == .codex ? codexGlowColor : claudeGlowColor
    }

    private func permissionDropdown(_ item: PermissionRequestItem, expanded: Bool? = nil) -> some View {
        PermissionDropdownView(
            item: item, position: 1, total: permissionCenter.queue.count, accent: agentAccent(item.agent),
            inTerminal: item.sessionId.flatMap { sessionDestination(item.agent == .codex ? .codex : .claude, $0) }?.isTerminal ?? true,
            expanded: expanded ?? (expandedPermission == item.id),
            onExpand: {
                expandedPermission = item.id
                notchVM.peek(duration: nil, additionalHeight: peekHeight(for: permissionDropdown(item, expanded: true), width: permissionNotchWidth),
                             width: permissionNotchWidth)
            }
        ) { decision in
            permissionCenter.decide(item.id, decision)
            // "In terminal" also brings that terminal forward, where the prompt will be.
            if decision == .terminal, let sessionId = item.sessionId {
                focusSession(item.agent == .codex ? .codex : .claude, sessionId)
            }
        }
    }

    private func mediaDropdown(_ playing: NowPlaying) -> some View {
        AttachedMediaDropdown(playing: playing, volume: mediaVolumeReading)
    }

    /// Something started playing, with 노치에 붙음 chosen (`NowPlayingMonitor.showAttached`).
    /// It doesn't push out another dropdown: into a closed notch only, else it isn't shown. Up
    /// already, it follows the new track in place and its time doesn't start over.
    private func showMediaNotice(_ playing: NowPlaying) -> Bool {
        if mediaNotice != nil, notchVM.notchState == .peeking {
            mediaNotice = playing
            return true
        }
        guard notchVM.notchState == .closed, !foldingPeek, !dropdownNotices.hasNotice() else { return false }
        mediaNotice = playing
        // At once, not on the next render: a volume key right after takes the row.
        MediaVolumeBand.shared.attachedIsDown = true
        mediaVolumeReading = MediaVolumeBand.shared.reading
        resetClosedJellyReveal()
        notchVM.peek(duration: nil, additionalHeight: mediaDropdownHeight + 12, width: mediaNotchWidth)
        scheduleMediaNoticeDismiss(after: Double(settings.foldSecondsMedia) + Self.peekSettleTime)
        return true
    }

    private func scheduleMediaNoticeDismiss(after seconds: Double) {
        mediaNoticeTask?.cancel()
        mediaNoticeTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await MainActor.run { dismissMediaNotice() }
        }
    }

    /// The camera's own spot opens the notch even with the attached player down, as with the
    /// card (user, 2026-11-18): resting there for the usual open delay folds the player and opens.
    private func watchHousing() {
        housingWatch?.cancel()
        // With 누를 때만 열기 the camera's spot opens on a click instead (the notch's tap).
        guard !settings.notchOpensOnClick else { return }
        housingWatch = Task { @MainActor in
            var since: Date?
            while !Task.isCancelled, mediaNotice != nil, notchVM.notchState == .peeking {
                if let screen = NotchDetector.notchScreen {
                    let mouse = NSEvent.mouseLocation
                    let size = notchVM.closedNotchSize
                    let onHousing = abs(mouse.x - screen.frame.midX) <= size.width / 2 && mouse.y >= screen.frame.maxY - size.height
                    if onHousing {
                        let start = since ?? Date()
                        since = start
                        if Date().timeIntervalSince(start) >= settings.notchOpenDelay {
                            mediaNoticeTask?.cancel()
                            mediaNotice = nil
                            if settings.notchHapticsEnabled { TrackpadHaptics.tap(strength: settings.notchHapticStrength) }
                            openSelectedMode()
                            return
                        }
                    } else {
                        since = nil
                    }
                }
                try? await Task.sleep(for: .milliseconds(80))
            }
        }
    }

    /// The attached player's fixed height, with the volume row while it shows.
    private var mediaDropdownHeight: CGFloat { AttachedMediaDropdown.height(with: mediaVolumeReading) }

    /// The volume row came or went in the attached player: it grows or shrinks to hold it, and
    /// waits to fold while the row shows. The player takes its new height at once, held at the
    /// top, and only the notch animates, uncovering the row; animating both, on two curves, moved
    /// the timeline and the buttons up and down meanwhile. The height is the fixed one plus the
    /// peek's 12, not measured: building the player in a hosting view to measure it stalled the
    /// notch for a moment at each key (user's recording, 2026-11-18).
    private func mediaVolumeChanged(_ reading: SystemControlReading?) {
        guard mediaNotice != nil, notchVM.notchState == .peeking else { return }
        let shown = reading != nil
        let came = shown != (mediaVolumeReading != nil)
        mediaVolumeReading = reading
        guard came else { return }
        if shown {
            mediaNoticeTask?.cancel()
        } else if !notchHovered {
            scheduleMediaNoticeDismiss(after: 1.5)
        }
        notchVM.resizePeek(to: CGSize(width: mediaNotchWidth, height: notchVM.closedNotchSize.height + mediaDropdownHeight + 12))
    }

    private func dismissMediaNotice() {
        housingWatch?.cancel()
        mediaNoticeTask?.cancel()
        guard let notice = mediaNotice else { return }
        switch dropdownExit(.media) {
        case .foldThenClear:
            foldPeek { if mediaNotice == notice { mediaNotice = nil } }
        case .clear:
            mediaNotice = nil
        case .clearThenRestore:
            mediaNotice = nil
            restorePeek()
        }
    }

    private func doneDropdown(_ notice: DoneNotice) -> some View {
        DoneDropdownView(
            agent: notice.source == .codex ? .codex : .claude,
            projectName: notice.projectName, turn: notice.turn, accent: doneBlue,
            openTitle: openTitle(notice.source, notice.turn.sessionId)
        ) {
            // Fold first, then switch apps: doing both at once cut the fold off mid-way.
            dismissDoneNotice()
            // 확인 on an SSH host's session: folding is all there is.
            guard !acknowledgesOnly(notice.source, notice.turn.sessionId) else { return }
            Task {
                try? await Task.sleep(for: .seconds(dropdownFoldDuration))
                await MainActor.run { focusSession(notice.source, notice.turn.sessionId) }
            }
        }
    }

    /// Height a dropdown needs below the closed notch at the given dropdown width.
    private func peekHeight<V: View>(for view: V, width: CGFloat) -> CGFloat {
        let content = view
            .frame(width: width - expandedNotchInset * 2)
            .fixedSize(horizontal: false, vertical: true)
        return ceil(NSHostingView(rootView: content).fittingSize.height) + 12
    }

    /// Requests come and go on their own (answered, timed out, or answered in Claude's
    /// own prompt); the dropdown follows the oldest one still waiting.
    private func handlePermissionQueue(_ queue: [PermissionRequestItem]) {
        if let first = queue.first {
            guard notchVM.notchState != .open else { return }
            if first.id != shownPermission?.id { NotchSounds.playAttention(for: first.sessionId) }
            showPermissionNotice = true
            shownPermission = first
            resetClosedJellyReveal()
            notchVM.peek(duration: nil, additionalHeight: peekHeight(for: permissionDropdown(first), width: permissionNotchWidth),
                         width: permissionNotchWidth)
        } else if showPermissionNotice {
            let exit = dropdownExit(.permission)
            guard exit != .foldThenClear else {
                foldPeek {
                    // A request that arrived meanwhile owns the dropdown now.
                    guard permissionCenter.queue.isEmpty else { return }
                    showPermissionNotice = false
                    shownPermission = nil
                }
                return
            }
            showPermissionNotice = false
            shownPermission = nil
            if exit == .clearThenRestore { restorePeek() }
        }
    }

    private func dropdownExit(_ leaving: DropdownNotice) -> DropdownExit {
        dropdownNotices.exit(leaving, peeking: notchVM.notchState == .peeking, open: notchVM.notchState == .open)
    }

    /// The notices that want the dropdown now; `DropdownNotices` holds the rules over them.
    private var dropdownNotices: DropdownNotices {
        DropdownNotices(permissionWaiting: !permissionCenter.queue.isEmpty, permissionShown: showPermissionNotice,
                        questionShown: showQuestionNotice, claudeQuestion: claudeInputRequest != nil,
                        codexQuestion: codexInputRequest != nil, speed: showSpeedNotice,
                        tether: tetherPlaceName != nil, done: doneNotice != nil,
                        pendingDone: pendingDoneNotice != nil, media: mediaNotice != nil)
    }

    /// Folds the dropdown with its content still in it and clears that content once it's
    /// tucked away; clearing first left the dropdown empty for the whole close.
    /// The clear is followed by `restorePeek()`: a notice that came during the fold (or one
    /// the fold's notice was hiding) would otherwise never come down, and a dropdown re-dropped
    /// for the notice being cleared would be left empty (both found by a model of these
    /// handlers, 2026-11-17).
    private func foldPeek(then clear: @escaping () -> Void) {
        foldingPeek = true
        notchVM.fold()
        Task {
            try? await Task.sleep(for: .seconds(dropdownFoldDuration))
            await MainActor.run {
                clear()
                foldingPeek = false
                restorePeek()
            }
        }
    }

    /// Re-fits the dropdown to whichever notice still holds it, highest priority first,
    /// or closes it. Every notice that goes away comes through here, so none of them can
    /// close the notch out from under another (or leave it stuck open, empty).
    private func restorePeek() {
        switch dropdownNotices.next {
        case .permission:
            handlePermissionQueue(permissionCenter.queue)
        case .claudeQuestion:
            if let request = claudeInputRequest { triggerClaudeInputNotice(request) }
        case .codexQuestion:
            if let request = codexInputRequest { triggerCodexInputNotice(request) }
        case .speed:
            notchVM.peek(duration: 90)
        case .tether:
            notchVM.peek(duration: nil, additionalHeight: 64)
        case .done:
            if let doneNotice {
                notchVM.peek(duration: nil, additionalHeight: peekHeight(for: doneDropdown(doneNotice), width: permissionNotchWidth),
                             width: permissionNotchWidth)
            }
        case .pendingDone:
            guard let pending = pendingDoneNotice else { return }
            pendingDoneNotice = nil
            if Date().timeIntervalSince(pending.at) < 60 {
                showDoneNotice(pending)
            } else {
                notchVM.fold()
            }
        case .media:
            notchVM.peek(duration: nil, additionalHeight: mediaDropdownHeight + 12,
                         width: mediaNotchWidth)
        case nil:
            if notchVM.notchState == .peeking { notchVM.fold() }
        }
    }

    /// A finish drops the 완료 드롭다운, unless its own app is in front (the wing's Done is
    /// enough there) or another dropdown holds the notch (it waits its turn).
    /// 오늘 and 완료 기록 (`AgentActivityLog`), whether or not the notch is open.
    private func recordTurn(_ turn: CompletedTurn, _ source: DoneFlash.Source) {
        guard !DemoMode.isActive else { return }
        let title: String? = switch source {
        case .claude: claudeCodeManager.sessionStates[turn.sessionId]?.title
        case .codex: codexManager.threadNames[turn.sessionId]
        }
        let folder = projectName(source, turn.sessionId)
        let destination = sessionDestination(source, turn.sessionId)
        if destination == .terminal, let terminal = sessionTerminal(source, turn.sessionId)?.bundleIdentifier {
            AgentActivityLog.shared.terminalUsed(terminal)
        }
        switch source {
        case .claude:
            let session = claudeCodeManager.availableSessions.first { $0.id == turn.sessionId }
            AgentActivityLog.shared.record(turn, agent: .claude,
                                           conversationId: session.flatMap { claudeCodeManager.conversationId(for: $0) },
                                           title: title ?? folder, folder: folder,
                                           model: claudeCodeManager.sessionStates[turn.sessionId]?.model,
                                           inApp: destination == .claude)
        case .codex:
            AgentActivityLog.shared.record(turn, agent: .codex, conversationId: nil, title: title ?? folder, folder: folder,
                                           model: codexManager.sessionStates[turn.sessionId]?.model,
                                           inApp: destination == .codex)
        }
    }

    private func handleCompletedTurn(_ turn: CompletedTurn, _ source: DoneFlash.Source) {
        guard notchVM.notchState != .open else { return }
        NotchSounds.playDone(for: turn.sessionId)
        if settings.doneHapticsEnabled, !NotchSounds.isMuted(turn.sessionId) {
            TrackpadHaptics.tap(strength: settings.notchHapticStrength)
        }
        if isSessionAppFrontmost(source, turn.sessionId) {
            showDoneFlash(source, turn: turn)
            return
        }
        let notice = DoneNotice(source: source, turn: turn, projectName: sessionLabel(source, turn.sessionId))
        if dropdownNotices.holdsDoneBack {
            pendingDoneNotice = notice
        } else {
            showDoneNotice(notice)
        }
    }

    private func showDoneNotice(_ notice: DoneNotice) {
        doneFlashTask?.cancel()
        doneFlash = nil
        doneNotice = notice
        resetClosedJellyReveal()
        notchVM.peek(duration: nil, additionalHeight: peekHeight(for: doneDropdown(notice), width: permissionNotchWidth),
                     width: permissionNotchWidth)
        // 설정 › 노치 › 드롭다운 머무는 시간, from when it is all the way down.
        scheduleDoneNoticeDismiss(after: Double(settings.foldSecondsDone) + Self.peekSettleTime)
    }

    /// How long a dropdown takes to come all the way down (`notchOpenSpring`); its time to stay
    /// is counted from there, as the AirPods card's is.
    private static let peekSettleTime: Double = 0.5

    private func scheduleDoneNoticeDismiss(after seconds: Double) {
        doneNoticeTask?.cancel()
        doneNoticeTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await MainActor.run { dismissDoneNotice() }
        }
    }

    private func dismissDoneNotice() {
        doneNoticeTask?.cancel()
        guard let notice = doneNotice else { return }
        switch dropdownExit(.done) {
        case .foldThenClear:
            foldPeek { if doneNotice == notice { doneNotice = nil } }
        case .clear:
            doneNotice = nil
        case .clearThenRestore:
            doneNotice = nil
            restorePeek()
        }
    }

    /// "세션 이름 · 폴더", or just the folder while the session has no name.
    private func sessionLabel(_ source: DoneFlash.Source, _ sessionId: String) -> String {
        let title: String? = switch source {
        case .claude: claudeCodeManager.sessionStates[sessionId]?.title
        case .codex: codexManager.threadNames[sessionId]
        }
        return [title, projectName(source, sessionId)].compactMap { $0 }.filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private func projectName(_ source: DoneFlash.Source, _ sessionId: String) -> String {
        let cwd: String? = switch source {
        case .claude: claudeCodeManager.sessionStates[sessionId]?.cwd
        case .codex: codexManager.availableSessions.first { $0.id == sessionId }?.cwd
        }
        guard let cwd, !cwd.isEmpty else { return "" }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    /// Where clicking the session in the list would go: its terminal, desktop app or editor.
    private func sessionDestination(_ source: DoneFlash.Source, _ sessionId: String) -> SessionAppDestination? {
        switch source {
        case .claude:
            guard let session = claudeCodeManager.availableSessions.first(where: { $0.id == sessionId }) else { return nil }
            return SessionAppDestination.claude(
                entrypoint: claudeCodeManager.sessionStates[sessionId]?.entrypoint ?? .unknown,
                ideName: session.ideName)
        case .codex:
            guard let session = codexManager.availableSessions.first(where: { $0.id == sessionId }) else { return nil }
            return codexManager.appDestination(for: session)
        }
    }

    private func sessionTerminal(_ source: DoneFlash.Source, _ sessionId: String) -> TerminalLocation? {
        switch source {
        case .claude:
            return claudeCodeManager.availableSessions.first { $0.id == sessionId }
                .flatMap { claudeCodeManager.terminalLocation(for: $0) }
        case .codex:
            return codexManager.sessionTerminals[sessionId]
        }
    }

    /// "터미널 열기" or "GUI 열기", by where the session runs; "확인" for one on an SSH host.
    private func openTitle(_ source: DoneFlash.Source, _ sessionId: String) -> String {
        (sessionDestination(source, sessionId) ?? .terminal).openTitle
    }

    /// 확인 on an SSH host's question: the question goes, and so does the approval mark Claude
    /// Code raises alongside it (a `permission_prompt` notification), which otherwise stayed in
    /// the wing as Needs OK.
    private func acknowledgeClaude(_ requestId: String, sessionId: String) {
        claudeCodeManager.dismissInputRequest(id: requestId)
        claudeCodeManager.dismissPermission(sessionId: sessionId)
    }

    /// The session runs on an SSH host: its button has nowhere to go and only clears the notice.
    private func acknowledgesOnly(_ source: DoneFlash.Source, _ sessionId: String) -> Bool {
        sessionDestination(source, sessionId)?.acknowledgesOnly == true
    }

    /// App-level: the session's terminal or editor is the frontmost app.
    private func isSessionAppFrontmost(_ source: DoneFlash.Source, _ sessionId: String) -> Bool {
        // Demo sessions have no app of their own; whatever is in front isn't theirs.
        guard !DemoMode.isActive else { return false }
        guard let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              let destination = sessionDestination(source, sessionId) else { return false }
        if destination == .terminal, let terminal = sessionTerminal(source, sessionId)?.bundleIdentifier {
            return terminal == front
        }
        return destination.bundleIdentifiers.contains(front)
    }

    /// The same destination as clicking the session in the list.
    private func focusSession(_ source: DoneFlash.Source, _ sessionId: String) {
        switch source {
        case .claude:
            if let session = claudeCodeManager.availableSessions.first(where: { $0.id == sessionId }) {
                claudeCodeManager.focusIDE(for: session)
            }
        case .codex:
            if let session = codexManager.availableSessions.first(where: { $0.id == sessionId }) {
                codexManager.focusApp(for: session)
            }
        }
    }

    /// Opens (or, with nil, leaves) the 세션 화면, widening the notch for it.
    private func showSessionDetail(_ target: SessionDetailTarget?) {
        // The resize moves the edges under a cursor that may sit near one; don't let that
        // read as leaving the notch.
        hoverExitNotBefore = Date().addingTimeInterval(0.55)
        withAnimation(modeSwitchAnimation) { sessionDetail = target }
        notchVM.resizeOpen(to: target == nil ? activeMode.expandedSize : sessionDetailNotchSize)
    }

    private func openSelectedMode() {
        expandedMode = keyboardLockManager.isLocked ? .keyboardLock : activeMode
        resetClosedJellyReveal()
        notchVM.open(size: activeMode.expandedSize)
    }

    /// Visible outer bounds own interaction; transparent hosting space passes through.
    private func updateInteractiveRegion() {
        let hasWings = notchVM.notchState == .closed
            && notchVM.notchSize.width > notchVM.closedNotchSize.width + 1
        UICoordinator.shared.setInteractiveSize(
            notchVM.notchSize,
            shape: isExpanded ? NotchShape(topCornerRadius: topCornerRadius,
                                          bottomCornerRadius: bottomCornerRadius) : nil,
            wingsBeyond: hasWings && settings.wingStepAside ? notchVM.closedNotchSize.width : nil
        )
    }

    /// The 음파 막대 are an NSView, which the surface's SwiftUI mask doesn't reach: they take
    /// the faded wing's opacity directly. They sit past the ramp, where it is flat anyway.
    private var rightWingLayerOpacity: Double {
        1 - wingFade.right * (1 - WingFade.floor)
    }

    /// The closed wing under the cursor steps aside: surface, content and glow melt into the
    /// menu bar from the notch's edge outward, and clicks go through (`UICoordinator`).
    private var wingFade: WingFade {
        let wing = notchVM.notchState == .closed ? ui.hoveredWing : nil
        return WingFade(notchWidth: notchVM.closedNotchSize.width,
                        left: wing == .left ? 1 : 0, right: wing == .right ? 1 : 0,
                        hintWidth: settings.wingOpenHint ? WingOpenHint.tabWidth : 0)
    }

    /// The notch is drawn over a camera housing (not an external display's bare top edge).
    private var notchOverHousing: Bool { (NotchDetector.notchScreen?.safeAreaInsets.top ?? 0) > 0 }

    /// The 위치 알림 shows only on the quiet closed notch; with the wings up the notch's own surface
    /// is there, and the startup glow lies on it alone.
    private var presenceLayer: NotchPresenceLayer {
        let quiet = notchVM.notchState == .closed && !baseNotchActive
        return NotchPresenceLayer(
            presence: notchPresence && quiet, fadesOut: quiet, housing: notchOverHousing,
            glow: showStartupGlow && notchVM.notchState == .closed,
            surfaceSize: notchSurfaceSize, sideInset: topCornerRadius, bottomCornerRadius: bottomCornerRadius,
            surface: NSColor(theme.surface ?? .black), still: reduceMotion)
    }

    /// Shows or hides the quiet notch's 위치 알림 (`NotchPresenceLayer` grows it out, breathes and
    /// draws it back in: user, 2026-11-18, start at the physical notch's size and grow out
    /// sideways and down).
    private func setPresence(_ on: Bool) {
        guard on != notchPresence else { return }
        notchPresence = on
    }

    /// The breathing begins once the surface has grown (`NotchPresenceLayer`).
    static let breathingStart: Duration = .milliseconds(600)
    /// At launch the notch and the startup glow last three breaths (user, 2026-11-18: two were
    /// too few): grown, then 0.8 s out and back twice and out a third time, fading from that peak.
    static let launchAnnouncement: Duration = breathingStart + .milliseconds(800 * 5)

    /// At launch: here is the notch, for a moment.
    private func announceNotch() {
        setPresence(true)
        presenceTask?.cancel()
        presenceTask = Task { @MainActor in
            // Goes with the startup glow (`triggerStartupGlow`), not before it.
            try? await Task.sleep(for: Self.launchAnnouncement)
            guard !Task.isCancelled, !(settings.notchOpensOnClick && notchHovered) else { return }
            setPresence(false)
        }
    }

    private func triggerStartupGlow() {
        startupGlowTask?.cancel()
        showStartupGlow = true
        startupGlowTask = Task {
            try? await Task.sleep(for: Self.launchAnnouncement)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.3)) {
                    showStartupGlow = false
                }
            }
        }
    }

    private func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow")), to: NSApp.delegate, from: nil)
    }

    /// The power button sits right next to Settings, so a stray click must not quit outright.
    private func confirmQuit() {
        // The notch panel floats above alert level and its click-through poll pauses while
        // runModal spins, so collapse it and release the mouse before the alert appears.
        notchVM.close()
        updateInteractiveRegion()
        UICoordinator.shared.refreshClickThrough()
        let previousApp = NSWorkspace.shared.frontmostApplication
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(notchCloseDuration))
            let alert = NSAlert()
            alert.messageText = L("ClangNotch를 종료할까요?", "Quit ClangNotch?")
            alert.addButton(withTitle: L("종료", "Quit"))
            alert.addButton(withTitle: L("취소", "Cancel"))
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                NSApp.terminate(nil)
            } else {
                previousApp?.activate(options: [])
            }
        }
    }

}

#Preview {
    ClangNotchContentView()
        .frame(width: 600, height: 300)
        .background(Color.gray.opacity(0.3))
}

/// The 미디어 드롭다운 inside the notch, at its fixed height plus the volume row's while that
/// shows: both from the one reading, so the row and the height change together.
private struct AttachedMediaDropdown: View {
    let playing: NowPlaying
    let volume: SystemControlReading?

    static func height(with volume: SystemControlReading?) -> CGFloat {
        126 + (volume != nil ? MediaVolumeBand.rowHeight : 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            MediaDropdownCardContent(playing: playing, visible: true, attached: true)
                .frame(height: 126)
            if let volume {
                // The player's own side margin inside the notch (`MediaDropdownCardContent`).
                MediaVolumeRow(reading: volume, inset: 20 - (expandedNotchInset - cornerRadiusInsets.opened.top))
            }
        }
        .frame(height: Self.height(with: volume), alignment: .top)
            // Held at the top while the notch grows to it: the peek's frame centres its content,
            // and the player sat cut off above and slid down as the notch grew (user's recording,
            // 2026-11-18).
            .frame(maxHeight: .infinity, alignment: .top)
    }
}
