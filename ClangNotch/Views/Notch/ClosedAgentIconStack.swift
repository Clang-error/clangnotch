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
    /// 아이콘 모자: the front icon's hat, then one per copy in order; empty draws none.
    var hats: [ClaudeIconHat?] = []
    /// Background shells running: a blue chip with a terminal, and their number from two on,
    /// between the icons and the label (2026-11-26: a mark on the icon's corner covered the
    /// zigzag and squeezed its number). It widens the stack by `chipWidth` and a gap.
    var shells = 0
    /// Copies spread toward the leading edge (left wing) or the trailing edge (right wing).
    let spreadsLeading: Bool
    let glowColor: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let iconSize: CGFloat = 12
    static let maxIcons = 9
    private static let columnStep: CGFloat = 9
    private static let rowOffset: CGFloat = 5

    /// The width this stack takes for `count` sessions and `shells` background shells; it grows
    /// only as copies or the shell chip are added.
    static func width(for count: Int, shells: Int = 0) -> CGFloat {
        iconsWidth(for: count) + (shells > 0 ? chipGap + chipWidth(for: shells) : 0)
    }

    private static func iconsWidth(for count: Int) -> CGFloat {
        iconSize + columnStep * CGFloat(columns(for: count))
    }

    private static let chipGap: CGFloat = 4
    /// Fixed per digit count, so the wing's width math needn't measure it.
    static func chipWidth(for shells: Int) -> CGFloat {
        shells <= 1 ? 14 : shells < 10 ? 21 : 26
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
        // The chip sits on the label's side: after the icons in the left wing, before them in the right.
        HStack(spacing: Self.chipGap) {
            if shells > 0, !spreadsLeading { shellChip }
            icons
            if shells > 0, spreadsLeading { shellChip }
        }
        .frame(width: Self.width(for: count, shells: shells), alignment: spreadsLeading ? .trailing : .leading)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.3, dampingFraction: 0.6),
                   value: shells)
    }

    private var icons: some View {
        let width = Self.iconsWidth(for: count)
        return ZStack(alignment: spreadsLeading ? .trailing : .leading) {
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
            // Hats go on once every copy is down: within a column the upper icon is drawn
            // over the lower one and would bury its hat. They fade less than their icons,
            // to stay readable.
            ForEach(copies.reversed()) { copy in
                if let hat = hat(at: copy.id) {
                    let column = CGFloat(copy.column)
                    ClaudeIconHatView(hat: hat, iconSize: Self.iconSize)
                        .scaleEffect(max(0.6, 1 - 0.1 * column))
                        .opacity(max(0.75, 1 - 0.15 * column))
                        .offset(x: (spreadsLeading ? -1 : 1) * Self.columnStep * column,
                                y: copy.row * Self.rowOffset)
                        .transition(hatTransition)
                }
            }
            // The lone icon keeps its soft glow; on a stack the glow would wrap the black
            // ring too and swell into an orange blob behind the front icon.
            icon(outlined: count > 1)
                .shadow(color: glowColor.opacity(count > 1 ? 0 : 0.6), radius: 3)
            if let hat = hat(at: 0) {
                ClaudeIconHatView(hat: hat, iconSize: Self.iconSize)
                    .transition(hatTransition)
            }
        }
        .frame(width: width, height: Self.iconSize + Self.rowOffset * 2,
               alignment: spreadsLeading ? .trailing : .leading)
        // Bouncy when a session joins or leaves; copies that change row (the odd middle
        // one splitting into a pair) spring to their new place too.
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.42, dampingFraction: 0.5),
                   value: count)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.3, dampingFraction: 0.6),
                   value: hats)
    }

    private var shellChip: some View {
        let blue = Color(red: 0.35, green: 0.7, blue: 1.0)
        return HStack(spacing: 1.5) {
            Image(systemName: "apple.terminal.fill")
                .font(.system(size: 7, weight: .bold))
            if shells > 1 {
                Text("\(shells)")
                    .font(.system(size: 7.5, weight: .bold).monospacedDigit())
            }
        }
        .foregroundColor(blue)
        .frame(width: Self.chipWidth(for: shells), height: 12)
        .background(blue.opacity(0.18), in: Capsule())
        .transition(hatTransition)
    }

    private func hat(at index: Int) -> ClaudeIconHat? {
        hats.indices.contains(index) ? hats[index] : nil
    }

    private var hatTransition: AnyTransition {
        reduceMotion ? .opacity : .scale(scale: 0.3).combined(with: .opacity)
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
