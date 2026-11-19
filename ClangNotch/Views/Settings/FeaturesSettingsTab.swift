import AppKit
import SwiftUI

/// 기능's pages: the notch's tabs, the 조절창, the 에어팟 드롭다운 and 미디어, each its own page under
/// 기능 in the sidebar (one long page before, user 2026-11-19). One view for the four, as they
/// share the permission notes.
struct FeaturesSettingsTab: View {
    @ObservedObject var settings: AppSettings
    /// Which of 기능's pages: `.notchTabs`, `.hud`, `.airpods` or `.media`.
    let page: SettingsPage
    /// Holds the Accessibility answer the three switches below need.
    @ObservedObject private var keyboardLock = KeyboardLockManager.shared

    @State private var audioCaptureGranted = AudioCapturePermission.isGranted

    /// A caption says which permission its switch needs only while that permission is missing
    /// (user, 2026-11-15).
    private var needsAccessibility: String {
        keyboardLock.hasAccessibilityPermission ? "" : L(". 손쉬운 사용 권한 필요", ". Needs Accessibility")
    }
    private var needsAudioCapture: String {
        audioCaptureGranted ? "" : L(". 오디오 캡처 권한 필요", ". Needs audio-capture permission")
    }

    /// Turning on a switch that needs Accessibility asks for it straight away.
    private func askForAccessibility(_ on: Bool) {
        guard on, !keyboardLock.hasAccessibilityPermission else { return }
        keyboardLock.requestPermission()
    }

    var body: some View {
        Form {
            switch page {
            case .notchTabs: notchTabs
            case .hud: hud
            case .batteryAlerts: batteryAlerts
            case .media: media
            default: EmptyView()
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        // Back from System Settings with the permission given: the note goes.
        .onAppear { audioCaptureGranted = AudioCapturePermission.isGranted }
    }

    private var notchTabs: some View {
        Section {
            SettingToggle(L("클립보드 기록", "Clipboard history"),
                          L("최근 복사한 글, 이미지, 파일. 파일은 위치만 기억하고 이미지는 앱이 종료되면 클립보드 기록은 삭제됨",
                            "Recently copied text, images and files. Files by their location; images leave the history when the app quits"),
                          isOn: $settings.enableClipboardHistory)
                .onChange(of: settings.enableClipboardHistory) { _, _ in
                    ClipboardManager.shared.syncWithSettings()
                }
            if settings.enableClipboardHistory {
                CopyDropdownPicker(settings: settings)
                    .padding(.leading, 20)
            }
            SettingToggle(L("앱별 볼륨 믹서", "Per-app volume mixer"),
                          L("앱마다 소리 크기 조절", "Volume per app") + needsAudioCapture,
                          isOn: $settings.enableAudioMixer)
                .onChange(of: settings.enableAudioMixer) { _, on in
                    if on { AudioMixerManager.shared.start() } else { AudioMixerManager.shared.stop() }
                }
            SettingToggle(L("Sidecar 빠른 연결", "Sidecar quick-connect"),
                          L("iPad를 보조 화면으로 바로 연결", "Connect an iPad as a second display"),
                          isOn: $settings.enableSidecar)
                .onChange(of: settings.enableSidecar) { _, on in
                    // The Sidecar tab starts it when shown.
                    if !on { SidecarManager.shared.stop() }
                }
            SettingToggle(L("배터리 잔량", "Battery levels"),
                          L("Mac, 블루투스 기기, iPhone의 배터리", "The Mac, Bluetooth accessories and iPhone"),
                          isOn: $settings.enableBattery)
                .onChange(of: settings.enableBattery) { _, on in
                    if on { BatteryManager.shared.startMonitoring() } else { BatteryManager.shared.stopMonitoring() }
                }
            EnergyHelperRow()
                .padding(.leading, 20)
            SettingToggle(L("인터넷 속도 측정", "Internet speed test"),
                          L("측정할 때만 네트워크 사용", "Uses the network only while testing"),
                          isOn: $settings.enableSpeedTest)
            if !keyboardLock.hasAccessibilityPermission && settings.enableKeyboardLock {
                AccessibilityMissingRow(permission: keyboardLock,
                                        what: L("손쉬운 사용 권한이 없어 아래 키보드 잠금이 동작하지 않습니다",
                                                "Without Accessibility, Keyboard lock below does nothing"))
            }
            SettingToggle(L("키보드 잠금", "Keyboard lock"),
                          L("키보드 입력 잠금", "Locks keyboard input") + needsAccessibility,
                          isOn: $settings.enableKeyboardLock)
                .onChange(of: settings.enableKeyboardLock) { _, on in askForAccessibility(on) }
        }
    }

    /// 조절창: the volume and brightness HUD and what goes with it.
    private var hud: some View {
        Section {
            if !keyboardLock.hasAccessibilityPermission
                && (settings.centerSystemBanners || settings.enableSoftwareVolume) {
                AccessibilityMissingRow(permission: keyboardLock,
                                        what: L("손쉬운 사용 권한이 없어 아래 볼륨, 밝기 표시 바꾸기와 모니터 소리 줄이기가 동작하지 않습니다",
                                                "Without Accessibility, the volume and brightness HUD and monitor volume below do nothing"))
            }
            SettingToggle(L("볼륨, 밝기 표시 바꾸기", "Replace volume and brightness HUD"),
                          L("macOS 볼륨, 밝기 표시 대신 메뉴 막대 아래 조절창 사용. 에어팟이나 맥스에서 크라운, 제스처로 바꾼 소리는 macOS 표시도 함께 표시됨",
                            "A HUD under the menu bar instead of macOS's volume and brightness display. Volume changed on AirPods or AirPods Max (crown, gestures) still shows macOS's display too") + needsAccessibility,
                          isOn: $settings.centerSystemBanners)
                .onChange(of: settings.centerSystemBanners) { _, on in
                    SystemBannerCenterer.shared.syncWithSettings()
                    askForAccessibility(on)
                }
            // Only means something while the HUD switch takes the keys: shown under it, indented.
            if settings.centerSystemBanners {
                Picker(L("조절창 위치", "HUD position"), selection: $settings.osdPosition) {
                    Text(L("왼쪽", "Left")).tag("left")
                    Text(L("가운데", "Center")).tag("center")
                    Text(L("오른쪽", "Right")).tag("right")
                }
                .pickerStyle(.segmented)
                .padding(.leading, 20)
                SettingToggle(L("밝기 조절키를 다른 앱에 넘기기", "Leave the brightness keys to other apps"),
                              L("MonitorControl, Lunar, BetterDisplay로 외부 모니터 밝기까지 조절할 때 켜기. 외부 모니터가 연결돼 있을 때만 넘김",
                                "On when MonitorControl, Lunar or BetterDisplay sets external displays too. Only while an external display is connected"),
                              isOn: $settings.passBrightnessKeys)
                    .padding(.leading, 20)
                if settings.passBrightnessKeys {
                    SettingToggle(L("노치앱의 밝기 조절창 보이기", "Show the notch app's brightness HUD"),
                                  isOn: $settings.showPassedBrightnessHUD)
                        .padding(.leading, 40)
                }
            }
            // Its own switch: it keeps the volume key tap up even with the HUD switch off.
            SettingToggle(L("볼륨 조절 안 되는 모니터 소리 줄이기", "Volume for monitors without volume control"),
                          L("HDMI, DisplayPort 스피커로 가는 소리를 가로채, 줄여서 다시 재생",
                            "Intercepts sound headed to HDMI or DisplayPort speakers and replays it quieter") + needsAccessibility,
                          isOn: $settings.enableSoftwareVolume)
                .onChange(of: settings.enableSoftwareVolume) { _, on in
                    SoftwareVolume.shared.syncWithSettings()
                    askForAccessibility(on)
                }
            if settings.enableSoftwareVolume {
                SoftwareVolumeExcludedApps(settings: settings)
            }
        }
    }

    /// 배터리 알림 (named 에어팟 드롭다운 until 2026-11-19): how and when the AirPods, headset and
    /// Mac battery cards show (its own section since 2026-11-12, its own page since 2026-11-19).
    private var batteryAlerts: some View {
        Section {
            // How the connection and low battery cards show, for both switches below.
            VStack(alignment: .leading, spacing: 8) {
                Text(L("에어팟 드롭다운 표시", "Show the AirPods dropdown"))
                AirPodsDropdownStylePicker(settings: settings)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .disabled(!settings.enableBattery)
            SettingToggle(L("에어팟 연결 알림", "AirPods connection dropdown"),
                          L("에어팟이나 블루투스 헤드셋을 연결하면 잔량 표시. 배터리 잔량이 켜져 있어야 함",
                            "Battery levels when AirPods or a Bluetooth headset connect. Needs Battery levels"),
                          isOn: $settings.enableAirPodsDropdown)
                .disabled(!settings.enableBattery)
            // Only means something with the card on: under it, indented.
            if settings.enableAirPodsDropdown {
                SettingToggle(L("에어팟 연결 알림 자동으로 접기", "Fold the AirPods dropdown by itself"),
                              isOn: $settings.airPodsDropdownAutoHide)
                    .padding(.leading, 20)
                    .disabled(!settings.enableBattery)
            }
            SettingToggle(L("에어팟, 헤드셋 배터리 부족 시 드롭다운", "Dropdown when AirPods or a headset run low"),
                          L("에어팟, 에어팟 맥스, 헤드셋이 20%, 10%가 되면 한 번씩. 30% 이상으로 충전될 때까지 다시 안 뜸",
                            "Once at 20% and once at 10% for AirPods, AirPods Max and headsets. Not again until charged back to 30%"),
                          isOn: $settings.airPodsLowBatteryDropdown)
                .disabled(!settings.enableBattery)
            if settings.airPodsLowBatteryDropdown {
                SettingToggle(L("알림센터로 보내기", "Send to Notification Center"),
                              L("기기들의 배터리 부족 알림이 알림센터에도 표시됨", "These devices' low battery alerts show in Notification Center too"),
                              isOn: $settings.airPodsLowBatteryNotification)
                    .padding(.leading, 20)
                    .disabled(!settings.enableBattery)
            }
            // Picked from pictures like the 에어팟 드롭다운 표시 above (user, 2026-11-19).
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("맥 배터리 부족 시 드롭다운", "Dropdown when this Mac runs low"))
                    Text(L("이 맥의 모델 그림으로 20%, 10%가 되면 한 번씩. 충전 중엔 안 뜸",
                           "Drawn as this Mac's model, once at 20% and once at 10%. Not while charging"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                PictureChoice(options: [(false, L("끔", "Off")), (true, L("분리", "Detached"))],
                              selection: $settings.macLowBatteryDropdown) { MacLowBatteryTile(shown: $0) }
                    .fixedSize(horizontal: false, vertical: true)
            }
            .disabled(!settings.enableBattery)
            if settings.macLowBatteryDropdown {
                SettingToggle(L("맥 배터리 부족 드롭다운 자동으로 접기", "Fold this Mac's dropdown by itself"),
                              isOn: $settings.macLowBatteryAutoHide)
                    .padding(.leading, 20)
                    .disabled(!settings.enableBattery)
            }
        }
    }

    private var media: some View {
        Section {
            SettingToggle(L("지금 재생 표시", "Show what's playing"),
                          L("음악, 영상이 재생되면 닫힌 노치 왼쪽에 앨범 그림, 오른쪽에 음파. 에이전트가 일하거나 테더링 중이면 오른쪽 끝에 작은 음파만. MacOS의 '지금 재생'을 읽음",
                            "While music or a video plays, the closed notch shows its artwork on the left and bars on the right. While the agents work or you tether, just small bars at the right edge. Reads macOS's Now Playing"),
                          isOn: $settings.enableNowPlaying)
                .onChange(of: settings.enableNowPlaying) { NowPlayingMonitor.shared.sync() }
            if settings.enableNowPlaying {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("미디어 드롭다운 표시", "Show the media dropdown"))
                    MediaDropdownStylePicker(settings: settings)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 20)
                SettingToggle(L("소리에 맞춰 음파 움직이기", "Move the bars with the sound"),
                              L("재생 중인 앱의 소리를 읽어 음파를 움직임", "Reads the sound of the app that plays to move the bars")
                                + needsAudioCapture + L(". 소리를 녹음하거나 저장하지 않음.", ". Nothing is recorded or saved."),
                              isOn: $settings.enableNowPlayingLevels)
                    .padding(.leading, 20)
                    .onChange(of: settings.enableNowPlayingLevels) {
                        NowPlayingLevels.shared.follow(NowPlayingMonitor.shared.nowPlaying)
                    }
                SettingToggle(L("에이전트가 일할 때도 작은 음파 표시", "Small bars while the agents work"),
                              L("에이전트가 일하거나 테더링 중이면 날개 오른쪽 끝에 작은 음파를 표시.",
                                "While the agents work or you tether, small bars show at the right wing's edge."),
                              isOn: $settings.nowPlayingMiniWhileWorking)
                    .padding(.leading, 20)
                Picker(L("재생을 멈추면 날개 숨기기", "When playback stops, hide the wings"), selection: $settings.nowPlayingHideAfterStop) {
                    Text(L("즉시", "Immediately")).tag("now")
                    Text(L("잠시 뒤 (1.5초)", "After a moment (1.5 s)")).tag("later")
                }
                .pickerStyle(.segmented)
                .padding(.leading, 20)
                SecondsRow(title: L("멈춘 곡이 펼친 노치에 남는 시간", "How long a paused track stays in the open notch"),
                           seconds: $settings.nowPlayingBandPausedSeconds, range: 1...600)
                    .padding(.leading, 20)
                    .onChange(of: settings.nowPlayingBandPausedSeconds) { NowPlayingMonitor.shared.pausedLimitChanged() }
            }
        }
    }
}

/// 권한 안내 줄: 키보드 잠금 (노치 탭), 볼륨, 밝기 표시 바꾸기 and 모니터 소리 줄이기 (조절창) do
/// nothing without Accessibility; `what` names the ones on the page. After a signature change (a development build swapped for a release) the old
/// entry can still show as on in System Settings without counting, hence the remove-and-add hint.
private struct AccessibilityMissingRow: View {
    @ObservedObject var permission: KeyboardLockManager
    let what: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(what)
                Text(L("이미 켜져 있는데도 이 줄이 보이면 목록에서 ClangNotch를 −로 지우고 다시 추가",
                       "If ClangNotch is already on there, remove it with − and add it again"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(L("권한 열기…", "Open Settings…")) {
                permission.requestPermission()
                if !permission.hasAccessibilityPermission { permission.openAccessibilitySettings() }
            }
        }
        // Back from System Settings with the permission given: the row goes away.
        .onAppear { permission.refreshPermissionStatus() }
    }
}

/// Apps "볼륨 조절 안 되는 모니터 소리 줄이기" leaves alone, so they keep their own sound path
/// (a screen-share that skips its own audio, say). Stored as bundle IDs.
private struct SoftwareVolumeExcludedApps: View {
    @ObservedObject var settings: AppSettings

    private var bundleIDs: [String] {
        settings.softwareVolumeExcludedApps.split(separator: "\n").map(String.init)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("제외할 앱", "Apps left out"))
            Text(L("가로채지 않아 볼륨 키로 안 줄어듦. 화면 공유에 다른 사람 소리가 섞이는 앱(디스코드 등)",
                   "Not intercepted, so the volume keys don't turn them down. Apps whose screen share picks up other people's voices (Discord, …)"))
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(bundleIDs, id: \.self) { id in
                HStack(spacing: 8) {
                    let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
                    if let url {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                            .resizable()
                            .frame(width: 18, height: 18)
                    }
                    Text(url.map { FileManager.default.displayName(atPath: $0.path) } ?? id)
                    Spacer()
                    Button {
                        set(bundleIDs.filter { $0 != id })
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
            Button(L("앱 추가…", "Add App…"), action: add)
        }
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let added = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
        set(bundleIDs + added.filter { !bundleIDs.contains($0) })
    }

    private func set(_ ids: [String]) {
        settings.softwareVolumeExcludedApps = ids.joined(separator: "\n")
        SoftwareVolume.shared.apply()
    }
}

/// 설정 -> 기능 -> 미디어 -> 지금 재생 -> 미디어 드롭다운: 끔, 떨어지는 카드 (the default) or 노치에 붙음,
/// picked from pictures like the 노치 색.
/// 미디어 드롭다운 표시: off, 분리 (the card) or 붙음 (attached to the notch).
private struct MediaDropdownStylePicker: View {
    @ObservedObject var settings: AppSettings

    enum Style: CaseIterable { case off, card, attached }

    var body: some View {
        PictureChoice(options: [(Style.off, L("노치", "Notch")), (Style.card, L("분리", "Detached")), (Style.attached, L("붙음", "Attached"))],
                      selection: Binding(
                        get: { !settings.enableNowPlayingDropdown ? .off : settings.mediaDropdownAttached ? .attached : .card },
                        set: { style in
                            settings.enableNowPlayingDropdown = style != .off
                            if style != .off { settings.mediaDropdownAttached = style == .attached }
                        })) { MediaDropdownStyleTile(style: $0) }
    }
}

/// 설정 -> 기능 -> 배터리 알림 -> 에어팟 드롭다운 표시: 날개에만 (the levels in the closed
/// notch's wings) or 분리 (the card that comes off the notch, the default), for the connection and
/// low battery cards, picked from pictures like the 미디어 드롭다운 표시. Off is each one's switch.
private struct AirPodsDropdownStylePicker: View {
    @ObservedObject var settings: AppSettings

    enum Style: CaseIterable { case wings, card }

    var body: some View {
        PictureChoice(options: [(Style.wings, L("노치", "Notch")), (Style.card, L("분리", "Detached"))],
                      selection: Binding(
                        get: { settings.airPodsDropdownWings ? .wings : .card },
                        set: { settings.airPodsDropdownWings = $0 == .wings })) { AirPodsDropdownStyleTile(style: $0) }
    }
}

/// The closed notch on a wallpaper, with the buds and the case in its wings (a ring each) or with
/// the card under it.
private struct AirPodsDropdownStyleTile: View {
    let style: AirPodsDropdownStylePicker.Style

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.2, green: 0.45, blue: 0.85), Color(red: 0.08, green: 0.2, blue: 0.5)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            switch style {
            case .wings:
                HStack(spacing: 2) {
                    glyph("airpodspro", size: 7)
                    ring(0.8)
                    Spacer()
                    ring(0.6)
                    glyph("airpods.chargingcase", size: 6)
                }
                .padding(.horizontal, 4)
                .frame(width: 72, height: 12)
                .background(UnevenRoundedRectangle(bottomLeadingRadius: 4, bottomTrailingRadius: 4).fill(Color.black))
            case .card:
                UnevenRoundedRectangle(bottomLeadingRadius: 4, bottomTrailingRadius: 4).fill(Color.black).frame(width: 28, height: 9)
                HStack(spacing: 10) {
                    VStack(spacing: 2) { glyph("airpodspro", size: 11); battery(0.8) }
                    VStack(spacing: 2) { glyph("airpods.chargingcase", size: 10); battery(0.6) }
                }
                .frame(width: 56, height: 30)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.black))
                .padding(.top, 15)
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
    }

    private func glyph(_ name: String, size: CGFloat) -> some View {
        Image(systemName: name).font(.system(size: size)).foregroundStyle(Color.white.opacity(0.9))
    }

    private func ring(_ level: CGFloat) -> some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.25), lineWidth: 1.2)
            Circle().trim(from: 0, to: level).stroke(Color.white, style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 7, height: 7)
    }

    private func battery(_ level: CGFloat) -> some View {
        Capsule().fill(Color.white.opacity(0.3)).frame(width: 12, height: 3)
            .overlay(alignment: .leading) { Capsule().fill(Color.green).frame(width: 12 * level, height: 3) }
    }
}

/// 맥 배터리 부족 시 드롭다운: the closed notch on a wallpaper, bare or with the Mac's card under it.
private struct MacLowBatteryTile: View {
    let shown: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.2, green: 0.45, blue: 0.85), Color(red: 0.08, green: 0.2, blue: 0.5)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            UnevenRoundedRectangle(bottomLeadingRadius: 4, bottomTrailingRadius: 4).fill(Color.black).frame(width: 28, height: 9)
            if shown {
                VStack(spacing: 3) {
                    Image(systemName: "laptopcomputer").font(.system(size: 13)).foregroundStyle(Color.white.opacity(0.9))
                    Capsule().fill(Color.white.opacity(0.3)).frame(width: 14, height: 3)
                        .overlay(alignment: .leading) { Capsule().fill(Color.red).frame(width: 3, height: 3) }
                }
                .frame(width: 56, height: 30)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.black))
                .padding(.top, 15)
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
    }
}

/// 복사 드롭다운 표시 (off or the side it comes out on) and its 모양, each as pictures. The shape's
/// pictures come out on the side picked above.
private struct CopyDropdownPicker: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("복사 드롭다운 표시", "Copy dropdown"))
            PictureChoice(options: [("off", L("끔", "Off")), ("down", L("아래", "Down")), ("left", L("왼쪽", "Left")), ("right", L("오른쪽", "Right"))],
                          selection: Binding(
                            get: { settings.clipboardOrb ? settings.clipboardOrbDirection : "off" },
                            set: { side in
                                settings.clipboardOrb = side != "off"
                                if side != "off" { settings.clipboardOrbDirection = side }
                            })) { side in
                CopyDropdownTile(side: side, pill: settings.clipboardOrbStyle == "pill")
            }
            if settings.clipboardOrb {
                Text(L("복사 드롭다운 모양", "Copy dropdown shape"))
                PictureChoice(options: [("orb", L("원", "Orb")), ("pill", L("알약", "Pill"))],
                              selection: $settings.clipboardOrbStyle) { style in
                    CopyDropdownTile(side: settings.clipboardOrbDirection, pill: style == "pill")
                }
            }
        }
    }
}

/// The closed notch on a wallpaper, and the copy dropdown beside or under it: an orb with the
/// check, or a pill with the check and a line for 복사됨.
private struct CopyDropdownTile: View {
    let side: String
    let pill: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.2, green: 0.45, blue: 0.85), Color(red: 0.08, green: 0.2, blue: 0.5)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            // The notch stays in the middle; the dropdown sits under it or beside it.
            UnevenRoundedRectangle(bottomLeadingRadius: 4, bottomTrailingRadius: 4).fill(Color.black).frame(width: notchWidth, height: 9)
            let beside = notchWidth / 2 + 2 + dropWidth / 2
            switch side {
            case "down": drop.offset(y: 12)
            case "left": drop.offset(x: -beside)
            case "right": drop.offset(x: beside)
            default: EmptyView()
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
    }

    private let notchWidth: CGFloat = 28
    private var dropWidth: CGFloat { pill ? 24 : 10 }

    private var drop: some View {
        HStack(spacing: 2.5) {
            Image(systemName: "checkmark")
                .font(.system(size: 5.5, weight: .heavy))
                .foregroundStyle(Color(red: 0.35, green: 0.85, blue: 0.5))
            if pill { Capsule().fill(Color.white.opacity(0.85)).frame(width: 10, height: 2.5) }
        }
        .frame(width: dropWidth, height: 10)
        .background(Capsule().fill(Color.black))
    }
}

private struct MediaDropdownStyleTile: View {
    let style: MediaDropdownStylePicker.Style

    private let art = LinearGradient(colors: [Color(red: 0.95, green: 0.45, blue: 0.55), Color(red: 0.45, green: 0.3, blue: 0.85)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.2, green: 0.45, blue: 0.85), Color(red: 0.08, green: 0.2, blue: 0.5)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            switch style {
            case .off:
                // The closed notch with only the wings: artwork on the left, bars on the right.
                HStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 2).fill(art).frame(width: 7, height: 7).padding(.leading, 4)
                    Spacer()
                    HStack(spacing: 1) {
                        ForEach([3.0, 5, 4, 6], id: \.self) { Capsule().fill(Color.pink.opacity(0.9)).frame(width: 1.5, height: $0) }
                    }
                    .padding(.trailing, 4)
                }
                .frame(width: 50, height: 11)
                .background(UnevenRoundedRectangle(bottomLeadingRadius: 4, bottomTrailingRadius: 4).fill(Color.black))
            case .card:
                UnevenRoundedRectangle(bottomLeadingRadius: 4, bottomTrailingRadius: 4).fill(Color.black).frame(width: 28, height: 9)
                player(width: 56, height: 30, attached: false).padding(.top, 15)
            case .attached:
                player(width: 64, height: 40, attached: true)
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
    }

    private func player(width: CGFloat, height: CGFloat, attached: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 3) {
                RoundedRectangle(cornerRadius: 2).fill(art).frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 2) {
                    Capsule().fill(Color.white.opacity(0.9)).frame(width: 22, height: 2.5)
                    Capsule().fill(Color.white.opacity(0.45)).frame(width: 14, height: 2.5)
                }
            }
            Capsule().fill(Color.white.opacity(0.3)).frame(height: 1.5)
                .overlay(alignment: .leading) { Capsule().fill(Color.white.opacity(0.9)).frame(width: 14, height: 1.5) }
            HStack(spacing: 6) { ForEach(0..<3, id: \.self) { _ in Circle().fill(Color.white.opacity(0.8)).frame(width: 3, height: 3) } }
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 6)
        .padding(.top, attached ? 11 : 5)
        .padding(.bottom, 4)
        .frame(width: width, height: height, alignment: .top)
        .background {
            if attached {
                UnevenRoundedRectangle(bottomLeadingRadius: 8, bottomTrailingRadius: 8, style: .continuous).fill(Color.black)
            } else {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.black)
            }
        }
    }
}

/// Settings -> Features: the energy mode helper, shown once it is installed or waiting for approval,
/// with the button that removes it. Installing it happens from the Battery tab's Mac row.
private struct EnergyHelperRow: View {
    @ObservedObject private var battery = BatteryManager.shared

    var body: some View {
        Group {
            if battery.energyHelper != .notInstalled {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("에너지 모드 변경 헬퍼", "Energy mode helper"))
                        Text(battery.energyHelper == .installed
                             ? L("배터리 탭에서 에너지 모드를 바꿀 수 있게 해줌", "Lets the Battery tab change the energy mode")
                             : L("시스템 설정 -> 로그인 항목에서 허용을 기다리는 중", "Waiting to be allowed in System Settings -> Login Items"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L("제거", "Remove")) { Task { await battery.uninstallEnergyHelper() } }
                }
            }
        }
        .onAppear { battery.refreshEnergyHelper() }
    }
}
