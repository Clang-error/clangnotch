import AppKit
import SwiftUI

final class ClangNotchAppDelegate: NSObject, NSApplicationDelegate {
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        if TWorldCommand.runIfRequested() { return }

        Task { @MainActor in
            UICoordinator.shared.setupUI()
        }

        if AppSettings.shared.telemetryAutoStart {
            Task { @MainActor in
                await TelemetryCoordinator.shared.start()
            }
        }

        Task { @MainActor in
            RemoteClaudeManager.shared.apply()
        }

        Task { @MainActor in
            SystemBannerCenterer.shared.syncWithSettings()
            UpdateChecker.shared.syncWithSettings()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { RemoteClaudeManager.shared.stopAll() }
        Task { @MainActor in
            await TelemetryCoordinator.shared.stop()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        CommandLine.arguments.contains("--tworld-login")
    }

    @objc func showSettingsWindow() {
        if let existingWindow = settingsWindow, existingWindow.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            existingWindow.makeKeyAndOrderFront(nil)
            return
        }

        let settingsView = AgentSettingsView()
            .environmentObject(TelemetryCoordinator.shared)

        let hostingController = NSHostingController(rootView: settingsView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 450, height: 300),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hostingController
        window.title = "Settings"
        window.setFrameAutosaveName("SettingsWindow")
        window.center()
        window.isReleasedWhenClosed = false

        settingsWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
