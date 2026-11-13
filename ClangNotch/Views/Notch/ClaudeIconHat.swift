import SwiftUI

/// 설정 › 실험 기능 › "Claude 아이콘에 모자 씌우기": a small hat on a closed wing's Claude
/// icon that says what its session is busy with (아이콘 모자).
enum ClaudeIconHat: Equatable {
    case hardhat, wizard, tophat, crown

    /// A turn that has run this long wears the hard hat.
    static let longTurn: TimeInterval = 120
    /// This many subagents at once is an orchestra: the wizard hat. Fewer wear the top hat.
    static let orchestraSubagents = 3

    /// The hat of a working session, the most telling first. The crown isn't here: it goes
    /// on the Done icon.
    static func wearing(_ state: ClaudeCodeState, now: Date) -> ClaudeIconHat? {
        if state.subagents.count >= orchestraSubagents { return .wizard }
        if !state.subagents.isEmpty { return .tophat }
        if let start = state.turnStartTime, now.timeIntervalSince(start) >= longTurn { return .hardhat }
        return nil
    }

    /// When `state` will put the hard hat on, if that is still ahead.
    static func hardhatDue(_ state: ClaudeCodeState, now: Date) -> Date? {
        guard state.subagents.isEmpty, let start = state.turnStartTime else { return nil }
        let due = start.addingTimeInterval(longTurn)
        return due > now ? due : nil
    }
}

/// The hat, drawn over a Claude icon of `iconSize`: put it on top of the icon, centred. It
/// takes the icon's size in layout and draws past it. Smooth shapes, not pixels; a ring in
/// the notch's own dark/light cuts it out of the icon, like the 아이콘 지그재그 outline.
struct ClaudeIconHatView: View {
    let hat: ClaudeIconHat
    var iconSize: CGFloat = 12

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Canvas { context, size in
            // Shapes are in icon points (a 12pt icon), from the middle of the hat's base. The
            // base rests on the top rays a little right of centre, tilted.
            let unit = iconSize / 12
            let transform = CGAffineTransform(translationX: size.width / 2 + unit, y: size.height / 2 - 3.5 * unit)
                .rotated(by: 13 * .pi / 180)
                .scaledBy(x: unit, y: unit)
            let pieces = Self.pieces(hat).map { (path: $0.path.applying(transform), color: $0.color) }
            let ring = GraphicsContext.Shading.color(colorScheme == .dark ? .black : .white)
            for piece in pieces {
                context.stroke(piece.path, with: ring, style: StrokeStyle(lineWidth: 1.5 * unit, lineJoin: .round))
            }
            for piece in pieces { context.fill(piece.path, with: .color(piece.color)) }
            if hat == .crown, let points = pieces.first {
                // Rounds the crown's points.
                context.stroke(points.path, with: .color(points.color),
                               style: StrokeStyle(lineWidth: 0.45 * unit, lineJoin: .round))
            }
        }
        .frame(width: iconSize * 2, height: iconSize * 2)
        .frame(width: iconSize, height: iconSize)
        .allowsHitTesting(false)
    }

    private static func pieces(_ hat: ClaudeIconHat) -> [(path: Path, color: Color)] {
        func box(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat, _ radius: CGFloat) -> Path {
            Path(roundedRect: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0), cornerRadius: radius)
        }
        func dot(_ x: CGFloat, _ y: CGFloat, _ radius: CGFloat) -> Path {
            Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
        }
        func rgb(_ hex: UInt32) -> Color {
            Color(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
        }
        switch hat {
        case .hardhat:
            var dome = Path()
            dome.move(to: CGPoint(x: -3.1, y: 0.2))
            dome.addCurve(to: CGPoint(x: 3.1, y: 0.2), control1: CGPoint(x: -3.1, y: -4.9), control2: CGPoint(x: 3.1, y: -4.9))
            dome.closeSubpath()
            return [(dome, rgb(0xF6C624)),
                    (box(-0.75, -3.75, 0.75, 0.2, 0.7), rgb(0xFFE88A)),
                    (box(-4.1, -0.35, 4.1, 0.95, 0.65), rgb(0xE2A60B))]
        case .wizard:
            var cone = Path()
            cone.move(to: CGPoint(x: -2.7, y: 0.2))
            cone.addCurve(to: CGPoint(x: 1.5, y: -6.3), control1: CGPoint(x: -1.6, y: -2.6), control2: CGPoint(x: -0.6, y: -5.6))
            cone.addCurve(to: CGPoint(x: 2.7, y: 0.2), control1: CGPoint(x: 0.9, y: -4.4), control2: CGPoint(x: 1.9, y: -2.2))
            cone.closeSubpath()
            return [(cone, rgb(0x8A68E6)),
                    (Path(ellipseIn: CGRect(x: -4.1, y: -0.85, width: 8.2, height: 2)), rgb(0x6546C4)),
                    (dot(0.15, -2.2, 0.62), rgb(0xFFD84D))]
        case .tophat:
            // Grey, not black: it has to show on a black notch.
            return [(box(-2.5, -5, 2.5, 0.3, 0.55), rgb(0x5A5A64)),
                    (box(-2.5, -1.75, 2.5, -0.55, 0), rgb(0xF3F1EC)),
                    (box(-4, -0.35, 4, 0.85, 0.6), rgb(0x5A5A64))]
        case .crown:
            var points = Path()
            points.addLines([CGPoint(x: -3.2, y: 0.5), CGPoint(x: -3.7, y: -3.3), CGPoint(x: -1.75, y: -1.7),
                             CGPoint(x: 0, y: -3.9), CGPoint(x: 1.75, y: -1.7), CGPoint(x: 3.7, y: -3.3),
                             CGPoint(x: 3.2, y: 0.5)])
            points.closeSubpath()
            let gold = rgb(0xF4C430)
            return [(points, gold),
                    (box(-3.2, -0.75, 3.2, 0.5, 0.3), rgb(0xD79C12)),
                    (dot(-3.7, -3.3, 0.5), gold), (dot(0, -3.9, 0.5), gold), (dot(3.7, -3.3, 0.5), gold),
                    (dot(0, -0.12, 0.5), rgb(0xE8554D))]
        }
    }
}
