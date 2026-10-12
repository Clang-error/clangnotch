import SwiftUI

struct KeyboardLockView: View {
    @ObservedObject var manager: KeyboardLockManager

    var body: some View {
        Group {
            if manager.hasAccessibilityPermission {
                lockToggle
            } else {
                permissionPrompt
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { manager.refreshPermissionStatus() }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            // Accessibility approval can change in System Settings while this
            // accessory app remains alive and inactive. Poll only while the
            // permission screen is visible so the control updates immediately.
            if !manager.hasAccessibilityPermission {
                manager.refreshPermissionStatus()
            }
        }
    }

    private var permissionPrompt: some View {
        VStack(spacing: 8) {
            Image(systemName: "lock.shield")
                .font(.system(size: 22))
                .foregroundColor(.white.opacity(0.7))
            Text("Needs Accessibility access to block keyboard input.")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.7))
                .multilineTextAlignment(.center)
            Button("Grant Access") {
                manager.requestPermission()
                if !manager.hasAccessibilityPermission {
                    manager.openAccessibilitySettings()
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    private var lockToggle: some View {
        VStack(spacing: 10) {
            Button {
                manager.toggle()
            } label: {
                VStack(spacing: 6) {
                    Image(systemName: manager.isLocked ? "lock.fill" : "lock.open.fill")
                        .font(.system(size: 26, weight: .semibold))
                    Text(manager.isLocked ? "Keyboard Locked" : "Lock Keyboard")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(manager.isLocked ? .black : .white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    manager.isLocked ? Color.green : Color.white.opacity(0.1),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
            }
            .buttonStyle(.plain)

            if manager.isLocked {
                Text("Click above or use the menu bar icon to unlock")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
            }
        }
    }
}
