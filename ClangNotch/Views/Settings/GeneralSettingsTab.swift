import AppKit
import SwiftUI

struct AppGeneralSettingsTab: View {
    @ObservedObject var settings: AppSettings
    @State private var launchAtLogin = LoginItem.isEnabled

    var body: some View {
        Form {
            Section {
                Picker(L("표시 언어", "Display language"), selection: $settings.settingsLanguage) {
                    Text(L("시스템 언어를 따름", "Follow system")).tag("system")
                    Text("한국어").tag("ko")
                    Text("English").tag("en")
                }
            } header: {
                Text(L("언어", "Language"))
            }

            Section {
                Picker(L("설정 창 색상", "Settings window color"), selection: $settings.settingsAppearance) {
                    Text(L("시스템을 따름", "Follow system")).tag("system")
                    Text(L("라이트", "Light")).tag("light")
                    Text(L("다크", "Dark")).tag("dark")
                }
            } header: {
                Text(L("설정 창", "Settings window"))
            }

            Section {
                Toggle(L("로그인 시 실행", "Launch at login"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        LoginItem.setEnabled(newValue)
                    }
                SettingToggle(L("메뉴 막대 아이콘 표시", "Show menu bar icon"), isOn: $settings.showMenuBarItem)
            } header: {
                Text(L("시작", "Startup"))
            }

            Section {
                SettingToggle(L("배터리 절약 모드", "Battery saver mode"),
                              L("배터리 사용 시 글로우 애니메이션을 줄여 배터리 절약.",
                                "Less glow animation on battery to save power."),
                              isOn: $settings.batterySaverEnabled)
            } header: {
                Text(L("성능", "Performance"))
            }

            Section {
                LabeledContent(L("튜토리얼", "Tutorial")) {
                    Button(L("다시 보기", "Show Again")) { Tutorial.shared.show(linksWhatsNew: false) }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}
