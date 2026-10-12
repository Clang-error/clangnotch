import SwiftUI

/// Drag-to-reorder, check-to-show list for the expanded notch's tab chips.
/// Order persists to `AppSettings.notchModeOrder`, visibility to
/// `AppSettings.hiddenNotchModes`, both as comma-joined `NotchMode` rawValues.
struct NotchTabOrderView: View {
    @ObservedObject private var settings = AppSettings.shared

    private var modes: [NotchMode] { NotchMode.order(from: settings.notchModeOrder) }
    private var hidden: Set<NotchMode> { NotchMode.hidden(from: settings.hiddenNotchModes) }

    var body: some View {
        List {
            ForEach(modes) { mode in
                HStack(spacing: 8) {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Toggle(isOn: visibility(of: mode)) {
                        Text(mode.label)
                            .font(.system(size: 12))
                    }
                    .toggleStyle(.checkbox)
                    Spacer()
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

    private func visibility(of mode: NotchMode) -> Binding<Bool> {
        Binding(
            get: { !hidden.contains(mode) },
            set: { shown in
                var updated = hidden
                if shown { updated.remove(mode) } else { updated.insert(mode) }
                // Written in case order so the stored string stays stable.
                settings.hiddenNotchModes = NotchMode.allCases
                    .filter(updated.contains)
                    .map(\.rawValue)
                    .joined(separator: ",")
            }
        )
    }
}
