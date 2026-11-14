import SwiftUI

/// 날개 비켜 주기's 툴팁 (설정 › 노치 › 툴팁 표시): while a wing steps aside, a tab grows out of
/// the notch's bottom edge and says where to go to open it, so the boundary between "steps
/// aside" and "opens" isn't left to guesswork (user, 2026-11-14). It sits just under the notch,
/// since the camera housing itself shows nothing. The tab is filled like the notch and the
/// notch's glow goes round it (`NotchShape.tabWidth`), so the two read as one shape: a tab with
/// a rim of its own looked stuck on. An arrow alone didn't say what happens.
struct WingOpenHint: View {
    static let animation = Animation.spring(response: 0.3, dampingFraction: 0.75)

    /// "여기" pointed at the tab itself, which opens nothing, and "노치" is what people call the
    /// wings too: the middle is the one place meant.
    private static var words: String { L("가운데에 올려서 펼치기", "Hover the middle to open") }
    private static let font = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
    private static let arrowWidth: CGFloat = 9
    private static let spacing: CGFloat = 4
    private static var measured: (words: String, width: CGFloat)?

    /// The tab's width, for the glow's outline as well: the words measured, the arrow, and the
    /// room either side past the fillets.
    static var tabWidth: CGFloat {
        let words = words
        if let measured, measured.words == words { return measured.width }
        let text = ceil(NSAttributedString(string: words, attributes: [.font: font]).size().width)
        let width = text + arrowWidth + spacing + 2 * (NotchShape.tabFillet + 9)
        measured = (words, width)
        return width
    }

    let notchHeight: CGFloat
    let shown: Bool
    /// The notch's surface.
    var surface: Color = .black

    var body: some View {
        HStack(spacing: Self.spacing) {
            Image(systemName: "chevron.up")
                .font(.system(size: 8, weight: .heavy))
                .frame(width: Self.arrowWidth)
            Text(Self.words)
                .font(Font(Self.font))
                .fixedSize()
        }
        .foregroundStyle(NotchPalette.ink.opacity(0.9))
        .frame(width: Self.tabWidth, height: NotchShape.tabDepth)
        // Inside the glow's line instead of under half of it: the fill draws over the glow
        // (an AppKit layer view, whatever the overlays' order), and covering the line's inner
        // half left it half as thick round the tab as along the notch, pinched to a point where
        // the two met (user, 2026-11-14).
        .background { NotchTab(inset: NotchGlowLayerView.lineWidth / 2).fill(surface) }
        .scaleEffect(y: shown ? 1 : 0.01, anchor: .top)
        .padding(.top, notchHeight)
        .opacity(shown ? 1 : 0)
        .animation(Self.animation, value: shown)
        .allowsHitTesting(false)
    }
}

/// The tab `NotchShape` draws an outline round, filled: concave fillets where it leaves the
/// notch's edge, rounded bottom corners. `inset` keeps it that far inside the outline all the
/// way round, and it starts that far up in the notch.
private struct NotchTab: Shape {
    let inset: CGFloat

    func path(in rect: CGRect) -> Path {
        // The same curves as the outline's, so the two stay the line's half-width apart.
        let fillet = NotchShape.tabFillet + inset, r = max(NotchShape.tabCorner - inset, 0)
        let left = rect.minX + fillet, right = rect.maxX - fillet
        let top = rect.minY - inset, mouth = rect.minY + NotchShape.tabFillet, bottom = rect.maxY - inset
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: top))
        path.addQuadCurve(to: CGPoint(x: left, y: mouth), control: CGPoint(x: left, y: top))
        path.addLine(to: CGPoint(x: left, y: bottom - r))
        path.addQuadCurve(to: CGPoint(x: left + r, y: bottom), control: CGPoint(x: left, y: bottom))
        path.addLine(to: CGPoint(x: right - r, y: bottom))
        path.addQuadCurve(to: CGPoint(x: right, y: bottom - r), control: CGPoint(x: right, y: bottom))
        path.addLine(to: CGPoint(x: right, y: mouth))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: top), control: CGPoint(x: right, y: top))
        path.closeSubpath()
        return path
    }
}
