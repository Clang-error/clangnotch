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
            Text("키보드 입력을 막으려면 손쉬운 사용 권한이 필요합니다.")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.7))
                .multilineTextAlignment(.center)
            Button("권한 허용") {
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
                    Text(manager.isLocked ? "키보드 잠김" : "키보드 잠그기")
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
                Text("위 버튼이나 메뉴바 아이콘으로 잠금을 풉니다")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
            }
        }
    }
}
