import SwiftUI

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

    // Battery saver: 15 FPS on battery, 25 FPS when charging or disabled
    private var frameInterval: Double {
        if settings.batterySaverEnabled && !powerMonitor.isCharging {
            return 1.0 / 15.0  // 15 FPS on battery
        }
        return 1.0 / 25.0  // 25 FPS when charging or battery saver off
    }

    /// Seconds for the highlight to travel the full width once.
    private let sweepPeriod: Double = 3.0
    /// Width of the highlight band, as a fraction of the notch width.
    private let bandWidth: CGFloat = 0.45
    /// Seconds for the highlight to travel the whole open outline once.
    private let outlinePeriod: Double = 5.0
    /// Nested segments, as (fraction of the outline, colour opacity, bright colour?),
    /// widest first. Many evenly stepped translucent layers stack into a smooth fade
    /// toward both ends; a few coarse ones read as grainy. The bright core is stepped
    /// the same way — a single opaque core segment showed hard, separate ends. Each
    /// layer's end is one visible step, so steps are kept faint: 12 body layers at
    /// 0.28 and 6 core layers at 0.3 still showed seams.
    private static let outlineLayers: [(length: CGFloat, opacity: Double, isBright: Bool)] =
        (0..<32).map { (0.34 - CGFloat($0) * 0.01, 0.1, false) }
        + (0..<16).map { (0.16 - CGFloat($0) * 0.009, 0.11, true) }

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
        TimelineView(.animation(minimumInterval: frameInterval)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            // Phase of the travelling highlight, 0...1 over `sweepPeriod`.
            let period = tracesOutline ? outlinePeriod : sweepPeriod
            let phase = (time.truncatingRemainder(dividingBy: period)) / period
            // Cross-fade to the secondary colour while the band crosses the middle
            // instead of flipping at exactly half way. The return flip at the wrap
            // happens while the band is off-screen, so it stays invisible.
            let mix = Self.smoothstep(0.3, 0.7, phase)
            let phaseGlowColor = Self.blend(glowColor, secondaryGlowColor, mix)
            let phaseBrightColor = Self.blend(brightColor, secondaryBrightColor, mix)
            // The band spans `bandWidth` of the view and is swept from fully off the
            // leading edge to fully off the trailing edge.
            let bandStart = phase * (1 + bandWidth) - bandWidth

            if tracesOutline {
                outlineTrace(phase: phase, glowColor: phaseGlowColor, brightColor: phaseBrightColor)
            } else {
            NotchShape(
                topCornerRadius: topCornerRadius,
                bottomCornerRadius: bottomCornerRadius,
                drawsTopEdge: false
            )
            .stroke(
                // Swept horizontally rather than by angle: an AngularGradient spreads colour
                // by angle from the centre, so on the wide bar the notch becomes once its
                // wings extend, the long top and bottom edges collapse into a couple of
                // narrow angle bands while the short left and right ends soak up most of the
                // sweep — the highlight stops travelling and just pools at one end.
                LinearGradient(
                    stops: [
                        .init(color: Color.clear, location: 0.0),
                        .init(color: phaseGlowColor.opacity(0.3), location: 0.2),
                        .init(color: phaseGlowColor, location: 0.4),
                        .init(color: phaseBrightColor, location: 0.5),
                        .init(color: phaseGlowColor, location: 0.6),
                        .init(color: phaseGlowColor.opacity(0.3), location: 0.8),
                        .init(color: Color.clear, location: 1.0),
                    ],
                    startPoint: UnitPoint(x: bandStart, y: 0.5),
                    endPoint: UnitPoint(x: bandStart + bandWidth, y: 0.5)
                ),
                lineWidth: 2.5
            )
            .shadow(color: phaseGlowColor.opacity(0.7), radius: 8)
            .shadow(color: phaseGlowColor.opacity(0.4), radius: 16)
            .shadow(color: phaseGlowColor.opacity(0.2), radius: 24)
            }
        }
        .allowsHitTesting(false)
    }

    /// The outline path runs top-left, down, across the bottom and up to top-right,
    /// so trimming it moves the highlight along the edges at an even pace.
    private func outlineTrace(phase: Double, glowColor: Color, brightColor: Color) -> some View {
        let maxLength = Self.outlineLayers[0].length
        // Centre travels from fully before the start to fully past the end.
        let centre = CGFloat(phase) * (1 + maxLength) - maxLength / 2
        let shape = NotchShape(
            topCornerRadius: topCornerRadius,
            bottomCornerRadius: bottomCornerRadius,
            drawsTopEdge: false
        )
        // One Canvas instead of a view per layer: 48 trimmed-shape views rebuilt every
        // frame nearly doubled the app's CPU while the panel was open.
        // The canvas clips its drawing, so it overhangs the outline by `bleed` on every
        // side; otherwise the outer half of the stroke along the bottom edge is cut off.
        let bleed: CGFloat = 4
        return Canvas { context, size in
            let path = shape.path(in: CGRect(origin: .zero, size: size).insetBy(dx: bleed, dy: bleed))
            // Butt caps: round caps bulge past each layer's end and mark the seams.
            let style = StrokeStyle(lineWidth: 2.5, lineCap: .butt)
            for layer in Self.outlineLayers {
                let from = max(0, centre - layer.length / 2)
                let to = min(1, centre + layer.length / 2)
                guard to > from else { continue }
                context.stroke(
                    path.trimmedPath(from: from, to: to),
                    with: .color((layer.isBright ? brightColor : glowColor).opacity(layer.opacity)),
                    style: style
                )
            }
        }
        .padding(-bleed)
        .shadow(color: glowColor.opacity(0.7), radius: 8)
        .shadow(color: glowColor.opacity(0.4), radius: 16)
        .shadow(color: glowColor.opacity(0.2), radius: 24)
    }

    private static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// `Color.mix(with:by:)` needs macOS 15; the target is 14.2.
    private static func blend(_ from: Color, _ to: Color?, _ fraction: Double) -> Color {
        guard let to, fraction > 0 else { return from }
        guard let blended = NSColor(from).usingColorSpace(.sRGB)?
            .blended(withFraction: fraction, of: NSColor(to)) else { return from }
        return Color(nsColor: blended)
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

/// Keeps the tool capsule fixed while a source-colored highlight reveals the
/// next command from leading to trailing.
struct ClosedToolTransitionLabel: View {
    let label: String
    let foregroundOpacity: Double
    let glowColor: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var wipeProgress: CGFloat = 1
    @State private var showWipe = false
    @State private var wipeTask: Task<Void, Never>?

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.white.opacity(foregroundOpacity))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.white.opacity(0.08), in: Capsule())
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
