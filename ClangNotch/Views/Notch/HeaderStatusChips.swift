import SwiftUI

/// Right side of the open-notch header, before the buttons: the tethering warning and the
/// pinned devices' battery levels, each a small capsule. When they don't fit beside the
/// 요약 줄 they shrink step by step: the warning drops its words, earbuds show only their
/// lower side, then devices from the end fold into a "+N" capsule.
struct HeaderStatusChips: View {
    @ObservedObject private var battery = BatteryManager.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var tether = TetherPlaceMonitor.shared

    private struct Fit: Hashable {
        var tetherWords: Bool
        var splitEarbuds: Bool
        var shown: Int
    }

    /// The pinned devices that are connected, in the order the user set.
    private var devices: [BatteryDevice] {
        settings.headerBatteryDeviceIDs.split(separator: "\n").compactMap { id in
            battery.devices.first { $0.id == id && $0.isConnected }
        }
    }

    var body: some View {
        let devices = self.devices
        let tethering = tether.activePlaceName != nil
        if tethering || !devices.isEmpty {
            let fits = [Fit(tetherWords: true, splitEarbuds: true, shown: devices.count),
                        Fit(tetherWords: false, splitEarbuds: true, shown: devices.count)]
                + stride(from: devices.count, through: 0, by: -1).map {
                    Fit(tetherWords: false, splitEarbuds: false, shown: $0)
                }
            ViewThatFits(in: .horizontal) {
                ForEach(fits, id: \.self) { fit in
                    row(fit, devices: devices, tethering: tethering)
                }
            }
        } else {
            // Something must stay here: an empty body drops the caller's flexible frame
            // with it, and the header buttons slid to the middle.
            Color.clear.frame(height: 0)
        }
    }

    private func row(_ fit: Fit, devices: [BatteryDevice], tethering: Bool) -> some View {
        HStack(spacing: 6) {
            if tethering { tetherChip(words: fit.tetherWords) }
            ForEach(devices.prefix(fit.shown)) { device in
                deviceChip(device, splitEarbuds: fit.splitEarbuds)
            }
            if fit.shown < devices.count {
                let hidden = devices.dropFirst(fit.shown)
                Text("+\(hidden.count)")
                    .foregroundColor(NotchPalette.ink.opacity(0.6))
                    .modifier(HeaderChip())
                    .help(hidden.map { "\($0.name) \($0.displayLevel)%" }.joined(separator: "\n"))
            }
            // Sets the chips apart from the header buttons.
            Rectangle()
                .fill(NotchPalette.ink.opacity(0.14))
                .frame(width: 1, height: 14)
                .padding(.leading, 4)
        }
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
    }

    private func tetherChip(words: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "personalhotspot")
                .font(.system(size: 10, weight: .semibold))
            if words { Text(L("테더링 중", "Tethering")) }
        }
        .foregroundColor(.red)
        .modifier(Breathing(active: true))
        .modifier(HeaderChip(fill: Color.red.opacity(0.16), stroke: Color.red.opacity(0.35)))
        .help(L("테더링 연결 중 · 해제 권장", "Tethering on · disconnect advised"))
    }

    private func deviceChip(_ device: BatteryDevice, splitEarbuds: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: device.compactSymbol)
                .font(.system(size: 11))
                .foregroundColor(NotchPalette.ink.opacity(0.6))
            // Earbuds caught separately show L and R, so one running down first is visible.
            // One side caught: the icon already says which, so just the level.
            let earbuds = device.parts.filter { $0.label == "L" || $0.label == "R" }
            if splitEarbuds && earbuds.count == 2 {
                ForEach(earbuds, id: \.label) { part in
                    Text(part.label)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(NotchPalette.ink.opacity(0.5))
                    level(part.percent)
                }
            } else {
                level(device.displayLevel)
            }
        }
        .modifier(HeaderChip())
        .help(device.name)
    }

    private func level(_ percent: Int) -> some View {
        Text("\(percent)%")
            .foregroundColor(percent <= 20 ? Color(red: 0.95, green: 0.35, blue: 0.35) : NotchPalette.ink.opacity(0.8))
    }
}

private struct HeaderChip: ViewModifier {
    var fill = NotchPalette.ink.opacity(0.08)
    var stroke: Color? = nil

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Capsule().fill(fill))
            .overlay { if let stroke { Capsule().strokeBorder(stroke, lineWidth: 1) } }
    }
}
