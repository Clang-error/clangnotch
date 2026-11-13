import SwiftUI

/// A closed wing steps aside while the cursor rests on it (`UICoordinator.hoveredWing`): from
/// the physical notch's edge outward it melts into the menu bar, glow included, and clicks go to
/// what is underneath. macOS 27.2.1 puts the menu bar's `[<<]` right next to the notch, where the
/// right wing covered it (reported 2026-11-13).
struct WingFade: Equatable {
    /// The physical notch, which never fades.
    var notchWidth: CGFloat
    /// 0 solid … 1 stepped aside, per side.
    var left: Double = 0
    var right: Double = 0

    /// How far out from the notch's edge the wing takes to melt away, and what is left of it.
    static let ramp: CGFloat = 30
    static let floor: Double = 0.07
    static let animation = Animation.easeOut(duration: 0.2)

    var isSolid: Bool { left == 0 && right == 0 }

    /// Opacity stops across a span of `width` centred on the notch: solid over it, easing down
    /// over `ramp` on a side that steps aside.
    func stops(width: CGFloat) -> [(location: CGFloat, opacity: Double)] {
        guard width > 0 else { return [(0, 1), (1, 1)] }
        let centre = width / 2, half = notchWidth / 2
        // Smoothstep at four points, so the ramp eases in and out instead of bending at its ends.
        let ease: [(t: CGFloat, s: Double)] = [(0, 0), (1.0 / 3, 0.259), (2.0 / 3, 0.741), (1, 1)]
        func opacity(_ side: Double, _ s: Double) -> Double { 1 - side * (1 - Self.floor) * s }
        var stops: [(CGFloat, Double)] = []
        for point in ease.reversed() {       // left side, outer end first
            stops.append(((centre - half - Self.ramp * point.t) / width, opacity(left, point.s)))
        }
        for point in ease {                  // right side, from the notch's edge out
            stops.append(((centre + half + Self.ramp * point.t) / width, opacity(right, point.s)))
        }
        // A wing narrower than the ramp puts stops off the span: keep them on it, in order.
        var last: CGFloat = 0
        return stops.map { stop in
            last = max(last, min(max(stop.0, 0), 1))
            return (last, stop.1)
        }
    }
}

/// `WingFade` as a mask: white where the notch shows. Animatable, so a wing melts away over
/// `WingFade.animation` instead of jumping.
struct WingFadeMask: View, Animatable {
    var fade: WingFade

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(fade.left, fade.right) }
        set { (fade.left, fade.right) = (newValue.first, newValue.second) }
    }

    var body: some View {
        if fade.isSolid {
            Rectangle().fill(.white)
        } else {
            GeometryReader { proxy in
                LinearGradient(stops: fade.stops(width: proxy.size.width).map {
                    Gradient.Stop(color: .white.opacity($0.opacity), location: $0.location)
                }, startPoint: .leading, endPoint: .trailing)
            }
        }
    }
}
