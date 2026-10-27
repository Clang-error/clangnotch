import AppKit
import ApplicationServices

/// "볼륨·밝기 표시 바꾸기": takes over macOS system banners the moment they appear.
/// Volume and brightness banners go off screen and ClangNotch's own 조절창
/// (`SystemControlOSD`) shows instead; every other banner (AirPods, …) moves from the
/// top-right corner to the horizontal center of its screen, just below the menu bar.
///
/// On macOS 27 these banners are windows of MenuBarAgent. Volume changes that skip
/// the keyboard (an AirPods Max crown) can't be caught with a key tap, so the window
/// itself is moved through Accessibility the moment it is created. Needs
/// Accessibility permission.
@MainActor
final class SystemBannerCenterer {
    static let shared = SystemBannerCenterer()

    nonisolated private static let agentBundleID = "com.apple.MenuBarAgent"
    private static let volumeBannerID = "volume-system-banner"
    private static let brightnessBannerID = "display-brightness-system-banner"

    private var observer: AXObserver?
    private var observedPID: pid_t?
    private var launchObserver: NSObjectProtocol?

    private init() {}

    func syncWithSettings() {
        if AppSettings.shared.centerSystemBanners { start() } else { stop() }
    }

    func start() {
        SystemControlOSD.shared.start()
        if launchObserver == nil {
            // MenuBarAgent is KeepAlive; after a restart the old observer is dead.
            launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
            ) { note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == Self.agentBundleID else { return }
                Task { @MainActor in SystemBannerCenterer.shared.attach() }
            }
        }
        attach()
    }

    func stop() {
        if let launchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(launchObserver)
        }
        launchObserver = nil
        detach()
        SystemControlOSD.shared.stop()
    }

    private func attach() {
        guard AXIsProcessTrusted(),
              let agent = NSRunningApplication.runningApplications(withBundleIdentifier: Self.agentBundleID).first,
              agent.processIdentifier != observedPID
        else { return }
        detach()

        let pid = agent.processIdentifier
        var newObserver: AXObserver?
        let created = AXObserverCreate(pid, { _, window, _, _ in
            // The run loop source is on the main run loop.
            MainActor.assumeIsolated { SystemBannerCenterer.takeOver(window) }
        }, &newObserver)
        guard created == .success, let newObserver else {
            debugLog("[SystemBanner] AXObserverCreate failed: \(created.rawValue)")
            return
        }
        AXObserverAddNotification(newObserver, AXUIElementCreateApplication(pid), kAXWindowCreatedNotification as CFString, nil)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(newObserver), .defaultMode)
        observer = newObserver
        observedPID = pid
        debugLog("[SystemBanner] watching MenuBarAgent pid \(pid)")
    }

    private func detach() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        observedPID = nil
    }

    private static func takeOver(_ window: AXUIElement) {
        // MenuBarAgent's menu bar windows are dialogs; banners are not.
        guard (attribute(window, kAXSubroleAttribute) as? String) != kAXDialogSubrole as String,
              let frame = frame(of: window)
        else { return }

        // AX frames have a top-left origin on the primary screen; NSScreen is bottom-left.
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let mid = CGPoint(x: frame.midX, y: primaryTop - frame.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mid) }) ?? NSScreen.main else { return }

        switch attribute(window, "AXIdentifier") as? String {
        case volumeBannerID:
            move(window, to: CGPoint(x: -10_000, y: frame.minY))
            SystemControlOSD.shared.showVolume(on: screen)
        case brightnessBannerID:
            move(window, to: CGPoint(x: -10_000, y: frame.minY))
            SystemControlOSD.shared.showBrightness(on: screen)
        default:
            // Only x changes: MenuBarAgent already places the banner just below the
            // menu bar, and moving it higher puts it behind the physical notch.
            move(window, to: CGPoint(x: screen.frame.midX - frame.width / 2, y: frame.minY))
        }
    }

    private static func move(_ window: AXUIElement, to point: CGPoint) {
        var origin = point
        guard let value = AXValueCreate(.cgPoint, &origin) else { return }
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func frame(of window: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success
        else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        return CGRect(origin: position, size: size)
    }
}
