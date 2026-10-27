import SwiftUI

/// What the menu bar icon and the popover header summarise. Both read this so they agree.
enum MenuBarActivity: Equatable {
    case idle
    case working(claude: Bool, codex: Bool, count: Int)
    case needsPermission(Int)
    case awaitingAnswer(Int)

    @MainActor static var current: MenuBarActivity {
        let questions = ClaudeCodeManager.shared.sessionsAwaitingInput.count + CodexManager.shared.pendingInputRequests.count
        if questions > 0 { return .awaitingAnswer(questions) }
        let permissions = ClaudeCodeManager.shared.sessionsNeedingPermission.count
        if permissions > 0 { return .needsPermission(permissions) }
        let claude = ClaudeCodeManager.shared.sessionStates.values.filter(\.isActive).count
        let codex = CodexManager.shared.sessionStates.values.filter(\.isActive).count
        let count = claude + codex
        return count > 0 ? .working(claude: claude > 0, codex: codex > 0, count: count) : .idle
    }

    var label: String {
        switch self {
        case .idle: return L("대기 중", "Idle")
        case .working(_, _, let count): return L("작업 중 · \(count)", "Working · \(count)")
        case .needsPermission(let count): return L("권한 승인 대기 · \(count)", "Waiting for permission · \(count)")
        case .awaitingAnswer(let count): return L("답변 대기 · \(count)", "Waiting for your answer · \(count)")
        }
    }

    var symbolName: String {
        if case .needsPermission = self { return "hand.raised.fill" }
        if case .awaitingAnswer = self { return "bubble.left.and.bubble.right" }
        return "wand.and.stars"
    }

    /// Claude is orange, Codex blue, both at once a blend of the two; waiting is red.
    var tints: [Color] {
        switch self {
        case .idle: return [.secondary]
        case .working(let claude, let codex, _):
            if claude && codex { return [.orange, .blue] }
            if claude { return [.orange, .pink] }
            if codex { return [.blue, .cyan] }
            return [.green]
        case .needsPermission, .awaitingAnswer: return [.red]
        }
    }

    var gradient: LinearGradient {
        LinearGradient(colors: tints, startPoint: .leading, endPoint: .trailing)
    }
}

/// The menu bar is the one surface that survives full-screen apps hiding the notch, so it
/// carries what you would otherwise open the notch for: agent state and the usage gauges.
struct AgentMenuBarContentView: View {
    @ObservedObject private var claudeCodeManager = ClaudeCodeManager.shared
    @ObservedObject private var codexManager = CodexManager.shared
    @ObservedObject private var tworld = TWorldSession.shared
    @ObservedObject private var network = NetworkInfoManager.shared
    @StateObject private var settings = AppSettings.shared
    @StateObject private var keyboardLockManager = KeyboardLockManager.shared

    var body: some View {
        let activity = MenuBarActivity.current
        VStack(spacing: 12) {
            MenuSection {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(activity.gradient.opacity(0.15))
                        Image(systemName: activity.symbolName)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(activity.gradient)
                    }
                    .frame(width: 28, height: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("ClangNotch")
                            .font(.system(size: 13, weight: .semibold))
                        Text(activity.label)
                            .font(.system(size: 10))
                            .foregroundStyle(activity.gradient)
                            .lineLimit(1)
                    }

                    Spacer()

                    Text("Claude \(claudeCodeManager.availableSessions.count) · Codex \(codexManager.availableSessions.count)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }

            if (settings.enableKeyboardLock || keyboardLockManager.isLocked) && keyboardLockManager.hasAccessibilityPermission {
                MenuSection {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill((keyboardLockManager.isLocked ? Color.green : Color.secondary).opacity(0.15))
                            Image(systemName: keyboardLockManager.isLocked ? "lock.fill" : "lock.open.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(keyboardLockManager.isLocked ? .green : .secondary)
                        }
                        .frame(width: 28, height: 28)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("키보드 잠금", "Keyboard Lock"))
                                .font(.system(size: 13, weight: .semibold))
                            Text(keyboardLockManager.isLocked ? L("모든 입력 차단 중", "Blocking all input") : L("차단 안 함", "Not blocking"))
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Toggle("", isOn: Binding(
                            get: { keyboardLockManager.isLocked },
                            set: { _ in keyboardLockManager.toggle() }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                    }
                }
            }

            MenuSection {
                if settings.enableClaudeUsage {
                    ClaudeUsageNotchSection()
                } else {
                    hint(L("Claude 사용량", "Claude usage"), L("설정에서 사용량 조회를 켜면 5시간·7일 한도가 표시됩니다.", "Turn on usage tracking in Settings to see the 5-hour and 7-day limits."))
                }
            }

            if settings.showSourceCodex {
                MenuSection {
                    if codexManager.rateLimits.hasData {
                        ClangNotchContentView.CodexUsageNotchSection(rateLimits: codexManager.rateLimits)
                    } else {
                        hint(L("Codex 사용량", "Codex usage"), L("Codex 세션에서 한도 정보가 수신되면 표시됩니다.", "Appears once a Codex session reports its limits."))
                    }
                }
            }

            // Same gate as the Speed tab: only while on the configured iPhone hotspot.
            if settings.enableTWorld, !settings.tworldHotspotSSID.isEmpty, network.ssid == settings.tworldHotspotSSID,
               !tworld.requiresLogin || tworld.balance != nil {
                TWorldUsageView()
            }

            MenuSection {
                HStack {
                    Button {
                        openSettings()
                    } label: {
                        Label(L("설정…", "Settings…"), systemImage: "gearshape")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Button {
                        NSApp.terminate(nil)
                    } label: {
                        Label(L("종료", "Quit"), systemImage: "power")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.red)
                }
            }
        }
        .padding(12)
        .id(settings.settingsLanguage)
        .frame(width: 300)
        // Solid, like the notch. NSPopover's own backing is light and its vibrancy fades
        // further when the popover loses key, which washed out the white-on-dark cards.
        .background(Color(white: 0.11))
        // `requiresLogin` starts true until the Keychain has been read; without this the
        // T world card never appears unless the Speed tab was opened first.
        .task {
            network.refresh()
            await tworld.prepare()
        }
    }

    private func hint(_ title: String, _ message: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.55))
            Text(message)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow")), to: NSApp.delegate, from: nil)
    }
}

private struct MenuSection<Content: View>: View {
    let title: String?
    let content: Content

    init(title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
            }

            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.1))
        )
    }
}

#Preview {
    AgentMenuBarContentView()
}
