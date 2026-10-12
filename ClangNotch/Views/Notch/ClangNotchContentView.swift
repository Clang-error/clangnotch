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
    @StateObject private var antigravityManager = AntigravityManager.shared
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
    @State private var showCompletionNotice = false
    @State private var showQuestionNotice = false
    @State private var codexInputRequest: CodexInputRequest?
    @State private var claudeInputRequest: ClaudeInputRequest?
    @State private var completionNoticeTask: Task<Void, Never>?
    @State private var completionDebounceTask: Task<Void, Never>?
    @State private var lastCompletionId: UUID?
    @State private var completionToolCall: ToolCall?
    @State private var hadActiveToolCalls = false
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
        notchVM.notchState == .closed ? notchCloseAnimation : animationSpring
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
    private let antigravityGlowColor = Color(red: 0.6, green: 0.3, blue: 0.85)
    private let antigravityBrightColor = Color(red: 0.75, green: 0.45, blue: 1.0)

    /// Show glow when there's recent activity (event within last 2 seconds)
    private var hasRecentActivity: Bool {
        guard let lastCall = visibleToolCalls.first else { return false }
        let elapsed = Date().timeIntervalSince(lastCall.endTime ?? lastCall.startTime)
        return elapsed < 2.0 || lastCall.isActive
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

    /// Calculate the content width (includes wings + center notch area)
    private var closedContentWidth: CGFloat {
        notchVM.closedNotchSize.width + 160  // wings extend 80px on each side
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

    /// Determines if Antigravity (Gemini) has activity
    private var antigravityHasRealActivity: Bool {
        antigravityManager.hasAnySessionActivity
    }

    /// Any AI source currently active.
    private var anyAIActive: Bool {
        claudeCodeManager.hasAnySessionActivity
            || (settings.showSourceCodex && codexManager.hasAnySessionActivity)
            || antigravityHasRealActivity
    }

    /// Real work state used for the one-shot closed-notch entrance. Retained idle
    /// sessions do not retrigger it, and tool changes keep the current panel steady.
    private var hasLiveAgentActivity: Bool {
        claudeHasRealActivity
            || codexHasRealActivity
            || antigravityHasRealActivity
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
            || batteryManager.closedNotchLowBattery != nil
    }

    private var notchActive: Bool {
        baseNotchActive || showClosedJellyDismiss
    }

    /// Activity-glow border condition (extracted to keep the body type-checkable).
    private var shouldShowActivityGlow: Bool {
        // Also traces the open panel's and the dropdown's outline while an agent works.
        guard !showCompletionNotice else { return false }
        // A question dropdown glows even though the asking session sits idle waiting.
        if notchVM.notchState == .peeking && showQuestionNotice { return true }
        return showActivityGlow
            || (isAgentActiveForVisibleSource && hasActiveToolCall)
            || claudeCodeManager.hasAnySessionActivity
            || (settings.showSourceCodex && codexManager.hasAnySessionActivity)
            || antigravityManager.hasAnySessionActivity
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
                    && !(showQuestionNotice && notchVM.notchState == .peeking)
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
        if showQuestionNotice && notchVM.notchState == .peeking {
            return codexInputRequest == nil ? claudeGlowColor : codexGlowColor
        }
        if claudeHasRealActivity {
            return activityGlowColor
        } else if codexHasRealActivity {
            return codexGlowColor
        } else if antigravityHasRealActivity {
            return antigravityGlowColor
        } else if settings.showSourceCodex && codexManager.hasAnySessionActivity && !claudeCodeManager.hasAnySessionActivity {
            return codexGlowColor
        }
        return activityGlowColor
    }

    /// Determines which bright color to use based on active source
    private var currentBrightColor: Color {
        if showQuestionNotice && notchVM.notchState == .peeking {
            return codexInputRequest == nil ? claudeBrightColor : codexBrightColor
        }
        if claudeHasRealActivity {
            return activityBrightColor
        } else if codexHasRealActivity {
            return codexBrightColor
        } else if antigravityHasRealActivity {
            return antigravityBrightColor
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
                    try? await Task.sleep(for: .milliseconds(300))
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
                    antigravityManager.setPaused(paused)
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
                notchVM.resizeOpen(to: mode.expandedSize)
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
                        handleAgentCompletion()
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
                .onChange(of: baseNotchActive) { wasActive, isActive in
                    // A collapse from the panel lands on the notch and clears there instead.
                    if wasActive && !isActive && !notchVM.isSettlingClosed {
                        triggerClosedJellyDismiss()
                    } else if isActive {
                        cancelClosedJellyDismiss()
                    }
                }
                .onChange(of: claudeCodeManager.pendingInputRequests, initial: true) { _, requests in
                    if let request = requests.first, request != claudeInputRequest {
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
                .onChange(of: codexManager.pendingInputRequests.count) { oldCount, newCount in
                    if newCount > oldCount, let request = codexManager.pendingInputRequests.first {
                        triggerCodexInputNotice(request)
                    } else if newCount == 0, codexInputRequest != nil {
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
        let isClaudeSessionIdle = claudeCodeManager.state.isSessionComplete && !isClaudeActive

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
        let isSimultaneousClaudeCodex = claudeHasRealActivity && codexHasRealActivity

        // Determine which source is active (prefer Codex if both, since it's newer)
        let activeSource: TelemetrySource = isCodexActive ? .codex : (isClaudeActive ? .claudeCode : .unknown)
        // Claude's end_turn lingers in lastStopReason until the next Claude activity, so
        // exclude the other live sources — otherwise a stale "Done" hides an active
        // Codex/Antigravity tool in the left wing.
        let isSessionIdle = isClaudeSessionIdle && !isCodexActive && !antigravityHasRealActivity

        let hasPermissionNeeded = settings.showPermissionIndicator
            && (!claudeCodeManager.sessionsNeedingPermission.isEmpty || !codexManager.pendingInputRequests.isEmpty)
        // A system-wide keyboard block has to stay visible without opening anything.
        let isKeyboardLocked = keyboardLockManager.isLocked

        // Determine what tool to show (prefer active Codex, then active Claude, then recent)
        let currentClaudeTool: ClaudeToolExecution? = claudeActiveTool ?? recentClaudeTool
        let currentCodexTool: CodexToolExecution? = codexActiveTool ?? recentCodexTool
        // Antigravity: map its current action to either a tool label or the thinking state
        let antigravityActive = antigravityHasRealActivity
        let antigravityAction: String? = antigravityActive ? antigravityManager.state.currentAction : nil
        let antigravityToolLabel: String? = (antigravityAction != nil && antigravityAction != "Thinking") ? antigravityAction : nil
        let isThinking = (isClaudeActive && currentClaudeTool == nil) || (isCodexActive && currentCodexTool == nil) || (antigravityActive && antigravityToolLabel == nil)

        // Get current tool name (prefer Codex if active, otherwise Claude)
        let currentToolName: String? = {
            if let codexTool = currentCodexTool, isCodexActive || codexActiveTool != nil {
                return codexTool.toolName
            }
            return currentClaudeTool?.toolName ?? antigravityToolLabel
        }()
        let hasCurrentTool = currentToolName != nil

        // A question waiting on an answer is already announced by the right wing's
        // "Answer". Repeating its tool name on the left says nothing new and is what
        // blows the bar up: "AskUserQuestion" alone claims 120pt, and since both wings
        // must claim the same width to stay centred, that is 240pt of empty black bar.
        let isQuestionWait = (settings.showSourceClaudeCode && !claudeCodeManager.pendingInputRequests.isEmpty)
            || (settings.showSourceCodex && !codexManager.pendingInputRequests.isEmpty)

        // When fully idle (no tool/thinking), the closed notch shows nothing.
        let showLeftWing = (hasCurrentTool || isThinking) && !isQuestionWait

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
        let showsClaudeIcon = !isSessionIdle && (hasCurrentTool || isThinking) && isClaudeActive && !isCodexActive
        let showsCodexIcon = !isSessionIdle && (hasCurrentTool || isThinking) && isCodexActive
        let leftWingWidth: CGFloat = showLeftWing ? (showsClaudeIcon || showsCodexIcon ? 12 : 8) + 6 + labelCapsuleWidth : 0
        let simultaneousClaudeLabel = currentClaudeTool?.toolName ?? "Thinking..."
        let showsSimultaneousClaudeWing = isSimultaneousClaudeCodex && !hasPermissionNeeded && !isQuestionWait

        let thinkingModelName: String? = {
            if isCodexActive {
                return extractCodexModelName(codexManager.state.model)
            }
            if antigravityActive && !isClaudeActive {
                return "Gemini"
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
            if isQuestionWait || hasPermissionNeeded { return 58 }
            if isSimultaneousClaudeCodex {
                return min(124, measuredTextWidth(simultaneousClaudeLabel, 10, .medium) + 12) + 6 + 12
            }
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
        let tetherLeftWidth = 14 + 6 + measuredTextWidth("테더링", 10, .semibold)
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
                            Text("테더링")
                                .font(.system(size: 10, weight: .semibold))
                                .lineLimit(1)
                                .fixedSize()
                        } else if isSessionIdle {
                            // Session complete indicator
                            Circle()
                                .fill(Color.green)
                                .frame(width: 8, height: 8)
                                .shadow(color: Color.green.opacity(0.5), radius: 2)
                            Text("Done")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.green.opacity(0.9))
                        } else if hasCurrentTool || isThinking {
                            // Source-specific indicator color
                            let indicatorColor = isCodexActive ? codexIndicatorColor : (isClaudeActive ? activityGlowColor : (antigravityActive ? antigravityGlowColor : activityGlowColor))
                            let isActive = isCodexActive || isClaudeActive || antigravityActive
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
                        } else if isQuestionWait {
                            HStack(spacing: 4) {
                                Image(systemName: "bubble.left.and.bubble.right")
                                    .font(.system(size: 8))
                                Text("Answer")
                                    .font(.system(size: 9, weight: .medium))
                            }
                            .foregroundColor(settings.showSourceCodex && !codexManager.pendingInputRequests.isEmpty ? .blue : .orange)
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
                Image(systemName: "waveform.path")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(chipAccent)
                    .frame(width: 22, height: 22)
                    .background(chipAccent.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 3) {
                    Text("ClangNotch")
                        .font(.system(size: 15, weight: .semibold))
                }
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
                    }.help("Stop telemetry")
                } else if telemetryCoordinator.state == .stopped {
                    NotchControlButton(systemName: "play.fill", tint: chipAccent) {
                        Task { await telemetryCoordinator.start() }
                    }.help("Start telemetry")
                }
                NotchControlButton(systemName: "gearshape") { openSettings() }
                    .help("Settings")
                NotchControlButton(systemName: "power", tint: .white.opacity(0.5)) { NSApp.terminate(nil) }
                    .help("Quit ClangNotch")
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
            || (settings.enableAntigravity && antigravityHasRealActivity)
            || isAgentActiveForVisibleSource
    }

    private var agentOverview: some View {
        HStack(spacing: 12) {
            Text(overviewHasActivity ? "Working" : "Quiet")
                .foregroundStyle(overviewHasActivity ? chipAccent : .secondary)
            Spacer(minLength: 0)
            Text("Sessions \((settings.showSourceClaudeCode ? claudeCodeManager.availableSessions.count : 0) + (settings.showSourceCodex ? codexManager.availableSessions.count : 0))")
            Label("\(attentionCount)", systemImage: "bubble.left.and.exclamationmark.bubble.right")
                .foregroundStyle(attentionCount > 0 ? .orange : .secondary)
                .help("Waiting for your response")
        }
        .font(.system(size: 11, weight: .medium))
        .monospacedDigit()
        .padding(.vertical, 8)
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
                            Text("Claude 사용량")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.55))
                            Text("사용량 조회가 꺼져 있습니다. 설정에서 켜면 5시간·7일 사용량을 확인할 수 있습니다.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("사용량 설정 열기") { openSettings() }
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
                            Text("Codex 사용량")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.55))
                            Text("아직 사용량 데이터가 없습니다. Codex 세션에서 한도 정보가 수신되면 표시됩니다.")
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
                agentOverview

                if settings.showSourceCodex, let request = codexManager.pendingInputRequests.first {
                    NotchSection(title: "NEEDS YOU · Codex") {
                        QuestionOptionsView(questions: request.questions, sourceName: "Codex", accentColor: .blue)
                    }
                }
                if settings.showSourceClaudeCode && settings.showPermissionIndicator && !claudeCodeManager.sessionsConfirmedNeedingPermission.isEmpty {
                    NotchSection(title: "NEEDS YOU · Claude") {
                        Button {
                            if let session = claudeCodeManager.sessionsConfirmedNeedingPermission.first {
                                claudeCodeManager.focusIDE(for: session)
                            }
                        } label: {
                            Label("Review permission in your editor", systemImage: "arrow.up.forward.app")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.orange)
                        }
                        .buttonStyle(.plain)
                    }
                }
                if settings.showSourceClaudeCode, let request = claudeCodeManager.pendingInputRequests.first {
                    NotchSection(title: "NEEDS YOU · Claude") {
                        QuestionOptionsView(questions: request.questions, sourceName: "Claude", accentColor: .orange)
                    }
                }

                if settings.enableAntigravity, antigravityManager.state.recentlyUsed {
                    NotchSection(title: "ANTIGRAVITY") {
                        Button {
                            notchVM.close()
                            SessionAppLauncher.open(.antigravity)
                        } label: {
                            Label(antigravityManager.state.currentAction ?? "Waiting for activity", systemImage: "sparkles")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.purple)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Open Antigravity")
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
                        onOpen: { notchVM.close() }
                    )
                }

            // Permission badge above footer
                if settings.showSourceClaudeCode && settings.showPermissionIndicator && !claudeCodeManager.sessionsNeedingPermission.isEmpty && claudeCodeManager.sessionsConfirmedNeedingPermission.isEmpty {
                    PermissionNeededBadge(toolName: claudeCodeManager.state.pendingPermissionTool)
                        .onTapGesture {
                            claudeCodeManager.focusIDE()
                        }
                }

            // Context progress bar (with integrated API usage badges)
                if settings.showContextProgress {
                    ContextProgressBar(
                        tokenUsage: claudeCodeManager.state.tokenUsage,
                        contextLimit: settings.contextTokenLimit,
                        showApiUsage: settings.enableClaudeUsage
                    )
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
            if showQuestionNotice {
                Color.clear
            } else if showCompletionNotice, let toolCall = completionToolCall {
                completionHeader(toolCall: toolCall)
            } else if showSpeedNotice {
                SpeedPeekHeader(manager: speedTest)
            } else if let tetherPlaceName {
                TetherPeekHeader(placeName: tetherPlaceName)
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
            if showQuestionNotice {
                questionContent
            } else if showCompletionNotice, let toolCall = completionToolCall {
                completionContent(toolCall: toolCall)
            } else if showSpeedNotice {
                SpeedPeekContent(manager: speedTest)
            } else if let tetherPlaceName {
                TetherPeekContent(placeName: tetherPlaceName)
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

                Text(codexInputRequest == nil ? "Claude asked a question" : "Codex asked a question")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.7))
            }

            Spacer()

            Button {
                goToAskingSession()
            } label: {
                Label("이동", systemImage: "arrow.up.forward.app")
                    .font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundColor(questionNoticeColor)
            .help("질문한 에이전트가 실행 중인 터미널이나 앱으로 이동")

            Button { dismissQuestionNotice() } label: {
                Image(systemName: "xmark").font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .help("알림 접기 — 질문 대기는 유지됩니다")
        }
    }

    private var questionContent: some View {
        VStack(spacing: 8) {
            questionHeader

            if let request = codexInputRequest {
                ScrollView(.vertical) {
                    QuestionOptionsView(questions: request.questions, sourceName: "Codex", accentColor: .blue)
                }
                .scrollIndicators(.visible)
            } else if let request = claudeInputRequest {
                ScrollView(.vertical) {
                    QuestionOptionsView(questions: request.questions, sourceName: "Claude", accentColor: .orange)
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
                    Text("Codex 사용량")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.8)
                        .foregroundColor(.white.opacity(0.5))
                    if rateLimits.limitReached {
                        // A window can sit well under 100% while a different one
                        // is what's actually blocking, so say so outright.
                        Text("한도 도달")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.red)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.red.opacity(0.18), in: Capsule())
                    }
                    Spacer()
                    if codexManager.isRefreshingRateLimits {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.clockwise")
                            Text("갱신 중")
                        }
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.white.opacity(0.45))
                    } else if let nextRefreshAt = codexManager.nextRateLimitRefreshAt {
                        // A spent weekly window pauses polling for days; "138:54:03" reads as
                        // nonsense, so use the same day/hour wording as the Claude card.
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let remaining = max(0, nextRefreshAt.timeIntervalSince(context.date))
                            HStack(spacing: 3) {
                                Image(systemName: "timer")
                                Text(remaining >= 1 ? ClaudeUsageNotchSection.formatCountdown(remaining) : "곧")
                            }
                            .font(.system(size: 9, weight: .medium).monospacedDigit())
                            .foregroundColor(.white.opacity(0.45))
                        }
                    }
                    Button(action: codexManager.refresh) {
                        // One symbol name, as in the Claude card: a swap under the repeatForever
                        // below loops its replace transition forever, even in the closed popover.
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.55))
                            .rotationEffect(.degrees(codexManager.isRefreshingRateLimits ? 360 : 0))
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
                            .foregroundColor(.secondary.opacity(0.7))
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
            return formatter.string(from: max(0, date.timeIntervalSinceNow)) ?? "0m"
        }

        private func windowLabel(_ minutes: Int) -> String {
            if minutes % 1_440 == 0 { return "\(minutes / 1_440)일" }
            if minutes % 60 == 0 { return "\(minutes / 60)시간" }
            return "\(minutes)분"
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

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(questions.enumerated()), id: \.offset) { _, question in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(question.multiSelect ? "\(question.header) · 복수 선택" : question.header)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(accentColor)
                        Text(question.question)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white)
                        ForEach(Array(question.options.enumerated()), id: \.offset) { _, option in
                            HStack(alignment: .top, spacing: 5) {
                                Circle()
                                    .fill(Color.white.opacity(0.5))
                                    .frame(width: 4, height: 4)
                                    .padding(.top, 5)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(option.label)
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundColor(.white.opacity(0.9))
                                    if !option.description.isEmpty {
                                        Text(option.description)
                                            .font(.system(size: 9))
                                            .foregroundColor(.white.opacity(0.6))
                                    }
                                }
                            }
                        }
                    }
                }

                if questions.isEmpty {
                    Text("질문 내용은 \(sourceName)에서 확인해 주세요.")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.7))
                }
                Label("\(sourceName)에서 응답", systemImage: "arrow.up.right.square")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(accentColor.opacity(0.8))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private struct NotchSection<Content: View>: View {
        let title: String?
        let content: Content

        init(title: String? = nil, @ViewBuilder content: () -> Content) {
            self.title = title
            self.content = content()
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                if let title {
                    Text(title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.55))
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

        var body: some View {
            Button(action: action) {
                Image(systemName: systemName)
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundColor(tint ?? .white.opacity(0.75))
            .padding(6)
            .background(
                Circle()
                    .fill(Color.white.opacity(0.08))
            )
        }
    }

    private struct NotchPill: View {
        let text: String
        var mono: Bool = false

        var body: some View {
            Text(text)
                .font(.system(size: 9, weight: .medium, design: mono ? .monospaced : .default))
                .foregroundColor(.white.opacity(0.7))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.white.opacity(0.08), in: Capsule())
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
                                .font(.system(size: 9, weight: .medium))
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
                                    .font(.system(size: 9, weight: .medium, design: .monospaced))
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
                                    .font(.system(size: 9, weight: .medium, design: .monospaced))
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

    // MARK: - Context Progress Bar

    private struct ContextProgressBar: View {
        let tokenUsage: ClaudeTokenUsage
        let contextLimit: Int
        var showApiUsage: Bool = false

        private var totalTokens: Int {
            tokenUsage.inputTokens + tokenUsage.outputTokens + tokenUsage.cacheReadInputTokens
        }

        private var progress: Double {
            guard contextLimit > 0 else { return 0 }
            return min(1.0, Double(totalTokens) / Double(contextLimit))
        }

        private var progressColor: Color {
            if progress > 0.9 { return .red }
            if progress > 0.7 { return .orange }
            if progress > 0.5 { return .yellow }
            return .green
        }

        var body: some View {
            VStack(spacing: 4) {
                HStack {
                    Text("Context")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))

                    Text("\(formatTokens(totalTokens)) / \(formatTokens(contextLimit))")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.7))

                    Spacer()

                    // API Usage badges integrated inline
                    if showApiUsage {
                        InlineApiUsageBadges()
                    }
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        // Background
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.white.opacity(0.1))

                        // Progress fill
                        RoundedRectangle(cornerRadius: 3)
                            .fill(progressColor.opacity(0.8))
                            .frame(width: geo.size.width * progress)
                    }
                }
                .frame(height: 6)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        }

        private func formatTokens(_ count: Int) -> String {
            if count >= 1000 {
                return String(format: "%.1fk", Double(count) / 1000.0)
            }
            return "\(count)"
        }
    }

    // MARK: - Singular Tool Detail View (for Claude Code tools)

    private struct SingularToolDetailView: View {
        let tool: ClaudeToolExecution
        let tokenUsage: ClaudeTokenUsage

        private let claudeColor = Color(red: 1.0, green: 0.55, blue: 0.2)

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                // Tool name and status
                HStack(spacing: 8) {
                    Circle()
                        .fill(claudeColor)
                        .frame(width: 10, height: 10)
                        .shadow(color: claudeColor.opacity(tool.isRunning ? 0.6 : 0.3), radius: tool.isRunning ? 4 : 2)

                    Text(tool.toolName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.primary)

                    Spacer()

                    if tool.isRunning {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 16, height: 16)
                    } else {
                        Text(tool.formattedDuration)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }

                // Description
                if let desc = tool.description, !desc.isEmpty {
                    Text(desc)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }

                // Argument/filename
                if let arg = tool.argument, !arg.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                        Text(arg)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary.opacity(0.8))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Divider()
                    .background(Color.white.opacity(0.1))

                // Token details
                HStack(spacing: 12) {
                    // Input tokens
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Input")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundColor(.secondary)
                        HStack(spacing: 2) {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.green.opacity(0.8))
                            Text(formatTokens(tool.inputTokens ?? tokenUsage.inputTokens))
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundColor(.primary)
                        }
                    }

                    // Output tokens
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Output")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundColor(.secondary)
                        HStack(spacing: 2) {
                            Image(systemName: "arrow.down")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.blue.opacity(0.8))
                            Text(formatTokens(tool.outputTokens ?? tokenUsage.outputTokens))
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundColor(.primary)
                        }
                    }

                    // Cache read
                    if (tool.cacheReadTokens ?? tokenUsage.cacheReadInputTokens) > 0 {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Cache")
                                .font(.system(size: 8, weight: .medium))
                                .foregroundColor(.secondary)
                            HStack(spacing: 2) {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundColor(.green.opacity(0.8))
                                Text(formatTokens(tool.cacheReadTokens ?? tokenUsage.cacheReadInputTokens))
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundColor(.green)
                            }
                        }
                    }

                    Spacer()

                    // Timeout if present
                    if let timeout = tool.timeout {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("Timeout")
                                .font(.system(size: 8, weight: .medium))
                                .foregroundColor(.secondary)
                            Text("\(timeout / 1000)s")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }

        private func formatTokens(_ count: Int) -> String {
            if count >= 1000 {
                return String(format: "%.1fk", Double(count) / 1000.0)
            }
            return "\(count)"
        }
    }

    // MARK: - Singular Telemetry Tool View (fallback for non-Claude tools)

    private struct SingularTelemetryToolView: View {
        let toolCall: ToolCall

        private var sourceColor: Color {
            switch toolCall.source {
            case .codex:
                return Color(red: 0.2, green: 0.45, blue: 0.9)
            case .claudeCode:
                return Color(red: 1.0, green: 0.55, blue: 0.2)
            case .unknown:
                return Color.gray
            }
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                // Tool name and status
                HStack(spacing: 8) {
                    Circle()
                        .fill(sourceColor)
                        .frame(width: 10, height: 10)

                    Text(toolCall.toolName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.primary)

                    Spacer()

                    if toolCall.isActive {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 16, height: 16)
                    } else {
                        Text(toolCall.formattedDuration)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }

                // Result or status
                if !toolCall.isActive {
                    HStack(spacing: 4) {
                        Image(systemName: toolCall.isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(toolCall.isSuccess ? .green : .red)
                        Text(toolCall.isSuccess ? "Completed" : "Failed")
                            .font(.system(size: 11))
                            .foregroundColor(toolCall.isSuccess ? .green : .red)
                    }
                }

                // Tokens if available
                if let tokens = toolCall.tokenCount, tokens > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                        Text("\(tokens) tokens")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }

                // Source badge
                HStack {
                    Spacer()
                    Text(toolCall.source.displayName)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(sourceColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(sourceColor.opacity(0.15), in: Capsule())
                }
            }
        }
    }

    private func handleHover(_ hovering: Bool) {
        hoverTask?.cancel()

        if hovering {
            withAnimation(animationSpring) {
                isHovering = true
            }

            if notchVM.notchState == .peeking && showQuestionNotice {
                return
            }
            guard notchVM.notchState != .open else { return }

            hoverTask = Task {
                try? await Task.sleep(for: .milliseconds(90))
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    guard notchVM.notchState != .open, isHovering,
                          !(notchVM.notchState == .peeking && showQuestionNotice) else { return }
                    openSelectedMode()
                }
            }
        } else {
            // Question reading stays compact until answered or explicitly dismissed.
            if notchVM.notchState == .peeking && showQuestionNotice {
                isHovering = false
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
        updateCompletionNoticeState()
    }

    private func updateCompletionNoticeState() {
        let hasActiveNow = visibleToolCalls.contains { $0.isActive }
        let lastCompleted = visibleToolCalls.first(where: { !$0.isActive })
        let isCompletionEvent = lastCompleted.map(isCompletionToolCall) ?? false

        if hasActiveNow {
            completionDebounceTask?.cancel()
        } else if isCompletionEvent {
            // Only show completion peek for actual "Complete" tool calls from telemetry,
            // not for every tool that finishes. JSONL tracking handles session completion separately.
            completionDebounceTask?.cancel()
            completionDebounceTask = Task {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                let stillIdle = !visibleToolCalls.contains { $0.isActive }
                guard stillIdle, let completed = lastCompleted else { return }
                if let endTime = completed.endTime, Date().timeIntervalSince(endTime) > 10 {
                    return
                }
                guard completed.id != lastCompletionId else { return }
                await MainActor.run {
                    showCompletionNotice = true
                    completionToolCall = completed
                    lastCompletionId = completed.id
                    stopActivityGlowForCompletion()
                    resetClosedJellyReveal()
                    notchVM.peek(duration: 3.0)
                    completionNoticeTask?.cancel()
                    completionNoticeTask = Task {
                        try? await Task.sleep(for: .seconds(3))
                        guard !Task.isCancelled else { return }
                        await MainActor.run {
                            withAnimation(.easeOut(duration: 0.3)) {
                                showCompletionNotice = false
                            }
                        }
                    }
                }
            }
        }

        hadActiveToolCalls = hasActiveNow
    }

    private func isCompletionToolCall(_ toolCall: ToolCall) -> Bool {
        let name = toolCall.toolName.lowercased()
        return name == "complete"
            || name == "response complete"
            || name == "output ready"
            || name == "response completed"
    }

    private func completionHeader(toolCall: ToolCall) -> some View {
        HStack(spacing: 10) {
            let isSuccess = toolCall.isSuccess
            Image(systemName: isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(isSuccess ? .green : .red)

            VStack(alignment: .leading, spacing: 2) {
                Text(isSuccess ? "Task Complete" : "Task Failed")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                Text("Source: \(toolCall.source.displayName)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(sourceTint(for: toolCall.source))
            }

            Spacer()
        }
        .padding(.horizontal, 16)
    }

    private func sourceTint(for source: TelemetrySource) -> Color {
        switch source {
        case .codex:
            return Color(red: 0.2, green: 0.45, blue: 0.9)
        case .claudeCode:
            return Color(red: 1.0, green: 0.55, blue: 0.2)
        case .unknown:
            return Color.white.opacity(0.65)
        }
    }

    private func completionContent(toolCall: ToolCall) -> some View {
        VStack(spacing: 8) {
            let summary = completionSummary(for: toolCall)
            Text(summary)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.7))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Text(toolCall.toolName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
                    .lineLimit(1)

                Spacer()

                if settings.showNotchTokenCount, let tokens = toolCall.tokenCount {
                    NotchPill(text: "\(tokens) t")
                }

                NotchPill(text: toolCall.formattedDuration, mono: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private func completionSummary(for toolCall: ToolCall) -> String {
        if let result = toolCall.result {
            switch result {
            case .success(let content):
                let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            case .failure(let error):
                let trimmed = error.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        if isCompletionToolCall(toolCall) {
            return "Model finished response"
        }
        return "Finished \(toolCall.toolName)"
    }

    private func stopActivityGlowForCompletion() {
        glowTask?.cancel()
        showActivityGlow = false
    }

    private func triggerCodexInputNotice(_ request: CodexInputRequest) {
        codexInputRequest = request
        claudeInputRequest = nil

        showInputNotice(questions: request.questions, sourceName: "Codex", accentColor: .blue)
    }

    private func triggerClaudeInputNotice(_ request: ClaudeInputRequest) {
        claudeInputRequest = request
        codexInputRequest = nil

        showInputNotice(questions: request.questions, sourceName: "Claude", accentColor: .orange)
    }

    private func showInputNotice(questions: [AgentInputQuestion], sourceName: String, accentColor: Color) {

        let content = VStack(spacing: 8) {
            questionHeader
            QuestionOptionsView(questions: questions, sourceName: sourceName, accentColor: accentColor)
        }
        .padding(.top, 10)
        .frame(width: openNotchSize.width - expandedNotchInset * 2)
        .fixedSize(horizontal: false, vertical: true)
        let additionalHeight = ceil(NSHostingView(rootView: content).fittingSize.height) + 12
        showQuestionNotice = true
        resetClosedJellyReveal()
        notchVM.peek(duration: nil, additionalHeight: additionalHeight, width: openNotchSize.width)
    }

    /// Mirrors `dismissSpeedNotice()`: dropping the notice also has to collapse the peek it
    /// opened, otherwise the notch is left expanded with nothing in it.
    /// Brings the asking session's own app or terminal forward — the same destination as
    /// clicking that session in the list — since the answer has to be typed there. Falls
    /// back to expanding the AI tab only when the asking session can't be identified.
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
            notchVM.close()
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
            notchVM.close()
        }
    }

    /// Only drops from a closed notch: an open panel or another notice already owns the
    /// space, and the monitor repeats the alert while tethering continues.
    private func triggerTetherNotice(_ placeName: String) {
        guard notchVM.notchState == .closed, !showQuestionNotice, !showSpeedNotice, !showCompletionNotice else { return }
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
           !showQuestionNotice, !showSpeedNotice, !showCompletionNotice {
            notchVM.close()
        }
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

    private func handleAgentCompletion() {
        // Refresh visible tool calls first
        visibleToolCalls = telemetryCoordinator.recentToolCalls.filter { isSourceVisible($0.source) }

        // Find the completion tool call that was just added
        guard let completeCall = visibleToolCalls.first(where: { $0.toolName == "Complete" }),
              completeCall.id != lastCompletionId else { return }

        showCompletionNotice = true
        completionToolCall = completeCall
        lastCompletionId = completeCall.id
        stopActivityGlowForCompletion()

        // Peek the notch to show completion
        resetClosedJellyReveal()
        notchVM.peek(duration: 3.0)

        // Hide completion notice after delay
        completionNoticeTask?.cancel()
        completionNoticeTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.3)) {
                    showCompletionNotice = false
                }
            }
        }
    }

    private func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow")), to: NSApp.delegate, from: nil)
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
