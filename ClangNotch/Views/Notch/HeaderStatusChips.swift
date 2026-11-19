import AppKit
import SwiftUI

/// The open-notch header's device chip, before the header buttons: the battery of the device
/// pinned with 헤더에 표시 (one since 2026-11-19), while it is connected. Earbuds caught
/// separately show L and R, or, `compact` (beside the camera, where room is short), the lower
/// side alone.
struct HeaderStatusChips: View {
    @ObservedObject private var battery = BatteryManager.shared
    @ObservedObject private var settings = AppSettings.shared
    var compact = false

    /// The pinned device, while it is connected.
    @MainActor static var device: BatteryDevice? {
        let id = AppSettings.shared.headerBatteryDeviceIDs.split(separator: "\n").first.map(String.init)
        return BatteryManager.shared.devices.first { $0.id == id && $0.isConnected }
    }

    var body: some View {
        // Read through the observed objects so a change redraws the chip.
        let _ = (battery.devices.count, settings.headerBatteryDeviceIDs)
        if let device = Self.device {
            chip(device)
        }
    }

    private static func earbuds(_ device: BatteryDevice) -> [BatteryPart] {
        device.parts.filter { $0.label == "L" || $0.label == "R" }
    }

    /// The chip's width as drawn, for deciding whether the header fits beside the camera
    /// (0 with no chip).
    @MainActor static func width(compact: Bool) -> CGFloat {
        guard let device else { return 0 }
        let text = { (s: String, size: CGFloat) in HeaderChipMetrics.textWidth(s, size) }
        let earbuds = earbuds(device)
        var content = HeaderChipMetrics.icon
        if !compact && earbuds.count == 2 {
            for part in earbuds { content += 4 + text(part.label, 10) + 4 + text("\(part.percent)%", 11) }
        } else {
            content += 4 + text("\(device.displayLevel)%", 11)
        }
        return content + 2 * HeaderChipMetrics.padding
    }

    private func chip(_ device: BatteryDevice) -> some View {
        HStack(spacing: 4) {
            Image(systemName: device.compactSymbol)
                .font(.system(size: 11))
                .foregroundColor(NotchPalette.ink.opacity(0.6))
                .frame(width: HeaderChipMetrics.icon)
            // Earbuds caught separately show L and R, so one running down first is visible.
            // One side caught: the icon already says which, so just the level.
            let earbuds = Self.earbuds(device)
            if !compact && earbuds.count == 2 {
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
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
        .modifier(HeaderChip())
        .help(device.name)
    }

    private func level(_ percent: Int) -> some View {
        Text("\(percent)%")
            .foregroundColor(percent <= 20 ? Color(red: 0.95, green: 0.35, blue: 0.35) : NotchPalette.ink.opacity(0.8))
    }
}

/// The tethering warning in the open-notch header, after the 요약 줄 (on the left in both the
/// band and the row under it, so it never crosses the camera). `compact` drops its words.
struct TetherHeaderChip: View {
    var compact = false

    @MainActor static func width(compact: Bool) -> CGFloat {
        HeaderChipMetrics.icon + (compact ? 0 : 4 + HeaderChipMetrics.textWidth(L("테더링 중", "Tethering"), 11))
            + 2 * HeaderChipMetrics.padding
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "personalhotspot")
                .font(.system(size: 10, weight: .semibold))
                .frame(width: HeaderChipMetrics.icon)
            if !compact { Text(L("테더링 중", "Tethering")) }
        }
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .lineLimit(1)
        .fixedSize()
        .foregroundColor(.red)
        .modifier(Breathing(active: true))
        .modifier(HeaderChip(fill: Color.red.opacity(0.16), stroke: Color.red.opacity(0.35)))
        .help(L("테더링 연결 중 · 해제 권장", "Tethering on · disconnect advised"))
    }
}

/// Sizes the header's chips share, so their widths can be worked out without drawing them.
enum HeaderChipMetrics {
    static let height: CGFloat = 24
    static let padding: CGFloat = 8
    static let icon: CGFloat = 14

    static func textWidth(_ text: String, _ size: CGFloat) -> CGFloat {
        let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold)
        let rounded = font.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? font
        return ceil((text as NSString).size(withAttributes: [.font: rounded]).width)
    }
}

private struct HeaderChip: ViewModifier {
    var fill = NotchPalette.ink.opacity(0.08)
    var stroke: Color? = nil

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, HeaderChipMetrics.padding)
            .frame(height: HeaderChipMetrics.height)
            .background(Capsule().fill(fill))
            .overlay { if let stroke { Capsule().strokeBorder(stroke, lineWidth: 1) } }
    }
}
