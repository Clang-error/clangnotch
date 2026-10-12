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
        }
        // Rebuilds every tab when the language changes; the picker lives on the first tab.
        .id(settings.settingsLanguage)
        .frame(width: 480, height: 560)
    }
}

// MARK: - General

struct AppGeneralSettingsTab: View {
    @ObservedObject var settings: AppSettings
    @State private var launchAtLogin = LoginItem.isEnabled

    var body: some View {
        Form {
            Section {
                Picker(L("설정 언어", "Settings language"), selection: $settings.settingsLanguage) {
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
                Toggle(L("실행 시 텔레메트리 수신기 시작", "Start telemetry receiver on launch"), isOn: $settings.telemetryAutoStart)
                Toggle(L("메뉴 막대 아이콘 표시", "Show menu bar icon"), isOn: $settings.showMenuBarItem)
            } header: {
                Text(L("시작", "Startup"))
            }

            Section {
                Toggle(L("배터리 절약 모드", "Battery saver mode"), isOn: $settings.batterySaverEnabled)
            } header: {
                Text(L("성능", "Performance"))
            } footer: {
                Text(L("배터리 사용 중 15 FPS, 충전 중 25 FPS.", "15 FPS on battery, 25 FPS when charging."))
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
            } footer: {
                Text(L(
                    "체크를 해제한 탭은 노치에 나타나지 않고, 나머지는 드래그해 순서를 바꿉니다. 체크 해제는 칩만 숨깁니다. 기능 자체가 동작할지는 아래 스위치가 정합니다.",
                    "Uncheck a tab to keep it out of the notch, drag to reorder the rest. Unchecking only hides the chip — the switches below decide whether a feature runs at all."
                ))
            }

            Section {
                Toggle(L("클립보드 기록", "Clipboard history"), isOn: $settings.enableClipboardHistory)
                    .onChange(of: settings.enableClipboardHistory) { _, _ in
                        ClipboardManager.shared.syncWithSettings()
                    }
                Toggle(L("앱별 볼륨 믹서", "Per-app volume mixer"), isOn: $settings.enableAudioMixer)
                    .onChange(of: settings.enableAudioMixer) { _, on in
                        if on { AudioMixerManager.shared.start() } else { AudioMixerManager.shared.stop() }
                    }
                Toggle(L("Sidecar 빠른 연결", "Sidecar quick-connect"), isOn: $settings.enableSidecar)
                    .onChange(of: settings.enableSidecar) { _, on in
                        if on { SidecarManager.shared.start() } else { SidecarManager.shared.stop() }
                    }
                Toggle(L("배터리 잔량", "Battery levels"), isOn: $settings.enableBattery)
                Toggle(L("인터넷 속도 측정", "Internet speed test"), isOn: $settings.enableSpeedTest)
                Toggle(L("키보드 잠금", "Keyboard lock"), isOn: $settings.enableKeyboardLock)
            } header: {
                Text(L("기능", "Features"))
            } footer: {
                Text(L("""
                클립보드 기록은 최근 복사한 텍스트를 메모리에만 보관하며 비밀번호는 건너뜁니다. \
                앱별 볼륨은 오디오 캡처 권한이 필요합니다. 배터리는 Mac, 블루투스 액세서리, iOS 기기를 \
                보여 줍니다. 속도 측정은 측정 버튼을 눌렀을 때만 트래픽을 보냅니다. \
                키보드 잠금은 손쉬운 사용 권한이 필요하며 직접 풀 때까지 잠겨 있습니다.
                """, """
                Clipboard history keeps recent copied text in memory; passwords are skipped. \
                Per-app volume needs audio-capture permission. Battery covers the Mac, Bluetooth \
                accessories and iOS devices. Speed test only sends traffic when you press Test. \
                Keyboard lock needs Accessibility permission and stays locked until you unlock it.
                """))
            }

            Section {
                Toggle(L("Wi-Fi 네트워크 이름 표시", "Show Wi-Fi network name"), isOn: $settings.enableNetworkName)
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
            } footer: {
                Text(L("""
                macOS는 위치 서비스 권한이 있는 앱에만 Wi-Fi 네트워크 이름(SSID)을 알려 줍니다. \
                이 기능은 위치를 그 밖의 용도로 쓰지 않습니다. 권한이 없으면 속도 측정에는 \
                연결 종류 이름("Wi-Fi", "Ethernet")이 대신 표시됩니다.
                """, """
                macOS only reveals the Wi-Fi network name (SSID) to apps with Location Services \
                access — nothing else here uses your location. Without it the speed test falls \
                back to the connection's name ("Wi-Fi", "Ethernet").
                """))
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
struct AgentsSettingsTab: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var remote = RemoteClaudeManager.shared
    @ObservedObject private var telemetry = TelemetryCoordinator.shared

    var body: some View {
        Form {
            Section {
                Toggle("Claude Code", isOn: $settings.showSourceClaudeCode)
                Toggle("Codex", isOn: $settings.showSourceCodex)
                Toggle("Antigravity (Gemini)", isOn: $settings.enableAntigravity)
                Toggle(L("알 수 없음", "Unknown"), isOn: $settings.showSourceUnknown)
            } header: {
                Text(L("소스", "Sources"))
            } footer: {
                Text(L("노치에 활동을 표시할 에이전트입니다.", "Which agents' activity reaches the notch."))
            }

            Section {
                Toggle(L("JSONL 세션 추적", "Enable JSONL session tracking"), isOn: $settings.enableClaudeCodeJSONL)
                Toggle(L("세션 점 표시", "Show session dots"), isOn: $settings.showSessionDots)
                    .disabled(!settings.enableClaudeCodeJSONL)
                Toggle(L("권한 대기 표시", "Show permission indicator"), isOn: $settings.showPermissionIndicator)
                    .disabled(!settings.enableClaudeCodeJSONL)
                Toggle(L("할 일 목록 표시", "Show todo list"), isOn: $settings.showTodoList)
                    .disabled(!settings.enableClaudeCodeJSONL)
                Toggle(L("생각 중 상태 표시", "Show thinking state"), isOn: $settings.showThinkingState)
                    .disabled(!settings.enableClaudeCodeJSONL)
            } header: {
                Text("Claude Code")
            } footer: {
                Text(L("~/.claude를 읽어 세션을 추적합니다.", "Reads ~/.claude to track sessions."))
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
                Text(L("원격 Claude Code (SSH)", "Remote Claude Code (SSH)"))
            } footer: {
                Text(L("~/.ssh/config의 호스트 별칭을 쉼표로 구분해 입력합니다. SSH 키 로그인만 지원합니다. ClangNotch가 각 호스트의 ~/.claude/settings.json에 훅을 추가하고(백업: settings.json.clangnotch-bak) 이 앱까지 SSH 역터널을 열어 둡니다. 호스트에서 이미 실행 중인 세션은 다시 시작해야 표시됩니다.", "Host aliases from ~/.ssh/config, comma-separated; key-based login is required. ClangNotch adds a hook to each host's ~/.claude/settings.json (backup: settings.json.clangnotch-bak) and keeps an SSH reverse tunnel open to this app. Sessions already running on the host show up after they restart."))
            }

            Section {
                Toggle(L("사용량 한도 추적", "Enable usage quota tracking"), isOn: $settings.enableClaudeUsage)
                Toggle(L("닫힌 노치에 표시", "Show in closed notch"), isOn: $settings.showClaudeUsageInClosedNotch)
                    .disabled(!settings.enableClaudeUsage)

                ClaudeUsageSettingsView()
                    .disabled(!settings.enableClaudeUsage)
            } header: {
                Text(L("Claude API 사용량", "Claude API Usage"))
            }

            Section {
                Toggle(L("JSONL 세션 추적", "Enable JSONL session tracking"), isOn: $settings.enableCodexJSONL)
            } header: {
                Text("OpenAI Codex")
            } footer: {
                Text(L("~/.codex/sessions를 읽어 세션을 추적합니다.", "Reads ~/.codex/sessions to track sessions."))
            }

            Section {
                Toggle(L("토큰 수 표시", "Show token count"), isOn: $settings.showNotchTokenCount)
                Toggle(L("입력/출력 토큰 표시", "Show input/output tokens"), isOn: $settings.showNotchTokenBreakdown)
                Toggle(L("비용 표시", "Show price"), isOn: $settings.showNotchCost)
                Toggle(L("컨텍스트 진행 막대 표시", "Show context progress bar"), isOn: $settings.showContextProgress)

                Stepper(value: $settings.contextTokenLimit, in: 50_000...1_000_000, step: 50_000) {
                    HStack {
                        Text(L("컨텍스트 한도", "Context limit"))
                        Spacer()
                        Text("\(settings.contextTokenLimit / 1000)k")
                            .foregroundColor(.secondary)
                    }
                }

                Stepper(value: $settings.recentToolCallsLimit, in: 5...50, step: 5) {
                    HStack {
                        Text(L("보관할 최근 툴 호출 수", "Recent tool calls to keep"))
                        Spacer()
                        Text("\(settings.recentToolCallsLimit)")
                            .foregroundColor(.secondary)
                    }
                }

                Picker(L("툴 표시 방식", "Tool display mode"), selection: $settings.toolDisplayMode) {
                    Text(L("최근 이벤트 목록", "Recent events list")).tag("list")
                    Text(L("단일 상세 이벤트", "Single detailed event")).tag("singular")
                }
                .pickerStyle(.segmented)
            } header: {
                Text(L("노치 표시", "Display in Notch"))
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
