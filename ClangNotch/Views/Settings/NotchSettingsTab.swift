import AppKit
import SwiftUI

/// The notch itself: which tabs exist, in what order, and how it opens.
struct NotchSettingsTab: View {
    @ObservedObject var settings: AppSettings
    @State private var displays = NotchDetector.displays

    /// A dropdown's time: a bordered box to type the seconds in, and − / + beside it. Typed
    /// values outside 2…60 are brought back into range.
    /// In a grouped Form a bare HStack with a text field becomes a label column with the field
    /// dropped below it (user's screenshot, 2026-11-12); LabeledContent keeps one centred row.
    private func foldRow(_ title: String, _ seconds: Binding<Int>, range: ClosedRange<Int> = 2...60) -> some View {
        LabeledContent(title) {
            HStack(alignment: .center, spacing: 6) {
                TextField("", value: Binding(get: { seconds.wrappedValue },
                                             set: { seconds.wrappedValue = min(range.upperBound, max(range.lowerBound, $0)) }),
                          format: .number)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 46)
                Text(L("초", "s"))
                    .foregroundColor(.secondary)
                Stepper("", value: seconds, in: range)
                    .labelsHidden()
            }
        }
    }

    var body: some View {
        Form {
            Section {
                NotchAppearancePicker(selection: $settings.notchAppearance)
                if settings.notchAppearance == NotchAppearanceMode.wallpaper.rawValue {
                    WallpaperColorSource(settings: settings)
                }
            } header: {
                Text(L("노치 색", "Notch color"))
            }

            Section {
                Picker(L("표시할 디스플레이", "Display"), selection: $settings.notchDisplay) {
                    Text(L("주 디스플레이", "Main display")).tag(NotchDetector.mainDisplay)
                    // The main display is the row above; by name only once it was picked by name.
                    ForEach(displays.filter { !$0.isMain || $0.uuid == settings.notchDisplay }, id: \.uuid) { display in
                        Text(display.name).tag(display.uuid)
                    }
                    // The picked one unplugged: it stays picked, and the notch is on the main display.
                    if settings.notchDisplay != NotchDetector.mainDisplay,
                       !displays.contains(where: { $0.uuid == settings.notchDisplay }) {
                        Text(L("연결 안 된 디스플레이", "Disconnected display")).tag(settings.notchDisplay)
                    }
                }
                .onChange(of: settings.notchDisplay) { _, _ in NotchDetector.displayChoiceChanged() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
                    displays = NotchDetector.displays
                }
                SettingToggle(L("전체 화면에서도 표시", "Show in full screen"),
                              L("전체 화면 앱 위에도 노치 유지", "Keeps the notch over full-screen apps"),
                              isOn: $settings.keepNotchInFullScreen)
            } header: {
                Text(L("표시", "Visibility"))
            }

            Section {
                SettingToggle(L("누를 때만 열기", "Open only on click"),
                              L("커서를 올려 두기만 해서는 열리지 않음", "Resting the cursor on the notch doesn't open it"),
                              isOn: $settings.notchOpensOnClick)
                if !settings.notchOpensOnClick {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(L("열리기까지 기다리는 시간", "Delay before opening"))
                        Spacer()
                        Text(String(format: L("%.1f초", "%.1fs"), settings.notchOpenDelay))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $settings.notchOpenDelay, in: 0...1, step: 0.05)
                    Text(L("커서를 노치에 위 시간만큼 올려 둬야 열림",
                           "Opens after the cursor rests on the notch this long"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                }
                SettingToggle(L("노치앱으로 인해 가려진 메뉴바 아이콘 보이기", "Show menu bar icons the notch app covers"),
                              settings.notchOpensOnClick
                                ? L("노치가 펼쳐져 가려지는 부분에 커서를 올리면, 배경이 옅어져 뒤의 메뉴바가 보이고 클릭할 수 있게 됩니다. 노치는 가운데를 눌러야 펼쳐짐.",
                                    "With the cursor on a part the widened notch covers, its background fades so the menu bar behind it shows and can be clicked. The notch opens from a click on its middle.")
                                : L("노치가 펼쳐져 가려지는 부분에 커서를 올리면, 배경이 옅어져 뒤의 메뉴바가 보이고 클릭할 수 있게 됩니다. 노치는 가운데에 올려야 펼쳐짐.",
                                    "With the cursor on a part the widened notch covers, its background fades so the menu bar behind it shows and can be clicked. The notch opens from its middle."),
                              isOn: $settings.wingStepAside)
                if settings.wingStepAside {
                    SettingToggle(L("툴팁 표시", "Show the tooltip"),
                                  L("날개가 비켜나 있는 동안 노치 아래에 툴팁을 띄움", "While a wing is aside, a tooltip shows under the notch"),
                                  isOn: $settings.wingOpenHint)
                        .padding(.leading, 20)
                }
                // Only opening on hover taps the trackpad: with 눌러서 열기 the click is the feedback,
                // so the switch would do nothing and isn't shown (user, 2026-11-19).
                if !settings.notchOpensOnClick {
                    SettingToggle(L("열릴 때 햅틱", "Haptic on open"),
                                  L("노치가 펼쳐질 때 트랙패드 햅틱", "Trackpad haptic when the notch opens"),
                                  isOn: $settings.notchHapticsEnabled)
                }
                SettingToggle(L("끝날 때 햅틱", "Haptic when done"),
                              L("세션이 작업을 끝내면 트랙패드 햅틱", "Trackpad haptic when a session finishes"),
                              isOn: $settings.doneHapticsEnabled)
                if (settings.notchHapticsEnabled && !settings.notchOpensOnClick) || settings.doneHapticsEnabled {
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
                    }
                }
            } header: {
                Text(L("열기와 햅틱", "Opening and haptics"))
            }

            Section {
                NotchTabOrderView()
            } header: {
                Text(L("탭", "Tabs"))
            }

            Section {
                foldRow(L("완료", "Done"), $settings.foldSecondsDone)
                foldRow(L("재생 중", "Now playing"), $settings.foldSecondsMedia)
                foldRow(L("에어팟", "AirPods"), $settings.foldSecondsAirPods)
                foldRow(L("에어팟 맥스, 헤드셋, 뚜껑 닫힌 채 낀 에어팟", "AirPods Max, headsets, buds worn with the lid shut"),
                        $settings.foldSecondsHeadphones)
                foldRow(L("맥 배터리 부족", "Mac low battery"), $settings.foldSecondsMac)
                foldRow(L("테더링", "Tethering"), $settings.foldSecondsTether)
                foldRow(L("속도", "Speed test"), $settings.foldSecondsSpeed)
                foldRow(L("복사", "Copy"), $settings.foldSecondsCopy, range: 1...60)
                Text(L("다 내려온 뒤부터 카운트 시작. 커서를 올려 두면 멈춤. 에어팟, 맥 드롭다운은 '자동으로 접기'를 켰을 때만(맥스, 헤드셋, 뚜껑 닫힌 채 낀 에어팟은 늘 접힘)",
                       "Counted from when it is all the way down. Paused while the cursor is on it. AirPods and Mac dropdowns only with their auto-fold on (Max, headsets and buds worn with the lid shut always fold)"))
                    .font(.caption).foregroundColor(.secondary)
            } header: {
                Text(L("드롭다운 머무는 시간", "How long dropdowns stay"))
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

/// 설정 -> 노치 › 노치 색: four picture tiles, each a small notch over a desktop.
private struct NotchAppearancePicker: View {
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 14) {
            ForEach(NotchAppearanceMode.allCases, id: \.self) { mode in
                let selected = selection == mode.rawValue
                Button { selection = mode.rawValue } label: {
                    VStack(spacing: 6) {
                        NotchAppearanceTile(mode: mode)
                            .frame(width: 92, height: 60)
                            .padding(3)
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2.5))
                        Text(title(mode))
                            .font(.callout.weight(selected ? .semibold : .regular))
                            .foregroundStyle(selected ? .primary : .secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    private func title(_ mode: NotchAppearanceMode) -> String {
        switch mode {
        case .wallpaper: return L("배경 따라", "Wallpaper")
        case .auto:      return L("자동", "Auto")
        case .light:     return L("라이트", "Light")
        case .dark:      return L("다크", "Dark")
        }
    }
}

/// 배경 따라's colour: read from the wallpaper, or picked off the screen with the eyedropper.
private struct WallpaperColorSource: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var appearance = NotchAppearance.shared

    var body: some View {
        Picker(L("색 가져오기", "Colour from"), selection: $settings.notchWallpaperSource) {
            Text(L("바탕화면에서", "Wallpaper")).tag("wallpaper")
            Text(L("직접 지정", "Custom")).tag("custom")
        }
        .pickerStyle(.segmented)

        if settings.notchWallpaperSource == "custom" {
            HStack {
                Text(L("스포이드", "Eyedropper"))
                Spacer()
                if let color = NotchAppearance.color(hex: settings.notchCustomColor) {
                    Circle()
                        .fill(Color(nsColor: color))
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.2), lineWidth: 1))
                        .frame(width: 20, height: 20)
                        .help(settings.notchCustomColor)
                }
                Button {
                    NSColorSampler().show { picked in
                        guard let picked else { return }
                        Task { @MainActor in settings.notchCustomColor = NotchAppearance.hex(picked) }
                    }
                } label: {
                    Label(L("색 찍기", "Pick"), systemImage: "eyedropper")
                }
            }
        } else if appearance.wallpaperUnreadable {
            Text(L("폴더로 바뀌는 바탕화면은 지금 사진을 알 수 없어 다크로 표시. 직접 지정 권장",
                   "A rotating wallpaper folder doesn't say which picture is showing, so the notch stays dark. Use Custom"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct NotchAppearanceTile: View {
    let mode: NotchAppearanceMode

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        ZStack {
            switch mode {
            case .wallpaper:
                scene(desktop: [Color(red: 0.95, green: 0.55, blue: 0.35), Color(red: 0.45, green: 0.25, blue: 0.6)],
                      surface: Color(red: 0.93, green: 0.58, blue: 0.42), ink: .black)
            case .auto:
                scene(desktop: desktop, surface: Color(white: 0.96), ink: .black)
                scene(desktop: desktop, surface: .black, ink: .white)
                    .mask(DiagonalHalf())
            case .light:
                scene(desktop: desktop, surface: Color(white: 0.96), ink: .black)
            case .dark:
                scene(desktop: desktop, surface: .black, ink: .white)
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
    }

    private var desktop: [Color] {
        [Color(red: 0.2, green: 0.45, blue: 0.85), Color(red: 0.08, green: 0.2, blue: 0.5)]
    }

    /// A desktop with an open notch hanging from the top edge, two lines of text in it.
    private func scene(desktop: [Color], surface: Color, ink: Color) -> some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: desktop, startPoint: .topLeading, endPoint: .bottomTrailing)
            UnevenRoundedRectangle(bottomLeadingRadius: 8, bottomTrailingRadius: 8, style: .continuous)
                .fill(surface)
                .frame(width: 64, height: 36)
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 4) {
                        Capsule().fill(ink.opacity(0.85)).frame(width: 30, height: 4)
                        Capsule().fill(ink.opacity(0.4)).frame(width: 44, height: 4)
                        Capsule().fill(ink.opacity(0.4)).frame(width: 22, height: 4)
                    }
                    .padding(.top, 9)
                    .padding(.leading, 8)
                }
        }
    }
}

/// The lower-right triangle of the tile, for 자동's half-light, half-dark tile.
private struct DiagonalHalf: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.maxX * 0.62, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.maxX * 0.38, y: rect.maxY))
            p.closeSubpath()
        }
    }
}
