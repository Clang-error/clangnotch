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

    /// 설정에서 칩 줄에 안 띄우기로 한 탭들. 저장 형식은 order와 같다.
    static func hidden(from stored: String) -> Set<NotchMode> {
        Set(stored.split(separator: ",").compactMap { NotchMode(rawValue: String($0)) })
    }
}

struct ClangNotchContentView: View {
    @EnvironmentObject var telemetryCoordinator: TelemetryCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var notchVM = NotchViewModel()
    @StateObject private var settings = AppSettings.shared
    @StateObject private var claudeCodeManager = ClaudeCodeManager.shared
    @StateObject private var codexManager = CodexManager.shared
    @StateObject private var clipboardManager = ClipboardManager.shared
    @StateObject private var audioMixer = AudioMixerManager.shared
    @StateObject private var sidecarManager = SidecarManager.shared
    @StateObject private var keyboardLockManager = KeyboardLockManager.shared
    @StateObject private var batteryManager = BatteryManager.shared
    @StateObject private var tetherMonitor = TetherPlaceMonitor.shared
    @StateObject private var speedTest = SpeedTestManager.shared
    @State private var expandedMode: NotchMode = .ai
    @State private var isHovering = false
    @State private var hoverTask: Task<Void, Never>?
    @State private var hoverExitNotBefore = Date.distantPast
    @State private var sessionStart = Date()
    @State private var showActivityGlow = false
    @State private var glowTask: Task<Void, Never>?
    @State private var clearTask: Task<Void, Never>?
    @State private var visibleToolCalls: [ToolCall] = []
    @State private var showStartupGlow = false
    @State private var startupGlowTask: Task<Void, Never>?
    @State private var showErrorGlow = false
    @State private var errorGlowTask: Task<Void, Never>?
    @State private var showQuestionNotice = false
    @State private var codexInputRequest: CodexInputRequest?
    @State private var claudeInputRequest: ClaudeInputRequest?
    /// A Claude or Codex turn that just finished normally; the closed wings show Done for 3s.
    @State private var doneFlash: DoneFlash?
    @State private var doneFlashTask: Task<Void, Never>?
    @StateObject private var permissionCenter = PermissionRequestCenter.shared
    @State private var showPermissionNotice = false
    /// The request on screen, kept so the dropdown still shows it while folding away.
    @State private var shownPermission: PermissionRequestItem?
    /// The session the 세션 화면 shows, opened from a 세션 줄.
    @State private var sessionDetail: SessionDetailTarget?
    @State private var doneNotice: DoneNotice?
    @State private var doneNoticeTask: Task<Void, Never>?
    /// A finish that came while another dropdown held the notch; shown once that one goes.
    @State private var pendingDoneNotice: DoneNotice?
    @State private var toolCallUpdateTask: Task<Void, Never>?
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
        notchVM.notchState == .closed ? notchVM.closeAnimation : (reduceMotion ? animationSpring : notchOpenSpring)
    }
    private var modeSwitchAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.12) : .interactiveSpring(response: 0.3, dampingFraction: 0.86)
    }

    private var modeContentTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .opacity.combined(with: .scale(scale: 0.985, anchor: .top))
    }

    private let startupGlowColor = Color(red: 0.55, green: 0.8, blue: 0.9)
    private let startupBrightColor = Color(red: 0.75, green: 0.9, blue: 1.0)
    private let errorGlowColor = Color(red: 0.9, green: 0.2, blue: 0.2)
    private let errorBrightColor = Color(red: 1.0, green: 0.3, blue: 0.3)
    private let claudeGlowColor = Color(red: 0.9, green: 0.4, blue: 0.1)
    private let claudeBrightColor = Color(red: 1.0, green: 0.55, blue: 0.2)
    // Raised to Claude-level luminance: the darker blue left the sweeping border
    // looking grainy and sluggish against the black notch.
    private let codexGlowColor = Color(red: 0.2, green: 0.5, blue: 1.0)
    private let codexBrightColor = Color(red: 0.5, green: 0.75, blue: 1.0)
    // Wing indicator dots keep the original Codex blue.
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

    private var recentTokenTotal: Int {
        if telemetryCoordinator.sessionTokenTotal > 0 {
            return telemetryCoordinator.sessionTokenTotal
        }
        return visibleToolCalls.compactMap { $0.tokenCount }.reduce(0, +)
    }

    private var topCornerRadius: CGFloat {
        isExpanded ? cornerRadiusInsets.opened.top : cornerRadiusInsets.closed.top
    }

    private var bottomCornerRadius: CGFloat {
        isExpanded ? cornerRadiusInsets.opened.bottom : cornerRadiusInsets.closed.bottom
    }

    private var activityGlowSource: TelemetrySource {
        // Only use a source if it's visible in settings
        if let firstSource = visibleToolCalls.first?.source {
            return firstSource
        }
        // Fallback to telemetry source only if that source is visible
        let source = telemetryCoordinator.telemetrySource
        return isSourceVisible(source) ? source : .claudeCode
    }

    private var activityGlowColor: Color {
        switch activityGlowSource {
        case .codex:
            return codexGlowColor
        case .claudeCode, .unknown:
            return claudeGlowColor
        }
    }

    private var activityBrightColor: Color {
        switch activityGlowSource {
        case .codex:
            return codexBrightColor
        case .claudeCode, .unknown:
            return claudeBrightColor
        }
    }

    private var hasActiveToolCall: Bool {
        visibleToolCalls.first?.isActive == true
    }

    /// Check if agent is active for a source that's visible in settings
    private var isAgentActiveForVisibleSource: Bool {
        guard telemetryCoordinator.isAgentActive else { return false }
        return isSourceVisible(telemetryCoordinator.telemetrySource)
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
        claudeHasRealActivity
            || codexHasRealActivity
            || (isAgentActiveForVisibleSource && hasActiveToolCall)
    }

    private var hasClipboard: Bool {
        settings.enableClipboardHistory
    }

    private var hasVolume: Bool { settings.enableAudioMixer }

    private var hasSidecar: Bool { settings.enableSidecar }

    private var hasBattery: Bool { settings.enableBattery }

    private var hasSpeedTest: Bool { settings.enableSpeedTest }

    /// 열린 헤더는 제목+상태 2줄에 컨트롤 캡슐까지 있어 물리 노치 높이로는 넘친다.
    private var headerHeight: CGFloat {
        notchVM.notchState == .open ? notchVM.closedNotchSize.height + openHeaderHeight : notchVM.closedNotchSize.height
    }

    /// 설정에서 지정한 순서대로, 지금 쓸 수 있고 숨기지 않은 탭만.
    private var visibleModes: [NotchMode] {
        let hidden = NotchMode.hidden(from: settings.hiddenNotchModes)
        return NotchMode.order(from: settings.notchModeOrder)
            .filter { isAvailable($0) && (!hidden.contains($0) || ($0 == .keyboardLock && keyboardLockManager.isLocked)) }
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

    /// Notch background: black when active, clear (invisible) when fully idle.
    private var isTrackingPaused: Bool {
        telemetryCoordinator.state == .stopped
    }

    /// A collapse from the panel keeps the surface black until it lands on the physical notch,
    /// then drops it in one frame — it already sits under the camera housing, so no exit effect.
    private var notchBackground: Color {
        notchActive || notchVM.isSettlingClosed ? .black : .clear
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
    }

    private var notchActive: Bool {
        baseNotchActive || showClosedJellyDismiss
    }

    /// Activity-glow border condition (extracted to keep the body type-checkable).
    private var shouldShowActivityGlow: Bool {
        // Also traces the open panel's and the dropdown's outline while an agent works.
        guard doneFlash == nil else { return false }
        // A question or permission dropdown glows even though the asking session sits idle waiting.
        if notchVM.notchState == .peeking && (showQuestionNotice || showPermissionNotice) { return true }
        // The 완료 드롭다운 glows only for work still really going on: the finished session's
        // activity grace period lit it and then cut it off mid-dropdown.
        if notchVM.notchState == .peeking && doneNotice != nil {
            return claudeHasRealActivity || codexHasRealActivity
        }
        return showActivityGlow
            || (isAgentActiveForVisibleSource && hasActiveToolCall)
            || claudeCodeManager.hasAnySessionActivity
            || (settings.showSourceCodex && codexManager.hasAnySessionActivity)
    }

    /// Opening from closed, the tethering glow is the same closed-sweep view it already was,
    /// so it resizes with the surface and needs no hiding — the warning never blinks out.
    /// A startup or error glow drawn while closed means the tethering glow is new: hide it.
    private var tetherGlowGrowsWithSurface: Bool {
        glowExpandsFromClosed && notchVM.notchState != .closed
            && tetherMonitor.activePlaceName != nil
            && !showStartupGlow && !showErrorGlow
    }

    /// Glow border overlay (extracted from the body modifier chain for type-check speed).
    @ViewBuilder
    private var glowOverlay: some View {
        ZStack {
            if showStartupGlow && notchVM.notchState == .closed {
                NotchGlowBorder(topCornerRadius: topCornerRadius, bottomCornerRadius: bottomCornerRadius,
                                glowColor: startupGlowColor, brightColor: startupBrightColor)
            } else if showErrorGlow && notchVM.notchState == .closed {
                NotchGlowBorder(topCornerRadius: topCornerRadius, bottomCornerRadius: bottomCornerRadius,
                                glowColor: errorGlowColor, brightColor: errorBrightColor)
            } else if tetherMonitor.activePlaceName != nil {
                // Tethering at a saved place: the glow sweeps red, agents working or not.
                // Opening from closed, it keeps the closed sweep until the surface settles.
                NotchGlowBorder(topCornerRadius: topCornerRadius, bottomCornerRadius: bottomCornerRadius,
                                glowColor: errorGlowColor, brightColor: errorBrightColor,
                                tracesOutline: notchVM.notchState != .closed
                                    && (isGlowSettled || !glowExpandsFromClosed))
            } else if shouldShowActivityGlow {
                let showBothSources = hasSimultaneousClaudeCodexActivity
                    && !((showQuestionNotice || showPermissionNotice) && notchVM.notchState == .peeking)
                NotchGlowBorder(topCornerRadius: topCornerRadius, bottomCornerRadius: bottomCornerRadius,
                                glowColor: showBothSources ? codexGlowColor : currentGlowColor,
                                brightColor: showBothSources ? codexBrightColor : currentBrightColor,
                                secondaryGlowColor: showBothSources ? claudeGlowColor : nil,
                                secondaryBrightColor: showBothSources ? claudeBrightColor : nil,
                                tracesOutline: notchVM.notchState != .closed)
            }

            if showClosedJellyRipple && notchVM.notchState == .closed {
                ClosedNotchJellyRipple(
                    topCornerRadius: topCornerRadius,
                    bottomCornerRadius: bottomCornerRadius,
                    glowColor: currentBrightColor
                )
            }

            if notchVM.notchState == .closed && !closedDisplayedLabel.isEmpty {
                ClosedNotchToolTransitionWipe(
                    trigger: closedDisplayedLabel,
                    topCornerRadius: topCornerRadius,
                    bottomCornerRadius: bottomCornerRadius,
                    glowColor: hasSimultaneousClaudeCodexActivity ? codexBrightColor : currentBrightColor,
                    secondaryGlowColor: hasSimultaneousClaudeCodexActivity ? claudeBrightColor : nil
                )
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
            return activityGlowColor
        } else if codexHasRealActivity {
            return codexGlowColor
        } else if settings.showSourceCodex && codexManager.hasAnySessionActivity && !claudeCodeManager.hasAnySessionActivity {
            return codexGlowColor
        }
        return activityGlowColor
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
            return activityBrightColor
        } else if codexHasRealActivity {
            return codexBrightColor
        } else if settings.showSourceCodex && codexManager.hasAnySessionActivity && !claudeCodeManager.hasAnySessionActivity {
            return codexBrightColor
        }
        return activityBrightColor
    }

    /// Visible notch outline for the current state; the closed body is one header tall.
    private var notchSurfaceSize: CGSize {
        CGSize(width: notchVM.notchSize.width,
               height: isExpanded ? notchVM.notchSize.height : notchVM.closedNotchSize.height)
    }

    private var notchSurfaceShape: some View {
        NotchShape(topCornerRadius: topCornerRadius, bottomCornerRadius: bottomCornerRadius)
            .frame(width: notchSurfaceSize.width, height: notchSurfaceSize.height)
    }

    private var notchVisual: some View {
        notchBody
            .padding(.horizontal, isExpanded ? expandedNotchInset : cornerRadiusInsets.closed.bottom)
            .padding(.bottom, isExpanded ? 12 : 0)
            // Keep one centred frame identity through closed, peek, and open states.
            // Conditional insertion here made the open header lay out from one side first.
            .frame(width: notchVM.notchSize.width,
                   height: isExpanded ? notchVM.notchSize.height : nil, alignment: .top)
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
            .onTapGesture {
                // Only open on tap. Don't close when tapping empty space while open —
                // a near-miss on a button shouldn't dismiss the notch (closing is
                // handled by the cursor leaving the notch region).
                if notchVM.notchState == .closed {
                    if let doneFlash, let turn = doneFlash.turn {
                        focusSession(doneFlash.source, turn.sessionId)
                        return
                    }
                    openSelectedMode()
                } else if notchVM.notchState == .peeking, doneNotice != nil,
                          !showPermissionNotice, !showQuestionNotice {
                    // Hovering holds the 완료 드롭다운 to read it; a click opens the notch,
                    // which used to wait until the dropdown had folded away by itself.
                    doneNoticeTask?.cancel()
                    doneNotice = nil
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
                    LinearGradient(colors: [.black, NotchPalette.background], startPoint: .top, endPoint: .bottom)
                        .opacity(notchVM.notchState == .open ? 1 : 0)
                }
                .frame(width: notchSurfaceSize.width, height: notchSurfaceSize.height)
            }
            .mask(alignment: .top) { notchSurfaceShape }
            .overlay(alignment: .top) {
                glowOverlay
                    .frame(width: notchSurfaceSize.width, height: notchSurfaceSize.height)
                    // Switching state swaps the glow for a new view that appears at its
                    // final size, ahead of the still-resizing surface; fade it in after.
                    .opacity(isGlowSettled || tetherGlowGrowsWithSurface ? 1 : 0)
            }
            .onChange(of: notchVM.notchState) { oldState, _ in
                glowSettleTask?.cancel()
                var hide = Transaction(animation: nil)
                hide.disablesAnimations = true
                withTransaction(hide) {
                    isGlowSettled = false
                    glowExpandsFromClosed = oldState == .closed
                }
                glowSettleTask = Task {
                    // The open spring is still settling at 300ms; a glow drawn then rides the bounce.
                    try? await Task.sleep(for: .milliseconds(450))
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
                .onChange(of: telemetryCoordinator.recentToolCalls.count) { _, _ in
                    handleToolCallUpdate()
                }
                .onChange(of: telemetryCoordinator.recentToolCalls.first?.id) { _, _ in
                    handleToolCallUpdate()
                }
                .onChange(of: notchVM.notchState) { _, newState in
                    if newState != .closed {
                        resetClosedJellyReveal()
                    }
                    // Default the expanded view to whatever is active when opening —
                    // a locked keyboard takes priority since that's most likely why
                    // you opened the notch.
                    if newState == .open {
                        notchVM.resizeOpen(to: activeMode.expandedSize)
                    }
                    updateInteractiveRegion()
                }
                .onChange(of: notchVM.notchSize) { _, _ in
                    updateInteractiveRegion()
                }
                .onChange(of: settings.showSourceCodex) { _, _ in
                    handleToolCallUpdate()
                }
                .onChange(of: settings.enableCodexJSONL) { _, enabled in
                    codexManager.setTrackingEnabled(enabled && !isTrackingPaused)
                }
                // "Stopped" in the header has to mean nothing is tracked — the OTLP receiver
                // alone stopping left the JSONL watchers lighting the notch up as Working.
                .onChange(of: isTrackingPaused, initial: true) { _, paused in
                    claudeCodeManager.setTrackingEnabled(!paused)
                    if settings.enableCodexJSONL {
                        codexManager.setTrackingEnabled(!paused, keepingUsage: true)
                    }
                }
                .onChange(of: settings.showSourceClaudeCode) { _, _ in
                    handleToolCallUpdate()
                }
                .onChange(of: settings.showSourceUnknown) { _, _ in
                    handleToolCallUpdate()
                }
    }

    private var layoutChanges: some View {
        notchChangesA
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
                // A request that came while the panel was open drops in once it closes.
                // Waits out the close animation, like the speed notice, so the two don't fight.
                if state == .closed { sessionDetail = nil }
                guard state == .closed, !permissionCenter.queue.isEmpty else { return }
                Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    guard notchVM.notchState == .closed else { return }
                    handlePermissionQueue(permissionCenter.queue)
                }
            }
    }

    private var decoratedNotch: some View {
        VStack(spacing: 0) {
            layoutChanges
                .onChange(of: telemetryCoordinator.isAgentActive) { wasActive, isActive in
                    if wasActive && !isActive {
                        // Only handle completion if the source that finished is visible in settings
                        guard isSourceVisible(telemetryCoordinator.telemetrySource) else { return }
                        // Agent just finished - trigger completion notice and stop glows
                        stopAllGlows()
                    }
                }
                .onChange(of: hasLiveAgentActivity) { wasActive, isActive in
                    if !wasActive && isActive {
                        cancelClosedJellyDismiss()
                        triggerClosedJellyReveal()
                    } else if !isActive {
                        resetClosedJellyReveal()
                    }
                }
                .onChange(of: claudeCodeManager.lastCompletedTurn) { _, turn in
                    guard let turn, settings.showSourceClaudeCode else { return }
                    handleCompletedTurn(turn, .claude)
                }
                .onChange(of: codexManager.lastCompletedTurn) { _, turn in
                    guard let turn, settings.showSourceCodex else { return }
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
                .onChange(of: claudeCodeManager.pendingInputRequests, initial: true) { old, requests in
                    if let request = requests.first, request != claudeInputRequest {
                        // `old == requests` is the launch pass: a question already waiting stays quiet.
                        if old != requests, request.id != claudeInputRequest?.id { NotchSounds.playAttention() }
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
                        if old != requests, request.id != codexInputRequest?.id { NotchSounds.playAttention() }
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
        .compositingGroup()
        .preferredColorScheme(.dark)
        // ⌘1–⌘7 pick the nth visible tab, but only while open: the tap that supplies them
        // is created on open and torn down on close, so nothing is intercepted otherwise.
        .onChange(of: notchVM.notchState) { _, state in
            NotchTabShortcuts.shared.setActive(state == .open)
        }
        .onReceive(NotificationCenter.default.publisher(for: .notchSelectTab)) { note in
            guard notchVM.notchState == .open, let index = note.userInfo?["index"] as? Int,
                  visibleModes.indices.contains(index) else { return }
            withAnimation(modeSwitchAnimation) { expandedMode = visibleModes[index] }
        }
        .onAppear {
            triggerStartupGlow()
            if hasLiveAgentActivity {
                triggerClosedJellyReveal()
            }
            updateInteractiveRegion()
            // Start Claude Usage quota tracking if enabled (warms the webview session;
            // surfaces the inline login if not authenticated yet).
            if settings.enableClaudeUsage {
                ClaudeUsageManager.shared.startRefreshing()
            }
            // Restores the T world session and starts its keep-alive without waiting for a card.
            Task { await TWorldSession.shared.prepare() }
            if settings.enableAudioMixer { audioMixer.start() }
            if settings.enableSidecar { sidecarManager.start() }
            // 배터리 부족 알림은 탭을 열지 않아도 울려야 하므로 기동 시부터 감시한다.
            if settings.enableBattery { batteryManager.startMonitoring() }
            tetherMonitor.start()
        }
        .onDisappear {
            NotchTabShortcuts.shared.setActive(false)
            startupGlowTask?.cancel()
            toolCallUpdateTask?.cancel()
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

            // Expanded content
            if notchVM.notchState == .open {
                expandedContent
                    .frame(height: max(0, notchVM.notchSize.height - headerHeight - 12))
                    .transition(.opacity)
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

    @ViewBuilder
    private var closedHeader: some View {
        // Claude Code active tool (from JSONL parsing) - check all sessions
        let claudeActiveTool = claudeCodeManager.state.activeTools.first
            ?? claudeCodeManager.sessionStates.values.compactMap { $0.activeTools.first }.first
        // Recent completed Claude tool (within last 5 seconds).
        // Only while the session is still active — once activity ends, notchActive goes
        // false (clear background), so drawing wings here would ghost over the desktop.
        let recentClaudeTool: ClaudeToolExecution? = {
            guard claudeCodeManager.hasAnySessionActivity,
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
            return currentClaudeTool?.toolName
        }()
        let hasCurrentTool = currentToolName != nil

        // A lone question waiting on an answer is announced by the right wing's
        // "Answer". Repeating its tool name on the left says nothing new and is what
        // blows the bar up: "AskUserQuestion" alone claims 120pt, and since both wings
        // must claim the same width to stay centred, that is 240pt of empty black bar.
        let isQuestionWait = isClaudeQuestionWait || isCodexQuestionWait
        // Keep Codex on the left and working Claude on the right, as when both work.
        let showsCodexQuestionOnLeft = isCodexQuestionWait && isSimultaneousClaudeCodex
        let showsClaudeQuestionOnRight = isClaudeQuestionWait && isSimultaneousClaudeCodex
        let showsQuestionOnRight = showsClaudeQuestionOnRight || (isQuestionWait && !isSimultaneousClaudeCodex)

        // A finished turn takes both wings for a moment, but never over something that
        // waits on the user (Locked, Answer, Needs OK).
        let showsDone = doneFlash != nil && !isKeyboardLocked && !isQuestionWait && !hasPermissionNeeded

        // When fully idle (no tool/thinking), the closed notch shows nothing.
        let showLeftWing = showsDone
            || ((hasCurrentTool || isThinking) && (!isQuestionWait || isSimultaneousClaudeCodex))
            || showsCodexQuestionOnLeft

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
        let sourceLabel = isSimultaneousClaudeCodex
            ? (currentCodexTool?.toolName ?? "Thinking...")
            : (currentToolName ?? "Thinking...")
        let closedLabel = closedDisplayedLabel.isEmpty ? sourceLabel : closedDisplayedLabel
        let labelCapsuleWidth = min(124, measuredTextWidth(closedLabel, 10, .medium) + 12)
        let showsClaudeIcon = (hasCurrentTool || isThinking) && isClaudeActive && !isCodexActive
        let showsCodexIcon = (hasCurrentTool || isThinking) && isCodexActive
        let leftWingWidth: CGFloat = showsDone ? 12 + 6 + measuredTextWidth("Done", 10, .medium)
            : showsCodexQuestionOnLeft ? 58
            : (showLeftWing ? (showsClaudeIcon || showsCodexIcon ? 12 : 8) + 6 + labelCapsuleWidth : 0)
        let simultaneousClaudeLabel = currentClaudeTool?.toolName ?? "Thinking..."
        let showsSimultaneousClaudeWing = isSimultaneousClaudeCodex && !isClaudeQuestionWait
            && (isCodexQuestionWait || !hasPermissionNeeded) && !showsDone

        let thinkingModelName: String? = {
            if isCodexActive {
                return extractCodexModelName(codexManager.state.model)
            }
            return extractModelName(claudeCodeManager.state.model)
        }()

        // A locked keyboard owns the right wing — while input is blocked, nothing else
        // there is worth reading.
        // "Answer" plus its dot is all the right wing carries while a question waits,
        // so it claims only that much rather than a tool row's full 120.
        let agentRightWingWidth: CGFloat = {
            if isKeyboardLocked {
                return measuredTextWidth("Locked", 10, .semibold) + 18
            }
            if showsDone { return DoneCheckmarkView.size }
            if showsSimultaneousClaudeWing {
                return min(124, measuredTextWidth(simultaneousClaudeLabel, 10, .medium) + 12) + 6 + 12
            }
            if showsQuestionOnRight || hasPermissionNeeded { return 58 }
            if let codexTool = currentCodexTool, isCodexActive || codexActiveTool != nil {
                if codexTool.isRunning {
                    guard let argument = codexTool.argument else { return 8 }
                    return 12 + min(96, measuredTextWidth(String(argument.prefix(20)), 9, .regular))
                }
                return measuredMonoTextWidth(codexTool.formattedDuration, 9)
            }
            if let claudeTool = currentClaudeTool {
                if claudeTool.isRunning {
                    guard let description = claudeTool.description else { return 8 }
                    return 12 + min(96, measuredTextWidth(String(description.prefix(20)), 9, .regular))
                }
                return measuredMonoTextWidth(claudeTool.formattedDuration, 9)
            }
            if isThinking {
                return 12 + (thinkingModelName.map { measuredTextWidth($0, 9, .medium) } ?? 0)
            }
            return 0
        }()
        // Tethering at a saved place: with the agents quiet it takes both wings ("테더링" and
        // "집 · 12분"); while they work it shrinks to a red hotspot icon at the right edge.
        let tetherPlace = tetherMonitor.activePlaceName
        let showsTetherWings = tetherPlace != nil && !showLeftWing && agentRightWingWidth == 0
        let tetherRightLabel = tetherPlace.map { "\($0) · \(tetherMonitor.connectedLabel)" } ?? ""
        let tetherLeftWidth = 14 + 6 + measuredTextWidth(L("테더링", "Tethering"), 10, .semibold)
        let baseRightWingWidth = showsTetherWings ? measuredTextWidth(tetherRightLabel, 10, .medium) : agentRightWingWidth
        let showsTetherIcon = tetherPlace != nil && !showsTetherWings
        let tetherIconWidth: CGFloat = showsTetherIcon ? 14 + (baseRightWingWidth > 0 ? 6 : 0) : 0

        // A low priority battery rides at the outer edge of the right wing and stays there
        // whatever else the wing is showing, until it recovers or is switched off.
        let lowBattery = batteryManager.closedNotchLowBattery
        let batteryBadgeWidth: CGFloat = lowBattery.map {
            ClosedLowBatteryBadge.width(for: $0) + (baseRightWingWidth > 0 || showsTetherIcon ? 6 : 0)
        } ?? 0
        let rightWingWidth = baseRightWingWidth + tetherIconWidth + batteryBadgeWidth

        // Both wings have to claim the same width, otherwise this centred row slides
        // sideways by half the difference and the shorter side's content ends up under
        // the physical notch. The slots include each wing's 8pt edge padding.
        let hasLeftWing = showLeftWing || showsTetherWings
        let leftContentWidth = showsTetherWings ? tetherLeftWidth : leftWingWidth
        let leftSlot: CGFloat = hasLeftWing ? leftContentWidth + 8 : 0
        let rightSlot: CGFloat = rightWingWidth > 0 ? rightWingWidth + 8 : 0
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
                }
        } else {
            HStack(spacing: 0) {
                // Left wing
                if hasLeftWing {
                    HStack(spacing: 6) {
                        if showsTetherWings {
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
                        } else if showsDone, let doneFlash {
                            if doneFlash.source == .claude {
                                Image("ClaudeIcon")
                                    .resizable()
                                    .frame(width: 12, height: 12)
                            } else {
                                Image("ChatGPTIcon")
                                    .resizable()
                                    .foregroundColor(.white)
                                    .frame(width: 12, height: 12)
                            }
                            Text("Done")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(doneBlue)
                                .lineLimit(1)
                                .fixedSize()
                        } else if hasCurrentTool || isThinking {
                            // Source-specific indicator color
                            let indicatorColor = isCodexActive ? codexIndicatorColor : activityGlowColor
                            let isActive = isCodexActive || isClaudeActive
                            if showsClaudeIcon {
                                Image("ClaudeIcon")
                                    .resizable()
                                    .frame(width: 12, height: 12)
                                    .shadow(color: indicatorColor.opacity(0.6), radius: 3)
                            } else if showsCodexIcon {
                                Image("ChatGPTIcon")
                                    .resizable()
                                    .foregroundColor(.white)
                                    .frame(width: 12, height: 12)
                                    .shadow(color: indicatorColor.opacity(0.6), radius: 3)
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
                    .animation(animationSpring, value: leftContentWidth)
                    .padding(.leading, 8)
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
                                Image("ClaudeIcon")
                                    .resizable()
                                    .frame(width: 12, height: 12)
                                    .shadow(color: claudeGlowColor.opacity(0.6), radius: 3)
                            }
                        } else if let codexTool = currentCodexTool, isCodexActive || codexActiveTool != nil {
                            // Codex tool info
                            HStack(spacing: 4) {
                                if codexTool.isRunning {
                                    ProgressView()
                                        .scaleEffect(0.3)
                                        .frame(width: 8, height: 8)
                                    if let arg = codexTool.argument {
                                        Text(arg.prefix(20))
                                            .font(.system(size: 9))
                                            .foregroundColor(.white.opacity(0.5))
                                            .lineLimit(1)
                                    }
                                } else {
                                    Text(codexTool.formattedDuration)
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundColor(.white.opacity(0.6))
                                        .lineLimit(1)
                                        .fixedSize(horizontal: true, vertical: false)
                                }
                            }
                        } else if let claudeTool = currentClaudeTool, !hasPermissionNeeded {
                            // Claude Code tool info
                            HStack(spacing: 4) {
                                if claudeTool.isRunning {
                                    ProgressView()
                                        .scaleEffect(0.3)
                                        .frame(width: 8, height: 8)
                                    if let desc = claudeTool.description {
                                        Text(desc.prefix(20))
                                            .font(.system(size: 9))
                                            .foregroundColor(.white.opacity(0.5))
                                            .lineLimit(1)
                                    }
                                } else {
                                    Text(claudeTool.formattedDuration)
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundColor(.white.opacity(0.6))
                                        .lineLimit(1)
                                        .fixedSize(horizontal: true, vertical: false)
                                }
                            }
                        } else if isThinking {
                            HStack(spacing: 4) {
                                ProgressView()
                                    .scaleEffect(0.3)
                                    .frame(width: 8, height: 8)
                                if let modelName = thinkingModelName {
                                    Text(modelName)
                                        .font(.system(size: 9, weight: .medium))
                                        .foregroundColor(.white.opacity(0.5))
                                }
                            }
                        } else if hasPermissionNeeded {
                            HStack(spacing: 4) {
                                PermissionNeededIndicatorCompact()
                                Text("Needs OK")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundColor(.orange)
                            }
                        } else if showsTetherWings {
                            Text(tetherRightLabel)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.white.opacity(0.75))
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                    .frame(width: baseRightWingWidth, alignment: .trailing)
                    .padding(.trailing, lowBattery == nil && !showsTetherIcon ? 8 : 6)
                }
                if showsTetherIcon {
                    Image(systemName: "personalhotspot")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(errorBrightColor)
                        .frame(width: 14)
                        .padding(.trailing, lowBattery == nil ? 8 : 6)
                }
                if let lowBattery {
                    ClosedLowBatteryBadge(device: lowBattery)
                        .frame(width: ClosedLowBatteryBadge.width(for: lowBattery), alignment: .trailing)
                        .padding(.trailing, 8)
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

    /// Extract model name from full model ID (e.g., "opus" from "claude-opus-4-5-20251101")
    private func extractModelName(_ modelId: String) -> String? {
        let parts = modelId.lowercased().split(separator: "-")
        // Look for known model names
        if parts.contains("opus") { return "Opus" }
        if parts.contains("sonnet") { return "Sonnet" }
        if parts.contains("haiku") { return "Haiku" }
        // Fallback: return second part if available (usually the model name)
        if parts.count > 1 {
            return String(parts[1]).capitalized
        }
        return nil
    }

    /// Extract model name from Codex model ID (e.g., "GPT-4" from "gpt-4-turbo")
    private func extractCodexModelName(_ modelId: String) -> String? {
        let id = modelId.lowercased()
        if id.contains("o3") { return "o3" }
        if id.contains("o1") { return "o1" }
        if id.contains("gpt-4") { return "GPT-4" }
        if id.contains("gpt-3") { return "GPT-3" }
        if id.contains("codex") { return "Codex" }
        // Fallback: first part
        let parts = id.split(separator: "-")
        if let first = parts.first {
            return String(first).uppercased()
        }
        return nil
    }

    private var openHeader: some View {
        VStack(spacing: 0) {
            // Keep all controls below the physical camera housing.
            Color.clear.frame(height: notchVM.closedNotchSize.height)
            HStack(spacing: 10) {
                agentOverview
                Spacer()
                HStack(spacing: 6) {
                    TelemetryStatusIndicatorView(state: telemetryCoordinator.state)
                    Text(telemetryCoordinator.state.displayText)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
                if telemetryCoordinator.state == .running {
                    NotchControlButton(systemName: "stop.fill", tint: .orange) {
                        Task { await telemetryCoordinator.stop() }
                    }.help(L("텔레메트리 중지", "Stop telemetry"))
                } else if telemetryCoordinator.state == .stopped {
                    NotchControlButton(systemName: "play.fill", tint: chipAccent) {
                        Task { await telemetryCoordinator.start() }
                    }.help(L("텔레메트리 시작", "Start telemetry"))
                }
                // Apple's own mute look: the bell, struck through when the sounds are off.
                NotchControlButton(systemName: settings.notchSoundsEnabled ? "bell" : "bell.slash",
                                   tint: settings.notchSoundsEnabled ? nil : .white.opacity(0.45)) {
                    settings.notchSoundsEnabled.toggle()
                }
                .help(settings.notchSoundsEnabled ? L("효과음 끄기", "Mute sounds") : L("효과음 켜기", "Turn sounds on"))
                NotchControlButton(systemName: "gearshape") { openSettings() }
                    .help(L("설정", "Settings"))
                NotchControlButton(systemName: "power", tint: .white.opacity(0.5)) { confirmQuit() }
                    .help(L("ClangNotch 종료", "Quit ClangNotch"))
            }
            .frame(height: openHeaderHeight)
            // Centred on the whole header, not squeezed between the title and the controls.
            .overlay {
                if tetherMonitor.activePlaceName != nil {
                    TetherWarningLabel()
                } else {
                    HeaderBatteryStrip()
                }
            }
        }
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if visibleModes.count > 1 { modeSwitcher }
            selectedModeContent
                .id(activeMode)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .transition(modeContentTransition)
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
                    focusSession(sessionDetail.agent == .codex ? .codex : .claude, sessionDetail.sessionId)
                    notchVM.close()
                }
            )
            .transition(modeContentTransition)
        } else {
            aiExpandedContent
        }
    }

    private var modeSwitcher: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(visibleModes) { mode in
                        NotchNavigationButton(mode: mode, selected: activeMode == mode,
                                              needsAttention: mode == .ai && attentionCount > 0) {
                            withAnimation(modeSwitchAnimation) {
                                expandedMode = mode
                            }
                        }
                        .id(mode)
                    }
                }
            }
            .onAppear { proxy.scrollTo(activeMode, anchor: .center) }
            .onChange(of: activeMode) { _, mode in
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(mode, anchor: .center) }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var attentionCount: Int {
        (settings.showSourceClaudeCode ? claudeCodeManager.sessionsConfirmedNeedingPermission.count : 0)
            + (settings.showSourceClaudeCode ? claudeCodeManager.sessionsAwaitingInput.count : 0)
            + (settings.showSourceCodex ? codexManager.pendingInputRequests.count : 0)
    }

    private var overviewHasActivity: Bool {
        (settings.showSourceClaudeCode && claudeHasRealActivity)
            || codexHasRealActivity
            || isAgentActiveForVisibleSource
    }

    /// 요약 줄, at the head of the open notch so it shows on every tab.
    private var agentOverview: some View {
        HStack(spacing: 12) {
            // How many sessions are working right now; telemetry alone can light it with none.
            let working = (settings.showSourceClaudeCode
                           ? claudeCodeManager.availableSessions.filter { claudeCodeManager.sessionStates[$0.id]?.isActive == true }.count : 0)
                + (settings.showSourceCodex
                   ? codexManager.availableSessions.filter { codexManager.sessionStates[$0.id]?.isActive == true }.count : 0)
            Text(!overviewHasActivity ? L("대기 중", "Quiet")
                 : working > 0 ? L("작업 중 \(working)", "Working \(working)") : L("작업 중", "Working"))
                .foregroundStyle(overviewHasActivity ? chipAccent : .secondary)
                .modifier(Breathing(active: overviewHasActivity))
            let sessionCount = (settings.showSourceClaudeCode ? claudeCodeManager.availableSessions.count : 0)
                + (settings.showSourceCodex ? codexManager.availableSessions.count : 0)
            Text(L("세션 \(sessionCount)", "Sessions \(sessionCount)"))
            Label("\(attentionCount)", systemImage: "bubble.left.and.exclamationmark.bubble.right")
                .foregroundStyle(attentionCount > 0 ? .orange : .secondary)
                .modifier(Breathing(active: attentionCount > 0))
                .help(L("답변·승인 대기", "Waiting for your response"))
        }
        .font(.system(size: 13, weight: .semibold))
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    private var usageOverview: some View {
        VStack(spacing: 12) {
            if settings.showSourceClaudeCode {
                NotchSection {
                    if settings.enableClaudeUsage {
                        ClaudeUsageNotchSection()
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L("Claude 사용량", "Claude usage"))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.55))
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
            if settings.showSourceCodex {
                NotchSection {
                    if codexManager.rateLimits.hasData {
                        CodexUsageNotchSection(rateLimits: codexManager.rateLimits)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L("Codex 사용량", "Codex usage"))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.55))
                            Text(L("아직 사용량 데이터가 없습니다. Codex 세션에서 한도 정보가 수신되면 표시됩니다.", "No usage data yet. It appears once a Codex session reports its limits."))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
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
                    NotchSection(title: "NEEDS YOU · Codex", onDismiss: { codexManager.dismissInputRequest(id: request.id) }) {
                        QuestionOptionsView(questions: request.questions, sourceName: "Codex", accentColor: .blue)
                    }
                }
                if settings.showSourceClaudeCode && settings.showPermissionIndicator && !claudeCodeManager.sessionsConfirmedNeedingPermission.isEmpty {
                    NotchSection(title: "NEEDS YOU · Claude", onDismiss: {
                        if let session = claudeCodeManager.sessionsConfirmedNeedingPermission.first {
                            claudeCodeManager.dismissPermission(sessionId: session.id)
                        }
                    }) {
                        Button {
                            if let session = claudeCodeManager.sessionsConfirmedNeedingPermission.first {
                                claudeCodeManager.focusIDE(for: session)
                            }
                        } label: {
                            Label(L("에디터에서 권한 확인", "Review permission in your editor"), systemImage: "arrow.up.forward.app")
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
                    NotchSection(title: "NEEDS YOU · Claude", onDismiss: { claudeCodeManager.dismissInputRequest(id: request.id) }) {
                        QuestionOptionsView(questions: request.questions, sourceName: "Claude", accentColor: .orange)
                    }
                }


                usageOverview

                // Show todo list if enabled and has items
                if settings.showSourceClaudeCode && settings.showTodoList && !claudeCodeManager.state.todos.isEmpty {
                    NotchSection(title: claudeCodeManager.selectedSession.map { "Current Tasks · \($0.displayName)" } ?? "Current Tasks") {
                        TodoListView(todos: claudeCodeManager.state.todos, maxItems: 4)
                    }
                }

                // The outer AI scroll view owns scrolling, so the session list renders all rows.
                NotchSection(title: "Sessions") {
                    ClaudeSessionListView(
                        manager: claudeCodeManager,
                        codexManager: codexManager,
                        maxItems: nil,
                        onOpen: { notchVM.close() },
                        onSelect: { showSessionDetail($0) }
                    )
                }

            // Permission badge above footer
                if settings.showSourceClaudeCode && settings.showPermissionIndicator && !claudeCodeManager.sessionsNeedingPermission.isEmpty && claudeCodeManager.sessionsConfirmedNeedingPermission.isEmpty {
                    Button {
                        claudeCodeManager.focusIDE()
                    } label: {
                        PermissionNeededBadge(toolName: claudeCodeManager.state.pendingPermissionTool)
                            .padding(3)
                    }
                    .buttonStyle(NotchHoverButtonStyle(cornerRadius: 6))
                    .help(L("에디터에서 권한 확인", "Review permission in your editor"))
                }

            // Use Claude Code tokens when JSONL is source, otherwise use telemetry
                let claudeTokens = claudeCodeManager.state.tokenUsage
                let hasClaudeTokens = claudeTokens.inputTokens > 0 || claudeTokens.outputTokens > 0
                let displayTokenTotal = hasClaudeTokens ? (claudeTokens.inputTokens + claudeTokens.outputTokens) : recentTokenTotal
                let displayCacheTokens = hasClaudeTokens ? claudeTokens.cacheReadInputTokens : telemetryCoordinator.sessionCacheTokens
                let displayCacheWriteTokens = hasClaudeTokens ? claudeTokens.cacheCreationInputTokens : 0

                NotchFooterView(
                    sessionDuration: Date().timeIntervalSince(sessionStart),
                    tokenTotal: displayTokenTotal,
                    cacheReadTokens: displayCacheTokens,
                    cacheWriteTokens: displayCacheWriteTokens,
                    showTokenCount: settings.showNotchTokenCount,
                    gitBranch: claudeCodeManager.state.gitBranch
                )
            }
            .padding(.horizontal, 1)
            .padding(.top, 1)
            .padding(.bottom, 8)
        }
        .scrollIndicators(.visible)
    }

    @ViewBuilder
    private var peekHeader: some View {
        Group {
            if showPermissionNotice || showQuestionNotice {
                Color.clear
            } else if showSpeedNotice {
                SpeedPeekHeader(manager: speedTest)
            } else if let tetherPlaceName {
                TetherPeekHeader(placeName: tetherPlaceName)
            } else if doneNotice != nil {
                Color.clear
            } else {
                HStack(spacing: 10) {
                    TelemetryStatusIndicatorView(state: telemetryCoordinator.state)
                    Text("Telemetry Active")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)

                    Spacer()
                }
                .padding(.horizontal, 16)
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
            } else {
                VStack(spacing: 8) {
                    if settings.showNotchTokenCount, recentTokenTotal > 0 {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.6))

                            Text("\(recentTokenTotal) t")
                                .font(.system(size: 14, weight: .medium, design: .monospaced))
                                .foregroundColor(.white)

                            Spacer()
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
        }
    }

    /// Set while the asking Claude session's hook waits on the notch, so picking an option
    /// answers the question from here.
    private var claudeQuestionAnswer: (([String: Any]) -> Void)? {
        // A next-step box's buttons send a message in the app; the notch can't press them.
        guard let request = claudeInputRequest, !request.isWrapUp,
              let sessionId = claudeCodeManager.sessionStates.first(where: {
                  $0.value.pendingInputRequests.contains { $0.id == request.id }
              })?.key,
              permissionCenter.answerableQuestionSessions.contains(sessionId) else { return nil }
        let center = permissionCenter
        return { answers in center.answerQuestion(sessionId: sessionId, answers: answers) }
    }

    private var questionNoticeColor: Color {
        codexInputRequest == nil ? .orange : codexGlowColor
    }

    private var questionHeader: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(questionNoticeColor)
                .frame(width: 12, height: 12)
                .shadow(color: questionNoticeColor.opacity(0.6), radius: 4)

            VStack(alignment: .leading, spacing: 2) {
                Text("Waiting for Your Answer")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)

                Text(codexInputRequest == nil ? L("Claude가 질문했습니다", "Claude asked a question") : L("Codex가 질문했습니다", "Codex asked a question"))
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.7))
            }

            Spacer()

            Button {
                goToAskingSession()
            } label: {
                Label(askingSessionOpenTitle, systemImage: "arrow.up.forward.app")
                    .font(.system(size: 10, weight: .medium))
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundColor(questionNoticeColor)
            .help(L("질문한 에이전트가 실행 중인 터미널이나 앱으로 이동", "Go to the terminal or app running the agent that asked"))

            Button { dismissQuestionNotice() } label: {
                Image(systemName: "xmark").font(.system(size: 10))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("알림 접기 — 질문 대기는 유지됩니다", "Collapse — the question stays pending"))
        }
    }

    /// The session that holds a Claude question, by its request.
    private func claudeSessionId(asking request: ClaudeInputRequest) -> String? {
        claudeCodeManager.sessionStates.first { $0.value.pendingInputRequests.contains { $0.id == request.id } }?.key
    }

    private func wrapUpDropdown(_ request: ClaudeInputRequest) -> some View {
        let sessionId = claudeSessionId(asking: request)
        return WrapUpDropdownView(
            request: request,
            projectName: sessionId.map { projectName(.claude, $0) } ?? "",
            accent: agentAccent(.claude),
            openTitle: askingSessionOpenTitle,
            onOpen: { goToAskingSession() },
            onDismiss: { claudeCodeManager.dismissInputRequest(id: request.id) }
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
        VStack(spacing: 8) {
            questionHeader

            if let request = codexInputRequest {
                ScrollView(.vertical) {
                    QuestionOptionsView(questions: request.questions, sourceName: "Codex", accentColor: .blue)
                }
                .scrollIndicators(.visible)
            } else if let request = claudeInputRequest {
                ScrollView(.vertical) {
                    QuestionOptionsView(questions: request.questions, sourceName: "Claude", accentColor: .orange,
                                        onSubmit: claudeQuestionAnswer)
                        .id(request.id)
                }
                .scrollIndicators(.visible)
            }
        }
        .padding(.top, 10)
    }

    struct CodexUsageNotchSection: View {
        let rateLimits: CodexRateLimits
        @ObservedObject private var codexManager = CodexManager.shared

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L("Codex 사용량", "Codex usage"))
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.8)
                        .foregroundColor(.white.opacity(0.5))
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
                        .foregroundColor(.white.opacity(0.5))
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
                            .foregroundColor(.white.opacity(0.5))
                        }
                    }
                    Button(action: codexManager.refresh) {
                        // One symbol name, as in the Claude card: a swap under the repeatForever
                        // below loops its replace transition forever, even in the closed popover.
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.55))
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
                    if let resetsAt = window.resetsAt {
                        Text("• \(relativeResetText(resetsAt)) · \(resetsAt, format: .dateTime.hour().minute())")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.white.opacity(0.1))
                        RoundedRectangle(cornerRadius: 2)
                            .fill(levelColor(window.usedPercent))
                            .frame(width: geometry.size.width * CGFloat(min(window.usedPercent, 100) / 100))
                    }
                }
                .frame(height: 6)
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
        @State private var picks: [Int: Set<Int>] = [:]

        /// One single-choice question needs no Send: the tap is the answer.
        private var answersOnTap: Bool {
            questions.count == 1 && questions.first?.multiSelect == false
        }

        private var canSend: Bool {
            questions.indices.allSatisfy { picks[$0]?.isEmpty == false }
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(question.multiSelect ? L("\(question.header) · 복수 선택", "\(question.header) · multiple choice") : question.header)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(accentColor)
                        Text(question.question)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white)
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
                                        .fill(Color.white.opacity(0.5))
                                        .frame(width: 4, height: 4)
                                        .padding(.top, 5)
                                    optionText(option)
                                }
                            }
                        }
                    }
                }

                if questions.isEmpty {
                    Text(L("질문 내용은 \(sourceName)에서 확인해 주세요.", "See \(sourceName) for the question."))
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.7))
                }
                HStack {
                    Label(onSubmit == nil ? L("\(sourceName)에서 응답", "Answer in \(sourceName)")
                                          : L("다른 답은 \(sourceName)에서", "Other answers in \(sourceName)"),
                          systemImage: "arrow.up.right.square")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(accentColor.opacity(0.8))
                    Spacer(minLength: 0)
                    if onSubmit != nil, !answersOnTap {
                        Button(action: submit) {
                            Text(L("보내기", "Send"))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(canSend ? .black : .white.opacity(0.4))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5)
                                .background(Capsule().fill(canSend ? accentColor : Color.white.opacity(0.08)))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(!canSend)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        private func optionText(_ option: AgentInputOption) -> some View {
            VStack(alignment: .leading, spacing: 1) {
                Text(option.label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                if !option.description.isEmpty {
                    Text(option.description)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.6))
                }
            }
        }

        private func optionButton(_ option: AgentInputOption, picked: Bool, multiSelect: Bool,
                                  action: @escaping () -> Void) -> some View {
            Button(action: action) {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: multiSelect ? (picked ? "checkmark.square.fill" : "square")
                                                  : (picked ? "largecircle.fill.circle" : "circle"))
                        .font(.system(size: 11))
                        .foregroundColor(picked ? accentColor : .white.opacity(0.45))
                        .padding(.top, 1)
                    optionText(option)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(picked ? accentColor.opacity(0.16) : Color.white.opacity(0.05)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }

        private func pick(_ option: Int, in question: Int, multiSelect: Bool) {
            if multiSelect {
                picks[question, default: []].formSymmetricDifference([option])
            } else {
                picks[question] = [option]
            }
            if answersOnTap { submit() }
        }

        private func submit() {
            guard canSend, let onSubmit else { return }
            var answers: [String: Any] = [:]
            for (index, question) in questions.enumerated() {
                let labels = (picks[index] ?? []).sorted().map { question.options[$0].label }
                answers[question.question] = question.multiSelect ? labels : labels.first
            }
            onSubmit(answers)
        }
    }

    private struct NotchSection<Content: View>: View {
        let title: String?
        var onDismiss: (() -> Void)? = nil
        let content: Content

        init(title: String? = nil, onDismiss: (() -> Void)? = nil, @ViewBuilder content: () -> Content) {
            self.title = title
            self.onDismiss = onDismiss
            self.content = content()
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                if let title {
                    HStack(spacing: 0) {
                        Text(title)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.55))
                        if let onDismiss {
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
                            .padding(.vertical, -5)
                        }
                    }
                }

                content
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.06))
            )
        }
    }

    private struct NotchControlButton: View {
        let systemName: String
        var tint: Color? = nil
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            // Padding and circle live inside the label so the whole circle is clickable.
            Button(action: action) {
                Image(systemName: systemName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(tint ?? .white.opacity(0.75))
                    .padding(6)
                    .background(Circle().fill(Color.white.opacity(hovering ? 0.16 : 0.08)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
        }
    }

    private struct NotchFooterView: View {
        let sessionDuration: TimeInterval
        let tokenTotal: Int
        let cacheReadTokens: Int
        let cacheWriteTokens: Int
        let showTokenCount: Bool
        let gitBranch: String?

        var body: some View {
            TimelineView(.periodic(from: .now, by: 5)) { _ in
                HStack(spacing: 8) {
                    Image(systemName: "clock")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.6))

                    Text(formatDuration(sessionDuration))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.8))

                    // Git branch badge
                    if let branch = gitBranch, !branch.isEmpty {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundColor(.purple.opacity(0.8))
                            Text(branch)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.purple.opacity(0.9))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.purple.opacity(0.15), in: Capsule())
                    }

                    Spacer()

                    if showTokenCount {
                        // Regular tokens (input + output)
                        Image(systemName: "sparkles")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.white.opacity(0.6))

                        Text(tokenTotal > 0 ? formatTokens(tokenTotal) : "-")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.8))

                        // Cache read tokens (green - savings)
                        if cacheReadTokens > 0 {
                            HStack(spacing: 2) {
                                Image(systemName: "arrow.down.circle")
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundColor(.green.opacity(0.8))
                                Text(formatTokens(cacheReadTokens))
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundColor(.green.opacity(0.9))
                            }
                        }

                        // Cache write tokens (yellow - creation)
                        if cacheWriteTokens > 0 {
                            HStack(spacing: 2) {
                                Image(systemName: "arrow.up.circle")
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundColor(.yellow.opacity(0.8))
                                Text(formatTokens(cacheWriteTokens))
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundColor(.yellow.opacity(0.9))
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.06), in: Capsule())
            }
        }

        private func formatTokens(_ count: Int) -> String {
            if count >= 1000 {
                return String(format: "%.1fk", Double(count) / 1000.0)
            }
            return "\(count)"
        }

        private func formatDuration(_ duration: TimeInterval) -> String {
            let totalSeconds = Int(duration)
            if totalSeconds < 60 {
                return "\(totalSeconds)s"
            } else if totalSeconds < 3600 {
                let minutes = totalSeconds / 60
                let seconds = totalSeconds % 60
                return String(format: "%dm %02ds", minutes, seconds)
            } else {
                let hours = totalSeconds / 3600
                let minutes = (totalSeconds % 3600) / 60
                return String(format: "%dh %02dm", hours, minutes)
            }
        }

    }

    private func handleHover(_ hovering: Bool) {
        hoverTask?.cancel()

        if hovering {
            withAnimation(animationSpring) {
                isHovering = true
            }

            if notchVM.notchState == .peeking && (showQuestionNotice || showPermissionNotice) {
                return
            }
            // Reading the 완료 드롭다운 holds it; it doesn't turn into the full panel.
            if notchVM.notchState == .peeking && doneNotice != nil {
                doneNoticeTask?.cancel()
                return
            }
            guard notchVM.notchState != .open else { return }

            hoverTask = Task {
                try? await Task.sleep(for: .milliseconds(90))
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    guard notchVM.notchState != .open, isHovering,
                          !(notchVM.notchState == .peeking && (showQuestionNotice || showPermissionNotice || doneNotice != nil)) else { return }
                    openSelectedMode()
                }
            }
        } else {
            // Question and permission reading stays compact until answered or explicitly dismissed.
            if notchVM.notchState == .peeking && (showQuestionNotice || showPermissionNotice) {
                isHovering = false
                return
            }
            if notchVM.notchState == .peeking && doneNotice != nil {
                isHovering = false
                scheduleDoneNoticeDismiss(after: 1.5)
                return
            }
            let delay = max(0.15, hoverExitNotBefore.timeIntervalSinceNow)
            hoverTask = Task {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    withAnimation(animationSpring) {
                        isHovering = false
                    }

                    // .peeking too, not just .open: a peek whose own timer was cancelled
                    // (by an open() that has since gone away) has nothing else left to close
                    // it, and it would sit there as an expanded rectangle indefinitely.
                    if notchVM.notchState == .open || notchVM.notchState == .peeking {
                        dismissQuestionNotice()
                        notchVM.close()
                        updateInteractiveRegion()
                    }
                }
            }
        }
    }

    private func triggerActivityGlow() {
        // Show glow immediately (only if not already showing)
        if !showActivityGlow {
            showActivityGlow = true
        }

        // Cancel previous hide timer and restart
        // Glow will hide only after 4 seconds of NO new events AND no active tools
        glowTask?.cancel()
        glowTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                // Keep glow visible while any tool is still active
                let hasActiveTool = visibleToolCalls.contains { $0.isActive }
                guard !hasActiveTool else { return }
                withAnimation(.easeOut(duration: 0.5)) {
                    showActivityGlow = false
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

        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            closedJellyScaleX = 0.55
            closedJellyScaleY = 0.78
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

    private func resetClosedJellyReveal() {
        closedJellyTask?.cancel()
        closedJellyScaleX = 1
        closedJellyScaleY = 1
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
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            showClosedJellyDismiss = false
            closedJellyScaleX = 1
            closedJellyScaleY = 1
            closedJellyContentOpacity = 1
        }
    }

    private func triggerErrorGlow() {
        // Show error glow immediately
        showErrorGlow = true
        // Stop activity glow when showing error
        showActivityGlow = false
        glowTask?.cancel()

        // Cancel previous error hide timer and restart
        // Error glow hides after 5 seconds
        errorGlowTask?.cancel()
        errorGlowTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.5)) {
                    showErrorGlow = false
                }
            }
        }
    }

    private func stopAllGlows() {
        glowTask?.cancel()
        errorGlowTask?.cancel()
        withAnimation(.easeOut(duration: 0.3)) {
            showActivityGlow = false
            showErrorGlow = false
        }
    }

    private func scheduleClear() {
        clearTask?.cancel()
        clearTask = Task {
            // Clear after 30 seconds of inactivity
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.3)) {
                    visibleToolCalls = []
                }
            }
        }
    }

    private func handleToolCallUpdate() {
        // Debounce rapid updates - coalesce multiple onChange calls into one
        toolCallUpdateTask?.cancel()
        toolCallUpdateTask = Task {
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                performToolCallUpdate()
            }
        }
    }

    private func performToolCallUpdate() {
        visibleToolCalls = telemetryCoordinator.recentToolCalls.filter { isSourceVisible($0.source) }

        // Check if the most recent completed tool call is an error
        if let lastCall = visibleToolCalls.first,
           !lastCall.isActive,
           !lastCall.isSuccess {
            triggerErrorGlow()
        } else {
            triggerActivityGlow()
        }

        scheduleClear()
    }

    private func stopActivityGlowForCompletion() {
        glowTask?.cancel()
        showActivityGlow = false
    }

    /// Only a closed notch shows it: the open panel already lists the session, and a
    /// dropdown covers the wings. A second finish within 3s replays it and restarts the clock.
    private func showDoneFlash(_ source: DoneFlash.Source, turn: CompletedTurn? = nil) {
        guard notchVM.notchState == .closed else { return }
        stopActivityGlowForCompletion()
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
        codexInputRequest = request
        claudeInputRequest = nil

        showInputNotice(questions: request.questions, sourceName: "Codex", accentColor: .blue)
    }

    private func triggerClaudeInputNotice(_ request: ClaudeInputRequest) {
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
                                onSubmit: sourceName == "Claude" ? claudeQuestionAnswer : nil)
        }
        .padding(.top, 10)
        .frame(width: openNotchSize.width - expandedNotchInset * 2)
        .fixedSize(horizontal: false, vertical: true)
        let additionalHeight = ceil(NSHostingView(rootView: content).fittingSize.height) + 12
        showQuestionNotice = true
        // The 권한 드롭다운 has a deadline; the question shows once it's gone.
        guard !showPermissionNotice else { return }
        resetClosedJellyReveal()
        notchVM.peek(duration: nil, additionalHeight: additionalHeight, width: openNotchSize.width)
    }

    /// Mirrors `dismissSpeedNotice()`: dropping the notice also has to collapse the peek it
    /// opened, otherwise the notch is left expanded with nothing in it.
    /// Brings the asking session's own app or terminal forward — the same destination as
    /// clicking that session in the list — since the answer has to be typed there. Falls
    /// back to expanding the AI tab only when the asking session can't be identified.
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

    private func goToAskingSession() {
        if let request = codexInputRequest,
           let session = codexManager.availableSessions.first(where: {
               codexManager.sessionStates[$0.id]?.pendingInputRequest?.id == request.id
           }) {
            codexManager.focusApp(for: session)
            dismissQuestionNotice()
        } else if let request = claudeInputRequest,
                  let session = claudeCodeManager.sessionsAwaitingInput.first(where: {
                      claudeCodeManager.sessionStates[$0.id]?.pendingInputRequests.contains { $0.id == request.id } == true
                  }) {
            claudeCodeManager.focusIDE(for: session)
            dismissQuestionNotice()
        } else {
            expandedMode = .ai
            resetClosedJellyReveal()
            notchVM.open(size: NotchMode.ai.expandedSize)
        }
    }

    private func dismissQuestionNotice() {
        showQuestionNotice = false
        if notchVM.notchState == .peeking {
            restorePeek()
        }
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

    /// 결과를 읽을 5초를 주고 드롭다운을 접는다.
    private func scheduleSpeedNoticeDismiss() {
        speedDismissTask?.cancel()
        speedDismissTask = Task {
            try? await Task.sleep(for: .seconds(5))
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
        guard notchVM.notchState == .closed, !showQuestionNotice, !showSpeedNotice,
              !showPermissionNotice, doneNotice == nil else { return }
        tetherPlaceName = placeName
        resetClosedJellyReveal()
        notchVM.peek(duration: nil, additionalHeight: 64)
        tetherNoticeTask?.cancel()
        tetherNoticeTask = Task {
            try? await Task.sleep(for: .seconds(8))
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
        if wasShowing, notchVM.notchState == .peeking,
           !showQuestionNotice, !showSpeedNotice, !showPermissionNotice, doneNotice == nil {
            restorePeek()
        }
    }

    // MARK: - 권한 드롭다운 / 완료 드롭다운

    private func agentAccent(_ agent: PermissionRequestItem.Agent) -> Color {
        agent == .codex ? codexGlowColor : claudeGlowColor
    }

    private func permissionDropdown(_ item: PermissionRequestItem) -> some View {
        PermissionDropdownView(
            item: item, position: 1, total: permissionCenter.queue.count, accent: agentAccent(item.agent),
            inTerminal: item.sessionId.flatMap { sessionDestination(item.agent == .codex ? .codex : .claude, $0) }?.isTerminal ?? true
        ) { decision in
            permissionCenter.decide(item.id, decision)
            // "In terminal" also brings that terminal forward, where the prompt will be.
            if decision == .terminal, let sessionId = item.sessionId {
                focusSession(item.agent == .codex ? .codex : .claude, sessionId)
            }
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
            if first.id != shownPermission?.id { NotchSounds.playAttention() }
            showPermissionNotice = true
            shownPermission = first
            resetClosedJellyReveal()
            notchVM.peek(duration: nil, additionalHeight: peekHeight(for: permissionDropdown(first), width: permissionNotchWidth),
                         width: permissionNotchWidth)
        } else if showPermissionNotice {
            if notchVM.notchState == .peeking, !hasNoticeAfter(permission: true) {
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
            if notchVM.notchState == .peeking { restorePeek() }
        }
    }

    /// Whether anything still wants the dropdown once the given notice is gone.
    private func hasNoticeAfter(permission: Bool = false, done: Bool = false) -> Bool {
        (!permission && showPermissionNotice) || showQuestionNotice || showSpeedNotice
            || tetherPlaceName != nil || (!done && doneNotice != nil) || pendingDoneNotice != nil
    }

    /// Folds the dropdown with its content still in it and clears that content once it's
    /// tucked away; clearing first left the dropdown empty for the whole close.
    private func foldPeek(then clear: @escaping () -> Void) {
        notchVM.fold()
        Task {
            try? await Task.sleep(for: .seconds(dropdownFoldDuration))
            await MainActor.run { clear() }
        }
    }

    /// Re-fits the dropdown to whichever notice still holds it, highest priority first,
    /// or closes it. Every notice that goes away comes through here, so none of them can
    /// close the notch out from under another (or leave it stuck open, empty).
    private func restorePeek() {
        if showPermissionNotice, !permissionCenter.queue.isEmpty {
            handlePermissionQueue(permissionCenter.queue)
        } else if showQuestionNotice, let request = claudeInputRequest {
            triggerClaudeInputNotice(request)
        } else if showQuestionNotice, let request = codexInputRequest {
            triggerCodexInputNotice(request)
        } else if showSpeedNotice {
            notchVM.peek(duration: 90)
        } else if tetherPlaceName != nil {
            notchVM.peek(duration: nil, additionalHeight: 64)
        } else if let doneNotice {
            notchVM.peek(duration: nil, additionalHeight: peekHeight(for: doneDropdown(doneNotice), width: permissionNotchWidth),
                         width: permissionNotchWidth)
        } else if let pending = pendingDoneNotice {
            pendingDoneNotice = nil
            if Date().timeIntervalSince(pending.at) < 60 {
                showDoneNotice(pending)
            } else {
                notchVM.fold()
            }
        } else if notchVM.notchState == .peeking {
            notchVM.fold()
        }
    }

    /// A finish drops the 완료 드롭다운, unless its own app is in front (the wing's Done is
    /// enough there) or another dropdown holds the notch (it waits its turn).
    private func handleCompletedTurn(_ turn: CompletedTurn, _ source: DoneFlash.Source) {
        guard notchVM.notchState != .open else { return }
        NotchSounds.playDone()
        if isSessionAppFrontmost(source, turn.sessionId) {
            showDoneFlash(source, turn: turn)
            return
        }
        let notice = DoneNotice(source: source, turn: turn, projectName: projectName(source, turn.sessionId))
        if showPermissionNotice || showQuestionNotice || showSpeedNotice || tetherPlaceName != nil {
            pendingDoneNotice = notice
        } else {
            showDoneNotice(notice)
        }
    }

    private func showDoneNotice(_ notice: DoneNotice) {
        stopActivityGlowForCompletion()
        doneFlashTask?.cancel()
        doneFlash = nil
        doneNotice = notice
        resetClosedJellyReveal()
        notchVM.peek(duration: nil, additionalHeight: peekHeight(for: doneDropdown(notice), width: permissionNotchWidth),
                     width: permissionNotchWidth)
        scheduleDoneNoticeDismiss(after: 5)
    }

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
        if notchVM.notchState == .peeking, !hasNoticeAfter(done: true) {
            foldPeek { if doneNotice == notice { doneNotice = nil } }
            return
        }
        doneNotice = nil
        if notchVM.notchState == .peeking { restorePeek() }
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

    /// "터미널 열기" or "GUI 열기", by where the session runs.
    private func openTitle(_ source: DoneFlash.Source, _ sessionId: String) -> String {
        (sessionDestination(source, sessionId) ?? .terminal).openTitle
    }

    /// App-level: the session's terminal or editor is the frontmost app.
    private func isSessionAppFrontmost(_ source: DoneFlash.Source, _ sessionId: String) -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
        return sessionDestination(source, sessionId)?.bundleIdentifiers.contains(front) == true
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
        UICoordinator.shared.setInteractiveSize(
            notchVM.notchSize,
            shape: isExpanded ? NotchShape(topCornerRadius: topCornerRadius,
                                          bottomCornerRadius: bottomCornerRadius) : nil
        )
    }

    private func triggerStartupGlow() {
        startupGlowTask?.cancel()
        showStartupGlow = true
        startupGlowTask = Task {
            try? await Task.sleep(for: .seconds(3))
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

    private func isSourceVisible(_ source: TelemetrySource) -> Bool {
        switch source {
        case .codex:
            return settings.showSourceCodex
        case .claudeCode:
            return settings.showSourceClaudeCode
        case .unknown:
            return settings.showSourceUnknown
        }
    }
}

#Preview {
    ClangNotchContentView()
        .environmentObject(TelemetryCoordinator.shared)
        .frame(width: 600, height: 300)
        .background(Color.gray.opacity(0.3))
}
