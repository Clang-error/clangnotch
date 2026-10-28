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

/// Blur + fade, the open-notch transition boring.notch and DynamicNotchKit use:
/// content comes into focus instead of just fading in.
private struct BlurFade: ViewModifier {
    var radius: CGFloat
    var opacity: Double

    func body(content: Content) -> some View {
        content.blur(radius: radius).opacity(opacity)
    }
}

extension AnyTransition {
    static func blurFade(radius: CGFloat = 8) -> AnyTransition {
        .modifier(active: BlurFade(radius: radius, opacity: 0), identity: BlurFade(radius: 0, opacity: 1))
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

/// Text lit like the notch glow: a bright band sweeps across it every 3s (the glow's
/// sweep period). With a `secondary` colour (Claude and Codex both working) the text
/// eases from one agent's colour to the other's and back every 6s. Paused when idle.
struct GlowSweepText: ViewModifier {
    var active: Bool
    var color: Color
    var bright: Color
    var secondary: Color? = nil
    var secondaryBright: Color? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder
    func body(content: Content) -> some View {
        if active {
            sweep(content)
        } else {
            content
        }
    }

    /// Same as NotchGlowBorder's: `Color.mix(with:by:)` needs macOS 15; the target is 14.2.
    private static func blend(_ from: Color, _ to: Color?, _ fraction: Double) -> Color {
        guard let to, fraction > 0 else { return from }
        guard let blended = NSColor(from).usingColorSpace(.sRGB)?
            .blended(withFraction: fraction, of: NSColor(to)) else { return from }
        return Color(nsColor: blended)
    }

    private func sweep(_ content: Content) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 25.0, paused: reduceMotion)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let mix = secondary == nil ? 0 : 0.5 - 0.5 * cos(2 * .pi * t / 6)
            let base = Self.blend(bright, secondaryBright, mix)
            let band = Self.blend(Self.blend(color, secondary, mix), .white, 0.65)
            let phase = reduceMotion ? 0.5 : (t.truncatingRemainder(dividingBy: 3)) / 3
            let center = phase * 1.6 - 0.3
            // The band's end points move, not its stops: past either end of the text the
            // gradient just holds `base`, so the band slides fully off instead of clamping on.
            content.foregroundStyle(LinearGradient(colors: [base, band, base],
                                                   startPoint: UnitPoint(x: center - 0.25, y: 0.5),
                                                   endPoint: UnitPoint(x: center + 0.25, y: 0.5)))
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
