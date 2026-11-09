import AppKit
import SwiftUI

/// The glow border's drawing, in Core Animation. The band's travel and its colour change run
/// in the render server at the display's rate, so the app draws nothing per frame. The
/// SwiftUI version redrew from a TimelineView at 15 fps on battery, and on a light wallpaper
/// the band visibly jumped about 10pt a frame (2026-11-09).
struct NotchGlowLayers: NSViewRepresentable, Animatable {
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat
    let glowColor: NSColor
    let brightColor: NSColor
    let secondaryGlowColor: NSColor?
    let secondaryBrightColor: NSColor?
    let tracesOutline: Bool
    /// Holds the band still where the clock puts it (Reduce Motion, hidden notch).
    let paused: Bool
    /// 0 lets the display decide; battery saver caps it at 30.
    let maxFrameRate: Float

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topCornerRadius, bottomCornerRadius) }
        set { (topCornerRadius, bottomCornerRadius) = (newValue.first, newValue.second) }
    }

    func makeNSView(context: Context) -> NotchGlowLayerView { NotchGlowLayerView() }

    func updateNSView(_ view: NotchGlowLayerView, context: Context) {
        view.configure(NotchGlowLayerView.Config(
            topCornerRadius: topCornerRadius, bottomCornerRadius: bottomCornerRadius,
            glow: glowColor.srgb, bright: brightColor.srgb,
            secondaryGlow: secondaryGlowColor?.srgb, secondaryBright: secondaryBrightColor?.srgb,
            tracesOutline: tracesOutline, paused: paused, maxFrameRate: maxFrameRate))
    }
}

final class NotchGlowLayerView: NSView {
    struct Config: Equatable {
        var topCornerRadius: CGFloat
        var bottomCornerRadius: CGFloat
        var glow: NSColor
        var bright: NSColor
        var secondaryGlow: NSColor?
        var secondaryBright: NSColor?
        var tracesOutline: Bool
        var paused: Bool
        var maxFrameRate: Float
    }

    /// Seconds for the closed band to cross the notch once.
    private static let sweepPeriod: Double = 3.0
    /// The closed band's width, as a fraction of the notch width.
    private static let bandWidth: CGFloat = 0.45
    /// Seconds for the open notch's highlight to travel its whole outline once.
    private static let outlinePeriod: Double = 5.0
    /// Nested segments, as (fraction of the outline, colour opacity, bright colour?),
    /// widest first. Many evenly stepped translucent layers stack into a smooth fade
    /// toward both ends; a few coarse ones read as grainy. The bright core is stepped
    /// the same way — a single opaque core segment showed hard, separate ends. Each
    /// layer's end is one visible step, so steps are kept faint: 12 body layers at
    /// 0.28 and 6 core layers at 0.3 still showed seams.
    private static let outlineLayers: [(length: CGFloat, opacity: CGFloat, isBright: Bool)] =
        (0..<32).map { (0.34 - CGFloat($0) * 0.01, 0.1, false) }
        + (0..<16).map { (0.16 - CGFloat($0) * 0.009, 0.11, true) }
    /// The three stacked halos, innermost first, as (blur radius, colour opacity).
    private static let halos: [(radius: CGFloat, opacity: CGFloat)] = [(8, 0.7), (16, 0.4), (24, 0.2)]
    private static let lineWidth: CGFloat = 2.5

    private var config: Config?
    /// Innermost first; each holds the next one in, and the innermost holds `content`.
    private let haloLayers = NotchGlowLayerView.halos.map { _ in CALayer() }
    private let content = CALayer()
    private let band = CAGradientLayer()
    private let bandMask = CAShapeLayer()
    private var traceLayers: [CAShapeLayer] = []

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = false
        layer?.masksToBounds = false
        var inner: CALayer = content
        for halo in haloLayers {
            halo.addSublayer(inner)
            halo.shadowOffset = .zero
            halo.shadowOpacity = 1
            inner = halo
        }
        layer?.addSublayer(inner)
        band.startPoint = CGPoint(x: 0, y: 0.5)
        band.endPoint = CGPoint(x: 1, y: 0.5)
        band.locations = [0, 0.2, 0.4, 0.5, 0.6, 0.8, 1]
        band.anchorPoint = .zero
        bandMask.fillColor = nil
        bandMask.strokeColor = NSColor.white.cgColor
        bandMask.lineWidth = Self.lineWidth
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { update(rebuild: false) }
    }

    func configure(_ new: Config) {
        guard new != config else { return }
        let rebuild = new.tracesOutline != config?.tracesOutline
        config = new
        update(rebuild: rebuild)
    }

    // MARK: - Layout

    private func update(rebuild: Bool) {
        guard let config else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        if rebuild {
            content.sublayers?.forEach { $0.removeFromSuperlayer() }
            traceLayers = []
            if config.tracesOutline {
                traceLayers = Self.outlineLayers.map { _ in
                    let layer = CAShapeLayer()
                    layer.fillColor = nil
                    layer.lineWidth = Self.lineWidth
                    // Butt caps: round caps bulge past each layer's end and mark the seams.
                    layer.lineCap = .butt
                    return layer
                }
                traceLayers.forEach(content.addSublayer)
            } else {
                content.addSublayer(band)
            }
            content.mask = config.tracesOutline ? nil : bandMask
        }

        let bounds = self.bounds
        for halo in haloLayers { halo.frame = bounds }
        content.frame = bounds
        let path = NotchShape(topCornerRadius: config.topCornerRadius,
                              bottomCornerRadius: config.bottomCornerRadius,
                              drawsTopEdge: false).path(in: bounds).cgPath
        if config.tracesOutline {
            for layer in traceLayers {
                layer.frame = bounds
                layer.path = path
            }
        } else {
            bandMask.frame = bounds
            bandMask.path = path
            // Taller than the outline so the stroke's outer half along the bottom is covered.
            band.bounds = CGRect(x: 0, y: 0, width: bounds.width * Self.bandWidth, height: bounds.height + 6)
        }
        startAnimations(config)
    }

    // MARK: - Animation

    private var period: Double { config?.tracesOutline == true ? Self.outlinePeriod : Self.sweepPeriod }

    /// Started from the wall clock, like the SwiftUI version: a glow swapped for a new one when
    /// the notch changes state carries on from the same spot.
    private func startAnimations(_ config: Config) {
        let period = self.period
        let phase = Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
        let animated: [CALayer] = haloLayers + [band] + traceLayers
        animated.forEach { $0.removeAllAnimations() }

        // Model values at the current phase: what shows while paused, and under the animations.
        let mix = config.secondaryGlow == nil ? 0 : Self.smoothstep(0.3, 0.7, phase)
        let glow = Self.blend(config.glow, config.secondaryGlow, mix)
        let bright = Self.blend(config.bright, config.secondaryBright, mix)
        for (halo, style) in zip(haloLayers, Self.halos) {
            halo.shadowRadius = style.radius
            halo.shadowColor = glow.withAlphaComponent(style.opacity).cgColor
        }
        if config.tracesOutline {
            for (layer, style) in zip(traceLayers, Self.outlineLayers) {
                let (from, to) = Self.segment(style.length, at: CGFloat(phase))
                layer.strokeStart = from
                layer.strokeEnd = to
                layer.strokeColor = (style.isBright ? bright : glow).withAlphaComponent(style.opacity).cgColor
            }
        } else {
            band.position = CGPoint(x: Self.bandX(phase, width: bounds.width), y: 0)
            band.colors = Self.bandColors(glow: glow, bright: bright)
        }
        guard !config.paused, bounds.width > 0 else { return }

        func add(_ animation: CAAnimation, to layer: CALayer, key: String) {
            animation.duration = period
            animation.repeatCount = .infinity
            animation.timeOffset = phase * period
            animation.isRemovedOnCompletion = false
            if config.maxFrameRate > 0 {
                animation.preferredFrameRateRange = CAFrameRateRange(
                    minimum: 30, maximum: config.maxFrameRate, preferred: config.maxFrameRate)
            }
            layer.add(animation, forKey: key)
        }

        if config.tracesOutline {
            for (layer, style) in zip(traceLayers, Self.outlineLayers) {
                add(Self.strokeKeyframes("strokeStart", length: style.length, end: false), to: layer, key: "start")
                add(Self.strokeKeyframes("strokeEnd", length: style.length, end: true), to: layer, key: "end")
            }
        } else {
            let travel = CABasicAnimation(keyPath: "position.x")
            travel.fromValue = Self.bandX(0, width: bounds.width)
            travel.toValue = Self.bandX(1, width: bounds.width)
            add(travel, to: band, key: "travel")
        }

        // Cross-fade to the secondary colour while the band crosses the middle instead of
        // flipping at exactly half way. The flip back at the wrap happens while the band is
        // off the notch, so it stays invisible.
        guard let secondaryGlow = config.secondaryGlow else { return }
        let secondaryBright = config.secondaryBright ?? config.bright
        func colourKeyframes(_ keyPath: String, _ from: Any, _ to: Any) -> CAKeyframeAnimation {
            let animation = CAKeyframeAnimation(keyPath: keyPath)
            animation.values = [from, from, to, to]
            animation.keyTimes = [0, 0.3, 0.7, 1]
            // Ease in-out across the middle, close to the old smoothstep.
            animation.timingFunctions = [CAMediaTimingFunction(name: .linear),
                                         CAMediaTimingFunction(name: .easeInEaseOut),
                                         CAMediaTimingFunction(name: .linear)]
            return animation
        }
        for (halo, style) in zip(haloLayers, Self.halos) {
            add(colourKeyframes("shadowColor", config.glow.withAlphaComponent(style.opacity).cgColor,
                                secondaryGlow.withAlphaComponent(style.opacity).cgColor), to: halo, key: "colour")
        }
        if config.tracesOutline {
            for (layer, style) in zip(traceLayers, Self.outlineLayers) {
                let from = (style.isBright ? config.bright : config.glow).withAlphaComponent(style.opacity).cgColor
                let to = (style.isBright ? secondaryBright : secondaryGlow).withAlphaComponent(style.opacity).cgColor
                add(colourKeyframes("strokeColor", from, to), to: layer, key: "colour")
            }
        } else {
            add(colourKeyframes("colors", Self.bandColors(glow: config.glow, bright: config.bright),
                                Self.bandColors(glow: secondaryGlow, bright: secondaryBright)),
                to: band, key: "colour")
        }
    }

    /// The closed band slides from fully off the leading edge to fully off the trailing edge.
    private static func bandX(_ phase: Double, width: CGFloat) -> CGFloat {
        (CGFloat(phase) * (1 + bandWidth) - bandWidth) * width
    }

    private static func bandColors(glow: NSColor, bright: NSColor) -> [CGColor] {
        [glow.withAlphaComponent(0), glow.withAlphaComponent(0.3), glow, bright, glow,
         glow.withAlphaComponent(0.3), glow.withAlphaComponent(0)].map(\.cgColor)
    }

    /// One outline segment at a phase. Its centre travels from fully before the outline's
    /// start to fully past its end (the path runs top-left, down, across and up to top-right).
    private static func segment(_ length: CGFloat, at phase: CGFloat) -> (CGFloat, CGFloat) {
        let longest = outlineLayers[0].length
        let centre = phase * (1 + longest) - longest / 2
        let from = min(max(centre - length / 2, 0), 1)
        let to = min(max(centre + length / 2, 0), 1)
        return (from, max(from, to))
    }

    /// The segment's start or end over one period, clamped to the outline: linear between
    /// the moments it enters and leaves 0…1, so keyframes there are exact.
    private static func strokeKeyframes(_ keyPath: String, length: CGFloat, end: Bool) -> CAKeyframeAnimation {
        let longest = outlineLayers[0].length
        let offset = end ? length / 2 : -length / 2
        // centre(t) + offset crosses 0 and 1 at these phases.
        let enter = (longest / 2 - offset) / (1 + longest)
        let leave = (1 + longest / 2 - offset) / (1 + longest)
        let times = ([0, enter, leave, 1] as [CGFloat]).map { min(max($0, 0), 1) }
        let value: (CGFloat) -> CGFloat = { t in
            let (from, to) = segment(length, at: t)
            return end ? to : from
        }
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.keyTimes = times.map { NSNumber(value: Double($0)) }
        animation.values = times.map(value)
        animation.calculationMode = .linear
        return animation
    }

    private static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> CGFloat {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return CGFloat(t * t * (3 - 2 * t))
    }

    private static func blend(_ from: NSColor, _ to: NSColor?, _ fraction: CGFloat) -> NSColor {
        guard let to, fraction > 0 else { return from }
        return from.blended(withFraction: fraction, of: to) ?? from
    }
}

private extension NSColor {
    var srgb: NSColor { usingColorSpace(.sRGB) ?? self }
}
