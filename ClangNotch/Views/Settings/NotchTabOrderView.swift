import SwiftUI

/// Drag-to-reorder list for the expanded notch's tab chips, persisted to
/// `AppSettings.notchModeOrder` as comma-joined `NotchMode` rawValues. Whether a tab shows is
/// its feature's switch in 설정 › 기능 › 노치 탭 alone; a tab whose feature is off is dimmed here.
struct NotchTabOrderView: View {
    @ObservedObject private var settings = AppSettings.shared

    private var modes: [NotchMode] { NotchMode.order(from: settings.notchModeOrder) }

    var body: some View {
        List {
            ForEach(modes) { mode in
                let on = isOn(mode)
                HStack(spacing: 8) {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text(mode.label)
                        .font(.system(size: 12))
                        .foregroundStyle(on ? .primary : .secondary)
                    Spacer()
                    if !on {
                        Text(L("기능 꺼짐", "Feature off"))
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 1)
            }
            .onMove { source, destination in
                var reordered = modes
                reordered.move(fromOffsets: source, toOffset: destination)
                settings.notchModeOrder = reordered.map(\.rawValue).joined(separator: ",")
            }
        }
        // Sized to the row count — a fixed height silently hides whichever tabs
        // don't fit, which reads as "that tab was never added".
        .frame(height: CGFloat(modes.count) * 26 + 16)
    }

    /// The 설정 › 기능 switch behind each tab (Agents has none).
    private func isOn(_ mode: NotchMode) -> Bool {
        switch mode {
        case .ai:           return true
        case .clipboard:    return settings.enableClipboardHistory
        case .volume:       return settings.enableAudioMixer
        case .sidecar:      return settings.enableSidecar
        case .keyboardLock: return settings.enableKeyboardLock
        case .battery:      return settings.enableBattery
        case .speed:        return settings.enableSpeedTest
        }
    }
}
