import SwiftUI

/// iPadOS's window resize grip: a short thick arc hugging the inside of a rounded bottom-right
/// corner. Here it is a toggle, not a drag: the 질문 드롭다운 grows to one larger size and back.
struct CornerResizeHandle: View {
    let cornerRadius: CGFloat
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            CornerArc(cornerRadius: cornerRadius)
                .stroke(Color.white.opacity(hovering ? 1 : 0.75),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .frame(width: cornerRadius, height: cornerRadius)
                .padding(8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The padding widens the target; the arc itself stays in the corner.
        .padding(-8)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

/// The corner's own curve (as `NotchShape` draws it), pulled in a few points and trimmed at
/// both ends so it reads as a grip rather than an outline.
private struct CornerArc: Shape {
    let cornerRadius: CGFloat
    private let inset: CGFloat = 7

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + 6, y: rect.maxY - inset))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - inset, y: rect.minY + 6),
                          control: CGPoint(x: rect.maxX - inset, y: rect.maxY - inset))
        return path
    }
}
