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

    // Clipboard history (NSPasteboard polling, text-only, memory-only)
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

    // Internet speed test (ping/download/upload against Cloudflare's public endpoints).
    // Only ever runs when the user presses Test in the tab.
    @AppStorage("enableSpeedTest") public var enableSpeedTest: Bool = true

    // Show the Wi-Fi SSID as the network name in the speed test. macOS hides the
    // SSID behind Location Services, so turning this on is what asks for it.
    @AppStorage("enableNetworkName") public var enableNetworkName: Bool = true

    // Exact hotspot name; an empty value disables T world quota display and polling.
    /// SKT shared data (T world). Off by default: it needs the user's own SKT account.
    @AppStorage("enableTWorld") public var enableTWorld: Bool = false
    @AppStorage("tworldHotspotSSID") public var tworldHotspotSSID: String = "아이폰"

    // Battery levels for Mac, Bluetooth accessories and iOS devices.
    // Wireless iPhone/iPad readings need libimobiledevice + Local Network permission.
    @AppStorage("enableBattery") public var enableBattery: Bool = true

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

    // Tab chips hidden from the expanded notch, as comma-joined NotchMode rawValues.
    // Purely about the chip row — the feature's own enable* setting still decides
    // whether the subsystem runs at all.
    @AppStorage("hiddenNotchModes") public var hiddenNotchModes: String = ""

    // Battery saver: 15 FPS on battery, 25 FPS when charging
    @AppStorage("batterySaverEnabled") public var batterySaverEnabled: Bool = true

    // Claude Code JSONL Session Tracking
    @AppStorage("enableClaudeCodeJSONL") public var enableClaudeCodeJSONL: Bool = true
    @AppStorage("showPermissionIndicator") public var showPermissionIndicator: Bool = true
    @AppStorage("showTodoList") public var showTodoList: Bool = true
    /// Done and attention sounds for the notch dropdowns; also the bell in the open header.
    @AppStorage("notchSoundsEnabled") public var notchSoundsEnabled: Bool = true
    /// Seconds the cursor rests on the notch before it opens; passing over it to the menu bar doesn't.
    @AppStorage("notchOpenDelay") public var notchOpenDelay: Double = 0.09
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
    /// Comma-separated `~/.ssh/config` host aliases whose Claude Code sessions are mirrored
    /// into the notch over an app-owned SSH reverse tunnel (see RemoteClaudeManager).
    @AppStorage("remoteClaudeHosts") public var remoteClaudeHosts: String = ""

    // Codex JSONL Session Tracking
    @AppStorage("enableCodexJSONL") public var enableCodexJSONL: Bool = true

    // Context and Display Settings
    @AppStorage("showContextProgress") public var showContextProgress: Bool = true

    // Claude Usage Quota Tracking
    @AppStorage("enableClaudeUsage") public var enableClaudeUsage: Bool = false
    @AppStorage("claudeUsageRefreshMode") public var claudeUsageRefreshMode: String = "smart"  // "smart" or "fixed"
    @AppStorage("claudeUsageRefreshInterval") public var claudeUsageRefreshInterval: Int = 300  // seconds

    /// App copy language — settings window, notch and menu bar popover: "ko" (default) or "en".
    /// The key keeps its old name so existing choices survive. See `L(_:_:)`.
    /// Daily check of GitHub Releases for a newer version (`UpdateChecker`).
    @AppStorage("checkForUpdates") public var checkForUpdates: Bool = true
    @AppStorage("settingsLanguage") public var settingsLanguage: String = "ko"

    public init() {}
}

/// App copy in the language picked under General. Reads UserDefaults directly so it also
/// works off the main actor (status and error text built in background tasks).
func L(_ korean: String, _ english: String) -> String {
    UserDefaults.standard.string(forKey: "settingsLanguage") == "en" ? english : korean
}
