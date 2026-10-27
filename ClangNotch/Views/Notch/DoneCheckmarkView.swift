import SwiftUI

/// Apple Pay's confirmation mark for the closed notch's right wing: the ring draws
/// round, the tick strokes in, then the mark pops once. Give it a new `id` to replay.
struct DoneCheckmarkView: View {
    static let size: CGFloat = 14

    let color: Color
    /// Wing size by default; the 완료 드롭다운 draws it larger. Strokes scale with it.
    var size: CGFloat = Self.size
    private var unit: CGFloat { size / Self.size }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var ringProgress: CGFloat = 0
    @State private var tickProgress: CGFloat = 0
    @State private var scale: CGFloat = 1

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: ringProgress)
                .stroke(color, style: StrokeStyle(lineWidth: 1.6 * unit, lineCap: .round))
                .rotationEffect(.degrees(-90))
            CheckmarkShape()
                .trim(from: 0, to: tickProgress)
                .stroke(color, style: StrokeStyle(lineWidth: 1.8 * unit, lineCap: .round, lineJoin: .round))
                .padding(3.5 * unit)
        }
        .frame(width: size, height: size)
        .scaleEffect(scale)
        .task {
            guard !reduceMotion else {
                ringProgress = 1
                tickProgress = 1
                return
            }
            withAnimation(.easeInOut(duration: 0.5)) { ringProgress = 1 }
            try? await Task.sleep(for: .milliseconds(450))
            withAnimation(.easeOut(duration: 0.28)) { tickProgress = 1 }
            try? await Task.sleep(for: .milliseconds(280))
            withAnimation(.spring(response: 0.2, dampingFraction: 0.5)) { scale = 1.18 }
            try? await Task.sleep(for: .milliseconds(140))
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { scale = 1 }
        }
    }
}

private struct CheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.55))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.minY + rect.height * 0.88))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.15))
        return path
    }
}
