import SwiftUI

/// Springs content in on appear instead of a plain fade: `.scale` grows dropdown content
/// from 0.85 at its top edge, `.rise` lifts list rows 6pt. `delay` staggers siblings.
struct PopIn: ViewModifier {
    enum Style { case scale, rise }

    var style: Style = .scale
    var delay: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(style == .scale && !shown ? 0.85 : 1, anchor: .top)
            .offset(y: style == .rise && !shown ? 6 : 0)
            .opacity(shown ? 1 : 0)
            .onAppear {
                guard !shown else { return }
                withAnimation(reduceMotion ? .easeOut(duration: 0.12)
                              : .spring(response: 0.3, dampingFraction: 0.6).delay(delay)) {
                    shown = true
                }
            }
    }
}

/// "This is new": a 1.06× swell with a white rim that settles back after 0.45s.
struct NewHighlight: ViewModifier {
    var cornerRadius: CGFloat
    var delay: Double = 0
    var active = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lit = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(lit ? 1.06 : 1)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(NotchPalette.ink.opacity(lit ? 0.75 : 0), lineWidth: 1.5)
            )
            .task {
                guard active, !reduceMotion else { return }
                try? await Task.sleep(for: .seconds(delay))
                withAnimation(.spring(response: 0.25, dampingFraction: 0.55)) { lit = true }
                try? await Task.sleep(for: .seconds(0.45))
                withAnimation(.easeOut(duration: 0.3)) { lit = false }
            }
    }
}

/// Blur + fade, the open-notch transition boring.notch and DynamicNotchKit use:
/// content comes into focus instead of just fading in.
private struct BlurFade: ViewModifier {
    var radius: CGFloat
    var opacity: Double

    func body(content: Content) -> some View {
        content.blur(radius: radius).opacity(opacity)
    }
}

extension AnyTransition {
    static func blurFade(radius: CGFloat = 8) -> AnyTransition {
        .modifier(active: BlurFade(radius: radius, opacity: 0), identity: BlurFade(radius: 0, opacity: 1))
    }
}

extension View {
    func popIn(_ style: PopIn.Style = .scale, delay: Double = 0) -> some View {
        modifier(PopIn(style: style, delay: delay))
    }

    func newHighlight(cornerRadius: CGFloat, delay: Double = 0, active: Bool = true) -> some View {
        modifier(NewHighlight(cornerRadius: cornerRadius, delay: delay, active: active))
    }
}

/// How text is lit like the notch glow: a bright band sweeps across it every 3s (the glow's
/// sweep period). With a `secondary` colour (Claude and Codex both working) the text
/// eases from one agent's colour to the other's and back every 6s. Paused when idle.
struct GlowSweepText {
    var active: Bool
    var color: Color
    var bright: Color
    var secondary: Color? = nil
    var secondaryBright: Color? = nil

    /// Same as `NotchGlowLayers`': `Color.mix(with:by:)` needs macOS 15; the target is 14.2.
    static func blend(_ from: Color, _ to: Color?, _ fraction: Double) -> Color {
        guard let to, fraction > 0 else { return from }
        guard let blended = NSColor(from).usingColorSpace(.sRGB)?
            .blended(withFraction: fraction, of: NSColor(to)) else { return from }
        return Color(nsColor: blended)
    }
}

/// A line of text under a `GlowSweepText`. Quiet, it is plain `Text`. Lit, the same text is
/// laid out but not drawn, and layers draw it: a picture of the text masks a gradient whose
/// band the render server slides across. As a `TimelineView` setting a new gradient on the text
/// 25 times a second, it had SwiftUI draw the open notch over again for every step (2026-11-16).
struct SweptText: View {
    let text: String
    let glow: GlowSweepText
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if glow.active {
            Text(text).hidden().overlay {
                SweptTextLayers(text: text, glow: glow, still: reduceMotion).allowsHitTesting(false)
            }
        } else {
            Text(text)
        }
    }
}

private struct SweptTextLayers: NSViewRepresentable {
    let text: String
    let glow: GlowSweepText
    let still: Bool

    func makeNSView(context: Context) -> SweptTextView { SweptTextView() }

    func updateNSView(_ view: SweptTextView, context: Context) {
        // The text as SwiftUI draws it here (font, digits, size), as an alpha picture.
        let scale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let key = "\(text)|\(scale)|\(context.environment.font.map { "\($0)" } ?? "")"
        if view.maskKey != key {
            let renderer = ImageRenderer(content: Text(text).foregroundStyle(.white)
                .environment(\.self, context.environment))
            renderer.scale = scale
            view.setMask(renderer.cgImage, scale: scale, key: key)
        }
        let white = Color.white
        func colors(_ base: Color, _ band: Color) -> [CGColor] {
            let base = NSColor(base).cgColor
            return [base, NSColor(GlowSweepText.blend(band, white, 0.65)).cgColor, base]
        }
        view.update(SweptTextView.Config(
            colors: colors(glow.bright, glow.color),
            secondary: glow.secondary.map { colors(glow.secondaryBright ?? glow.bright, $0) },
            still: still))
    }
}

final class SweptTextView: NSView {
    struct Config: Equatable {
        /// Base, band, base.
        var colors: [CGColor]
        /// The same for the other agent, when both work.
        var secondary: [CGColor]?
        var still: Bool
    }

    private static let period = 3.0
    private static let colourCycle = 6.0
    private static let sine = CAMediaTimingFunction(controlPoints: 0.37, 0, 0.63, 1)

    private let gradient = CAGradientLayer()
    private let textMask = CALayer()
    private var config: Config?
    fileprivate var maskKey = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        textMask.contentsGravity = .center
        gradient.mask = textMask
        layer?.addSublayer(gradient)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    fileprivate func setMask(_ image: CGImage?, scale: CGFloat, key: String) {
        maskKey = key
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        textMask.contents = image
        textMask.contentsScale = scale
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        textMask.frame = bounds
        CATransaction.commit()
    }

    /// The band's centre runs from 0.3 before the text to 0.3 past it, half a text wide: its end
    /// points move, not its stops, so past either end the gradient just holds the base colour.
    private static func points(at phase: Double) -> (CGPoint, CGPoint) {
        let centre = phase * 1.6 - 0.3
        return (CGPoint(x: centre - 0.25, y: 0.5), CGPoint(x: centre + 0.25, y: 0.5))
    }

    func update(_ new: Config) {
        guard config != new else { return }
        config = new
        gradient.removeAllAnimations()
        let now = Date().timeIntervalSinceReferenceDate
        let phase = new.still ? 0.5 : now.truncatingRemainder(dividingBy: Self.period) / Self.period
        let (start, end) = Self.points(at: phase)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.colors = new.colors
        gradient.startPoint = start
        gradient.endPoint = end
        CATransaction.commit()

        func add(_ animation: CABasicAnimation, cycle: Double) {
            animation.repeatCount = .infinity
            animation.timeOffset = now.truncatingRemainder(dividingBy: cycle)
            animation.isRemovedOnCompletion = false
            gradient.add(animation, forKey: animation.keyPath)
        }
        if let secondary = new.secondary {
            let colours = CABasicAnimation(keyPath: "colors")
            colours.fromValue = new.colors
            colours.toValue = secondary
            colours.duration = Self.colourCycle / 2
            colours.autoreverses = true
            colours.timingFunction = Self.sine
            add(colours, cycle: Self.colourCycle)
        }
        guard !new.still else { return }
        for (keyPath, from, to) in [("startPoint", Self.points(at: 0).0, Self.points(at: 1).0),
                                    ("endPoint", Self.points(at: 0).1, Self.points(at: 1).1)] {
            let travel = CABasicAnimation(keyPath: keyPath)
            travel.fromValue = NSValue(point: from)
            travel.toValue = NSValue(point: to)
            travel.duration = Self.period
            add(travel, cycle: Self.period)
        }
    }
}

/// The 요약 줄's status dot. Grey when quiet; while working it breathes in the working
/// agent's colour, and with a `secondary` (both agents working) it eases between the two
/// colours on `GlowSweepText`'s 6s cycle, so dot and text change together.
/// Core Animation since 2026-11-16: as a 25 fps `TimelineView` it kept SwiftUI drawing the open
/// notch over again for as long as anything worked.
struct StatusDot: View {
    var active: Bool
    var color: Color
    var secondary: Color? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        StatusDotLayers(active: active, color: NSColor(color), secondary: secondary.map { NSColor($0) },
                        quiet: (scheme == .dark ? NSColor.white : .black).withAlphaComponent(0.35),
                        still: reduceMotion)
            // The view is the 7 pt dot plus room for its 3 pt glow, which an NSView would cut off.
            .frame(width: StatusDotView.side, height: StatusDotView.side)
            .padding(-(StatusDotView.side - StatusDotView.dot) / 2)
            .allowsHitTesting(false)
    }
}

private struct StatusDotLayers: NSViewRepresentable {
    let active: Bool
    let color: NSColor
    let secondary: NSColor?
    let quiet: NSColor
    let still: Bool

    func makeNSView(context: Context) -> StatusDotView { StatusDotView() }

    func updateNSView(_ view: StatusDotView, context: Context) {
        view.update(StatusDotView.Config(active: active, color: color, secondary: secondary, quiet: quiet, still: still))
    }
}

final class StatusDotView: NSView {
    struct Config: Equatable {
        var active: Bool
        var color: NSColor
        var secondary: NSColor?
        var quiet: NSColor
        var still: Bool
    }

    static let dot: CGFloat = 7
    static let side: CGFloat = 19
    /// The breath: 2.4 s there and back. The colours: 6 s there and back.
    private static let breath = 2.4
    private static let colourCycle = 6.0
    /// The cosine the timeline used, as a curve.
    private static let sine = CAMediaTimingFunction(controlPoints: 0.37, 0, 0.63, 1)

    private let dotLayer = CALayer()
    private var config: Config?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        dotLayer.cornerRadius = Self.dot / 2
        dotLayer.shadowRadius = 3
        dotLayer.shadowOffset = .zero
        layer?.addSublayer(dotLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dotLayer.bounds = CGRect(x: 0, y: 0, width: Self.dot, height: Self.dot)
        dotLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    func update(_ new: Config) {
        guard config != new else { return }
        config = new
        dotLayer.removeAllAnimations()
        let fill = new.active ? new.color : new.quiet
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dotLayer.backgroundColor = fill.cgColor
        dotLayer.shadowColor = fill.cgColor
        dotLayer.opacity = 1
        // Still under Reduce Motion: the full dot with its glow, as the stopped timeline drew it.
        dotLayer.shadowOpacity = new.active ? 0.8 : 0
        CATransaction.commit()
        guard new.active, !new.still else { return }

        let now = Date().timeIntervalSinceReferenceDate
        func add(_ keyPath: String, from: Any, to: Any, cycle: Double) {
            let animation = CABasicAnimation(keyPath: keyPath)
            animation.fromValue = from
            animation.toValue = to
            animation.duration = cycle / 2
            animation.autoreverses = true
            animation.repeatCount = .infinity
            animation.timingFunction = Self.sine
            animation.timeOffset = now.truncatingRemainder(dividingBy: cycle)
            animation.isRemovedOnCompletion = false
            dotLayer.add(animation, forKey: keyPath)
        }
        add("opacity", from: 1.0, to: 0.55, cycle: Self.breath)
        add("shadowOpacity", from: 0.8, to: 0.0, cycle: Self.breath)
        if let secondary = new.secondary {
            add("backgroundColor", from: new.color.cgColor, to: secondary.cgColor, cycle: Self.colourCycle)
            add("shadowColor", from: new.color.cgColor, to: secondary.cgColor, cycle: Self.colourCycle)
        }
    }
}

/// A status word that slowly fades and comes back while `active`. Driven by a paused
/// TimelineView, so nothing redraws once it goes quiet; Reduce Motion keeps it still.
struct Breathing: ViewModifier {
    var active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 25.0, paused: !active || reduceMotion)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let wave = 0.5 + 0.5 * cos(2 * .pi * t / 2.4)
            content.opacity(!active || reduceMotion ? 1 : 0.45 + 0.55 * wave)
        }
    }
}
