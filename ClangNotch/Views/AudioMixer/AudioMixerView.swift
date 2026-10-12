import SwiftUI

struct AudioMixerView: View {
    @ObservedObject var manager: AudioMixerManager

    private let pending = Color(red: 1.0, green: 0.78, blue: 0.3)

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 8) {
                if let holder = manager.micHolder { micWarningBanner(holder) }
                if manager.apps.isEmpty {
                    Text("No apps playing audio")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.4))
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
                Text("\(app) 마이크 사용 중")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                Text("블루투스로 볼륨 줄이면 통화가 끊길 수 있어요")
                    .font(.system(size: 9))
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
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.9))
                    .lineLimit(1)
                Slider(value: $gain, in: 0...1) { _ in
                    manager.setGain(gain, for: app)
                }
                .controlSize(.mini)
                .tint(accent)
            }
            Text("\(Int(gain * 100))%")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(gain < 0.99 ? accent : .white.opacity(0.5))
                .frame(width: 36, alignment: .trailing)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 4)
        // Reflect external refreshes (app list re-poll keeps the model gain authoritative).
        .onChange(of: app.gain) { _, newValue in
            if abs(newValue - gain) > 0.001 { gain = newValue }
        }
    }
}
