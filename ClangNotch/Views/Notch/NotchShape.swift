import SwiftUI

/// The notch silhouette: hangs from the top edge, flares out into the menu bar at the top
/// corners and rounds off at the bottom. Both radii animate, which is how the closed notch
/// grows into the open panel.
struct NotchShape: Shape {
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat
    /// Outlines leave this off so a stroke doesn't draw a line along the screen's top edge.
    var drawsTopEdge: Bool
    /// 열리는 곳 표시 (`WingOpenHint`): a tab hanging from the middle of the bottom edge, which
    /// the outline goes round, so the glow runs along the tab too instead of past it. Width 0
    /// for none; `tabProgress` 0…1 is how far it has grown out of the edge.
    var tabWidth: CGFloat = 0
    var tabProgress: CGFloat = 0
    static let tabDepth: CGFloat = 19
    /// The concave curve where the tab leaves the edge, and its own bottom corners. The curve
    /// is small: at 7 the tab's top flared out like ears on a light window, and with none it
    /// broke off the edge at a right angle (user, 2026-11-14).
    static let tabFillet: CGFloat = 4
    static let tabCorner: CGFloat = 7
    /// 다이내믹 아일랜드 (`NotchIsland`): the body floats, so its top corners round outward like
    /// the bottom ones, `bottomCornerRadius` each, and the outline always closes along the top.
    /// The sides stay `topCornerRadius` in from the frame, so every width worked out for the
    /// notch (`expandedNotchInset`, `mediaNotchWidth`) holds.
    var island: Bool

    init(topCornerRadius: CGFloat = 6, bottomCornerRadius: CGFloat = 14, drawsTopEdge: Bool = true, island: Bool = false) {
        self.topCornerRadius = topCornerRadius
        self.bottomCornerRadius = bottomCornerRadius
        self.drawsTopEdge = drawsTopEdge
        self.island = island
    }

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topCornerRadius, bottomCornerRadius) }
        set { (topCornerRadius, bottomCornerRadius) = (newValue.first, newValue.second) }
    }

    func path(in rect: CGRect) -> Path {
        island ? islandPath(in: rect) : notchPath(in: rect)
    }

    private func notchPath(in rect: CGRect) -> Path {
        let top = topCornerRadius, bottom = bottomCornerRadius
        // The body's sides sit `top` in from the frame; the flares fill the gap at the top.
        let left = rect.minX + top, right = rect.maxX - top
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: left, y: rect.minY + top), control: CGPoint(x: left, y: rect.minY))
        path.addLine(to: CGPoint(x: left, y: rect.maxY - bottom))
        path.addQuadCurve(to: CGPoint(x: left + bottom, y: rect.maxY), control: CGPoint(x: left, y: rect.maxY))
        addTab(to: &path, in: rect)
        path.addLine(to: CGPoint(x: right - bottom, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: right, y: rect.maxY - bottom), control: CGPoint(x: right, y: rect.maxY))
        path.addLine(to: CGPoint(x: right, y: rect.minY + top))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: right, y: rect.minY))
        if drawsTopEdge {
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        }
        return path
    }

    /// Round corners all the way round, circular arcs so the closed pill is a true capsule.
    private func islandPath(in rect: CGRect) -> Path {
        let left = rect.minX + topCornerRadius, right = rect.maxX - topCornerRadius
        let radius = max(0, min(bottomCornerRadius, rect.height / 2, (right - left) / 2))
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: left, y: rect.minY), tangent2End: CGPoint(x: left, y: rect.maxY), radius: radius)
        path.addArc(tangent1End: CGPoint(x: left, y: rect.maxY), tangent2End: CGPoint(x: right, y: rect.maxY), radius: radius)
        addTab(to: &path, in: rect)
        path.addArc(tangent1End: CGPoint(x: right, y: rect.maxY), tangent2End: CGPoint(x: right, y: rect.minY), radius: radius)
        path.addArc(tangent1End: CGPoint(x: right, y: rect.minY), tangent2End: CGPoint(x: rect.midX, y: rect.minY), radius: radius)
        path.closeSubpath()
        return path
    }

    /// The 열리는 곳 표시 tab along the bottom edge, drawn left to right.
    private func addTab(to path: inout Path, in rect: CGRect) {
        if tabWidth > 0 {
            let from = rect.midX - tabWidth / 2, to = rect.midX + tabWidth / 2
            let fillet = Self.tabFillet, corner = Self.tabCorner, depth = Self.tabDepth
            func y(_ down: CGFloat) -> CGFloat { rect.maxY + down * tabProgress }
            path.addLine(to: CGPoint(x: from, y: rect.maxY))
            path.addQuadCurve(to: CGPoint(x: from + fillet, y: y(fillet)), control: CGPoint(x: from + fillet, y: rect.maxY))
            path.addLine(to: CGPoint(x: from + fillet, y: y(depth - corner)))
            path.addQuadCurve(to: CGPoint(x: from + fillet + corner, y: y(depth)), control: CGPoint(x: from + fillet, y: y(depth)))
            path.addLine(to: CGPoint(x: to - fillet - corner, y: y(depth)))
            path.addQuadCurve(to: CGPoint(x: to - fillet, y: y(depth - corner)), control: CGPoint(x: to - fillet, y: y(depth)))
            path.addLine(to: CGPoint(x: to - fillet, y: y(fillet)))
            path.addQuadCurve(to: CGPoint(x: to, y: rect.maxY), control: CGPoint(x: to - fillet, y: rect.maxY))
        }
    }
}

extension EnvironmentValues {
    /// The notch is the 다이내믹 아일랜드 (`NotchIsland`): the glow and presence layers under it
    /// draw `NotchShape(island: true)`. Set once on the surface by `ClangNotchContentView`.
    @Entry var notchIsland = false
}
