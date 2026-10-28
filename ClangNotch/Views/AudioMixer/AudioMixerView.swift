import SwiftUI

struct AudioMixerView: View {
    @ObservedObject var manager: AudioMixerManager

    private let pending = Color(red: 1.0, green: 0.78, blue: 0.3)

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 8) {
                if let holder = manager.micHolder { micWarningBanner(holder) }
                if manager.apps.isEmpty {
                    Text(L("소리를 내는 앱 없음", "No apps playing audio"))
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.5))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.top, 20)
                } else {
                    ForEach(manager.apps) { app in
                        AppVolumeRow(app: app, manager: manager)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { manager.start() }
    }

    /// Shown only when an app holds the mic *and* output is Bluetooth — lowering a tapped
    /// app's volume can stutter the call. We warn but never lock; the user decides.
    private func micWarningBanner(_ app: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "mic.fill")
                .font(.system(size: 12))
                .foregroundColor(pending)
            VStack(alignment: .leading, spacing: 1) {
                Text(L("\(app) 마이크 사용 중", "\(app) is using the mic"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                Text(L("블루투스로 볼륨 줄이면 통화가 끊길 수 있어요", "Lowering volume over Bluetooth can drop the call"))
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.5))
            }
            Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(pending.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8).stroke(pending.opacity(0.3), lineWidth: 1)
        )
        .padding(.horizontal, 4)
    }
}

private struct AppVolumeRow: View {
    let app: AudioApp
    let manager: AudioMixerManager
    @State private var gain: Float

    private let accent = Color(red: 0.3, green: 0.85, blue: 0.55)

    init(app: AudioApp, manager: AudioMixerManager) {
        self.app = app
        self.manager = manager
        _gain = State(initialValue: app.gain)
    }

    var body: some View {
        HStack(spacing: 9) {
            if let icon = app.icon {
                Image(nsImage: icon).resizable().frame(width: 22, height: 22)
            } else {
                Image(systemName: "app.dashed").resizable().frame(width: 22, height: 22)
                    .foregroundColor(.white.opacity(0.4))
            }
            VolumePill(name: app.name, gain: $gain, accent: accent) {
                manager.setGain(gain, for: app)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .notchCard(cornerRadius: 8)
        .padding(.horizontal, 4)
        // Reflect external refreshes (app list re-poll keeps the model gain authoritative).
        .onChange(of: app.gain) { _, newValue in
            if abs(newValue - gain) > 0.001 { gain = newValue }
        }
    }
}

/// Sapphire's pill slider: the app name and % sit inside the track, and the part under
/// the fill is redrawn dark so the text flips colour exactly where the fill ends. Drag or
/// click anywhere on it; the gain is applied when the finger lifts, as the old Slider did.
private struct VolumePill: View {
    let name: String
    @Binding var gain: Float
    let accent: Color
    let commit: () -> Void

    private let height: CGFloat = 26

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let fillWidth = width * CGFloat(gain)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.1))
                labels(color: .white.opacity(0.85), percentColor: gain < 0.99 ? accent : .white.opacity(0.5))
                Capsule()
                    .fill(accent)
                    .frame(width: max(height, fillWidth))
                    .opacity(gain > 0.005 ? 1 : 0)
                labels(color: .black.opacity(0.8), percentColor: .black.opacity(0.8))
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: max(height, fillWidth))
                    }
                    .opacity(gain > 0.005 ? 1 : 0)
            }
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in gain = Float(min(max(value.location.x / width, 0), 1)) }
                    .onEnded { _ in commit() }
            )
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel(name)
        .accessibilityValue("\(Int(gain * 100))%")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: gain = min(1, gain + 0.05)
            case .decrement: gain = max(0, gain - 0.05)
            @unknown default: return
            }
            commit()
        }
    }

    private func labels(color: Color, percentColor: Color) -> some View {
        HStack {
            Text(name)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(color)
                .lineLimit(1)
            Spacer(minLength: 6)
            Text("\(Int(gain * 100))%")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(percentColor)
        }
        .padding(.horizontal, 10)
        .allowsHitTesting(false)
    }
}
