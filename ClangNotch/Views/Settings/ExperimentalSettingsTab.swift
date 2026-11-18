import AppKit
import SwiftUI

/// 설정 › 실험 기능: things that lean on another app's internals and may stop working after
/// that app updates, and try-outs like the 아이콘 모자. Each is off until turned on.
struct ExperimentalSettingsTab: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var typingSounds = TypingSounds.shared

    var body: some View {
        Form {
            Section {
                SettingToggle(L("Codex 질문에 노치에서 답하기", "Answer Codex questions from the notch"),
                              L("Codex 앱과 터미널 Codex(Plan 모드)가 선택지로 물으면 노치에서 바로 답함. Codex 내부 연결을 써서 업데이트되면 안 될 수 있음",
                                "Answers multiple-choice questions from the Codex app and from Codex in a terminal (Plan mode). Uses Codex's internal connections, so an update may break it"),
                              isOn: $settings.experimentalCodexAppAnswers)
                    .disabled(!settings.showSourceCodex)
            } header: {
                Text("Codex")
            }

            Section {
                SettingToggle(L("Claude 다음 단계에 노치에서 답하기", "Answer Claude next steps from the notch"),
                              L("Claude 앱이 다음 단계 상자로 물으면 노치에서 버튼을 눌러 답함. Claude Code 훅으로 세션을 깨워 답을 전해서 앱에서 누른 것과 기록이 다름",
                                "Press the Claude app's next-step buttons from the notch. A Claude Code hook wakes the session with the answer, so the record differs from pressing in the app"),
                              isOn: $settings.experimentalClaudeNextStepAnswers)
                    .disabled(!settings.showSourceClaudeCode)
                    .onChange(of: settings.experimentalClaudeNextStepAnswers) { _, _ in
                        ClaudeCodeManager.shared.syncNextStepHook()
                    }
                SettingToggle(L("Claude 아이콘에 모자 씌우기", "Hats on the Claude icon"),
                              L("닫힌 노치 날개의 Claude 아이콘이 세션마다 하는 일에 따라 모자를 씀. 서브에이전트 1~2개는 실크해트, 3개 이상은 마법사 모자, 2분 넘게 이어지는 세션은 안전모, Done은 왕관",
                                "Each Claude icon in the closed notch's wings wears a hat for what its session is doing: a top hat with one or two subagents, a wizard hat with three or more, a hard hat on a session past two minutes, a crown on Done"),
                              isOn: $settings.experimentalClaudeIconHats)
                    .disabled(!settings.showSourceClaudeCode)
            } header: {
                Text("Claude Code")
            } footer: {
                Text(L("다른 앱의 내부 동작에 의존하는 기능이라, 그 앱이 업데이트되면 안 될 수 있음.",
                       "These lean on other apps' internals and may stop working when those apps update."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                SettingToggle(L("입력 효과음", "Typing sounds"),
                              L("키보드와 마우스 버튼을 누를 때마다 소리 팩 폴더에 넣은 소리를 냄",
                                "A sound from your sound pack folder for every key and mouse button pressed"),
                              isOn: $settings.experimentalTypingSounds)
                    .onChange(of: settings.experimentalTypingSounds) { _, _ in typingSounds.syncWithSettings() }
                // Stays while the switch is off: the shortcut is what turns it back on.
                if settings.experimentalTypingSounds || settings.experimentalTypingSoundsShortcutKey >= 0 {
                    TypingSoundShortcutRow(settings: settings)
                }
                if settings.experimentalTypingSounds {
                    Toggle(L("헤드폰, 이어폰일 때만", "Only on headphones"),
                           isOn: $settings.experimentalTypingSoundsHeadphonesOnly)
                        .onChange(of: settings.experimentalTypingSoundsHeadphonesOnly) { _, _ in typingSounds.syncWithSettings() }
                    if let output = typingSounds.askedOutput {
                        Toggle(L("\(output.name)에서도 소리 내기", "Also on \(output.name)"),
                               isOn: Binding(get: { typingSounds.allows(output.uid) },
                                             set: { typingSounds.allow(output.uid, $0) }))
                    }
                    typingVolume(L("키보드 소리 크기", "Key sound volume"), $settings.experimentalTypingSoundsKeyVolume, .letter)
                    typingVolume(L("클릭 소리 크기", "Click sound volume"), $settings.experimentalTypingSoundsMouseVolume, .mouse)
                    LabeledContent {
                        Button(L("소리 팩 폴더 열기", "Open Sound Pack Folder")) { typingSounds.openPackFolder() }
                    } label: {
                        if typingSounds.status == .noPermission {
                            Text(L("손쉬운 사용이나 입력 모니터링 권한이 필요함", "Needs Accessibility or Input Monitoring permission"))
                                .font(.callout)
                        } else if typingSounds.status == .noPack {
                            Text(L("폴더에 소리 파일이 없음", "No sound files in the folder"))
                                .font(.callout)
                        }
                    }
                }
            } header: {
                Text(L("소리", "Sound"))
            } footer: {
                Text(L("소리는 앱에 들어 있지 않음. 소리 팩 폴더에 letter.wav, punctuation.wav, space.wav, special.wav, mouse.wav를 넣고 스위치를 껐다 켜면 읽음. 없는 종류는 소리가 안 남. 누른 키는 소리를 고르는 데만 쓰고 남기지 않음.",
                       "No sounds come with the app. Put letter.wav, punctuation.wav, space.wav, special.wav and mouse.wav in the sound pack folder, then turn the switch off and on to read them. A kind without its file is silent. The key pressed only picks the sound and is not kept."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    /// A volume row: 0 to 200%, and the sound once at the new level when the slider is let go.
    private func typingVolume(_ title: String, _ value: Binding<Double>, _ kind: TypingSoundKind) -> some View {
        HStack(spacing: 8) {
            Text(title)
            Image(systemName: "speaker.fill").foregroundStyle(.secondary)
            Slider(value: value, in: 0...2) { editing in
                if !editing { typingSounds.preview(kind) }
            }
            .onChange(of: value.wrappedValue) { _, _ in typingSounds.applyVolumes() }
            Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
            Text("\(Int((value.wrappedValue * 100).rounded()))%")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }
}

/// 입력 효과음's "켜고 끄는 단축키": the button shows the shortcut and, pressed, takes the next
/// key held with ⌃, ⌥ or ⌘ as the new one. Esc leaves it as it was; the x removes it.
private struct TypingSoundShortcutRow: View {
    @ObservedObject var settings: AppSettings
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        LabeledContent(L("켜고 끄는 단축키", "Shortcut to turn on and off")) {
            HStack(spacing: 6) {
                Button(recording ? L("키를 누르세요", "Press the keys")
                       : settings.experimentalTypingSoundsShortcutKey < 0 ? L("지정", "Set")
                       : settings.experimentalTypingSoundsShortcutLabel) {
                    recording ? stop() : start()
                }
                if settings.experimentalTypingSoundsShortcutKey >= 0, !recording {
                    Button {
                        save(key: -1, modifiers: [], label: "")
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(L("단축키 지우기", "Remove the shortcut"))
                }
            }
        }
        .onDisappear { stop() }
        // The settings window closed or left behind mid-recording: the monitor would go on
        // taking keys from the app's other windows, and the next ⌘V would become the shortcut.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            if recording { stop() }
        }
    }

    private func start() {
        recording = true
        TypingSounds.shared.releaseShortcut()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = TypingSoundShortcut.modifiers(of: event.modifierFlags)
            if Int(event.keyCode) == TypingSoundShortcut.escapeKey, flags.isEmpty {
                stop()
            } else if TypingSoundShortcut.isUsable(flags) {
                save(key: Int(event.keyCode), modifiers: flags,
                     label: TypingSoundShortcut.label(key: Int(event.keyCode), modifiers: flags,
                                                      characters: TypingSoundShortcut.character(forKey: Int(event.keyCode))
                                                          ?? event.charactersIgnoringModifiers))
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    /// Ends the recording, the key monitor with it, and takes the saved shortcut again.
    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        TypingSounds.shared.syncShortcut()
    }

    private func save(key: Int, modifiers: NSEvent.ModifierFlags, label: String) {
        let before = (settings.experimentalTypingSoundsShortcutKey, settings.experimentalTypingSoundsShortcutModifiers,
                      settings.experimentalTypingSoundsShortcutLabel)
        settings.experimentalTypingSoundsShortcutKey = key
        settings.experimentalTypingSoundsShortcutModifiers = Int(modifiers.rawValue)
        settings.experimentalTypingSoundsShortcutLabel = label
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        // A shortcut macOS won't give isn't shown as set.
        if !TypingSounds.shared.syncShortcut() {
            NSSound.beep()
            (settings.experimentalTypingSoundsShortcutKey, settings.experimentalTypingSoundsShortcutModifiers,
             settings.experimentalTypingSoundsShortcutLabel) = before
            TypingSounds.shared.syncShortcut()
        }
    }
}
