import SwiftUI

/// The travelling glow on the notch outline: a horizontal sweep on the closed notch, a trace
/// along the outline on the open notch and dropdowns. Drawn by `NotchGlowLayers`.
struct NotchGlowBorder: View {
    let topCornerRadius: CGFloat
    let bottomCornerRadius: CGFloat
    let glowColor: Color
    let brightColor: Color
    let secondaryGlowColor: Color?
    let secondaryBrightColor: Color?
    /// Travel along the outline at a constant speed instead of sweeping across it.
    /// The open panel's tall sides would otherwise light all at once and vanish.
    let tracesOutline: Bool

    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var powerMonitor = PowerStateMonitor.shared
    /// Hidden for full screen, the panel is only transparent; the glow kept animating.
    @ObservedObject private var ui = UICoordinator.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        topCornerRadius: CGFloat,
        bottomCornerRadius: CGFloat,
        glowColor: Color,
        brightColor: Color,
        secondaryGlowColor: Color? = nil,
        secondaryBrightColor: Color? = nil,
        tracesOutline: Bool = false
    ) {
        self.topCornerRadius = topCornerRadius
        self.bottomCornerRadius = bottomCornerRadius
        self.glowColor = glowColor
        self.brightColor = brightColor
        self.secondaryGlowColor = secondaryGlowColor
        self.secondaryBrightColor = secondaryBrightColor
        self.tracesOutline = tracesOutline
    }

    var body: some View {
        NotchGlowLayers(
            topCornerRadius: topCornerRadius, bottomCornerRadius: bottomCornerRadius,
            glowColor: NSColor(glowColor), brightColor: NSColor(brightColor),
            secondaryGlowColor: secondaryGlowColor.map { NSColor($0) },
            secondaryBrightColor: secondaryBrightColor.map { NSColor($0) },
            tracesOutline: tracesOutline,
            paused: reduceMotion || !ui.isVisible,
            // Battery saver: at most 30 fps on battery. Measured 2026-11-09 on battery: GPU use
            // +17–19%p at 60 fps (about 170 mW), +10%p at 30, +14%p for the old 15 fps SwiftUI glow.
            maxFrameRate: settings.batterySaverEnabled && !powerMonitor.isCharging ? 30 : 0
        )
        .allowsHitTesting(false)
    }
}

/// A single expanding outline after the closed panel's jelly entrance settles.
/// It owns no timeline: insertion starts one animation and removal stops all work.
struct ClosedNotchJellyRipple: View {
    let topCornerRadius: CGFloat
    let bottomCornerRadius: CGFloat
    let glowColor: Color

    @State private var isExpanded = false

    var body: some View {
        NotchShape(
            topCornerRadius: topCornerRadius,
            bottomCornerRadius: bottomCornerRadius
        )
        .stroke(glowColor.opacity(0.75), lineWidth: 1.5)
        .scaleEffect(
            x: isExpanded ? 1.08 : 0.62,
            y: isExpanded ? 1.38 : 0.72,
            anchor: .top
        )
        .opacity(isExpanded ? 0 : 0.8)
        .blur(radius: isExpanded ? 4 : 0)
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeOut(duration: 0.62)) {
                isExpanded = true
            }
        }
    }
}

/// A one-shot highlight along the closed panel outline when the displayed
/// command changes. The ordinary glow keeps its slower ambient sweep.
struct ClosedNotchToolTransitionWipe: View {
    let trigger: String
    let topCornerRadius: CGFloat
    let bottomCornerRadius: CGFloat
    let glowColor: Color
    let secondaryGlowColor: Color?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress: CGFloat = 1
    @State private var isVisible = false
    @State private var useSecondaryColor = false
    @State private var wipeTask: Task<Void, Never>?

    init(
        trigger: String,
        topCornerRadius: CGFloat,
        bottomCornerRadius: CGFloat,
        glowColor: Color,
        secondaryGlowColor: Color? = nil
    ) {
        self.trigger = trigger
        self.topCornerRadius = topCornerRadius
        self.bottomCornerRadius = bottomCornerRadius
        self.glowColor = glowColor
        self.secondaryGlowColor = secondaryGlowColor
    }

    var body: some View {
        GeometryReader { proxy in
            let bandWidth: CGFloat = 48
            let bandOffset = -bandWidth + progress * (proxy.size.width + bandWidth)
            let activeColor = useSecondaryColor ? (secondaryGlowColor ?? glowColor) : glowColor

            if isVisible {
                NotchShape(
                    topCornerRadius: topCornerRadius,
                    bottomCornerRadius: bottomCornerRadius,
                    drawsTopEdge: false
                )
                .stroke(activeColor.opacity(0.95), lineWidth: 2.5)
                .shadow(color: activeColor.opacity(0.8), radius: 8)
                .mask {
                    LinearGradient(
                        colors: [.clear, .white, .white, .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: bandWidth)
                    .offset(x: bandOffset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
            }
        }
        .allowsHitTesting(false)
        .onChange(of: trigger) { oldValue, newValue in
            guard !oldValue.isEmpty, oldValue != newValue else { return }
            triggerWipe()
        }
        .onDisappear {
            wipeTask?.cancel()
        }
    }

    private func triggerWipe() {
        wipeTask?.cancel()

        if reduceMotion {
            isVisible = false
            return
        }

        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            progress = 0
            isVisible = true
            useSecondaryColor = false
        }

        wipeTask = Task {
            // The closed panel may be resizing for 0.35s. Waiting for that geometry
            // to settle keeps expansion and contraction transitions symmetrical.
            try? await Task.sleep(for: .milliseconds(360))
            guard !Task.isCancelled else { return }
            if secondaryGlowColor != nil {
                withAnimation(.easeInOut(duration: 0.325)) {
                    progress = 0.5
                }
                try? await Task.sleep(for: .milliseconds(325))
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.325)) {
                    // Animated with the sweep so the colour fades over rather than flips.
                    useSecondaryColor = true
                    progress = 1
                }
            } else {
                withAnimation(.easeInOut(duration: 0.65)) {
                    progress = 1
                }
            }
            try? await Task.sleep(for: .milliseconds(secondaryGlowColor == nil ? 650 : 325))
            guard !Task.isCancelled else { return }
            isVisible = false
        }
    }
}

/// 날개 알약: the tool name over a thin running line in the agent's colour (picked
/// 2026-10-29 over upstream's grey capsule). A source-colored highlight still reveals the
/// next command from leading to trailing.
struct ClosedToolTransitionLabel: View {
    let label: String
    let foregroundOpacity: Double
    let glowColor: Color
    /// Waiting on the user: the line holds still.
    var isPaused = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var wipeProgress: CGFloat = 1
    @State private var showWipe = false
    @State private var wipeTask: Task<Void, Never>?

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(NotchPalette.ink.opacity(foregroundOpacity))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(ClosedToolTrack(color: glowColor, isPaused: isPaused))
            .contentTransition(.opacity)
            .animation(.easeInOut(duration: 0.18), value: label)
            .overlay {
                GeometryReader { proxy in
                    if showWipe {
                        LinearGradient(
                            colors: [.clear, glowColor.opacity(0.9), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: 22)
                        .offset(x: -22 + wipeProgress * (proxy.size.width + 44))
                        .blendMode(.screen)
                    }
                }
            }
            .clipShape(Capsule())
            .onChange(of: label) { _, _ in
                triggerWipe()
            }
            .onDisappear {
                wipeTask?.cancel()
            }
    }

    private func triggerWipe() {
        wipeTask?.cancel()

        if reduceMotion {
            showWipe = false
            return
        }

        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            wipeProgress = 0
            showWipe = true
        }

        wipeTask = Task {
            await Task.yield()
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.39)) {
                wipeProgress = 1
            }
            try? await Task.sleep(for: .milliseconds(390))
            guard !Task.isCancelled else { return }
            showWipe = false
        }
    }
}

/// The line under the 날개 알약, with a segment running along it every 1.4s; still under Reduce Motion.
/// Paused, the segment stops where the running one was: the phase comes from the clock, so
/// the paused track (a new view once the wing switches to "Waiting") reads the same spot.
private struct ClosedToolTrack: View {
    let color: Color
    var isPaused = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Taken when the view is created, so a track that starts paused has it from its first frame.
    @State private var frozenPhase = ClosedToolTrack.phase(at: Date())

    private static func phase(at date: Date) -> Double {
        date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 25.0, paused: reduceMotion || isPaused)) { timeline in
            // Near either end the segment is mostly clipped; a stopped one stays whole.
            let phase = isPaused ? min(max(frozenPhase, 0.26), 0.74) : Self.phase(at: timeline.date)
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(NotchPalette.ink.opacity(0.1))
                    Capsule().fill(color)
                        .frame(width: width * 0.35)
                        .offset(x: -width * 0.35 + phase * width * 1.35)
                }
                .frame(height: 1.5)
                .clipShape(Capsule())
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .onChange(of: isPaused) { _, paused in if paused { frozenPhase = Self.phase(at: Date()) } }
    }
}
