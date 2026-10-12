import SwiftUI

enum NotchPalette {
    static let accent = Color(red: 0.57, green: 0.88, blue: 0.77)
    static let background = Color(red: 0.045, green: 0.055, blue: 0.065)
    static let surface = Color(red: 0.075, green: 0.085, blue: 0.10)
}

extension NotchMode {
    var icon: String {
        switch self {
        case .ai: return "sparkles"
        case .clipboard: return "doc.on.clipboard"
        case .volume: return "slider.horizontal.3"
        case .sidecar: return "ipad.landscape"
        case .keyboardLock: return "keyboard"
        case .battery: return "battery.75percent"
        case .speed: return "network"
        }
    }

    var title: String {
        switch self {
        case .ai: return "Agent overview"
        case .clipboard: return "Clipboard"
        case .volume: return "Audio mixer"
        case .sidecar: return "Extend your screen"
        case .keyboardLock: return "Keyboard lock"
        case .battery: return "Device batteries"
        case .speed: return "Network speed"
        }
    }

    var subtitle: String {
        switch self {
        case .ai: return "Live activity, open sessions, and decisions waiting for you."
        case .clipboard: return "Your recent text. Click an item to copy it again."
        case .volume: return "Find the right balance for each app."
        case .sidecar: return "Connect your iPad as a second display."
        case .keyboardLock: return "A moment to clean your keyboard."
        case .battery: return "A quick check on the devices around you."
        case .speed: return "Measure your connection, from download to latency."
        }
    }
}

struct NotchNavigationButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let mode: NotchMode
    let selected: Bool
    let needsAttention: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: mode.icon)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                    .scaleEffect(selected && !reduceMotion ? 1.08 : 1)
                if selected {
                    Text(mode.label)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize()
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                }
                if needsAttention {
                    Circle().fill(.orange).frame(width: 5, height: 5)
                }
            }
            .foregroundStyle(selected ? NotchPalette.accent : .white.opacity(hovering ? 0.9 : 0.55))
            .padding(.horizontal, 10)
            .frame(height: 37)
            .background(selected ? NotchPalette.accent.opacity(0.12) : .white.opacity(hovering ? 0.06 : 0),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? NotchPalette.accent.opacity(0.18) : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? .easeOut(duration: 0.12) : .interactiveSpring(response: 0.3, dampingFraction: 0.86),
                   value: selected)
        .accessibilityLabel(mode.title)
        .accessibilityValue(selected ? "Selected" : "")
        .help(mode.subtitle)
    }
}
