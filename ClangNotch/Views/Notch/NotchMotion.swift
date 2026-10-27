import SwiftUI

/// Springs content in on appear instead of a plain fade: `.scale` grows dropdown content
/// from 0.85 at its top edge, `.rise` lifts list rows 6pt. `delay` staggers siblings.
struct PopIn: ViewModifier {
    enum Style { case scale, rise }

    var style: Style = .scale
    var delay: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(style == .scale && !shown ? 0.85 : 1, anchor: .top)
            .offset(y: style == .rise && !shown ? 6 : 0)
            .opacity(shown ? 1 : 0)
            .onAppear {
                guard !shown else { return }
                withAnimation(reduceMotion ? .easeOut(duration: 0.12)
                              : .spring(response: 0.3, dampingFraction: 0.6).delay(delay)) {
                    shown = true
                }
            }
    }
}

/// "This is new": a 1.06× swell with a white rim that settles back after 0.45s.
struct NewHighlight: ViewModifier {
    var cornerRadius: CGFloat
    var delay: Double = 0
    var active = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lit = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(lit ? 1.06 : 1)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(lit ? 0.75 : 0), lineWidth: 1.5)
            )
            .task {
                guard active, !reduceMotion else { return }
                try? await Task.sleep(for: .seconds(delay))
                withAnimation(.spring(response: 0.25, dampingFraction: 0.55)) { lit = true }
                try? await Task.sleep(for: .seconds(0.45))
                withAnimation(.easeOut(duration: 0.3)) { lit = false }
            }
    }
}

extension View {
    func popIn(_ style: PopIn.Style = .scale, delay: Double = 0) -> some View {
        modifier(PopIn(style: style, delay: delay))
    }

    func newHighlight(cornerRadius: CGFloat, delay: Double = 0, active: Bool = true) -> some View {
        modifier(NewHighlight(cornerRadius: cornerRadius, delay: delay, active: active))
    }
}
