import SwiftUI

/// The notch silhouette: hangs from the top edge, flares out into the menu bar at the top
/// corners and rounds off at the bottom. Both radii animate, which is how the closed notch
/// grows into the open panel.
struct NotchShape: Shape {
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat
    /// Outlines leave this off so a stroke doesn't draw a line along the screen's top edge.
    var drawsTopEdge: Bool

    init(topCornerRadius: CGFloat = 6, bottomCornerRadius: CGFloat = 14, drawsTopEdge: Bool = true) {
        self.topCornerRadius = topCornerRadius
        self.bottomCornerRadius = bottomCornerRadius
        self.drawsTopEdge = drawsTopEdge
    }

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topCornerRadius, bottomCornerRadius) }
        set { (topCornerRadius, bottomCornerRadius) = (newValue.first, newValue.second) }
    }

    func path(in rect: CGRect) -> Path {
        let top = topCornerRadius, bottom = bottomCornerRadius
        // The body's sides sit `top` in from the frame; the flares fill the gap at the top.
        let left = rect.minX + top, right = rect.maxX - top
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: left, y: rect.minY + top), control: CGPoint(x: left, y: rect.minY))
        path.addLine(to: CGPoint(x: left, y: rect.maxY - bottom))
        path.addQuadCurve(to: CGPoint(x: left + bottom, y: rect.maxY), control: CGPoint(x: left, y: rect.maxY))
        path.addLine(to: CGPoint(x: right - bottom, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: right, y: rect.maxY - bottom), control: CGPoint(x: right, y: rect.maxY))
        path.addLine(to: CGPoint(x: right, y: rect.minY + top))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: right, y: rect.minY))
        if drawsTopEdge {
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        }
        return path
    }
}
