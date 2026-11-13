import SwiftUI

struct KeyboardLockView: View {
    @ObservedObject var manager: KeyboardLockManager
    @ObservedObject private var tester = KeyTester.shared

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
            // accessory app remains alive and inactive. The timer runs while this tab is
            // shown; it only asks again while the permission is still missing.
            if !manager.hasAccessibilityPermission {
                manager.refreshPermissionStatus()
            }
        }
    }

    private var permissionPrompt: some View {
        VStack(spacing: 8) {
            Image(systemName: "lock.shield")
                .font(.system(size: 22))
                .foregroundColor(NotchPalette.ink.opacity(0.7))
            Text(L("키보드 입력을 막으려면 손쉬운 사용 권한이 필요합니다.", "Needs Accessibility access to block keyboard input."))
                .font(.system(size: 11))
                .foregroundColor(NotchPalette.ink.opacity(0.7))
                .multilineTextAlignment(.center)
            Button(L("권한 허용", "Grant Access")) {
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
                // The lock takes the keys ahead of a running test; end the test first.
                tester.stop()
                manager.toggle()
            } label: {
                VStack(spacing: 6) {
                    Image(systemName: manager.isLocked ? "lock.fill" : "lock.open.fill")
                        .font(.system(size: 26, weight: .semibold))
                    Text(manager.isLocked ? L("키보드 잠김", "Keyboard Locked") : L("키보드 잠그기", "Lock Keyboard"))
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(manager.isLocked ? .black : NotchPalette.ink)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    manager.isLocked ? Color.green : NotchPalette.ink.opacity(0.1),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
            }
            .buttonStyle(.plain)

            if manager.isLocked {
                Text(L("위 버튼이나 메뉴바 아이콘으로 잠금을 풉니다", "Click above or use the menu bar icon to unlock"))
                    .font(.system(size: 10))
                    .foregroundColor(NotchPalette.ink.opacity(0.5))
                    .multilineTextAlignment(.center)
            }

            keyTestCard
        }
    }

    /// Key Test 카드: keys light up while held, and only during a test, which keeps every key
    /// from other apps. Leaving the tab or closing the notch ends it.
    private var keyTestCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Key Test")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundColor(NotchPalette.ink.opacity(0.4))
                Spacer(minLength: 0)
                Button(tester.isTesting ? L("끝내기", "Stop") : L("테스트 시작", "Start Test")) {
                    tester.toggle()
                }
                .controlSize(.small)
                .disabled(manager.isLocked)
            }
            KeyTestKeyboard(tester: tester)
                .opacity(tester.isTesting ? 1 : 0.5)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .notchCard()
        .onDisappear { tester.stop() }
    }
}
