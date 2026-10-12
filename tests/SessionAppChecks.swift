import AppKit

func debugLog(_ message: @autoclosure () -> String) {}

@main
struct SessionAppChecks {
    @MainActor static func main() {
        precondition(SessionAppDestination.codex(originator: "Codex Desktop", source: "vscode") == .codex)
        precondition(SessionAppDestination.codex(originator: "codex_chatgpt_ios_remote", source: "vscode") == .codex)
        precondition(SessionAppDestination.codex(originator: "codex_cli_rs", source: "cli") == .terminal)
        precondition(SessionAppDestination.codex(originator: "codex_vscode", source: "vscode") == .vscode)
        precondition(SessionAppDestination.codex(originator: "Antigravity", source: "vscode") == .antigravity)
        precondition(SessionAppDestination.codex(originator: "", source: "") == .terminal)
        precondition(SessionAppDestination.claude(entrypoint: .desktop, ideName: "Terminal") == .claude)
        precondition(SessionAppDestination.claude(entrypoint: .terminal, ideName: "Visual Studio Code") == .terminal)
        precondition(SessionAppDestination.claude(entrypoint: .vscode, ideName: "Antigravity") == .antigravity)
        precondition(SessionAppDestination.claude(entrypoint: .unknown, ideName: "Cursor") == .cursor)
        precondition(SessionAppDestination.claude(entrypoint: .unknown, ideName: "Terminal") == .terminal)
        precondition(SessionAppDestination.claude(entrypoint: .unknown, ideName: "Unrecognised editor") == nil)
        for destination in [SessionAppDestination.codex, .claude, .terminal, .vscode, .antigravity] {
            let application = destination.bundleIdentifiers.lazy.compactMap {
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
            }.first
            print("\(destination.label): \(application?.path ?? "not installed")")
        }
        precondition(SessionAppResolver.application(containing: "/Users/example/.local/bin/codex") == nil)
        precondition(SessionAppResolver.application(containing: "/Applications/ChatGPT.app/Contents/Resources/codex") == .codex)
        if CommandLine.arguments.count > 1 {
            let actual = SessionAppResolver.codexOwner(of: URL(fileURLWithPath: CommandLine.arguments[1]))
            precondition(actual == .terminal, "Resumed terminal session must override old Desktop metadata")
            print("Live transcript owner: Terminal")
        }
        print("PASS: input-host precedence, Desktop vs vscode transport, CLI, editors, unknown-host fallback")
    }
}
