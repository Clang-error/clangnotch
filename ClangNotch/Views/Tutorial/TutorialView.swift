import AppKit
import AVFoundation
import SwiftUI

/// The 튜토리얼's pages. The first picks the language and the rest follow it at once, clips
/// included: each has a Korean and an English take (`tutorial-<page>-<ko|en>.mp4`, recorded with
/// docs/demo-pipeline). The switches are the settings' own, with the same side effects.
struct TutorialView: View {
    /// 60 pt taller than 새로운 점 (460x520): the Sessions page's two agent columns with their
    /// 실험 기능 didn't fit under the clip.
    static let size = CGSize(width: 460, height: 580)

    @ObservedObject var tutorial: Tutorial
    let close: () -> Void
    @ObservedObject private var settings = AppSettings.shared
    @State private var page: Page = .language

    enum Page: Int, CaseIterable {
        case language, notch, sessions, questions, hud, tabs

        /// The clip's name without its language.
        var clip: String? {
            switch self {
            case .language: nil
            case .notch: "tutorial-notch"
            case .sessions: "tutorial-sessions"
            case .questions: "tutorial-questions"
            case .hud: "tutorial-hud"
            case .tabs: "tutorial-tabs"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch page {
                case .language: languagePage
                case .notch: notchPage
                case .sessions: sessionsPage
                case .questions: questionsPage
                case .hud: hudPage
                case .tabs: tabsPage
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 32)
            .padding(.top, 32)
            footer
        }
        .frame(width: Self.size.width, height: Self.size.height)
        // L() reads the saved language when a body runs: a pick on the first page redraws all.
        .id(settings.settingsLanguage)
    }

    // MARK: Pages

    private var languagePage: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("ClangNotch")
                .font(.title2.weight(.semibold))
            Text(L("언어 선택. 설정 -> 일반에서도 변경 가능.", "Pick a language. Also in Settings -> General."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .frame(maxWidth: .infinity)
                .padding(.top, 44)
            HStack(spacing: 12) {
                languageButton("ko", title: "한국어", subtitle: "Korean")
                languageButton("en", title: "English", subtitle: "영어")
            }
            .padding(.top, 28)
        }
    }

    private var notchPage: some View {
        page(.notch,
             title: L("노치 열기, 탭 이동", "Open the notch, switch tabs"),
             caption: (settings.notchOpensOnClick
                        ? L("노치 클릭 시 열림.", "Opens when the notch is clicked.")
                        : L("노치에 마우스 올릴 시 열림.", "Opens when the pointer rests on the notch."))
                + L(" 열린 동안 ⌘1~⌘7로 탭 이동. 단, 단축키는 손쉬운 사용 권한 필요.",
                    " ⌘1–⌘7 switch tabs while it's open. The shortcuts need Accessibility.")) {
            EmptyView()
        }
    }

    private var sessionsPage: some View {
        page(.sessions,
             title: L("세션 카드, 날개", "Sessions card and wings"),
             caption: L("Claude Code, Codex 작업 시 닫힌 노치 양옆 날개에 표시. 세션 줄 클릭 시 세션 화면 열림.",
                        "While Claude Code or Codex works, the wings beside the closed notch show it. A session row opens its steps and diffs.")) {
            // One column per agent: its switch, then its 실험 기능 (the same keys as 설정 -> 실험
            // 기능, shorter names under the agent's own heading; the setting's name is the tooltip).
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 5) {
                    columnHeading("Claude Code")
                    switchRow(L("사용", "Enabled"), $settings.showSourceClaudeCode)
                    experimentalHeading
                    Group {
                        switchRow(L("다음 단계 답하기", "Answer next steps"), $settings.experimentalClaudeNextStepAnswers)
                            .help(L("Claude 다음 단계에 노치에서 답하기", "Answer Claude next steps from the notch"))
                            .onChange(of: settings.experimentalClaudeNextStepAnswers) { SettingEffects.claudeHooksChanged() }
                        switchRow(L("새 세션 제안 답하기", "Answer new session offers"), $settings.experimentalClaudeSessionOffers)
                            .help(L("Claude 새 세션 제안에 노치에서 답하기", "Answer Claude new session offers from the notch"))
                            .onChange(of: settings.experimentalClaudeSessionOffers) { SettingEffects.claudeHooksChanged() }
                        switchRow(L("아이콘 모자", "Icon hats"), $settings.experimentalClaudeIconHats)
                            .help(L("Claude 아이콘에 모자 씌우기", "Hats on the Claude icon"))
                    }
                    .disabled(!settings.showSourceClaudeCode)
                }
                VStack(alignment: .leading, spacing: 5) {
                    columnHeading("Codex")
                    switchRow(L("사용", "Enabled"), $settings.showSourceCodex)
                        .onChange(of: settings.showSourceCodex) { SettingEffects.codexChanged() }
                    experimentalHeading
                    switchRow(L("질문 답하기", "Answer questions"), $settings.experimentalCodexAppAnswers)
                        .help(L("Codex 질문에 노치에서 답하기", "Answer Codex questions from the notch"))
                        .disabled(!settings.showSourceCodex)
                }
                // Codex's names are short; Claude's column gets the rest ("Answer new session offers").
                .frame(width: 150)
            }
        }
    }

    private func columnHeading(_ title: String) -> some View {
        Text(title).font(.callout.weight(.semibold))
    }

    private var experimentalHeading: some View {
        Text(L("실험 기능", "Experimental"))
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 2)
    }

    private var questionsPage: some View {
        page(.questions,
             title: L("권한, 질문 드롭다운", "Permission and question dropdowns"),
             caption: L("Claude가 허락을 구하거나 질문 시 노치에서 바로 답하기 가능.",
                        "When Claude asks for permission or asks a question, answer it right in the notch.")) {
            switchRow(L("권한 대기 표시 (날개의 Needs OK)", "Show permission indicator (Needs OK on the wing)"),
                      $settings.showPermissionIndicator)
            switchRow(L("효과음", "Sounds"), $settings.notchSoundsEnabled)
        }
    }

    private var hudPage: some View {
        page(.hud,
             title: L("조절창, 복사 드롭다운", "HUD and copy dropdown"),
             caption: L("볼륨, 밝기 조절 시 macOS 표시 대신 노치 아래에 조절창 표시. 복사 시 노치에서 드롭다운 표시. 단, 조절창은 손쉬운 사용 권한 필요.",
                        "Volume and brightness show in a HUD under the notch, in place of macOS's. A copy drops from the notch. The HUD needs Accessibility.")) {
            switchRow(L("볼륨, 밝기 표시 바꾸기", "Replace volume and brightness HUD"), $settings.centerSystemBanners)
                .onChange(of: settings.centerSystemBanners) { _, on in SettingEffects.systemBannersChanged(on) }
            switchRow(L("복사 드롭다운 표시", "Copy dropdown"), $settings.clipboardOrb)
        }
    }

    private var tabsPage: some View {
        page(.tabs,
             title: L("유틸 탭", "Utility tabs"),
             caption: L("켜 둔 기능마다 노치에 탭 추가.", "Each feature turned on gets a tab in the notch.")) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    switchRow(L("클립보드 기록", "Clipboard history"), $settings.enableClipboardHistory)
                        .onChange(of: settings.enableClipboardHistory) { SettingEffects.clipboardHistoryChanged() }
                    switchRow(L("앱별 볼륨 믹서", "Per-app volume mixer"), $settings.enableAudioMixer)
                        .onChange(of: settings.enableAudioMixer) { _, on in SettingEffects.audioMixerChanged(on) }
                }
                GridRow {
                    switchRow(L("Sidecar 빠른 연결", "Sidecar quick-connect"), $settings.enableSidecar)
                        .onChange(of: settings.enableSidecar) { _, on in SettingEffects.sidecarChanged(on) }
                    switchRow(L("배터리 잔량", "Battery levels"), $settings.enableBattery)
                        .onChange(of: settings.enableBattery) { _, on in SettingEffects.batteryChanged(on) }
                }
                GridRow {
                    switchRow(L("인터넷 속도 측정", "Internet speed test"), $settings.enableSpeedTest)
                    switchRow(L("키보드 잠금", "Keyboard lock"), $settings.enableKeyboardLock)
                        .onChange(of: settings.enableKeyboardLock) { _, on in SettingEffects.askForAccessibility(on) }
                }
            }
        }
    }

    // MARK: Parts

    /// A page under the first: its clip, title, what it says, then its switches.
    private func page(_ page: Page, title: String, caption: String,
                      @ViewBuilder switches: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let clip = page.clip {
                TutorialClip(name: "\(clip)-\(L("ko", "en"))")
                    .frame(height: 223)
            }
            Text(title)
                .font(.title3.weight(.semibold))
                .padding(.top, 18)
            Text(caption)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 6) {
                switches()
            }
            .padding(.top, 14)
        }
    }

    private func switchRow(_ title: String, _ isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            // One line: "Sidecar quick-connect" wrapped in a half-width column.
            Text(title)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }

    /// Picking writes the language straight away; without a pick it stays as it was
    /// (following the system, out of the box), which is the one shown as picked.
    private func languageButton(_ code: String, title: String, subtitle: String) -> some View {
        let picked = L("ko", "en") == code
        return Button {
            settings.settingsLanguage = code
        } label: {
            VStack(spacing: 4) {
                Text(title).font(.title3.weight(.medium))
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 88)
            .background(picked ? Color.accentColor.opacity(0.15) : Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(picked ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: picked ? 2 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        ZStack {
            HStack(spacing: 16) {
                if page != .language {
                    Button(L("이전", "Back")) { move(-1) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
                if page == .tabs, tutorial.whatsNewNotes != nil {
                    Button(L("새로운 점 보기", "What's New")) { tutorial.openWhatsNew() }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                }
                Spacer()
                Button(page == .tabs ? L("시작", "Start") : L("다음", "Next")) {
                    if page == .tabs { close() } else { move(1) }
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
            }
            HStack(spacing: 7) {
                ForEach(Page.allCases, id: \.self) { dot in
                    Circle()
                        .fill(dot == page ? Color.primary : Color.secondary.opacity(0.35))
                        .frame(width: 6, height: 6)
                }
            }
            .accessibilityElement()
            .accessibilityLabel(L("\(Page.allCases.count)쪽 중 \(page.rawValue + 1)쪽", "Page \(page.rawValue + 1) of \(Page.allCases.count)"))
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 24)
    }

    private func move(_ step: Int) {
        guard let next = Page(rawValue: page.rawValue + step) else { return }
        page = next
    }
}

/// A clip that loops without sound, played by Core Animation (an AVPlayerLayer), not redrawn
/// by SwiftUI. A missing file leaves the black frame. It rounds its own corners: a SwiftUI clip
/// doesn't reach an NSView's layers.
private struct TutorialClip: NSViewRepresentable {
    let name: String

    func makeNSView(context: Context) -> ClipView { ClipView() }
    func updateNSView(_ view: ClipView, context: Context) { view.play(name) }
    static func dismantleNSView(_ view: ClipView, coordinator: ()) { view.stop() }

    final class ClipView: NSView {
        private let playerLayer = AVPlayerLayer()
        private var looper: AVPlayerLooper?
        private var playing: String?

        override init(frame: NSRect) {
            super.init(frame: frame)
            layer = CALayer()
            wantsLayer = true
            layer?.backgroundColor = NSColor.black.cgColor
            layer?.cornerRadius = 10
            layer?.cornerCurve = .continuous
            layer?.masksToBounds = true
            playerLayer.videoGravity = .resizeAspectFill
            layer?.addSublayer(playerLayer)
        }

        required init?(coder: NSCoder) { nil }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = bounds
            CATransaction.commit()
        }

        func play(_ name: String) {
            guard name != playing else { return }
            stop()
            playing = name
            guard let url = Bundle.main.url(forResource: name, withExtension: "mp4") else { return }
            let player = AVQueuePlayer()
            player.isMuted = true
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
            playerLayer.player = player
            player.play()
        }

        func stop() {
            playerLayer.player?.pause()
            playerLayer.player = nil
            looper = nil
            playing = nil
        }
    }
}
