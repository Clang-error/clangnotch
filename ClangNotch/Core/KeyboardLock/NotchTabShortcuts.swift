import AppKit
import Carbon.HIToolbox

extension Notification.Name {
    /// userInfo["index"]: Int — position in the visible tab strip.
    static let notchSelectTab = Notification.Name("notchSelectTab")
}

/// ⌘1–⌘7 switch tabs while the notch is open. The panel can never become key, so the
/// keystrokes are taken from a CGEvent tap instead — one that exists only while the notch
/// is open. Closed, peeking, or any other app in front: no tap, nothing intercepted.
@MainActor
final class NotchTabShortcuts {
    static let shared = NotchTabShortcuts()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private init() {}

    /// Called by the notch view as its state changes.
    func setActive(_ active: Bool) {
        if active {
            guard eventTap == nil, AXIsProcessTrusted() else { return }
            _ = startTap()
        } else {
            stopTap()
        }
    }

    private static let digitKeyCodes: [Int64: Int] = [
        Int64(kVK_ANSI_1): 0, Int64(kVK_ANSI_2): 1, Int64(kVK_ANSI_3): 2, Int64(kVK_ANSI_4): 3,
        Int64(kVK_ANSI_5): 4, Int64(kVK_ANSI_6): 5, Int64(kVK_ANSI_7): 6
    ]

    private func startTap() -> Bool {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                // Synchronous and allocation-free, like KeyboardLockManager's tap.
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let refcon {
                        let shortcuts = Unmanaged<NotchTabShortcuts>.fromOpaque(refcon).takeUnretainedValue()
                        if let tap = shortcuts.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
                    }
                    return Unmanaged.passUnretained(event)
                }
                guard type == .keyDown else { return Unmanaged.passUnretained(event) }
                // Exactly ⌘ (caps lock / fn / keypad bits ignored); ⌘⇧1, ⌃⌘1 etc. pass through.
                let modifiers = event.flags.intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate])
                guard modifiers == .maskCommand,
                      let index = NotchTabShortcuts.digitKeyCodes[event.getIntegerValueField(.keyboardEventKeycode)]
                else { return Unmanaged.passUnretained(event) }
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .notchSelectTab, object: nil, userInfo: ["index": index])
                }
                return nil
            },
            userInfo: refcon
        ) else { return false }
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
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        eventTap = nil
        runLoopSource = nil
    }
}
