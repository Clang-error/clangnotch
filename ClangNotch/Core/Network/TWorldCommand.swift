import AppKit

/// Run the same signed executable from Terminal without creating a notch or opening Safari.
enum TWorldCommand {
    @MainActor static func runIfRequested() -> Bool {
        if CommandLine.arguments.contains("--tworld-login") {
            NSApp.setActivationPolicy(.regular)
            TWorldSession.shared.showLogin { NSApp.terminate(nil) }
            return true
        }
        guard CommandLine.arguments.contains("--tworld-balance") else { return false }
        Task {
            do {
                let vault = TWorldCookieVault()
                let stored = try await vault.load()
                let (balance, updated) = try await TWorldClient().fetch(cookies: stored.cookies, headers: stored.headers, endpoint: stored.endpoint)
                try await vault.save(updated, headers: stored.headers, endpoint: stored.endpoint)
                let output: [String: Any] = [
                    "name": balance.name, "totalGB": balance.totalGB,
                    "usedGB": balance.usedGB, "remainingGB": balance.remainingGB,
                    "fetchedAt": ISO8601DateFormatter().string(from: balance.fetchedAt)
                ]
                let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
                exit(0)
            } catch {
                // Never log cookie values, raw account responses or Keychain contents.
                FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
                exit(1)
            }
        }
        return true
    }
}
