import AppKit

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
        case .terminal, .ssh: return ["dev.warp.Warp-Stable", "com.apple.Terminal"]
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
    static func open(_ destination: SessionAppDestination) {
        let workspace = NSWorkspace.shared
        for identifier in destination.bundleIdentifiers {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first {
                app.activate(options: [])
                return
            }
            if let url = workspace.urlForApplication(withBundleIdentifier: identifier) {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                workspace.openApplication(at: url, configuration: configuration) { _, error in
                    if let error { debugLog("[SessionApp] Could not open \(destination.label): \(error.localizedDescription)") }
                }
                return
            }
        }
        debugLog("[SessionApp] Application not installed: \(destination.label)")
    }
}
