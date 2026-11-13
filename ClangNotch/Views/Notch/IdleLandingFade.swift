import SwiftUI

/// A collapse that lands on an idle notch has nothing left to show: the closed surface is a
/// little larger than the camera housing, so it fades out before it lands instead of leaving a
/// black rim there. The fade follows the surface's height, not the clock, so the notch stays
/// solid while it folds and only melts over its last few points. Fading by time from the start
/// had the panel see-through at half its height (reported 2026-11-14: "흐려지면서 들어감").
struct IdleLandingFade: ViewModifier, Animatable {
    /// The surface's height, animated by the collapse's own curve.
    var height: CGFloat
    let closedHeight: CGFloat
    let isLanding: Bool

    /// How far above the closed notch the surface starts to fade.
    static let reach: CGFloat = 14

    var animatableData: CGFloat {
        get { height }
        set { height = newValue }
    }

    static func opacity(height: CGFloat, closedHeight: CGFloat) -> Double {
        Double(min(1, max(0, (height - closedHeight) / reach)))
    }

    func body(content: Content) -> some View {
        content.opacity(isLanding ? Self.opacity(height: height, closedHeight: closedHeight) : 1)
    }
}
