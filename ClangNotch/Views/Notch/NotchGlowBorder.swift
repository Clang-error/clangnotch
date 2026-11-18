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
    /// A closed wing stepping aside fades the glow on its side with it.
    let wingFade: WingFade?

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
        tracesOutline: Bool = false,
        wingFade: WingFade? = nil
    ) {
        self.topCornerRadius = topCornerRadius
        self.bottomCornerRadius = bottomCornerRadius
        self.glowColor = glowColor
        self.brightColor = brightColor
        self.secondaryGlowColor = secondaryGlowColor
        self.secondaryBrightColor = secondaryBrightColor
        self.tracesOutline = tracesOutline
        self.wingFade = wingFade
    }

    /// 열리는 곳 표시 is out: the glow goes round its tab.
    private var hintShown: Bool {
        guard let wingFade else { return false }
        return wingFade.hintWidth > 0 && !wingFade.isSolid
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
            maxFrameRate: settings.batterySaverEnabled && !powerMonitor.isCharging ? 30 : 0,
            wingFade: wingFade,
            tabProgress: hintShown ? 1 : 0
        )
        .animation(WingOpenHint.animation, value: hintShown)
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
/// Core Animation since 2026-11-16: as a 25 fps `TimelineView` it had SwiftUI lay out and draw
/// the whole closed notch on the main thread for every step, the largest share of the app's CPU
/// while an agent works (measured with the timeline stopped: 7.5% → 2.3% of a core, WindowServer
/// 33% → 26%). The render server moves the segment now, like the glow.
private struct ClosedToolTrack: NSViewRepresentable {
    let color: Color
    var isPaused = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    /// A hidden notch (full-screen app, Mission Control) is only at alpha 0: nothing should run
    /// with nobody to see it. Also the wing under the cursor, which fades.
    @ObservedObject private var ui = UICoordinator.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var powerMonitor = PowerStateMonitor.shared

    func makeNSView(context: Context) -> ClosedToolTrackView { ClosedToolTrackView() }

    func updateNSView(_ view: ClosedToolTrackView, context: Context) {
        let ink: NSColor = scheme == .dark ? .white : .black
        view.update(ClosedToolTrackView.Config(
            color: NSColor(color), rail: ink.withAlphaComponent(0.1),
            held: isPaused, still: reduceMotion || !ui.isVisible,
            // Battery saver: at most 30 fps on battery, as for the glow.
            maxFrameRate: settings.batterySaverEnabled && !powerMonitor.isCharging ? 30 : 0,
            fade: WingFade(notchWidth: getClosedNotchSize().width,
                           left: ui.hoveredWing == .left ? 1 : 0, right: ui.hoveredWing == .right ? 1 : 0)))
    }
}

/// `ClosedToolTrack`'s layers. It fills the 날개 알약 and draws only its bottom 1.5 pt, so the
/// pill's capsule cuts the line's ends as SwiftUI's clip did.
final class ClosedToolTrackView: NSView {
    struct Config: Equatable {
        var color: NSColor
        var rail: NSColor
        /// Waiting on the user: the segment holds where it was.
        var held: Bool
        /// Reduce Motion or a hidden notch: nothing moves.
        var still: Bool
        var maxFrameRate: Float
        var fade: WingFade
    }

    private static let period = 1.4
    private static let lineHeight: CGFloat = 1.5
    /// The segment's length as a share of the line.
    private static let segment: CGFloat = 0.35

    private let rail = CALayer()
    private let runner = CALayer()
    private let fadeMask = CAGradientLayer()
    private var config: Config?
    private var laidOutWidth: CGFloat = 0
    /// Taken when the view is created, so a track that starts paused has it from its first frame.
    private var frozenPhase = ClosedToolTrackView.phase()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        rail.masksToBounds = true
        rail.cornerRadius = Self.lineHeight / 2
        runner.cornerRadius = Self.lineHeight / 2
        runner.anchorPoint = CGPoint(x: 0, y: 0.5)
        rail.addSublayer(runner)
        layer?.addSublayer(rail)
        fadeMask.startPoint = CGPoint(x: 0, y: 0.5)
        fadeMask.endPoint = CGPoint(x: 1, y: 0.5)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Clicks belong to the notch, never to the line.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private static func phase() -> Double {
        Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
    }

    /// The segment's leading edge: fully before the line at 0, fully past it at 1.
    private static func leading(_ phase: Double, width: CGFloat) -> CGFloat {
        -width * segment + CGFloat(phase) * width * (1 + segment)
    }

    func update(_ new: Config) {
        let old = config
        guard old != new else { return }
        config = new
        if new.held, let old, !old.held { frozenPhase = Self.phase() }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rail.backgroundColor = new.rail.cgColor
        runner.backgroundColor = new.color.cgColor
        CATransaction.commit()
        if old?.held != new.held || old?.still != new.still || old?.maxFrameRate != new.maxFrameRate {
            restart()
        }
        if old?.fade != new.fade { applyFade(animated: old != nil) }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.cornerRadius = bounds.height / 2
        // The view isn't flipped: y 0 is the pill's bottom edge.
        rail.frame = CGRect(x: 0, y: 0, width: bounds.width, height: Self.lineHeight)
        runner.bounds = CGRect(x: 0, y: 0, width: bounds.width * Self.segment, height: Self.lineHeight)
        CATransaction.commit()
        if bounds.width != laidOutWidth {
            laidOutWidth = bounds.width
            restart()
        }
        applyFade(animated: false)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyFade(animated: false)
    }

    /// Started from the wall clock, as the timeline read it: a track made anew when the wing's
    /// content changes carries on from the same spot.
    private func restart() {
        runner.removeAllAnimations()
        guard let config, bounds.width > 0 else { return }
        let width = bounds.width
        let now = Self.phase()
        // Near either end the segment is mostly clipped; a stopped one stays whole.
        let shown = config.held ? min(max(frozenPhase, 0.26), 0.74) : now
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        runner.position = CGPoint(x: Self.leading(shown, width: width), y: Self.lineHeight / 2)
        CATransaction.commit()
        guard !config.held, !config.still else { return }

        let travel = CABasicAnimation(keyPath: "position.x")
        travel.fromValue = Self.leading(0, width: width)
        travel.toValue = Self.leading(1, width: width)
        travel.duration = Self.period
        travel.repeatCount = .infinity
        travel.timeOffset = now * Self.period
        travel.isRemovedOnCompletion = false
        if config.maxFrameRate > 0 {
            travel.preferredFrameRateRange = CAFrameRateRange(
                minimum: 30, maximum: config.maxFrameRate, preferred: config.maxFrameRate)
        }
        runner.add(travel, forKey: "travel")
    }

    /// The wing's SwiftUI mask doesn't reach an NSView, so the line takes the same fade itself:
    /// `WingFade`'s stops across a span centred on the notch, which sits at the panel's centre.
    private func applyFade(animated: Bool) {
        guard let fade = config?.fade, let layer, let host = window?.contentView else { return }
        guard !fade.isSolid || layer.mask != nil else { return }
        let centre = convert(CGPoint(x: host.bounds.midX, y: 0), from: host).x
        let half = max(abs(centre - bounds.minX), abs(centre - bounds.maxX)) + 1
        let frame = CGRect(x: centre - half, y: 0, width: half * 2, height: bounds.height)
        let stops = fade.stops(width: frame.width)
        let locations = stops.map { NSNumber(value: Double($0.location)) }
        if layer.mask == nil {
            // Put it on solid, so stepping aside animates from there.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            fadeMask.frame = frame
            fadeMask.locations = locations
            fadeMask.colors = stops.map { _ in NSColor.white.cgColor }
            layer.mask = fadeMask
            CATransaction.commit()
        }
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(0.2)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        if fade.isSolid {
            // Back to solid: take the mask off once the fade back has finished.
            CATransaction.setCompletionBlock { [weak self] in
                guard let self, self.config?.fade.isSolid ?? true else { return }
                self.layer?.mask = nil
            }
        }
        fadeMask.frame = frame
        fadeMask.locations = locations
        fadeMask.colors = stops.map { NSColor(white: 1, alpha: $0.opacity).cgColor }
        CATransaction.commit()
    }
}

/// A working session row: the notch's travelling glow, going round the row's outline over a
/// faint steady rim. Under Reduce Motion only the rim stays. (Here rather than in NotchMotion,
/// which the layout checks compile without the app's singletons.)
/// Core Animation since 2026-11-16: as an `AngularGradient` stroke in a 25 fps `TimelineView`,
/// CoreGraphics shaded the gradient on the main thread for every row and every step, rows
/// scrolled out of sight included (30% of the main thread with the notch open and eight sessions
/// working). A conic gradient layer turns under the row's border now, in the render server.
struct TracingGlowOutline: NSViewRepresentable {
    var cornerRadius: CGFloat
    var color: Color
    /// When the row's work began: its lap counts from there, so rows don't all go round in step.
    var since: Date? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// A hidden notch is only at alpha 0: nothing turns with nobody to see it.
    @ObservedObject private var ui = UICoordinator.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var powerMonitor = PowerStateMonitor.shared

    func makeNSView(context: Context) -> TracingGlowOutlineView { TracingGlowOutlineView() }

    func updateNSView(_ view: TracingGlowOutlineView, context: Context) {
        view.update(TracingGlowOutlineView.Config(
            cornerRadius: cornerRadius, color: NSColor(color), since: since,
            reduceMotion: reduceMotion, hidden: !ui.isVisible,
            // Battery saver: at most 30 fps on battery, as for the glow.
            maxFrameRate: settings.batterySaverEnabled && !powerMonitor.isCharging ? 30 : 0))
    }
}

/// `TracingGlowOutline`'s layers: the rim, and a square conic gradient turning about the row's
/// centre, seen only through the row's border.
final class TracingGlowOutlineView: NSView {
    struct Config: Equatable {
        var cornerRadius: CGFloat
        var color: NSColor
        var since: Date?
        var reduceMotion: Bool
        var hidden: Bool
        var maxFrameRate: Float
    }

    private static let period = 3.0
    private static let rimWidth: CGFloat = 1.5
    private static let traceWidth: CGFloat = 2.2

    private let rim = CALayer()
    /// Flipped like SwiftUI's space (y down), so the layer turns clockwise as the
    /// `AngularGradient` did.
    private let trace = CALayer()
    private let border = CALayer()
    private let spinner = CAGradientLayer()
    private var config: Config?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        rim.cornerCurve = .continuous
        rim.borderWidth = Self.rimWidth
        border.cornerCurve = .continuous
        border.borderWidth = Self.traceWidth
        border.borderColor = NSColor.white.cgColor
        trace.isGeometryFlipped = true
        trace.mask = border
        spinner.type = .conic
        spinner.startPoint = CGPoint(x: 0.5, y: 0.5)
        spinner.endPoint = CGPoint(x: 1, y: 0.5)
        // The conic layer's stops run against the turn, so they are the gradient's mirrored:
        // 0 → 0.1 → 0.25 became 1 → 0.9 → 0.75, and the long fade still leads the lap (checked
        // on frames: unmirrored, it trailed).
        spinner.locations = [0, 0.75, 0.9, 1]
        trace.addSublayer(spinner)
        layer?.addSublayer(rim)
        layer?.addSublayer(trace)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The row under it takes the clicks and the hover.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(_ new: Config) {
        let old = config
        guard old != new else { return }
        config = new
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rim.cornerRadius = new.cornerRadius
        border.cornerRadius = new.cornerRadius
        rim.borderColor = new.color.withAlphaComponent(0.22).cgColor
        let clear = new.color.withAlphaComponent(0).cgColor
        spinner.colors = [clear, clear, new.color.withAlphaComponent(0.55).cgColor, clear]
        trace.isHidden = new.reduceMotion
        CATransaction.commit()
        if old?.since != new.since || old?.reduceMotion != new.reduceMotion || old?.hidden != new.hidden
            || old?.maxFrameRate != new.maxFrameRate {
            restart()
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rim.frame = bounds
        trace.frame = bounds
        border.frame = bounds
        // Wide enough to cover the row whichever way it is turned.
        let side = (bounds.width * bounds.width + bounds.height * bounds.height).squareRoot() + 2
        spinner.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        spinner.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    /// The lap's phase comes from the clock and `since`, as the timeline read it.
    private func restart() {
        spinner.removeAllAnimations()
        guard let config else { return }
        let elapsed = Date().timeIntervalSince(config.since ?? Date(timeIntervalSinceReferenceDate: 0))
        let phase = elapsed.truncatingRemainder(dividingBy: Self.period) / Self.period
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spinner.setAffineTransform(CGAffineTransform(rotationAngle: CGFloat(phase * 2 * .pi)))
        CATransaction.commit()
        guard !config.reduceMotion, !config.hidden else { return }

        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0
        turn.toValue = 2 * Double.pi
        turn.duration = Self.period
        turn.repeatCount = .infinity
        turn.timeOffset = phase * Self.period
        turn.isRemovedOnCompletion = false
        if config.maxFrameRate > 0 {
            turn.preferredFrameRateRange = CAFrameRateRange(
                minimum: 30, maximum: config.maxFrameRate, preferred: config.maxFrameRate)
        }
        spinner.add(turn, forKey: "turn")
    }
}
