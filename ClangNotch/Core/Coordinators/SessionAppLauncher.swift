import AppKit

/// A terminal session's own terminal app and, where that terminal can reach it, its tab or
/// pane. Empty when the session runs in a terminal but which one is unknown.
struct TerminalLocation: Equatable, Sendable {
    enum Tab: Equatable, Sendable {
        case warp(URL)
        case rex(cli: String, server: String?, session: String, block: String)
    }

    var bundleIdentifier: String?
    var tab: Tab?
}

/// The input host takes precedence over the agent's transport (Desktop also reports vscode).
enum SessionAppDestination: Equatable, Sendable {
    case codex, claude, terminal, ssh, vscode, antigravity, cursor, windsurf, zed

    var label: String {
        switch self {
        case .codex: return "Codex app"
        case .claude: return "Claude app"
        case .terminal: return "Terminal"
        case .ssh: return "SSH"
        case .vscode: return "VS Code"
        case .antigravity: return "Antigravity"
        case .cursor: return "Cursor"
        case .windsurf: return "Windsurf"
        case .zed: return "Zed"
        }
    }

    var iconName: String {
        switch self {
        case .terminal: return "terminal"
        case .ssh: return "network"
        case .codex, .claude: return "macwindow"
        case .vscode, .zed: return "chevron.left.forwardslash.chevron.right"
        case .antigravity: return "atom"
        case .cursor: return "cursorarrow"
        case .windsurf: return "water.waves"
        }
    }

    var bundleIdentifiers: [String] {
        switch self {
        case .codex: return ["com.openai.codex"]
        case .claude: return ["com.anthropic.claudefordesktop"]
        case .terminal, .ssh: return ["dev.warp.Warp-Stable", "com.superlogical.rex", "com.apple.Terminal"]
        case .vscode: return ["com.microsoft.VSCode", "com.visualstudio.code.oss"]
        case .antigravity: return ["com.google.antigravity-ide", "com.google.antigravity"]
        case .cursor: return ["com.todesktop.230313mzl4w4u92"]
        case .windsurf: return ["com.codeium.windsurf"]
        case .zed: return ["dev.zed.Zed"]
        }
    }

    var isTerminal: Bool { self == .terminal || self == .ssh }

    /// The notch's go-to-session button: a terminal, or a GUI app (desktop app or editor).
    var openTitle: String {
        isTerminal ? L("터미널 열기", "Open terminal") : L("GUI 열기", "Open app")
    }

    static func editor(named name: String) -> Self? {
        let name = name.lowercased()
        if name.contains("antigravity") { return .antigravity }
        if name.contains("cursor") { return .cursor }
        if name.contains("windsurf") { return .windsurf }
        if name.contains("zed") { return .zed }
        if name.contains("vscode") || name.contains("visual studio code") || name == "code" { return .vscode }
        return nil
    }

    static func codex(originator: String, source: String) -> Self {
        let origin = originator.lowercased()
        if origin.contains("codex desktop") || origin.contains("codex_chatgpt") { return .codex }
        if let editor = editor(named: origin) { return editor }
        if let editor = editor(named: source) { return editor }
        return .terminal
    }

    static func claude(entrypoint: ClaudeEntrypoint, ideName: String) -> Self? {
        switch entrypoint {
        case .desktop: return .claude
        case .terminal: return .terminal
        case .ssh: return .ssh
        case .vscode: return editor(named: ideName) ?? .vscode
        default:
            if let editor = editor(named: ideName) { return editor }
            return ideName.lowercased() == "terminal" ? .terminal : nil
        }
    }
}

@MainActor
enum SessionAppLauncher {
    /// Without a known `terminal`, the first installed app of `destination` comes forward.
    static func open(_ destination: SessionAppDestination, in terminal: TerminalLocation? = nil) {
        switch terminal?.tab {
        case .warp(let url):
            NSWorkspace.shared.open(url)
            return
        case .rex(let cli, let server, let session, let block):
            focusRexPane(cli: cli, server: server, session: session, block: block)
        case nil:
            break
        }
        if let identifier = terminal?.bundleIdentifier, activate(identifier) { return }
        for identifier in destination.bundleIdentifiers where activate(identifier) { return }
        debugLog("[SessionApp] Application not installed: \(destination.label)")
    }

    private static func activate(_ identifier: String) -> Bool {
        let workspace = NSWorkspace.shared
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first {
            app.activate(options: [])
            return true
        }
        guard let url = workspace.urlForApplication(withBundleIdentifier: identifier) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        workspace.openApplication(at: url, configuration: configuration) { _, error in
            if let error { debugLog("[SessionApp] Could not open \(identifier): \(error.localizedDescription)") }
        }
        return true
    }

    /// Also switches to the pane's window. A pane in another Rex session stays put: switching
    /// sessions from outside the app needs Remote Control in Rex's settings (2026-10-31).
    private static func focusRexPane(cli: String, server: String?, session: String, block: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = (server.map { ["-S", $0] } ?? []) + ["--autostart=false", "focus", "-s", session, block]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            debugLog("[SessionApp] Could not focus the Rex pane: \(error.localizedDescription)")
        }
    }
}
