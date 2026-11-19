import SwiftUI

/// 날개에만 (설정 -> 기능 -> 배터리 알림 -> 에어팟 드롭다운 표시): the 에어팟 드롭다운's card drawn in
/// the closed notch's wings instead of coming down. The left wing holds the buds, the right wing
/// the case, its ring toward the notch and its picture at the outer edge; each level is a ring
/// with the number inside (user's mock-ups, 2026-11-19). What shows follows the card
/// (`AirPodsDropdownContent`): the pair turning with one level (the lower bud), one bud each with
/// its own level while one charges in the case, a single bud, a Max or a headset.
@MainActor
struct ClosedAirPodsWings {
    /// The card it was laid out from, so the same card isn't laid out again.
    let card: AirPodsDropdown.Card
    /// Built once per card (the art lookups touch the disk), not on every redraw of the wings.
    let left: [Piece]
    let right: [Piece]
    let leftWidth: CGFloat
    let rightWidth: CGFloat

    /// `notchHeight`: the closed bar's height. A screen without a notch has only the menu bar's
    /// (about 25 pt), so the art shrinks to fit it.
    init(card: AirPodsDropdown.Card, notchHeight: CGFloat) {
        self.card = card
        let layout = Layout(card: card, artHeight: min(30, notchHeight - 2), budHeight: min(26, notchHeight - 4))
        left = layout.left
        right = layout.right
        leftWidth = left.reduce(0) { $0 + $1.width }
        rightWidth = right.reduce(0) { $0 + $1.width }
    }

    enum Piece {
        /// One of macOS's banner loops. They are framed loosely: drawn `zoom` times the box's
        /// height, centred, in a box `aspect` times as wide as it is tall.
        case video(URL, height: CGFloat, zoom: CGFloat, aspect: CGFloat)
        case image(NSImage, height: CGFloat)
        case symbol(String, height: CGFloat)
        case ring(level: Int, charging: Bool)
        case gap(CGFloat)

        var width: CGFloat {
            switch self {
            case .video(_, let height, _, let aspect): return ceil(height * aspect)
            case .image(let image, let height):
                return image.size.height > 0 ? ceil(image.size.width / image.size.height * height) : height
            case .symbol(_, let height): return height
            case .ring: return AirPodsLevelRing.width
            case .gap(let gap): return gap
            }
        }
    }

    /// Which pieces go in which wing, for one card.
    @MainActor
    private struct Layout {
        let card: AirPodsDropdown.Card
        /// The pair or the Max turning, and a still bud or the case.
        let artHeight: CGFloat
        let budHeight: CGFloat

        private var kind: AirPodsArt.Kind? { AirPodsArt.kind(for: card.productID) }
        private var hasCase: Bool { kind == .buds && card.caseLevel != nil }

        var left: [Piece] {
            if kind == .buds && card.symbol == nil && card.splitsBuds {
                return bud(left: true) + [.gap(8)] + bud(left: false)
            }
            // With no case to show, the level goes to the right wing so the two stay balanced.
            return hasCase ? [art] + (deviceRing.map { [.gap(4), $0] } ?? []) : [art]
        }

        var right: [Piece] {
            if hasCase, let caseLevel = card.caseLevel {
                return [.ring(level: caseLevel, charging: card.caseCharging), .gap(4), caseArt]
            }
            if kind == .buds && card.symbol == nil && card.splitsBuds { return [] }
            return deviceRing.map { [$0] } ?? []
        }

        private func bud(left: Bool) -> [Piece] {
            let image: Piece = AirPodsArt.singleBud(for: card.productID, left: left).map { .image($0, height: budHeight) }
                ?? .symbol(AirPodsArt.deviceSymbol(for: card.productID), height: budHeight)
            guard let level = left ? card.leftLevel : card.rightLevel else { return [image] }
            return [image, .gap(3), .ring(level: level, charging: left ? card.leftCharging : card.rightCharging)]
        }

        /// The device as the card draws it: one bud, a headset's symbol, or the pair or the Max turning.
        private var art: Piece {
            if let side = card.side, let bud = AirPodsArt.singleBud(for: card.productID, left: side == "L") {
                return .image(bud, height: budHeight)
            }
            if let symbol = card.symbol { return .symbol(symbol, height: budHeight) }
            if card.side == nil, let video = AirPodsArt.bannerVideo(for: card.productID, color: card.color) {
                // From each loop's drawn area over all its frames (2026-11-19): the Pro 2 pair spans
                // 95% of the frame across and 57% down as it turns, a Max 81% and 91%. Zoomed so it
                // fills 94% of the box's height, with the box as wide as it then is: the first
                // guess (1.75, 1.45) cut the pair's sides as the buds turned apart.
                return kind == .headphones
                    ? .video(video, height: artHeight, zoom: 1.03, aspect: 0.86)
                    : .video(video, height: artHeight, zoom: 1.65, aspect: 1.6)
            }
            if let still = AirPodsArt.frontPair(for: card.productID) ?? AirPodsArt.device(for: card.productID, color: card.color) {
                return .image(still, height: budHeight)
            }
            return .symbol(AirPodsArt.deviceSymbol(for: card.productID), height: budHeight)
        }

        private var deviceRing: Piece? {
            guard let level = card.level else { return nil }
            let charging = card.side.map { $0 == "L" ? card.leftCharging : card.rightCharging }
                ?? (card.leftCharging && card.rightCharging)
            return .ring(level: level, charging: charging)
        }

        private var caseArt: Piece {
            if let video = AirPodsArt.bannerVideo(for: card.productID, isCase: true, color: card.color) {
                // The case loop spans 89% across and 67% down: 84% of the box's height, 1.12 wide.
                return .video(video, height: budHeight, zoom: 1.25, aspect: 1.15)
            }
            if let still = AirPodsArt.chargingCase { return .image(still, height: budHeight - 4) }
            return .symbol("airpods.chargingcase", height: budHeight - 4)
        }
    }

    /// One wing's pieces in a row, at the widths `leftWidth` and `rightWidth` add up.
    struct Row: View {
        let pieces: [Piece]

        var body: some View {
            HStack(spacing: 0) {
                ForEach(Array(pieces.enumerated()), id: \.offset) { _, piece in
                    switch piece {
                    case .video(let url, let height, let zoom, _):
                        LoopingVideo(url: url, zoom: zoom)
                            .frame(width: piece.width, height: height)
                    case .image(let image, let height):
                        Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                            .frame(width: piece.width, height: height)
                    case .symbol(let name, let height):
                        Image(systemName: name).resizable().scaledToFit()
                            .foregroundColor(NotchPalette.ink.opacity(0.8))
                            .padding(height * 0.12)
                            .frame(width: height, height: height)
                    case .ring(let level, let charging):
                        AirPodsLevelRing(level: level, charging: charging)
                    case .gap(let gap):
                        Spacer().frame(width: gap)
                    }
                }
            }
        }
    }
}

/// A level as a ring that fills clockwise from the top, the number inside. Charging opens the
/// ring at the top and sets a bolt in the gap; green while charging, red at 20% and below.
struct AirPodsLevelRing: View {
    let level: Int
    let charging: Bool

    static let width: CGFloat = 24
    private static let diameter: CGFloat = 22
    private static let line: CGFloat = 2.4
    /// How much of the turn the bolt's gap takes on each side of the top.
    private static let boltGap: CGFloat = 26 / 360

    var body: some View {
        let gap = charging ? Self.boltGap : 0
        let filled = gap + (1 - 2 * gap) * CGFloat(min(max(level, 0), 100)) / 100
        let color: Color = level <= 20 ? .red : charging ? .green : NotchPalette.ink
        ZStack {
            Group {
                Circle().trim(from: gap, to: 1 - gap)
                    .stroke(NotchPalette.ink.opacity(0.16), style: StrokeStyle(lineWidth: Self.line, lineCap: charging ? .round : .butt))
                Circle().trim(from: gap, to: filled)
                    .stroke(color, style: StrokeStyle(lineWidth: Self.line, lineCap: .round))
            }
            .rotationEffect(.degrees(-90))
            .padding(Self.line / 2)
            if charging {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 7, weight: .heavy))
                    .foregroundColor(.green)
                    .offset(y: -(Self.diameter - Self.line) / 2)
            }
            // The number stays where it is whether or not the bolt shows (user, 2026-11-19).
            Text("\(level)")
                .font(.system(size: level >= 100 ? 7.5 : 9, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundColor(NotchPalette.ink)
                .fixedSize()
        }
        .frame(width: Self.diameter, height: Self.diameter)
        .frame(width: Self.width)
    }
}
