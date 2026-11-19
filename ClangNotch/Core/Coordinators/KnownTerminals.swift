import AppKit

/// Terminal apps a Mac might have, for 설정 -> 에이전트 -> 터미널 앱 and the Sessions card's
/// 시작 page (2026-11-19). Only the ones installed are offered.
enum KnownTerminals {
    static let all: [(bundleID: String, name: String)] = [
        ("com.apple.Terminal", L("터미널", "Terminal")),
        ("com.googlecode.iterm2", "iTerm2"),
        ("dev.warp.Warp-Stable", "Warp"),
        ("com.mitchellh.ghostty", "Ghostty"),
        ("com.github.wez.wezterm", "WezTerm"),
        ("net.kovidgoyal.kitty", "kitty"),
        ("org.alacritty", "Alacritty"),
        ("com.superlogical.rex", "Rex"),
    ]

    static func isInstalled(_ bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    static var installed: [(bundleID: String, name: String)] { all.filter { isInstalled($0.bundleID) } }

    /// The terminal 시작 opens: the one picked in Settings, else the one the sessions last ran in,
    /// else one that is running, else the first installed.
    @MainActor static var preferred: String? {
        let picked = AppSettings.shared.preferredTerminal
        if !picked.isEmpty, isInstalled(picked) { return picked }
        if let last = AgentActivityLog.shared.lastTerminalApp, isInstalled(last) { return last }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return all.first { running.contains($0.bundleID) }?.bundleID ?? installed.first?.bundleID
    }
}
