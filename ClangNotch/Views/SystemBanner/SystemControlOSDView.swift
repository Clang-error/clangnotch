import SwiftUI

/// The 조절창: a BetterDisplay-style pill with the device name, a value badge, and a bar
/// between a small and a large icon with 16 step ticks underneath.
///
/// Matches BetterDisplay's GlassOSD (read off its binary, 2026-10-14): clear Liquid Glass with
/// a 40% black tint on a 24pt continuous rounded rectangle, a blur-in/blur-out entrance,
/// rolling digits and a springy bar, and the end icon bouncing when a key is pressed again at
/// the limit. The glass only stays clear because `ActiveLookingPanel` draws as active.
struct SystemControlOSDView: View {
    @ObservedObject var osd: SystemControlOSD

    var body: some View {
        content
            .frame(width: SystemControlOSD.pillSize.width + SystemControlOSD.shadowPadding * 2,
                   height: SystemControlOSD.pillSize.height + SystemControlOSD.shadowPadding * 2)
            .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var content: some View {
        if #available(macOS 26, *) {
            if osd.shown, let reading = osd.reading {
                // Glass behind the content; a GlassEffectContainer would fold the content into
                // the glass and blur it.
                pill(reading)
                    .background {
                        Self.shape.fill(.clear).glassEffect(.clear.tint(.black.opacity(0.4)), in: Self.shape)
                    }
                    .transition(.modifier(active: Materialize(progress: 0), identity: Materialize(progress: 1)))
            }
        } else if osd.shown, let reading = osd.reading {
            pill(reading)
                .background(.ultraThinMaterial, in: Self.shape)
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
        }
    }

    private static let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)

    // Sizes measured off BetterDisplay's OSD at 2x (2026-10-14): title cap height 8.5pt,
    // badge digits 6.5pt in a 16pt capsule 9pt below the top, 5pt bar centered 40.5pt down.
    private func pill(_ reading: SystemControlReading) -> some View {
        let icons = icons(for: reading.kind)
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(reading.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                badge(reading)
            }
            .frame(height: 16)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .trailing) {
                if let level = reading.battery { battery(level) }
            }
            HStack(spacing: 0) {
                Image(systemName: icons.min)
                    .font(.system(size: 11, weight: .medium))
                    .symbolEffect(.bounce, value: osd.minBounce)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 24)
                bar(reading)
                    .padding(.horizontal, 1)
                Image(systemName: icons.max)
                    .font(.system(size: 13, weight: .medium))
                    .symbolEffect(.bounce, value: osd.maxBounce)
                    .frame(width: 24)
            }
            .frame(height: 15)
            .padding(.top, 8)
        }
        .foregroundStyle(.white)
        .padding(.top, 9)
        .padding(.leading, 9)
        .padding(.trailing, 15)
        .frame(width: SystemControlOSD.pillSize.width, height: SystemControlOSD.pillSize.height, alignment: .top)
    }

    /// Fixed to the widest value of its kind, so the capsule never changes size while the
    /// digits roll.
    private func badge(_ reading: SystemControlReading) -> some View {
        ZStack {
            ForEach(widestBadges(for: reading), id: \.self) { Text($0).hidden() }
            Text(reading.badge)
                .contentTransition(.numericText(countsDown: osd.countsDown))
        }
        .font(.system(size: 9, weight: .semibold))
        .monospacedDigit()
        .foregroundStyle(.black.opacity(0.75))
        .padding(.horizontal, 7)
        .frame(height: 16)
        .background(Capsule().fill(.white.opacity(0.85)))
        .fixedSize()
    }

    /// 기기 배터리: slightly dimmed so it reads as a side note to the volume.
    private func battery(_ level: Int) -> some View {
        HStack(spacing: 3) {
            Image(systemName: Self.batterySymbol(level))
                .font(.system(size: 11, weight: .medium))
            Text("\(level)%")
                .font(.system(size: 9, weight: .semibold))
                .monospacedDigit()
        }
        .foregroundStyle(.white.opacity(0.9))
    }

    private static func batterySymbol(_ level: Int) -> String {
        switch level {
        case 88...: return "battery.100percent"
        case 63...: return "battery.75percent"
        case 38...: return "battery.50percent"
        case 13...: return "battery.25percent"
        default: return "battery.0percent"
        }
    }

    private func widestBadges(for reading: SystemControlReading) -> [String] {
        switch reading.kind {
        case .brightness:
            return [reading.badge.contains("•") ? "100% • 600 " + L("니트", "nits") : "100%"]
        case .volume, .mute:
            return ["100%", L("음소거", "Muted")]
        }
    }

    private func bar(_ reading: SystemControlReading) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.18))
                Capsule()
                    .fill(.white.opacity(reading.kind == .mute ? 0.35 : 1))
                    .frame(width: geometry.size.width * reading.fraction)
            }
        }
        .frame(height: 5)
        // The 16 step ticks hang just below the bar without moving it off the icons' center.
        .overlay(alignment: .top) {
            HStack(spacing: 0) {
                ForEach(0..<17, id: \.self) { index in
                    Circle().fill(.white.opacity(0.35)).frame(width: 2, height: 2)
                    if index < 16 { Spacer(minLength: 0) }
                }
            }
            .padding(.horizontal, 8)
            .offset(y: 8)
        }
    }

    private func icons(for kind: SystemControlReading.Kind) -> (min: String, max: String) {
        switch kind {
        case .brightness: return ("sun.min.fill", "sun.max.fill")
        case .volume: return ("speaker.fill", "speaker.wave.3.fill")
        case .mute: return ("speaker.slash.fill", "speaker.wave.3.fill")
        }
    }
}

/// Stand-in for the glass materialize animation: comes in blurred, slightly small and clear.
private struct Materialize: ViewModifier {
    let progress: Double

    func body(content: Content) -> some View {
        content
            .blur(radius: (1 - progress) * 8)
            .scaleEffect(0.92 + 0.08 * progress)
            .opacity(progress)
    }
}
