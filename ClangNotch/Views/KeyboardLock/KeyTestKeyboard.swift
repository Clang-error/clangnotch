import SwiftUI

/// The Key Test card's keyboard: a MacBook (ANSI) layout whose keys light up while held.
struct KeyTestKeyboard: View {
    @ObservedObject var tester: KeyTester

    private struct Key: Identifiable {
        let label: String
        /// Virtual key codes that light this key (the F row also has its media function's code).
        let codes: [Int]
        var width: CGFloat = 1
        var id: String { label + codes.map(String.init).joined(separator: ",") }
    }

    private static let gap: CGFloat = 4
    private static let height: CGFloat = 24
    private static let functionHeight: CGFloat = 18

    private static func row(_ pairs: [(String, Int)]) -> [Key] { pairs.map { Key(label: $0.0, codes: [$0.1]) } }

    private static let functionRow: [Key] = [Key(label: "esc", codes: [53], width: 1.5)]
        + [("F1", [122]), ("F2", [120]), ("F3", [99, 160]), ("F4", [118, 177, 131]), ("F5", [96, 176]),
           ("F6", [97, 178]), ("F7", [98]), ("F8", [100]), ("F9", [101]), ("F10", [109]), ("F11", [103]),
           ("F12", [111])].map { Key(label: $0.0, codes: $0.1) }
        + [Key(label: "", codes: [])]  // Touch ID: no key code

    private static let rows: [[Key]] = [
        row([("`", 50), ("1", 18), ("2", 19), ("3", 20), ("4", 21), ("5", 23), ("6", 22), ("7", 26),
             ("8", 28), ("9", 25), ("0", 29), ("-", 27), ("=", 24)])
            + [Key(label: "⌫", codes: [51], width: 1.5)],
        [Key(label: "⇥", codes: [48], width: 1.5)]
            + row([("Q", 12), ("W", 13), ("E", 14), ("R", 15), ("T", 17), ("Y", 16), ("U", 32), ("I", 34),
                   ("O", 31), ("P", 35), ("[", 33), ("]", 30), ("\\", 42)]),
        [Key(label: "⇪", codes: [57], width: 1.75)]
            + row([("A", 0), ("S", 1), ("D", 2), ("F", 3), ("G", 5), ("H", 4), ("J", 38), ("K", 40),
                   ("L", 37), (";", 41), ("'", 39)])
            + [Key(label: "↩", codes: [36], width: 1.75)],
        [Key(label: "⇧", codes: [56], width: 2.25)]
            + row([("Z", 6), ("X", 7), ("C", 8), ("V", 9), ("B", 11), ("N", 45), ("M", 46), (",", 43),
                   (".", 47), ("/", 44)])
            + [Key(label: "⇧", codes: [60], width: 2.25)],
    ]

    private static let bottomRow: [Key] = [
        Key(label: "fn", codes: [63]), Key(label: "⌃", codes: [59]), Key(label: "⌥", codes: [58]),
        Key(label: "⌘", codes: [55], width: 1.25), Key(label: "", codes: [49], width: 5),
        Key(label: "⌘", codes: [54], width: 1.25), Key(label: "⌥", codes: [61]),
    ]
    private static let left = Key(label: "◀", codes: [123])
    private static let up = Key(label: "▲", codes: [126])
    private static let down = Key(label: "▼", codes: [125])
    private static let right = Key(label: "▶", codes: [124])

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            VStack(spacing: Self.gap) {
                keyRow(Self.functionRow, width: width, height: Self.functionHeight)
                ForEach(Self.rows.indices, id: \.self) { keyRow(Self.rows[$0], width: width, height: Self.height) }
                bottom(width: width)
            }
        }
        .frame(height: Self.functionHeight + Self.height * 5 + Self.gap * 5)
    }

    /// Each row fills the full width; widths are shares of the row's own units.
    private func unit(_ keys: [Key], extraUnits: CGFloat = 0, extraKeys: Int = 0, width: CGFloat) -> CGFloat {
        let units = keys.reduce(0) { $0 + $1.width } + extraUnits
        return (width - Self.gap * CGFloat(keys.count + extraKeys - 1)) / units
    }

    private func keyRow(_ keys: [Key], width: CGFloat, height: CGFloat) -> some View {
        let unit = unit(keys, width: width)
        return HStack(spacing: Self.gap) {
            ForEach(keys) { cap($0, width: unit * $0.width, height: height) }
        }
    }

    /// Modifiers, space, then the inverted-T arrows with ▲ over ▼ in one column.
    private func bottom(width: CGFloat) -> some View {
        let unit = unit(Self.bottomRow, extraUnits: 3, extraKeys: 3, width: width)
        let half = (Self.height - 2) / 2
        return HStack(spacing: Self.gap) {
            ForEach(Self.bottomRow) { cap($0, width: unit * $0.width, height: Self.height) }
            cap(Self.left, width: unit, height: half).frame(height: Self.height, alignment: .bottom)
            VStack(spacing: 2) {
                cap(Self.up, width: unit, height: half)
                cap(Self.down, width: unit, height: half)
            }
            cap(Self.right, width: unit, height: half).frame(height: Self.height, alignment: .bottom)
        }
    }

    private func cap(_ key: Key, width: CGFloat, height: CGFloat) -> some View {
        let lit = key.codes.contains { tester.pressed.contains($0) }
        // Released keys keep a fainter glow for 2 seconds, then fade out.
        let glow = !lit && key.codes.contains { tester.afterglow.contains($0) }
        return Text(key.label)
            .font(.system(size: key.label.count > 1 ? 8 : 10, weight: .medium))
            .foregroundColor(lit ? .black : .white.opacity(glow ? 0.9 : 0.6))
            .frame(width: max(0, width), height: height)
            .background(lit ? Color.white : Color.white.opacity(glow ? 0.35 : 0.06),
                        in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(Color.white.opacity(lit || glow ? 0 : 0.08), lineWidth: 1))
            // On at once; down to the afterglow quickly, out of it slowly.
            .animation(lit ? nil : .easeOut(duration: glow ? 0.15 : 0.5), value: lit ? 2 : glow ? 1 : 0)
    }
}
