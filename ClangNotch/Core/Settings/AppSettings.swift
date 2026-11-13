import Foundation
import SwiftUI

@MainActor
public final class AppSettings: ObservableObject {
    public static let shared = AppSettings()

    /// `HookReceiver`'s port. The key predates the receiver, so a changed port carries over.
    @AppStorage("telemetryOtlpPort") public var hookPort: Int = 4318
    @AppStorage("showMenuBarItem") public var showMenuBarItem: Bool = false
    @AppStorage("showSourceCodex") public var showSourceCodex: Bool = true
    @AppStorage("showSourceClaudeCode") public var showSourceClaudeCode: Bool = true

    // Clipboard history (NSPasteboard polling): text, copied files and images. The list lives in
    // memory; images are kept in the app's cache folder.
    @AppStorage("enableClipboardHistory") public var enableClipboardHistory: Bool = true

    // Per-app volume mixer (Core Audio process taps, macOS 14.2+, needs audio-capture permission)
    @AppStorage("enableAudioMixer") public var enableAudioMixer: Bool = false

    // Sidecar quick-connect (private SidecarCore API — one-tap iPad connect/disconnect)
    @AppStorage("enableSidecar") public var enableSidecar: Bool = true

    // Keyboard lock (CGEventTap-based system-wide keyboard block, needs Accessibility permission)
    @AppStorage("enableKeyboardLock") public var enableKeyboardLock: Bool = false

    // "볼륨·밝기 표시 바꾸기": replace macOS volume/brightness banners with our 조절창 and
    // center the other system banners (SystemBannerCenterer + SystemControlOSD, needs Accessibility)
    @AppStorage("centerSystemBanners") public var centerSystemBanners: Bool = true
    // "밝기 키는 다른 앱에 넘기기": with the HUD switch on, brightness keys still go on to macOS and
    // apps like MonitorControl that set external displays from them.
    @AppStorage("passBrightnessKeys") public var passBrightnessKeys: Bool = false
    // "밝기 조절창 보이기": while those keys are passed on, our 조절창 still comes up with the result.
    @AppStorage("showPassedBrightnessHUD") public var showPassedBrightnessHUD: Bool = true
    // "조절창 위치": "left", "center" or "right" under the menu bar (SystemControlOSD).
    @AppStorage("osdPosition") public var osdPosition: String = "center"
    // SoftwareVolume's audio tap for outputs macOS can't turn down (HDMI/DisplayPort speakers).
    // Off by default: it intercepts every app's sound. Its own switch; the key tap needs Accessibility.
    @AppStorage("enableSoftwareVolume") public var enableSoftwareVolume: Bool = false
    // Bundle IDs that tap leaves alone, newline-separated; each also covers its helpers
    // (com.hnc.Discord → com.hnc.Discord.helper.Renderer). Discord because its Go Live would
    // otherwise stream friends' voices replayed by ClangNotch (2026-11-09).
    @AppStorage("softwareVolumeExcludedApps") public var softwareVolumeExcludedApps: String = "com.hnc.Discord"

    // Internet speed test (ping/download/upload against Cloudflare's public endpoints).
    // Only ever runs when the user presses Test in the tab.
    @AppStorage("enableSpeedTest") public var enableSpeedTest: Bool = true

    // Show the Wi-Fi SSID as the network name in the speed test. macOS hides the
    // SSID behind Location Services, so turning this on is what asks for it.
    @AppStorage("enableNetworkName") public var enableNetworkName: Bool = true

    /// SKT shared data (T world). Off by default: it needs the user's own SKT account.
    @AppStorage("enableTWorld") public var enableTWorld: Bool = false
    /// Exact hotspot name; an empty value hides the SKT shared data card.
    @AppStorage("tworldHotspotSSID") public var tworldHotspotSSID: String = "아이폰"

    // Battery levels for Mac, Bluetooth accessories and iOS devices.
    // Wireless iPhone/iPad readings need libimobiledevice + Local Network permission.
    @AppStorage("enableBattery") public var enableBattery: Bool = true

    // 에어팟 드롭다운: name and levels under the notch when AirPods connect. Needs enableBattery.
    @AppStorage("enableAirPodsDropdown") public var enableAirPodsDropdown: Bool = true
    // Under it: drop the same card when AirPods, a Max or a headset falls to 20% and again at
    // 10%, not again until charged past 20%. And under that: keep macOS's own low-battery
    // notification for those devices as well (off: the card alone).
    @AppStorage("airPodsLowBatteryDropdown") public var airPodsLowBatteryDropdown: Bool = true
    @AppStorage("airPodsLowBatteryNotification") public var airPodsLowBatteryNotification: Bool = true
    // The same card, drawn as this Mac's model, when the Mac itself falls to 20% and 10%.
    @AppStorage("macLowBatteryDropdown") public var macLowBatteryDropdown: Bool = true
    // Under it: that card folds after 10 s (off: it stays until closed).
    @AppStorage("macLowBatteryAutoHide") public var macLowBatteryAutoHide: Bool = true

    // Off: the 에어팟 드롭다운 stays until its X is pressed or it is pushed up into the notch;
    // a Max or another headset still folds after 10 s.
    @AppStorage("airPodsDropdownAutoHide") public var airPodsDropdownAutoHide: Bool = true

    // 지금 재생 표시: what plays (macOS's Now Playing) in the closed notch's wings, read through
    // /usr/bin/perl (NowPlayingMonitor). Under it: the 미디어 드롭다운 when something starts playing.
    @AppStorage("enableNowPlaying") public var enableNowPlaying: Bool = true
    @AppStorage("enableNowPlayingDropdown") public var enableNowPlayingDropdown: Bool = true
    // Also under it: the 음파 막대 follow the sound, read from the playing app with an audio
    // capture tap (NowPlayingLevels). Off: no tap, the bars bounce by themselves.
    @AppStorage("enableNowPlayingLevels") public var enableNowPlayingLevels: Bool = true
    // When playback stops, the closed notch's media wings go "now" or "later" (1.5 s, the bars
    // resting meanwhile).
    @AppStorage("nowPlayingHideAfterStop") public var nowPlayingHideAfterStop: String = "later"
    // The few bars at the right wing's edge while the agents (or tethering) hold the wings.
    @AppStorage("nowPlayingMiniWhileWorking") public var nowPlayingMiniWhileWorking: Bool = true

    // 드롭다운 머무는 시간 (설정 › 노치), in seconds, counted from when the dropdown is all the way
    // down. The AirPods and Mac cards use theirs only while their 자동으로 접기 is on, except
    // headphones and buds worn with the lid shut, which always fold.
    @AppStorage("foldSecondsDone") public var foldSecondsDone: Int = 5
    @AppStorage("foldSecondsTether") public var foldSecondsTether: Int = 8
    @AppStorage("foldSecondsSpeed") public var foldSecondsSpeed: Int = 5
    @AppStorage("foldSecondsAirPods") public var foldSecondsAirPods: Int = 6
    @AppStorage("foldSecondsHeadphones") public var foldSecondsHeadphones: Int = 10
    @AppStorage("foldSecondsMac") public var foldSecondsMac: Int = 10
    @AppStorage("foldSecondsMedia") public var foldSecondsMedia: Int = 5

    // Battery device ids shown in the open notch header, newline-separated.
    @AppStorage("headerBatteryDeviceIDs") public var headerBatteryDeviceIDs: String = ""

    // Closed-notch low-battery priority order, newline-separated, first = highest.
    // Chosen separately from the header list.
    @AppStorage("closedBatteryPriorityIDs") public var closedBatteryPriorityIDs: String = ""

    // Devices whose closed-notch badge was switched off, newline-separated; each re-arms once it passes 20%.
    @AppStorage("lowBatteryNotchSnoozedIDs") public var lowBatteryNotchSnoozedIDs: String = ""

    // Order of the tab chips in the expanded notch, as comma-joined NotchMode rawValues.
    // Reorderable from Settings; unknown/new modes are appended by NotchMode.order(from:).
    @AppStorage("notchModeOrder") public var notchModeOrder: String =
        "ai,volume,sidecar,clipboard,speed,battery,keyboardLock"


    // Battery saver: on battery the glow is capped at 30 fps; no cap while charging.
    @AppStorage("batterySaverEnabled") public var batterySaverEnabled: Bool = true

    @AppStorage("showPermissionIndicator") public var showPermissionIndicator: Bool = true
    @AppStorage("showTodoList") public var showTodoList: Bool = true
    // "플랜 표시 (사용량 카드)" under Claude Code and under Codex: the plan badge beside each
    // 사용량 카드's title.
    @AppStorage("showClaudePlan") public var showClaudePlan: Bool = true
    @AppStorage("showCodexPlan") public var showCodexPlan: Bool = true
    // "사용량 한도 표시" under Codex: the Codex 사용량 카드 (notch and menu bar popover). Its
    // limits come in the session logs and, every 5 minutes while this is on, from the local
    // `codex app-server` (no sign-in of its own, unlike Claude's).
    @AppStorage("showCodexUsage") public var showCodexUsage: Bool = true
    // 설정 › 실험 기능 › "Codex 질문에 노치에서 답하기": answers go in through the Codex app's
    // internal IPC socket (CodexAppIPC) and the shared daemon's experimental API (CodexDaemonIPC),
    // which an update can change. Off by default. The key keeps its first name.
    @AppStorage("experimentalCodexAppAnswers") public var experimentalCodexAppAnswers: Bool = false
    // 설정 › 실험 기능 › "Claude 다음 단계에 노치에서 답하기": a Stop hook that stays behind after
    // the turn and wakes the session with the pick (NextStepHooks). Off by default; the hook is
    // in ~/.claude/settings.json only while this is on.
    @AppStorage("experimentalClaudeNextStepAnswers") public var experimentalClaudeNextStepAnswers: Bool = false
    /// Done and attention sounds for the notch dropdowns; also the bell in the open header.
    @AppStorage("notchSoundsEnabled") public var notchSoundsEnabled: Bool = true
    /// Seconds the cursor rests on the notch before it opens; passing over it to the menu bar doesn't.
    @AppStorage("notchOpenDelay") public var notchOpenDelay: Double = 0.09
    /// Keep the notch over full-screen apps instead of hiding it there (Mission Control still hides it).
    @AppStorage("keepNotchInFullScreen") public var keepNotchInFullScreen: Bool = false
    /// 노치 색: "wallpaper", "auto", "light" or "dark" (`NotchAppearanceMode`).
    @AppStorage("notchAppearance") public var notchAppearance: String = "dark"
    /// 배경 따라's colour: "wallpaper" (read from the wallpaper file) or "custom" (`notchCustomColor`).
    @AppStorage("notchWallpaperSource") public var notchWallpaperSource: String = "wallpaper"
    /// "#RRGGBB" picked with the eyedropper for 배경 따라 › 직접 지정.
    @AppStorage("notchCustomColor") public var notchCustomColor: String = ""
    /// A light trackpad tap when the notch opens on hover.
    @AppStorage("notchHapticsEnabled") public var notchHapticsEnabled: Bool = true
    /// The same tap when a session finishes its turn; muted sessions stay quiet.
    @AppStorage("doneHapticsEnabled") public var doneHapticsEnabled: Bool = true
    /// 1 (lightest) … 8 (firmest); 7 and 8 repeat the firmest tap.
    @AppStorage("notchHapticStrength") public var notchHapticStrength: Int = 8
    /// Minutes a question or permission may wait before its sound plays again; 0 = never.
    @AppStorage("attentionReminderMinutes") public var attentionReminderMinutes: Int = 5
    /// Usage cards: predicted landing tick and the pace line under each bar.
    @AppStorage("usagePaceEnabled") public var usagePaceEnabled: Bool = true
    /// No notch sounds while the screen is locked.
    @AppStorage("muteSoundsWhenLocked") public var muteSoundsWhenLocked: Bool = true
    /// 0–1, on top of the system volume.
    @AppStorage("notchSoundsVolume") public var notchSoundsVolume: Double = 0.7
    /// Newline-separated session IDs muted from the 세션 줄's context menu.
    @AppStorage("mutedSoundSessionIDs") public var mutedSoundSessionIDs: String = ""
    /// Comma-separated hosts (`user@address`, `user@address:port` or a `~/.ssh/config` alias; see
    /// `SSHHost`) whose Claude Code sessions are mirrored into the notch over an app-owned SSH
    /// reverse tunnel (see RemoteClaudeManager).
    @AppStorage("remoteClaudeHosts") public var remoteClaudeHosts: String = ""
    /// 설정 › 에이전트 › SSH 원격 세션 switches: off, nothing connects and the host list is
    /// folded away. A list that was filled in before the switches existed turns its switch on
    /// (`migrateRemoteSwitches`).
    @AppStorage("remoteClaudeEnabled") public var remoteClaudeEnabled: Bool = false
    @AppStorage("remoteCodexEnabled") public var remoteCodexEnabled: Bool = false
    /// Comma-separated hosts, as above, whose Codex sessions are mirrored into the notch by
    /// reading their session files over SSH (see RemoteCodexManager).
    @AppStorage("remoteCodexHosts") public var remoteCodexHosts: String = ""

    // Context and Display Settings
    @AppStorage("showContextProgress") public var showContextProgress: Bool = true

    // Claude Usage Quota Tracking
    @AppStorage("enableClaudeUsage") public var enableClaudeUsage: Bool = false
    @AppStorage("claudeUsageRefreshMode") public var claudeUsageRefreshMode: String = "smart"  // "smart" or "fixed"
    @AppStorage("claudeUsageRefreshInterval") public var claudeUsageRefreshInterval: Int = 300  // seconds

    /// Daily check of GitHub Releases for a newer version (`UpdateChecker`).
    @AppStorage("checkForUpdates") public var checkForUpdates: Bool = true
    /// App copy language — settings window, notch and menu bar popover: "system" (default since
    /// 2026-11-13: Korean on a Korean system, English on any other), "ko" or "en".
    /// The key keeps its old name so existing choices survive. See `L(_:_:)`.
    @AppStorage("settingsLanguage") public var settingsLanguage: String = "system"

    public init() {}

    /// The SSH switches came after the host lists (2026-11-12): a list someone already filled
    /// in keeps working instead of going quiet behind a switch that defaults to off.
    func migrateRemoteSwitches() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "remoteClaudeEnabled") == nil, !SSHHost.list(remoteClaudeHosts).isEmpty { remoteClaudeEnabled = true }
    }
}

/// App copy in the language picked under General. Reads UserDefaults directly so it also
/// works off the main actor (status and error text built in background tasks).
func L(_ korean: String, _ english: String) -> String {
    switch UserDefaults.standard.string(forKey: "settingsLanguage") {
    case "en": return english
    case "ko": return korean
    default: return systemLanguageIsKorean ? korean : english
    }
}

/// The system's (or, under 언어 및 지역 › 응용 프로그램, this app's) first language is Korean.
/// Read once: macOS hands an app a changed language on its next launch anyway.
private let systemLanguageIsKorean = Locale.preferredLanguages.first?.hasPrefix("ko") ?? false
