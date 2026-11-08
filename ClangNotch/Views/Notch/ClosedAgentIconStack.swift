import SwiftUI

/// The agent icon in a closed-notch wing, with one more copy per extra working session of
/// that agent zigzagging behind it (아이콘 지그재그). Each column outward holds an upper and a
/// lower copy; an odd one left over sits in the middle of the outermost column, so the
/// shape stays symmetric top to bottom. No backing discs: every icon is ringed in black,
/// which cuts it out of the copies behind it.
struct ClosedAgentIconStack: View {
    enum Agent { case claude, codex }

    let agent: Agent
    /// Working sessions of this agent; 1 draws the plain icon.
    let count: Int
    /// Copies spread toward the leading edge (left wing) or the trailing edge (right wing).
    let spreadsLeading: Bool
    let glowColor: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let iconSize: CGFloat = 12
    static let maxIcons = 9
    private static let columnStep: CGFloat = 9
    private static let rowOffset: CGFloat = 5

    /// The width this stack takes for `count` sessions; it grows only as copies are added.
    static func width(for count: Int) -> CGFloat {
        iconSize + columnStep * CGFloat(columns(for: count))
    }

    private static func columns(for count: Int) -> Int {
        let back = min(max(count, 1), maxIcons) - 1
        return (back + 1) / 2
    }

    private struct Copy: Identifiable {
        let id: Int
        let column: Int
        let row: CGFloat  // -1 up, 0 middle, 1 down
    }

    private var copies: [Copy] {
        let back = min(max(count, 1), Self.maxIcons) - 1
        guard back > 0 else { return [] }
        return (1...back).map { i in
            let row: CGFloat = (i == back && back % 2 == 1) ? 0 : (i % 2 == 1 ? -1 : 1)
            return Copy(id: i, column: (i + 1) / 2, row: row)
        }
    }

    var body: some View {
        let width = Self.width(for: count)
        ZStack(alignment: spreadsLeading ? .trailing : .leading) {
            // Outermost first, so each nearer icon lands on top of the ones behind it.
            ForEach(copies.reversed()) { copy in
                let column = CGFloat(copy.column)
                icon(outlined: true)
                    .scaleEffect(max(0.6, 1 - 0.1 * column))
                    .opacity(max(0.45, 1 - 0.15 * column))
                    .offset(x: (spreadsLeading ? -1 : 1) * Self.columnStep * column,
                            y: copy.row * Self.rowOffset)
                    // Scales about the front icon (the offset leaves the frame there), so a
                    // new session's copy springs out from behind it and a finished one
                    // shrinks back into it.
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.1).combined(with: .opacity))
            }
            // The lone icon keeps its soft glow; on a stack the glow would wrap the black
            // ring too and swell into an orange blob behind the front icon.
            icon(outlined: count > 1)
                .shadow(color: glowColor.opacity(count > 1 ? 0 : 0.6), radius: 3)
        }
        .frame(width: width, height: Self.iconSize + Self.rowOffset * 2,
               alignment: spreadsLeading ? .trailing : .leading)
        // Bouncy when a session joins or leaves; copies that change row (the odd middle
        // one splitting into a pair) spring to their new place too.
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.42, dampingFraction: 0.5),
                   value: count)
    }

    @ViewBuilder
    private func icon(outlined: Bool) -> some View {
        ZStack {
            if outlined {
                // A ring in the notch's own dark/light around the silhouette: eight offset copies, like a text stroke.
                ForEach(0..<8, id: \.self) { step in
                    let angle = Double(step) * .pi / 4
                    base.renderingMode(.template)
                        .foregroundColor(NotchPalette.inkInverse)
                        .frame(width: Self.iconSize, height: Self.iconSize)
                        .offset(x: cos(angle) * 1.2, y: sin(angle) * 1.2)
                }
            }
            switch agent {
            case .claude:
                base.frame(width: Self.iconSize, height: Self.iconSize)
            case .codex:
                base.renderingMode(.template)
                    .foregroundColor(NotchPalette.ink)
                    .frame(width: Self.iconSize, height: Self.iconSize)
            }
        }
    }

    private var base: Image {
        Image(agent == .claude ? "ClaudeIcon" : "ChatGPTIcon").resizable()
    }
}
