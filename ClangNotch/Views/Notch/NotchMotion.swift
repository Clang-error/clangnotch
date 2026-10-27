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

/// A working session row: the notch's travelling glow, going round the row's outline over a
/// faint steady rim. Under Reduce Motion only the rim stays.
struct TracingGlowOutline: View {
    var cornerRadius: CGFloat
    var color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        TimelineView(.animation(minimumInterval: 1.0 / 25.0, paused: reduceMotion)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3) / 3
            shape
                .strokeBorder(AngularGradient(stops: [
                    .init(color: color.opacity(0), location: 0),
                    .init(color: color.opacity(reduceMotion ? 0 : 0.55), location: 0.1),
                    .init(color: color.opacity(0), location: 0.25),
                    .init(color: color.opacity(0), location: 1),
                ], center: .center, angle: .degrees(phase * 360)), lineWidth: 2.2)
                .background(shape.strokeBorder(color.opacity(0.22), lineWidth: 1.5))
        }
    }
}

/// A status word that slowly fades and comes back while `active`. Driven by a paused
/// TimelineView, so nothing redraws once it goes quiet; Reduce Motion keeps it still.
struct Breathing: ViewModifier {
    var active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 25.0, paused: !active || reduceMotion)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let wave = 0.5 + 0.5 * cos(2 * .pi * t / 2.4)
            content.opacity(!active || reduceMotion ? 1 : 0.45 + 0.55 * wave)
        }
    }
}
