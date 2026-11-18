import AppKit
import SwiftUI

/// 노치 위치 알림 and the startup glow (2026-11-18), drawn as Core Animation layers so the render
/// server moves them: SwiftUI's repeating scale laid the whole notch out on the main thread every
/// frame (3.4% of a core while the cursor rested on the quiet notch, measured against 0.2%).
///
/// The surface (`presence`) grows out, breathes and draws back in, reaching the same distance
/// past both sides and the bottom. Over a camera housing it starts at the housing's edges (its
/// sides sit `sideInset` inside the frame, so they are pushed out by that much), grows 3 pt and
/// breathes between 3 and 6 pt; on a bare edge it grows from 8 pt inside and breathes out to
/// 3 pt. The glow is the outline lit in the startup colour, breathing with it; without the
/// surface it lies on the notch's own outline (a notch already showing its wings). Under Reduce
/// Motion both only fade.
struct NotchPresenceLayer: NSViewRepresentable {
    var presence: Bool
    /// Going away while the quiet notch stays closed: it draws back in. Otherwise (opened, or the
    /// wings came and the notch's own surface took over) it goes at once.
    var fadesOut: Bool
    var housing: Bool
    var glow: Bool
    var surfaceSize: CGSize
    var sideInset: CGFloat
    var bottomCornerRadius: CGFloat
    var surface: NSColor
    var still: Bool

    /// Room around the surface for its growth and the glow's halo, which an NSView would cut off.
    static let margin: CGFloat = 16

    func makeNSView(context: Context) -> NotchPresenceView { NotchPresenceView() }

    func updateNSView(_ view: NotchPresenceView, context: Context) {
        view.update(NotchPresenceView.Config(
            presence: presence, fadesOut: fadesOut, housing: housing, glow: glow, size: surfaceSize,
            sideInset: sideInset, bottomCornerRadius: bottomCornerRadius, surface: surface, still: still))
    }
}

extension View {
    /// Hangs a `NotchPresenceLayer` from the top of a surface `size` wide and tall, with its margin.
    func notchPresenceLayer(_ layer: NotchPresenceLayer) -> some View {
        overlay(alignment: .top) {
            layer
                .frame(width: layer.surfaceSize.width + 2 * NotchPresenceLayer.margin,
                       height: layer.surfaceSize.height + NotchPresenceLayer.margin)
                .allowsHitTesting(false)
        }
    }
}

final class NotchPresenceView: NSView {
    struct Config: Equatable {
        var presence: Bool
        var fadesOut: Bool
        var housing: Bool
        var glow: Bool
        var size: CGSize
        var sideInset: CGFloat
        var bottomCornerRadius: CGFloat
        var surface: NSColor
        var still: Bool
    }

    /// The breath: 0.8 s each way, starting once the surface has grown.
    private static let breath = 0.8
    private static var breathingStart: Double {
        let parts = ClangNotchContentView.breathingStart.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
    private static let line = NSColor(red: 0.75, green: 0.9, blue: 1.0, alpha: 1)
    /// The same blue, deeper, for the halo: the pale startup colour vanished on a light wallpaper.
    private static let halo = NSColor(red: 0.2, green: 0.55, blue: 1.0, alpha: 1)

    /// Holds everything the surface's coming and going fades.
    private let content = CALayer()
    private let surfaceLayer = CAShapeLayer()
    private let glowLayer = CALayer()
    /// The line with a tight halo, over the same line with a wide one.
    private let haloNear = CAShapeLayer()
    private let haloFar = CAShapeLayer()
    private var config: Config?
    private var showingSurface = false
    private var glowing = false
    /// When the surface's breathing began (or begins), so the glow breathes in step with it.
    private var breathBegin: CFTimeInterval = 0

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for (shape, radius, opacity) in [(haloFar, CGFloat(7), Float(0.6)), (haloNear, 3, 0.95)] {
            shape.fillColor = nil
            shape.strokeColor = Self.line.cgColor
            shape.lineWidth = 1.2
            shape.shadowColor = Self.halo.cgColor
            shape.shadowOffset = .zero
            shape.shadowRadius = radius
            shape.shadowOpacity = opacity
            glowLayer.addSublayer(shape)
        }
        content.addSublayer(surfaceLayer)
        content.addSublayer(glowLayer)
        content.opacity = 0
        glowLayer.opacity = 0
        layer?.addSublayer(content)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [content, surfaceLayer, glowLayer, haloNear, haloFar] { layer.frame = bounds }
        CATransaction.commit()
    }

    // MARK: Geometry

    /// How far the surface reaches past its own edges, by stage.
    private struct Outsets { var start, grown, breath, end: CGFloat }
    private func outsets(_ c: Config) -> Outsets {
        c.housing ? Outsets(start: 0, grown: 3, breath: 6, end: 0) : Outsets(start: -8, grown: 0, breath: 3, end: -6)
    }

    /// The outline `outset` past the surface on both sides and below. Over a housing the sides are
    /// pushed out by `sideInset` first, so outset 0 is the housing's own edges.
    private func path(_ c: Config, outset: CGFloat, surface: Bool, fill: Bool) -> CGPath {
        let base = surface && c.housing ? c.sideInset : 0
        let rect = CGRect(x: NotchPresenceLayer.margin - base - outset, y: 0,
                          width: c.size.width + 2 * (base + outset), height: c.size.height + outset)
        return NotchShape(topCornerRadius: c.sideInset, bottomCornerRadius: c.bottomCornerRadius, drawsTopEdge: fill)
            .path(in: rect).cgPath
    }

    // MARK: Updates

    func update(_ new: Config) {
        guard new != config else { return }
        let old = config
        config = new
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surfaceLayer.fillColor = new.surface.cgColor
        CATransaction.commit()

        if new.presence != showingSurface {
            new.presence ? showSurface(new) : hideSurface(new, animated: new.fadesOut && !new.still)
        } else if showingSurface, old?.size != new.size || old?.housing != new.housing || old?.sideInset != new.sideInset {
            // Resized while showing: in place at its grown size, breathing again from there.
            setOutlines(new, outset: outsets(new).grown)
            if !new.still { breathe(new, from: CACurrentMediaTime()) }
        } else if !showingSurface, glowing, old?.size != new.size || old?.sideInset != new.sideInset {
            setOutlines(new, outset: 0)
        }

        if new.glow != glowing {
            new.glow ? showGlow(new) : hideGlow()
        }
        // The glow needs the content shown even without the surface (the wings' own surface).
        if !showingSurface, glowing, content.animation(forKey: "fade") == nil {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            content.opacity = 1
            CATransaction.commit()
        }
    }

    /// Puts the surface and the glow's line at `outset` (the glow on the bare outline without the
    /// surface). No surface unless it shows: the glow alone over a notch with its wings up drew
    /// the black surface over the wings (user, 2026-11-18).
    private func setOutlines(_ c: Config, outset: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surfaceLayer.path = showingSurface ? path(c, outset: outset, surface: true, fill: true) : nil
        let line = path(c, outset: showingSurface ? outset : 0, surface: showingSurface, fill: false)
        haloNear.path = line
        haloFar.path = line
        CATransaction.commit()
    }

    private func animatePaths(_ c: Config, from: CGFloat, to: CGFloat, key: String,
                              make: () -> CABasicAnimation) {
        let pairs: [(CAShapeLayer, Bool)] = [(surfaceLayer, true), (haloNear, false), (haloFar, false)]
        for (layer, fill) in pairs {
            let animation = make()
            animation.keyPath = "path"
            animation.fromValue = path(c, outset: from, surface: true, fill: fill)
            animation.toValue = path(c, outset: to, surface: true, fill: fill)
            layer.add(animation, forKey: key)
        }
    }

    private func showSurface(_ c: Config) {
        showingSurface = true
        let o = outsets(c)
        for layer in [surfaceLayer, haloNear, haloFar] { layer.removeAllAnimations() }
        content.removeAnimation(forKey: "fade")
        let fromOpacity = content.presentation()?.opacity ?? 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.opacity = 1
        CATransaction.commit()
        setOutlines(c, outset: c.still ? 0 : o.grown)

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = fromOpacity
        fade.toValue = 1
        fade.duration = c.still ? 0.25 : 0.6
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        content.add(fade, forKey: "fade")
        guard !c.still else { return }

        animatePaths(c, from: o.start, to: o.grown, key: "grow") {
            if c.housing {
                let grow = CABasicAnimation()
                grow.duration = 0.6
                grow.timingFunction = CAMediaTimingFunction(name: .easeOut)
                return grow
            }
            let spring = CASpringAnimation(perceptualDuration: 0.5, bounce: 0.14)
            spring.duration = spring.settlingDuration
            return spring
        }
        breathe(c, from: CACurrentMediaTime() + Self.breathingStart)
    }

    /// The surface breathes from its grown outline out to `breath` and back, for as long as it shows.
    private func breathe(_ c: Config, from begin: CFTimeInterval) {
        breathBegin = begin
        let o = outsets(c)
        animatePaths(c, from: o.grown, to: o.breath, key: "breath") {
            let breath = CABasicAnimation()
            breath.beginTime = begin
            breath.duration = Self.breath
            breath.autoreverses = true
            breath.repeatCount = .infinity
            breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            return breath
        }
        if glowing { breatheGlow(from: begin) }
    }

    private func hideSurface(_ c: Config, animated: Bool) {
        showingSurface = false
        let o = outsets(c)
        let layers = [surfaceLayer, haloNear, haloFar]
        guard animated else {
            for layer in layers { layer.removeAllAnimations() }
            content.removeAnimation(forKey: "fade")
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            content.opacity = glowing ? 1 : 0
            CATransaction.commit()
            setOutlines(c, outset: 0)
            return
        }
        let current = layers.map { ($0.presentation()?.path ?? $0.path) }
        let fromOpacity = content.presentation()?.opacity ?? 1
        for layer in layers { layer.removeAllAnimations() }
        content.removeAnimation(forKey: "fade")
        let duration = c.housing ? 0.4 : 0.3

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            // Gone: back to the bare outline for a glow that may still show.
            guard let self, !self.showingSurface, let config = self.config else { return }
            self.setOutlines(config, outset: 0)
        }
        for (index, (layer, fill)) in [(surfaceLayer, true), (haloNear, false), (haloFar, false)].enumerated() {
            let end = path(c, outset: o.end, surface: true, fill: fill)
            let draw = CABasicAnimation(keyPath: "path")
            draw.fromValue = current[index]
            draw.toValue = end
            draw.duration = duration
            draw.timingFunction = CAMediaTimingFunction(name: .easeIn)
            layer.path = end
            layer.add(draw, forKey: "draw")
        }
        content.opacity = 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = fromOpacity
        fade.toValue = 0
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
        content.add(fade, forKey: "fade")
        CATransaction.commit()
    }

    private func showGlow(_ c: Config) {
        glowing = true
        glowLayer.removeAllAnimations()
        if !showingSurface { setOutlines(c, outset: 0) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glowLayer.opacity = c.still ? 1 : 0.3
        CATransaction.commit()
        guard !c.still else { return }
        breatheGlow(from: showingSurface ? breathBegin : CACurrentMediaTime() + Self.breathingStart)
    }

    private func breatheGlow(from begin: CFTimeInterval) {
        let breath = CABasicAnimation(keyPath: "opacity")
        breath.fromValue = 0.3
        breath.toValue = 1
        breath.beginTime = begin
        breath.duration = Self.breath
        breath.autoreverses = true
        breath.repeatCount = .infinity
        breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        glowLayer.add(breath, forKey: "breath")
    }

    private func hideGlow() {
        glowing = false
        let from = glowLayer.presentation()?.opacity ?? glowLayer.opacity
        glowLayer.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glowLayer.opacity = 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = 0
        fade.duration = 0.3
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        glowLayer.add(fade, forKey: "fade")
        if !showingSurface, content.animation(forKey: "fade") == nil {
            // Without the surface the content holds only the glow: let it go once that has faded.
            CATransaction.setCompletionBlock { [weak self] in
                guard let self, !self.showingSurface, !self.glowing else { return }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.content.opacity = 0
                CATransaction.commit()
            }
        }
        CATransaction.commit()
    }
}
