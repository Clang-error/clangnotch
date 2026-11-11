import AppKit
import SwiftUI

final class ClangNotchAppDelegate: NSObject, NSApplicationDelegate {
    private var settingsWindow: NSWindow?
    private var settingsToolbar: SettingsToolbarController?
    private var settingsNavigator: SettingsNavigator?

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
            // 모니터 소리 줄이기 also runs with 볼륨·밝기 표시 바꾸기 off.
            SoftwareVolume.shared.syncWithSettings()
            // Starts following the Accessibility setting, which the key taps above wait on.
            KeyboardLockManager.shared.refreshPermissionStatus()
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

        let (settingsView, toolbarController, navigator) = MainActor.assumeIsolated {
            let navigator = SettingsNavigator()
            return (AgentSettingsView(navigator: navigator), SettingsToolbarController(navigator: navigator), navigator)
        }
        settingsNavigator = navigator

        let hostingController = NSHostingController(rootView: settingsView)
        // The window is sized below. Left to size it, the controller added the toolbar's 52pt
        // to the fixed 600pt view, and the view (drawn up under the toolbar) left that strip
        // empty at the bottom.
        hostingController.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 450, height: 300),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // The sidebar runs up under the title bar; the unified toolbar makes that bar 52pt
        // tall so the traffic lights line up with the back/forward control and the title.
        // Set before the content: added after, the window sizes itself 66pt too tall.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbar = toolbarController.toolbar
        window.toolbarStyle = .unified
        window.isMovableByWindowBackground = true
        window.contentViewController = hostingController
        window.title = L("ClangNotch 설정", "ClangNotch Settings")
        // New key: the old one restores the tab-style window's 600×560 frame.
        window.setFrameAutosaveName("SettingsWindowSidebar")
        // The saved frame can be from a build that sized the window wrong, so the size is set
        // here. The view runs under the toolbar (full-size content) and fills the frame:
        // setContentSize put the toolbar's 52pt on top and left that strip empty at the bottom
        // (measured 780×652, 2026-11-11).
        window.setFrame(NSRect(x: 0, y: 0, width: 780, height: 600), display: false)
        window.center()
        window.isReleasedWhenClosed = false

        settingsWindow = window
        // The toolbar holds its delegate weakly.
        settingsToolbar = toolbarController
        // A closed window kept its whole SwiftUI view tree alive, still following every
        // manager it observes, until the next open replaced it.
        var closeObserver: NSObjectProtocol?
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self, weak window] _ in
            if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
            window?.contentViewController = nil
            if self?.settingsWindow === window {
                self?.settingsWindow = nil
                self?.settingsToolbar = nil
                self?.settingsNavigator = nil
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// The settings window, on `page`.
    @MainActor
    func showSettingsWindow(page: SettingsPage) {
        showSettingsWindow()
        settingsNavigator?.open(page)
    }
}
