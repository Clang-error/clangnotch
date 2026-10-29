import AppKit
import SwiftUI

final class ClangNotchAppDelegate: NSObject, NSApplicationDelegate {
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        if TWorldCommand.runIfRequested() { return }

        // Recording mode: only the notch and the scripted sessions. No hook receiver
        // (the real instance owns port 4318), no update checks.
        if DemoMode.isActive {
            Task { @MainActor in
                UICoordinator.shared.setupUI()
                DemoDriver.shared.start()
            }
            return
        }

        Task { @MainActor in
            UICoordinator.shared.setupUI()
        }

        Task { @MainActor in
            HookReceiver.shared.start()
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
        MainActor.assumeIsolated {
            RemoteClaudeManager.shared.stopAll()
            HookReceiver.shared.stop()
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

        let hostingController = NSHostingController(rootView: settingsView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 450, height: 300),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hostingController
        window.title = L("ClangNotch 설정", "ClangNotch Settings")
        window.setFrameAutosaveName("SettingsWindow")
        window.center()
        window.isReleasedWhenClosed = false

        settingsWindow = window
        // A closed window kept its whole SwiftUI view tree alive, still following every
        // manager it observes, until the next open replaced it.
        var closeObserver: NSObjectProtocol?
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self, weak window] _ in
            if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
            window?.contentViewController = nil
            if self?.settingsWindow === window { self?.settingsWindow = nil }
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
