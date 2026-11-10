import AppKit

/// A terminal session's own terminal app and, where that terminal can reach it, its tab or
/// pane. Empty when the session runs in a terminal but which one is unknown.
struct TerminalLocation: Equatable, Sendable {
    /// How the terminal is told to show the tab or pane. The launcher knows no terminal by
    /// name: `SessionAppResolver` picks the way from what the terminal left in the process.
    enum Tab: Equatable, Sendable {
        /// An address the terminal opens itself.
        case url(URL)
        /// The terminal's own CLI: executable and arguments, one command after another.
        case commands([[String]])
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
    /// The Claude desktop app shows one of its sessions (`local_…`) at this address, the one
    /// behind its Dock menu's "Continue". Undocumented: read from 4.23118.0 and tried on
    /// 2026-11-10. An archived session lands on the app's Code page instead.
    static func claudeLink(session: String) -> URL? {
        session.hasPrefix("local_") ? URL(string: "claude://code/continue?session=\(session)") : nil
    }

    /// The Codex app's own address for a thread, as it writes them itself.
    static func codexLink(thread: String) -> URL? {
        UUID(uuidString: thread) == nil ? nil : URL(string: "codex://threads/\(thread)")
    }

    /// `link` is a desktop app's address for the session: the app comes forward on it.
    /// Without a known `terminal`, an app of `destination` comes forward.
    static func open(_ destination: SessionAppDestination, in terminal: TerminalLocation? = nil, at link: URL? = nil) {
        if let link, NSWorkspace.shared.open(link) { return }
        switch terminal?.tab {
        case .url(let url):
            if NSWorkspace.shared.open(url) { return }
        case .commands(let commands):
            run(commands)
        case nil:
            break
        }
        if let identifier = terminal?.bundleIdentifier, activate(identifier) { return }
        // Which terminal is unknown: one that is open, or none. Launching the first installed
        // one only put an empty Warp window in front (2026-11-10).
        for identifier in destination.bundleIdentifiers where activate(identifier, launching: !destination.isTerminal) { return }
        debugLog("[SessionApp] No application to open for \(destination.label)")
    }

    private static func activate(_ identifier: String, launching: Bool = true) -> Bool {
        let workspace = NSWorkspace.shared
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first {
            app.activate(options: [])
            return true
        }
        guard launching, let url = workspace.urlForApplication(withBundleIdentifier: identifier) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        workspace.openApplication(at: url, configuration: configuration) { _, error in
            if let error { debugLog("[SessionApp] Could not open \(identifier): \(error.localizedDescription)") }
        }
        return true
    }

    /// A terminal's commands, in order and off the main thread. One that fails doesn't stop
    /// the rest: the app has come forward either way, only the tab is not found.
    private static func run(_ commands: [[String]]) {
        Task.detached(priority: .userInitiated) {
            for command in commands {
                guard let executable = command.first else { continue }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = Array(command.dropFirst())
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    process.waitUntilExit()
                } catch {
                    debugLog("[SessionApp] Could not run \(executable): \(error.localizedDescription)")
                }
            }
        }
    }
}
