import Foundation

/// What a switch sets going beyond its saved value, for the switches that sit both in 설정 and
/// in the 튜토리얼, so the two can't drift apart.
@MainActor
enum SettingEffects {
    static func clipboardHistoryChanged() { ClipboardManager.shared.syncWithSettings() }

    static func audioMixerChanged(_ on: Bool) {
        if on { AudioMixerManager.shared.start() } else { AudioMixerManager.shared.stop() }
    }

    /// The Sidecar tab starts it when shown.
    static func sidecarChanged(_ on: Bool) {
        if !on { SidecarManager.shared.stop() }
    }

    static func batteryChanged(_ on: Bool) {
        if on { BatteryManager.shared.startMonitoring() } else { BatteryManager.shared.stopMonitoring() }
    }

    /// A switch that needs Accessibility asks for it as it is turned on.
    static func askForAccessibility(_ on: Bool) {
        let keyboardLock = KeyboardLockManager.shared
        guard on, !keyboardLock.hasAccessibilityPermission else { return }
        keyboardLock.requestPermission()
    }

    static func codexChanged() { RemoteCodexManager.shared.apply() }

    /// The next-step and session-offer answers each put a hook in Claude Code's settings.
    static func claudeHooksChanged() { ClaudeCodeManager.shared.syncExperimentalHooks() }

    /// 볼륨, 밝기 표시 바꾸기 takes the keys, which needs Accessibility.
    static func systemBannersChanged(_ on: Bool) {
        SystemBannerCenterer.shared.syncWithSettings()
        askForAccessibility(on)
    }
}
