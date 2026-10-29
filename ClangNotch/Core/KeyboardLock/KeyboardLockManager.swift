import AppKit
import ApplicationServices

private let blockedMediaKeyCodes: Set<Int> = [
    Int(NX_KEYTYPE_SOUND_UP),
    Int(NX_KEYTYPE_SOUND_DOWN),
    Int(NX_KEYTYPE_MUTE),
    Int(NX_KEYTYPE_PLAY),
    Int(NX_KEYTYPE_NEXT),
    Int(NX_KEYTYPE_PREVIOUS),
    Int(NX_KEYTYPE_FAST),
    Int(NX_KEYTYPE_REWIND),
]
private let systemDefinedEventType = CGEventType(rawValue: UInt32(NX_SYSDEFINED))!

private func isBlockedMediaKeyEvent(_ event: CGEvent) -> Bool {
    guard let nsEvent = NSEvent(cgEvent: event),
          Int(nsEvent.subtype.rawValue) == NX_SUBTYPE_AUX_CONTROL_BUTTONS else {
        return false
    }

    let keyCode = (nsEvent.data1 & 0xFFFF0000) >> 16
    return blockedMediaKeyCodes.contains(keyCode)
}

/// Blocks all keyboard input system-wide via a CGEventTap, so you can clean the
/// physical keyboard without triggering keystrokes (same idea as apps like
/// KeyboardCleanTool). Mouse/trackpad is never touched, so the toggle stays
/// reachable — this swallows regular keys plus volume and media controls.
@MainActor
final class KeyboardLockManager: ObservableObject {
    static let shared = KeyboardLockManager()

    @Published private(set) var isLocked = false
    @Published private(set) var hasAccessibilityPermission = AXIsProcessTrusted()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private init() {
        // Accessibility permission can be granted/revoked in System Settings while
        // the app is running — catch up whenever the user comes back to it, not
        // just when the tab happens to be reopened.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshPermissionStatus()
            }
        }
    }

    func toggle() {
        isLocked ? unlock() : lock()
    }

    func lock() {
        guard !isLocked else { return }
        guard AXIsProcessTrusted() else {
            hasAccessibilityPermission = false
            debugLog("[KeyboardLock] lock() blocked — Accessibility permission not granted")
            return
        }
        guard startTap() else {
            debugLog("[KeyboardLock] lock() failed — could not create event tap")
            return
        }
        isLocked = true
        debugLog("[KeyboardLock] locked")
    }

    func unlock() {
        guard isLocked else { return }
        stopTap()
        isLocked = false
        debugLog("[KeyboardLock] unlocked")
    }

    /// Triggers the system Accessibility permission prompt (only shows once per app).
    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        hasAccessibilityPermission = AXIsProcessTrustedWithOptions(options)
    }

    /// Re-checks permission without prompting — call when the tab reappears in
    /// case the user granted access in System Settings since we last checked.
    func refreshPermissionStatus() {
        hasAccessibilityPermission = AXIsProcessTrusted()
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Event tap

    private func startTap() -> Bool {
        let eventMask: UInt32 = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << systemDefinedEventType.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { _, type, event, refcon in
                // The event tap callback must stay synchronous and allocation-free.
                // Crossing into MainActor here can stall the tap long enough for
                // macOS to disable it, which makes the lock appear enabled while
                // keystrokes continue through.
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let refcon {
                        let manager = Unmanaged<KeyboardLockManager>.fromOpaque(refcon).takeUnretainedValue()
                        if let tap = manager.eventTap {
                            CGEvent.tapEnable(tap: tap, enable: true)
                        }
                    }
                    return Unmanaged.passUnretained(event)
                }
                if type == .keyDown || type == .keyUp || type == .flagsChanged {
                    return nil
                }
                if type == systemDefinedEventType && isBlockedMediaKeyEvent(event) {
                    return nil
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else {
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
            CFMachPortInvalidate(tap)
            return false
        }

        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func stopTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }
}
