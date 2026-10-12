import Foundation
import SwiftUI

@MainActor
public final class AppSettings: ObservableObject {
    public static let shared = AppSettings()

    @AppStorage("mcpBinaryPath") public var mcpBinaryPath: String = "/usr/local/bin/bridge4simulator-xcauto"
    @AppStorage("mcpHttpPort") public var mcpHttpPort: Int = 8765
    @AppStorage("mcpUseHTTP") public var mcpUseHTTP: Bool = true
    @AppStorage("autoStartMCP") public var autoStartMCP: Bool = true
    @AppStorage("autoRestartOnCrash") public var autoRestartOnCrash: Bool = true
    @AppStorage("maxRestartAttempts") public var maxRestartAttempts: Int = 5
    @AppStorage("showBuildNotifications") public var showBuildNotifications: Bool = true
    @AppStorage("recentToolCallsLimit") public var recentToolCallsLimit: Int = 10
    @AppStorage("forceNotchMode") public var forceNotchMode: Bool = true  // Force notch UI for testing
    @AppStorage("telemetryOtlpPort") public var telemetryOtlpPort: Int = 4318
    @AppStorage("telemetryAutoStart") public var telemetryAutoStart: Bool = true
    @AppStorage("showMenuBarItem") public var showMenuBarItem: Bool = false
    @AppStorage("showNotchTokenCount") public var showNotchTokenCount: Bool = true
    @AppStorage("showNotchTokenBreakdown") public var showNotchTokenBreakdown: Bool = true
    @AppStorage("showNotchCost") public var showNotchCost: Bool = true
    @AppStorage("showSourceCodex") public var showSourceCodex: Bool = true
    @AppStorage("showSourceClaudeCode") public var showSourceClaudeCode: Bool = true
    @AppStorage("showSourceUnknown") public var showSourceUnknown: Bool = false

    // Antigravity (Gemini) CLI activity in the notch
    @AppStorage("enableAntigravity") public var enableAntigravity: Bool = true

    // Clipboard history (NSPasteboard polling, text-only, memory-only)
    @AppStorage("enableClipboardHistory") public var enableClipboardHistory: Bool = true

    // Per-app volume mixer (Core Audio process taps, macOS 14.2+, needs audio-capture permission)
    @AppStorage("enableAudioMixer") public var enableAudioMixer: Bool = false

    // Sidecar quick-connect (private SidecarCore API — one-tap iPad connect/disconnect)
    @AppStorage("enableSidecar") public var enableSidecar: Bool = true

    // Keyboard lock (CGEventTap-based system-wide keyboard block, needs Accessibility permission)
    @AppStorage("enableKeyboardLock") public var enableKeyboardLock: Bool = false

    // Internet speed test (ping/download/upload against Cloudflare's public endpoints).
    // Only ever runs when the user presses Test in the tab.
    @AppStorage("enableSpeedTest") public var enableSpeedTest: Bool = true

    // Show the Wi-Fi SSID as the network name in the speed test. macOS hides the
    // SSID behind Location Services, so turning this on is what asks for it.
    @AppStorage("enableNetworkName") public var enableNetworkName: Bool = true

    // Exact hotspot name; an empty value disables T world quota display and polling.
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
    @AppStorage("showSessionDots") public var showSessionDots: Bool = true
    @AppStorage("showPermissionIndicator") public var showPermissionIndicator: Bool = true
    @AppStorage("showTodoList") public var showTodoList: Bool = true
    @AppStorage("showThinkingState") public var showThinkingState: Bool = true
    /// Comma-separated `~/.ssh/config` host aliases whose Claude Code sessions are mirrored
    /// into the notch over an app-owned SSH reverse tunnel (see RemoteClaudeManager).
    @AppStorage("remoteClaudeHosts") public var remoteClaudeHosts: String = ""

    // Codex JSONL Session Tracking
    @AppStorage("enableCodexJSONL") public var enableCodexJSONL: Bool = true

    // Context and Display Settings
    @AppStorage("contextTokenLimit") public var contextTokenLimit: Int = 200_000
    @AppStorage("showContextProgress") public var showContextProgress: Bool = true
    /// Display mode: "list" for recent events list, "singular" for single detailed event
    @AppStorage("toolDisplayMode") public var toolDisplayMode: String = "list"

    // Claude Usage Quota Tracking
    @AppStorage("enableClaudeUsage") public var enableClaudeUsage: Bool = false
    @AppStorage("claudeUsageRefreshMode") public var claudeUsageRefreshMode: String = "smart"  // "smart" or "fixed"
    @AppStorage("claudeUsageRefreshInterval") public var claudeUsageRefreshInterval: Int = 180  // seconds
    @AppStorage("showClaudeUsageInClosedNotch") public var showClaudeUsageInClosedNotch: Bool = true

    /// Language of the settings window's copy: "ko" (default) or "en". See `L(_:_:)`.
    @AppStorage("settingsLanguage") public var settingsLanguage: String = "ko"

    public var mcpConfiguration: MCPConfiguration {
        MCPConfiguration(
            binaryPath: mcpBinaryPath,
            httpPort: mcpHttpPort,
            transport: mcpUseHTTP ? .http : .stdio
        )
    }

    public init() {}
}

/// Settings-window copy in the language picked under General. Reads UserDefaults directly
/// so it also works off the main actor (status and error text built in background tasks).
func L(_ korean: String, _ english: String) -> String {
    UserDefaults.standard.string(forKey: "settingsLanguage") == "en" ? english : korean
}
