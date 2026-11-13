import Foundation

@main
struct IdleLandingFadeChecks {
    /// y of a cubic Bezier timing curve at time fraction `x`.
    static func curve(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, at x: Double) -> Double {
        var low = 0.0, high = 1.0
        for _ in 0..<60 {
            let t = (low + high) / 2
            let bx = 3 * (1 - t) * (1 - t) * t * x1 + 3 * (1 - t) * t * t * x2 + t * t * t
            if bx < x { low = t } else { high = t }
        }
        let t = (low + high) / 2
        return 3 * (1 - t) * (1 - t) * t * y1 + 3 * (1 - t) * t * t * y2 + t * t * t
    }

    static func main() {
        let closed: CGFloat = 32
        func opacity(_ height: CGFloat) -> Double { IdleLandingFade.opacity(height: height, closedHeight: closed) }

        precondition(opacity(232) == 1 && opacity(closed + IdleLandingFade.reach) == 1, "Solid until the last few points")
        precondition(opacity(closed) == 0 && opacity(closed - 2) == 0, "Gone when it lands")
        precondition(abs(opacity(closed + IdleLandingFade.reach / 2) - 0.5) < 1e-9, "Halfway through the reach, half faded")

        // The panel closing (`notchCloseAnimation`) and a dropdown folding (`dropdownFoldAnimation`),
        // from 200pt above the closed notch: solid for as long as the surface is still large.
        for (name, x1, y1, x2, y2) in [("close", 0.25, 0.8, 0.35, 1.0), ("fold", 0.4, 0.0, 0.2, 1.0)] {
            var last = 1.0
            for step in 0...100 {
                let height = closed + 200 * CGFloat(1 - curve(x1, y1, x2, y2, at: Double(step) / 100))
                let value = opacity(height)
                precondition(value <= last + 1e-9, "\(name): never comes back")
                if height > closed + 40 { precondition(value == 1, "\(name): see-through at \(height)pt") }
                last = value
            }
            precondition(last == 0, "\(name): clear at the end")
        }
        print("PASS: idle landing fade: solid while the surface folds, fades over its last points, for both collapse curves")
    }
}
