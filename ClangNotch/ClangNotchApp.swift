import SwiftUI

@main
struct ClangNotchApp: App {
    @NSApplicationDelegateAdaptor(ClangNotchAppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            AgentSettingsView()
                .environmentObject(TelemetryCoordinator.shared)
        }
    }
}
