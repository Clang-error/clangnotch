import SwiftUI

public struct AgentSettingsView: View {
    @EnvironmentObject var telemetryCoordinator: TelemetryCoordinator
    @StateObject private var settings = AppSettings.shared

    public init() {}

    public var body: some View {
        TabView {
            AppGeneralSettingsTab(settings: settings)
                .tabItem {
                    Label(L("일반", "General"), systemImage: "gear")
                }

            NotchSettingsTab(settings: settings)
                .tabItem {
                    Label(L("노치", "Notch"), systemImage: "macbook")
                }

            AgentsSettingsTab(settings: settings)
                .tabItem {
                    Label(L("에이전트", "Agents"), systemImage: "brain")
                }

            TelemetryStatusTab(settings: settings, telemetryCoordinator: telemetryCoordinator)
                .tabItem {
                    Label(L("텔레메트리", "Telemetry"), systemImage: "waveform.path.ecg")
                }

            AboutSettingsTab(settings: settings)
                .tabItem {
                    Label(L("정보", "About"), systemImage: "info.circle")
                }
        }
        // Rebuilds every tab when the language changes; the picker lives on the first tab.
        .id(settings.settingsLanguage)
        .frame(width: 600, height: 560)
    }
}

/// A switch with what it does in one line under it, so no setting needs a paragraph.
private struct SettingToggle: View {
    let title: String
    let caption: String
    @Binding var isOn: Bool

    init(_ title: String, _ caption: String, isOn: Binding<Bool>) {
        self.title = title
        self.caption = caption
        self._isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - General

struct AppGeneralSettingsTab: View {
    @ObservedObject var settings: AppSettings
    @State private var launchAtLogin = LoginItem.isEnabled

    var body: some View {
        Form {
            Section {
                Picker(L("표시 언어", "Display language"), selection: $settings.settingsLanguage) {
                    Text("한국어").tag("ko")
                    Text("English").tag("en")
                }
            } header: {
                Text(L("언어", "Language"))
            }

            Section {
                Toggle(L("로그인 시 실행", "Launch at login"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        LoginItem.setEnabled(newValue)
                    }
                SettingToggle(L("실행할 때 알림 수신기 켜기", "Start the alert receiver on launch"),
                              L("권한·질문 드롭다운과 원격 SSH 세션이 이걸로 들어옵니다. 끄면 오지 않습니다.",
                                "Permission and question dropdowns and remote SSH sessions arrive through it."),
                              isOn: $settings.telemetryAutoStart)
                SettingToggle(L("메뉴 막대 아이콘 표시", "Show menu bar icon"),
                              L("세션 수·키보드 잠금·설정을 메뉴 막대에서 열기", "Sessions, keyboard lock and settings from the menu bar"),
                              isOn: $settings.showMenuBarItem)
            } header: {
                Text(L("시작", "Startup"))
            }

            Section {
                SettingToggle(L("배터리 절약 모드", "Battery saver mode"),
                              L("배터리로 쓸 때 글로우 애니메이션을 덜 부드럽게(15fps) 그립니다.",
                                "Draws the glow at 15 fps instead of 25 while on battery."),
                              isOn: $settings.batterySaverEnabled)
            } header: {
                Text(L("성능", "Performance"))
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - About

struct AboutSettingsTab: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var updates = UpdateChecker.shared
    @State private var copied = false

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 6) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 96, height: 96)
                        // The icon file is a full square (macOS 26 masks it itself); give it
                        // the same continuous rounded corners here.
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    Text("ClangNotch")
                        .font(.title2.weight(.semibold))
                    // Click to copy, for bug reports.
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(version, forType: .string)
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.2))
                            copied = false
                        }
                    } label: {
                        Text(copied ? L("복사됨", "Copied") : L("버전 \(version)", "Version \(version)"))
                            .monospacedDigit()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(L("눌러서 복사", "Click to copy"))
                    Text(L("개발자 Clang_error", "Developer: Clang_error"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }

            Section {
                SettingToggle(L("업데이트 알림 받기", "Notify about updates"),
                              L("새 버전이 나오면 알림으로 알려 줍니다.", "Shows a notification when a new version is out."),
                              isOn: $settings.checkForUpdates)
                    .onChange(of: settings.checkForUpdates) { _, _ in updates.syncWithSettings() }
                if let version = updates.availableVersion {
                    HStack {
                        Text(L("새 버전 \(version)", "Version \(version) available"))
                        Spacer()
                        Button(L("받기", "Download")) { NSWorkspace.shared.open(updates.releaseURL) }
                    }
                }
            } header: {
                Text(L("업데이트", "Updates"))
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Notch

/// Everything about the notch itself: which tabs exist, in what order, and the
/// utility features behind them.
struct NotchSettingsTab: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var network = NetworkInfoManager.shared

    var body: some View {
        Form {
            Section {
                NotchTabOrderView()
            } header: {
                Text(L("탭", "Tabs"))
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(L("열리기까지 기다리는 시간", "Delay before opening"))
                        Spacer()
                        Text(String(format: L("%.1f초", "%.1fs"), settings.notchOpenDelay))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $settings.notchOpenDelay, in: 0...1, step: 0.05)
                    Text(L("커서를 노치에 이만큼 올려 둬야 펼쳐집니다. 메뉴 막대로 가다 스쳐도 안 열리게 하려면 늘리세요.",
                           "The cursor has to rest on the notch this long before it opens. Raise it if the notch opens while you head for the menu bar."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                SettingToggle(L("열릴 때 햅틱", "Haptic on open"),
                              L("노치가 펼쳐질 때 트랙패드가 가볍게 톡 칩니다.", "A light trackpad tap when the notch opens."),
                              isOn: $settings.notchHapticsEnabled)
                SettingToggle(L("끝날 때 햅틱", "Haptic when done"),
                              L("세션이 작업을 끝내면 트랙패드가 톡 칩니다. 소리를 끈 세션은 빼요.", "A trackpad tap when a session finishes; muted sessions skipped."),
                              isOn: $settings.doneHapticsEnabled)
                if settings.notchHapticsEnabled || settings.doneHapticsEnabled {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(L("햅틱 세기", "Haptic strength"))
                            Spacer()
                            Text("\(settings.notchHapticStrength)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: Binding(get: { Double(settings.notchHapticStrength) },
                                              set: { settings.notchHapticStrength = Int($0.rounded()) }),
                               in: 1...8, step: 1)
                            .onChange(of: settings.notchHapticStrength) { _, strength in
                                TrackpadHaptics.tap(strength: strength)
                            }
                        Text(L("옮길 때마다 그 세기로 한 번 울립니다.", "Taps once at each step so you can feel it."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(L("열기와 햅틱", "Opening and haptics"))
            }

            Section {
                SettingToggle(L("클립보드 기록", "Clipboard history"),
                              L("최근 복사한 글. 메모리에만 두고 비밀번호는 빼요.", "Recent copied text, in memory only; passwords skipped."),
                              isOn: $settings.enableClipboardHistory)
                    .onChange(of: settings.enableClipboardHistory) { _, _ in
                        ClipboardManager.shared.syncWithSettings()
                    }
                SettingToggle(L("앱별 볼륨 믹서", "Per-app volume mixer"),
                              L("앱마다 소리 크기 조절. 오디오 캡처 권한 필요.", "Volume per app. Needs audio-capture permission."),
                              isOn: $settings.enableAudioMixer)
                    .onChange(of: settings.enableAudioMixer) { _, on in
                        if on { AudioMixerManager.shared.start() } else { AudioMixerManager.shared.stop() }
                    }
                SettingToggle(L("Sidecar 빠른 연결", "Sidecar quick-connect"),
                              L("iPad를 보조 화면으로 바로 연결", "Connect an iPad as a second display"),
                              isOn: $settings.enableSidecar)
                    .onChange(of: settings.enableSidecar) { _, on in
                        if on { SidecarManager.shared.start() } else { SidecarManager.shared.stop() }
                    }
                SettingToggle(L("배터리 잔량", "Battery levels"),
                              L("Mac·블루투스 기기·iPhone의 배터리", "The Mac, Bluetooth accessories and iPhone"),
                              isOn: $settings.enableBattery)
                SettingToggle(L("인터넷 속도 측정", "Internet speed test"),
                              L("측정 버튼을 누를 때만 데이터를 씁니다.", "Uses data only when you press Test."),
                              isOn: $settings.enableSpeedTest)
                SettingToggle(L("키보드 잠금", "Keyboard lock"),
                              L("직접 풀 때까지 키 입력을 막습니다. 손쉬운 사용 권한 필요.", "Blocks typing until you unlock. Needs Accessibility."),
                              isOn: $settings.enableKeyboardLock)
                SettingToggle(L("볼륨·밝기 표시 바꾸기", "Replace volume and brightness HUD"),
                              L("macOS 볼륨·밝기 표시 대신 노치 조절창을 씁니다. 손쉬운 사용 권한 필요.",
                                "Shows the notch's own HUD instead of macOS's. Needs Accessibility."),
                              isOn: $settings.centerSystemBanners)
                    .onChange(of: settings.centerSystemBanners) { _, _ in
                        SystemBannerCenterer.shared.syncWithSettings()
                    }
            } header: {
                Text(L("기능", "Features"))
            }

            Section {
                SettingToggle(L("Wi-Fi 이름 표시", "Show Wi-Fi name"),
                              L("Speed 탭과 아래 기능들에 쓰입니다. macOS가 위치 권한을 요구해요(위치는 다른 데 안 씀).",
                                "Used by the Speed tab and the features below. macOS asks for Location access for it (used for nothing else)."),
                              isOn: $settings.enableNetworkName)
                    .onChange(of: settings.enableNetworkName) { _, on in
                        if on { network.requestAccess() } else { network.refresh() }
                    }
                if settings.enableNetworkName {
                    LabeledContent(L("위치 서비스", "Location Services")) {
                        HStack(spacing: 8) {
                            Text(networkPermissionStatus)
                                .foregroundColor(.secondary)
                            if !network.hasLocationAccess {
                                Button(network.authorization == .notDetermined ? L("허용…", "Allow…") : L("시스템 설정 열기", "Open System Settings")) {
                                    network.requestAccess()
                                }
                            }
                        }
                    }
                }
            } header: {
                Text(L("네트워크 이름", "Network name"))
            }

            TWorldSettingsView()

            TetherPlacesSettingsView()
        }
        .formStyle(.grouped)
        .padding()
    }

    private var networkPermissionStatus: String {
        switch network.authorization {
        case .authorizedAlways: return L("허용됨", "Allowed")
        case .denied:           return L("거부됨", "Denied")
        case .restricted:       return L("제한됨", "Restricted")
        case .notDetermined:    return L("아직 요청 안 함", "Not asked yet")
        @unknown default:       return L("사용 불가", "Unavailable")
        }
    }
}

// MARK: - Agents

/// Which coding agents are tracked, and how their activity reads in the notch.
/// One section per agent, after the settings both share, so nothing about an agent is
/// split across the page.
struct AgentsSettingsTab: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var remote = RemoteClaudeManager.shared
    @ObservedObject private var telemetry = TelemetryCoordinator.shared

    /// One switch per agent: showing it in the notch and reading its session logs go together.
    private var claudeEnabled: Binding<Bool> {
        Binding(get: { settings.showSourceClaudeCode && settings.enableClaudeCodeJSONL },
                set: { settings.showSourceClaudeCode = $0; settings.enableClaudeCodeJSONL = $0 })
    }

    private var codexEnabled: Binding<Bool> {
        Binding(get: { settings.showSourceCodex && settings.enableCodexJSONL },
                set: { settings.showSourceCodex = $0; settings.enableCodexJSONL = $0 })
    }

    var body: some View {
        Form {
            Section {
                Toggle(L("효과음", "Sounds"), isOn: $settings.notchSoundsEnabled)
                HStack(spacing: 8) {
                    Text(L("효과음 크기", "Sound volume"))
                    Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                    // Letting go plays the done sound at the new level.
                    Slider(value: $settings.notchSoundsVolume, in: 0...1) { editing in
                        if !editing { NotchSounds.playDone() }
                    }
                    Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                }
                .disabled(!settings.notchSoundsEnabled)
                Picker(L("답을 기다리면 다시 알림", "Remind while waiting"), selection: $settings.attentionReminderMinutes) {
                    Text(L("안 함", "Never")).tag(0)
                    Text(L("3분마다", "Every 3 min")).tag(3)
                    Text(L("5분마다", "Every 5 min")).tag(5)
                    Text(L("10분마다", "Every 10 min")).tag(10)
                }
                .disabled(!settings.notchSoundsEnabled)
                Toggle(L("화면이 잠겨 있으면 소리 끄기", "Mute while the screen is locked"), isOn: $settings.muteSoundsWhenLocked)
                    .disabled(!settings.notchSoundsEnabled)
                SettingToggle(L("사용량 추정", "Usage forecast"),
                              L("지금 속도로 쓰면 리셋 때 몇 %일지 사용량 막대에 회색 눈금과 한 줄로 보여 줍니다.",
                                "Shows where usage lands at reset at the current pace, as a grey tick and a line under each usage bar."),
                              isOn: $settings.usagePaceEnabled)
                Toggle(L("토큰 수 표시", "Show token count"), isOn: $settings.showNotchTokenCount)
                SettingToggle(L("컨텍스트 막대 표시", "Show context bar"),
                              L("세션 화면 맨 위에 컨텍스트가 얼마나 찼는지 한 줄로 보여 줍니다. 크기(200k·1M 등)는 세션마다 알아서 잡습니다.",
                                "A thin line atop the session view showing how full its context is. The window size is detected per session."),
                              isOn: $settings.showContextProgress)
                Stepper(value: $settings.recentToolCallsLimit, in: 5...50, step: 5) {
                    HStack {
                        Text(L("보관할 최근 툴 호출 수", "Recent tool calls to keep"))
                        Spacer()
                        Text("\(settings.recentToolCallsLimit)")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(L("공통 · Claude Code · Codex", "Shared · Claude Code · Codex"))
            }

            Section {
                Toggle(L("사용", "Enabled"), isOn: claudeEnabled)
                Toggle(L("권한 대기 표시 (날개의 Needs OK)", "Show permission indicator (Needs OK on the wing)"), isOn: $settings.showPermissionIndicator)
                    .disabled(!claudeEnabled.wrappedValue)
                Toggle(L("할 일 목록 표시 (Current Tasks 카드)", "Show todo list (Current Tasks card)"), isOn: $settings.showTodoList)
                    .disabled(!claudeEnabled.wrappedValue)
            } header: {
                Text("Claude Code")
            }

            Section {
                Toggle(L("사용량 한도 추적", "Enable usage quota tracking"), isOn: $settings.enableClaudeUsage)
                ClaudeUsageSettingsView()
                    .disabled(!settings.enableClaudeUsage)
            } header: {
                Text(L("Claude Code · 사용량", "Claude Code · Usage"))
            }

            Section {
                HStack {
                    TextField(L("SSH 호스트", "SSH hosts"), text: $settings.remoteClaudeHosts, prompt: Text("myserver, other-host"))
                        .onSubmit { remote.apply() }
                    Button(L("연결", "Connect")) { remote.apply() }
                }
                ForEach(remote.statuses.keys.sorted(), id: \.self) { host in
                    LabeledContent(host, value: remote.statuses[host] ?? "")
                }
                if telemetry.state != .running {
                    Text(L("텔레메트리 수신기가 꺼져 있어 원격 이벤트를 받을 수 없습니다.", "The telemetry receiver is off, so remote events can't arrive."))
                        .foregroundStyle(.orange)
                }
            } header: {
                Text(L("Claude Code · 원격 (SSH)", "Claude Code · Remote (SSH)"))
            }

            Section {
                Toggle(L("사용", "Enabled"), isOn: codexEnabled)
            } header: {
                Text("Codex")
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Telemetry

struct TelemetryStatusTab: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var telemetryCoordinator: TelemetryCoordinator

    var body: some View {
        Form {
            Section {
                HStack {
                    Text(L("OTLP HTTP 포트", "OTLP HTTP Port"))
                    Spacer()
                    TextField(L("포트", "Port"), value: $settings.telemetryOtlpPort, format: .number)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                }
            } header: {
                Text(L("수신기", "Receiver"))
            }

            Section {
                Toggle(L("알 수 없음", "Unknown"), isOn: $settings.showSourceUnknown)
            } header: {
                Text(L("출처", "Sources"))
            }

            Section {
                HStack {
                    TelemetryStatusIndicatorView(state: telemetryCoordinator.state)
                    Text(stateText)
                        .font(.system(size: 12))

                    Spacer()

                    if telemetryCoordinator.state == .running {
                        Button(L("중지", "Stop")) {
                            Task { await telemetryCoordinator.stop() }
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    } else if telemetryCoordinator.state == .stopped {
                        Button(L("시작", "Start")) {
                            Task { await telemetryCoordinator.start() }
                        }
                        .buttonStyle(.bordered)
                        .tint(.green)
                    }
                }
            } header: {
                Text(L("상태", "Status"))
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var stateText: String {
        switch telemetryCoordinator.state {
        case .stopped: return L("중지됨", "Stopped")
        case .starting: return L("시작 중", "Starting")
        case .running: return L("수신 중", "Listening")
        case .error(let message): return L("오류: ", "Error: ") + message
        }
    }
}

#Preview {
    AgentSettingsView()
        .environmentObject(TelemetryCoordinator.shared)
}
