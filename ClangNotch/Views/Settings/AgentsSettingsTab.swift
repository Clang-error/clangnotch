import AppKit
import SwiftUI

/// Which coding agents are tracked, and how their activity reads in the notch.
/// The shared settings first, then one section per agent, so nothing about an agent is
/// split across the page.
struct AgentsSettingsTab: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var remote = RemoteClaudeManager.shared
    @ObservedObject private var remoteCodex = RemoteCodexManager.shared

    /// One switch per agent: showing it in the notch and reading its session logs go together.
    private var claudeEnabled: Binding<Bool> { $settings.showSourceClaudeCode }
    private var codexEnabled: Binding<Bool> { $settings.showSourceCodex }

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
                // Typed like the dropdown times (설정 -> 노치): LabeledContent keeps one centred row.
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent(L("쉬는 세션이 목록에 남는 시간", "How long a quiet session stays listed")) {
                        HStack(alignment: .center, spacing: 6) {
                            let range = SessionRetention.minutesRange
                            TextField("", value: Binding(get: { settings.sessionKeepMinutes },
                                                         set: { settings.sessionKeepMinutes = min(range.upperBound, max(range.lowerBound, $0)) }),
                                      format: .number)
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                                .monospacedDigit()
                                .frame(width: 46)
                            Text(L("분", "min"))
                                .foregroundColor(.secondary)
                            Stepper("", value: $settings.sessionKeepMinutes, in: range)
                                .labelsHidden()
                        }
                    }
                    Text(L("마지막 활동 뒤, 설정 시간이 지나면 세션이 목록에서 제외(1~240분). 작업 중인 세션 및 고정된 세션은 유지.",
                           "A session leaves the list this long after its last activity (1–240 min). Working and pinned sessions stay."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                SettingToggle(L("사용량 추정", "Usage forecast"),
                              L("지금 속도로 쓰면 리셋 시 몇 %일지 예측.",
                                "Predicts the % at reset at the current pace."),
                              isOn: $settings.usagePaceEnabled)
                SettingToggle(L("컨텍스트 막대 표시", "Show context bar"),
                              L("세션 화면 맨 위에 컨텍스트 사용량 표시.",
                                "Context usage atop the session view."),
                              isOn: $settings.showContextProgress)
                // Covers Codex approvals too, so it isn't under Claude Code.
                Toggle(L("권한 대기 표시 (날개의 Needs OK)", "Show permission indicator (Needs OK on the wing)"), isOn: $settings.showPermissionIndicator)
                    .disabled(!claudeEnabled.wrappedValue && !codexEnabled.wrappedValue)
            } header: {
                Text(L("공통, Claude Code, Codex", "Shared, Claude Code, Codex"))
            }

            Section {
                VStack(alignment: .leading, spacing: 2) {
                    Picker(L("터미널 앱", "Terminal app"), selection: $settings.preferredTerminal) {
                        Text(L("자동", "Automatic")).tag("")
                        ForEach(KnownTerminals.installed, id: \.bundleID) { Text($0.name).tag($0.bundleID) }
                    }
                    Text(L("Sessions 카드의 시작에서 여는 터미널. 자동은 세션이 마지막으로 돌던 터미널.",
                           "The terminal the Sessions card's Start opens. Automatic: the one your sessions last ran in."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                AgentsCardOrderView(settings: settings)
                SessionCardPageOrderView(settings: settings)
                SessionCardHistoryReset()
            } header: {
                Text(L("Agents 탭 카드", "Agents tab cards"))
            }

            Section {
                Toggle(L("사용", "Enabled"), isOn: claudeEnabled)
                Toggle(L("할 일 목록 표시 (Current Tasks 카드)", "Show todo list (Current Tasks card)"), isOn: $settings.showTodoList)
                    .disabled(!claudeEnabled.wrappedValue)
                SettingToggle(L("백그라운드 셸 표시", "Show background shells"),
                              L("Claude가 백그라운드에서 돌리는 셸, Monitor를 세션 아래 줄로 표시. 셸 종료까지 완료 보류, 실패 시 드롭다운.",
                                "Shells and Monitors Claude runs in the background, as rows under the session. Done waits for them; a failure drops down."),
                              isOn: $settings.showClaudeBackgroundShells)
                    .disabled(!claudeEnabled.wrappedValue)
                SettingToggle(L("사용량 한도 추적", "Enable usage quota tracking"),
                              L("Claude Code 로그인 정보의 한도 확인. 키체인 확인 창이 한 번 뜰 수 있음.",
                                "Checks the limits with Claude Code's sign-in. Keychain may ask once."),
                              isOn: $settings.enableClaudeUsage)
                ClaudeUsageSettingsView()
                    .disabled(!settings.enableClaudeUsage)
                Toggle(L("플랜 표시 (사용량 카드)", "Show plan (usage card)"), isOn: $settings.showClaudePlan)
                    .disabled(!claudeEnabled.wrappedValue || !settings.enableClaudeUsage)
                SettingToggle(L("SSH 원격 세션", "Remote sessions over SSH"),
                              L("SSH로 접속되는 다른 컴퓨터에서 도는 Claude Code 세션도 이 노치에 표시.",
                                "Also shows Claude Code sessions running on other computers you reach over SSH."),
                              isOn: $settings.remoteClaudeEnabled)
                    .disabled(!claudeEnabled.wrappedValue)
                    .onChange(of: settings.remoteClaudeEnabled) { remote.sync() }
                if settings.remoteClaudeEnabled {
                    RemoteHostsEditor(
                        hosts: $settings.remoteClaudeHosts, statuses: remote.statuses,
                        details: [
                            L("리눅스, 맥 컴퓨터: 그 컴퓨터의 ~/.claude에 훅 스크립트(clangnotch-hook.sh)를 넣고 settings.json에 훅 항목을 추가함. 원래 파일은 settings.json.clangnotch-bak으로 남음. 작업 중, 질문, 권한 대기, 완료를 모두 표시함. 선택지가 있는 질문은 노치에서 바로 답할 수 있음.",
                              "Linux and macOS: puts a hook script (clangnotch-hook.sh) in that computer's ~/.claude and adds hook entries to settings.json. The original is kept as settings.json.clangnotch-bak. Working, questions, approvals and Done all show, and a question with options can be answered from the notch."),
                            L("윈도우 컴퓨터(또는 curl, jq가 없어 훅을 못 넣는 컴퓨터): 아무것도 설치하지 않고 Claude Code가 남기는 대화 기록과 세션 상태만 읽어 옴. 질문과 권한 대기는 기다린다는 것만 표시하고 내용은 표시할 수 없음.",
                              "Windows (or a computer without curl and jq, where the hooks can't go): installs nothing and only reads the transcripts and session state Claude Code writes. A question or an approval shows only as waiting, without its text."),
                            L("어느 환경인지는 연결할 때 확인해 상태에 표시함.",
                              "The kind of computer is checked when connecting and shown in the state."),
                            L("이 맥이 켜져 있는 동안 SSH 연결 하나를 열어 둠.",
                              "One SSH connection stays open while this Mac is on."),
                        ],
                        sync: { remote.sync(asking: $0) }, reconnect: remote.reconnect)
                        .disabled(!claudeEnabled.wrappedValue)
                }
            } header: {
                Text("Claude Code")
            }

            Section {
                Toggle(L("사용", "Enabled"), isOn: codexEnabled)
                SettingToggle(L("사용량 한도 표시", "Show usage limits"),
                              L("Codex의 한도를 사용량 카드에 표시. 따로 로그인 없이 세션 기록과 해당 맥의 Codex에서 읽음.",
                                "Shows Codex's limits in the usage card, read from its session logs and the Codex on this Mac. No extra sign-in."),
                              isOn: $settings.showCodexUsage)
                    .disabled(!codexEnabled.wrappedValue)
                    .onChange(of: settings.showCodexUsage) { _, on in if on { CodexManager.shared.refresh() } }
                CodexAccountStatus()
                Toggle(L("플랜 표시 (사용량 카드)", "Show plan (usage card)"), isOn: $settings.showCodexPlan)
                    .disabled(!codexEnabled.wrappedValue || !settings.showCodexUsage)
                SettingToggle(L("SSH 원격 세션", "Remote sessions over SSH"),
                              L("SSH로 접속되는 다른 컴퓨터에서 도는 Codex 세션도 이 노치에 표시.",
                                "Also shows Codex sessions running on other computers you reach over SSH."),
                              isOn: $settings.remoteCodexEnabled)
                    .disabled(!codexEnabled.wrappedValue)
                    .onChange(of: settings.remoteCodexEnabled) { remoteCodex.sync() }
                    .onChange(of: settings.showSourceCodex) { SettingEffects.codexChanged() }
                if settings.remoteCodexEnabled {
                    RemoteHostsEditor(
                        hosts: $settings.remoteCodexHosts, statuses: remoteCodex.statuses,
                        details: [
                            L("리눅스, 맥, 윈도우 컴퓨터. 그 컴퓨터에는 아무것도 설치하거나 바꾸지 않고 Codex가 남기는 세션 기록만 읽어 옴.",
                              "Linux, macOS and Windows. Installs and changes nothing there, only reads the session logs Codex writes."),
                            L("작업 중, 질문, 완료가 표시됨. 권한 요청 알림과 노치에서 답하기는 안 됨.",
                              "Working, questions and Done show. No approval requests or answering from the notch."),
                            L("어느 환경인지는 연결할 때 확인함.",
                              "The kind of computer is checked when connecting."),
                            L("이 맥이 켜져 있는 동안 SSH 연결 하나를 열어 둠.",
                              "One SSH connection stays open while this Mac is on."),
                        ],
                        sync: { remoteCodex.sync(asking: $0) }, reconnect: remoteCodex.reconnect)
                        .disabled(!codexEnabled.wrappedValue)
                }
            } header: {
                Text("Codex")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

/// 설정 -> 보안: what the 권한 드롭다운 lets through.
struct SecuritySettingsTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                SettingToggle(L("위험 표시가 떠도 허용", "Allow despite a danger sign"),
                              L("받은 스크립트 실행, 관리자 권한(sudo), 비밀 정보 접근 같은 위험 표시가 떠도 노치에서 허용 가능.",
                                "Allow from the notch even when it flags a downloaded script, administrator rights (sudo) or secrets."),
                              isOn: $settings.permissionAllowFlagged)
                SettingToggle(L("긴 명령도 펼치지 않고 허용", "Allow long commands without opening them"),
                              L("3줄이나 180자를 넘는 명령을 전체 보기로 끝까지 보지 않아도 허용 가능.",
                                "Allow a command longer than 3 lines or 180 characters without reading it to the end in Show all."),
                              isOn: $settings.permissionAllowUnread)
            } header: {
                Text(L("노치에서 허용", "Allowing from the notch"))
            } footer: {
                Text(L("기본 노치 동작은 위험해 보이거나 다 보이지 않는 명령은 다 읽은 뒤에 허용, 또는 터미널에서 허용하게 됩니다. 설정을 허용한 뒤 발생하는 명령의 결과는 사용자 책임입니다.",
                       "By default the notch allows a command that looks dangerous or doesn't show in full only once it has been read, or in the terminal. What a command does after you turn these on is your own responsibility."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// What unfolds under an agent's "SSH 원격 세션" switch: its hosts, each with its connection
/// state, 다시 연결 and remove; a field to add one (`user@address`, or picked from `~/.ssh/config`); and what
/// connecting does, spelled out. The list is kept in settings as a comma-separated string.
private struct RemoteHostsEditor: View {
    @Binding var hosts: String
    let statuses: [String: String]
    /// What this agent's remote does, one line each.
    let details: [String]
    /// The list changed; the argument is a host just added, which may ask its questions.
    let sync: (String?) -> Void
    let reconnect: (String) -> Void

    @State private var draft = ""

    private var list: [String] { SSHHost.list(hosts) }

    private func add(_ host: String) {
        let host = host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, !list.contains(host) else { return }
        hosts = (list + [host]).joined(separator: ", ")
        draft = ""
        sync(host)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("호스트", "Hosts"))
                .font(.callout)
                .foregroundStyle(.secondary)
            ForEach(list, id: \.self) { host in
                HStack(spacing: 8) {
                    Text(host).font(.callout.monospaced())
                    Spacer()
                    Text(statuses[host] ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                    Button { reconnect(host) } label: { Image(systemName: "arrow.clockwise") }
                        .help(L("다시 연결 (처음 보는 호스트 확인과 비밀번호를 물을 수 있음)", "Reconnect (may ask to confirm a new host, or for a password)"))
                    Button {
                        hosts = list.filter { $0 != host }.joined(separator: ", ")
                        // Its saved password and host keys go with it once neither agent lists it:
                        // removing and adding again is what a changed host key asks for.
                        let settings = AppSettings.shared
                        if !SSHHost.list(settings.remoteClaudeHosts).contains(host), !SSHHost.list(settings.remoteCodexHosts).contains(host) {
                            SSHLogin.forget(host)
                        }
                        sync(nil)
                    } label: { Image(systemName: "minus.circle") }
                        .help(L("목록에서 빼기", "Remove from the list"))
                }
                .buttonStyle(.borderless)
            }
            // A bordered field under its own heading: borderless in the form, the placeholder
            // read as one more line of grey text and nobody saw where to type.
            Text(L("호스트 추가", "Add a host"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            HStack {
                TextField("", text: $draft, prompt: Text(L("사용자@주소  (예: me@192.168.0.10)", "user@address  (e.g. me@192.168.0.10)")))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { add(draft) }
                let aliases = SSHHost.configAliases.filter { !list.contains($0) }
                if !aliases.isEmpty {
                    Menu(L("SSH 설정에서", "From SSH config")) {
                        ForEach(aliases, id: \.self) { alias in Button(alias) { add(alias) } }
                    }
                    .fixedSize()
                }
                Button(L("추가", "Add")) { add(draft) }
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text(L("동작 방식", "How it works"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(details + [
                    L("주소: 사용자@주소 (포트가 22가 아니면 사용자@주소:포트), 또는 ~/.ssh/config에 만들어 둔 별칭.",
                      "Address: user@address (user@address:port if the port isn't 22), or an alias from ~/.ssh/config."),
                    L("처음 연결하는 컴퓨터면 신뢰할지 묻고, 키로 로그인이 안 되면 비밀번호를 물음.",
                      "A computer seen for the first time is confirmed once, and the password is asked when key login doesn't work."),
                ], id: \.self) { line in
                    Text(line)
                }
            }
            .font(.caption2)
            .foregroundColor(.secondary.opacity(0.8))
        }
    }
}

/// Codex 묶음's account line, the counterpart of "Claude Code 계정": Codex's own sign-in file
/// is there. Only its presence is checked; the usage itself comes in the session logs.
private struct CodexAccountStatus: View {
    private var detected: Bool {
        FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.codex/auth.json")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(L("Codex 계정", "Codex Account"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                HStack(spacing: 4) {
                    Circle()
                        .fill(detected ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(detected ? L("감지됨", "Detected") : L("감지 안 됨", "Not detected"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Text(L("Codex가 이 맥에 남긴 로그인 확인. 감지 안 되면 Codex에서 로그인.", "Checks the sign-in Codex left on this Mac. Sign in with Codex if not detected."))
                .font(.caption2)
                .foregroundColor(.secondary.opacity(0.7))
        }
    }
}

/// 설정 -> 에이전트 -> Sessions 카드 기록: clears what the 오늘 and 완료 기록 pages keep, all of it
/// at once (user, 2026-11-21).
private struct SessionCardHistoryReset: View {
    @ObservedObject private var log = AgentActivityLog.shared
    @State private var confirming = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Sessions 카드 기록", "Sessions card history"))
                Text(L("오늘, 7일, 전체 숫자와 완료 기록.", "The Today, 7 days and All numbers and Finished."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(L("초기화…", "Reset…")) { confirming = true }
                .disabled(log.isEmpty)
        }
        .confirmationDialog(L("Sessions 카드 기록을 모두 지울까요?", "Clear all Sessions card history?"),
                            isPresented: $confirming) {
            Button(L("초기화", "Reset"), role: .destructive) { log.reset() }
            Button(L("취소", "Cancel"), role: .cancel) {}
        }
    }
}

/// 설정 -> 에이전트 -> Sessions 카드 페이지: the Sessions card's pages (세션, 오늘, 완료 기록, 시작),
/// dragged to reorder in the same plain list (2026-11-19).
private struct SessionCardPageOrderView: View {
    @ObservedObject var settings: AppSettings

    private var pages: [SessionCardPage] { SessionCardPage.order(from: settings.sessionCardPageOrder) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("Sessions 카드 페이지", "Sessions card pages"))
            List {
                ForEach(pages) { page in
                    HStack(spacing: 8) {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Text(page.title)
                            .font(.system(size: 12))
                        Spacer()
                    }
                    .padding(.vertical, 1)
                }
                .onMove { source, destination in
                    var reordered = pages
                    reordered.move(fromOffsets: source, toOffset: destination)
                    settings.sessionCardPageOrder = SessionCardPage.stored(reordered)
                }
            }
            // Sized to the row count, with no room left under the last row.
            .frame(height: CGFloat(pages.count) * 26 + 6)
        }
    }
}

/// 설정 -> 에이전트 -> Agents 탭 카드: the Agents tab's cards under NEEDS YOU (which stays on top),
/// dragged to reorder in a plain list like 설정 › 노치 › 탭 (2026-11-19). A card that wouldn't show
/// (its agent or its own switch off) is dimmed, as the tab list dims a tab whose feature is off.
private struct AgentsCardOrderView: View {
    @ObservedObject var settings: AppSettings

    private var cards: [AgentsCard] { AgentsCard.order(from: settings.agentsCardOrder) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            List {
                ForEach(cards) { card in
                    let on = shows(card)
                    HStack(spacing: 8) {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Text(title(card))
                            .font(.system(size: 12))
                            .foregroundStyle(on ? .primary : .secondary)
                        Spacer()
                        if !on {
                            Text(L("꺼짐", "Off"))
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 1)
                }
                .onMove { source, destination in
                    var reordered = cards
                    reordered.move(fromOffsets: source, toOffset: destination)
                    settings.agentsCardOrder = AgentsCard.stored(reordered)
                }
            }
            // Sized to the row count, with no room left under the last row.
            .frame(height: CGFloat(cards.count) * 26 + 6)
        }
    }

    private func title(_ card: AgentsCard) -> String {
        switch card {
        case .claudeUsage: return L("Claude 사용량", "Claude usage")
        case .codexUsage: return L("Codex 사용량", "Codex usage")
        case .tasks: return "Current Tasks"
        case .sessions: return "Sessions"
        }
    }

    /// Whether the card would show in the notch at all, as `ClangNotchContentView.agentsCard` decides.
    private func shows(_ card: AgentsCard) -> Bool {
        switch card {
        case .claudeUsage: return settings.showSourceClaudeCode
        case .codexUsage: return settings.showSourceCodex && settings.showCodexUsage
        case .tasks: return settings.showSourceClaudeCode && settings.showTodoList
        case .sessions: return true
        }
    }
}
