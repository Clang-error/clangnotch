import AppKit

/// Key Test card in the Keyboard tab: which keys are held right now, by virtual key code.
/// Only while a test runs (started with the card's button) does ClangNotch take the keys,
/// and it keeps them from every other app: an Esc reaching a terminal ended the agent's turn.
/// The test ends with the button, or when the card leaves the screen, so input never stays
/// captured behind a closed notch.
@MainActor
final class KeyTester: ObservableObject {
    static let shared = KeyTester()

    @Published private(set) var isTesting = false
    @Published private(set) var pressed: Set<Int> = []
    /// Released within the last 2 seconds: drawn as a fainter afterglow.
    @Published private(set) var afterglow: Set<Int> = []

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var flashes: [Int: DispatchWorkItem] = [:]
    private var fades: [Int: DispatchWorkItem] = [:]

    private init() {}

    func toggle() { isTesting ? stop() : start() }

    func start() {
        guard eventTap == nil else { return }
        // Without Accessibility the tap can't be made: ask instead of doing nothing.
        guard AXIsProcessTrusted() else {
            // As the lock button does: macOS's prompt, and System Settings if that didn't do it.
            let permission = KeyboardLockManager.shared
            permission.requestPermission()
            if !permission.hasAccessibilityPermission { permission.openAccessibilitySettings() }
            return
        }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue) | (1 << UInt64(NX_SYSDEFINED))
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, _ in
                // Main run loop, so on the main thread.
                MainActor.assumeIsolated { KeyTester.shared.handle(type, event) }
                    ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: nil
        ), let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else { return }
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isTesting = true
    }

    func stop() {
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false); CFMachPortInvalidate(eventTap) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        eventTap = nil
        runLoopSource = nil
        (Array(flashes.values) + Array(fades.values)).forEach { $0.cancel() }
        flashes = [:]
        fades = [:]
        pressed = []
        afterglow = []
        isTesting = false
    }

    /// Volume and brightness keys never reach this tap: `SoftwareVolume` takes them first.
    /// During a test it hands them over here and drops them; true means they were used.
    func mediaKey(_ key: Int, isDown: Bool) -> Bool {
        guard isTesting else { return false }
        if let code = Self.mediaKeyCodes[key] { set(code, down: isDown) }
        return true
    }

    /// True swallows the event.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return false
        case .keyDown, .keyUp:
            set(Int(event.getIntegerValueField(.keyboardEventKeycode)), down: type == .keyDown)
            return true
        case .flagsChanged:
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            if let bit = Self.modifierBits[code] {
                set(code, down: event.flags.rawValue & bit != 0)
            } else {
                // Caps lock reports a state change, not down and up: flash it.
                flash(code)
            }
            return true
        default:
            guard type.rawValue == UInt32(NX_SYSDEFINED), let ns = NSEvent(cgEvent: event),
                  ns.subtype.rawValue == 8 else { return false }
            return mediaKey((ns.data1 & 0xFFFF_0000) >> 16, isDown: (ns.data1 & 0xFF00) >> 8 == 0xA)
        }
    }

    private func set(_ code: Int, down: Bool) {
        flashes[code]?.cancel()
        fades[code]?.cancel()
        if down {
            pressed.insert(code)
            afterglow.remove(code)
            return
        }
        guard pressed.remove(code) != nil else { return }
        afterglow.insert(code)
        let work = DispatchWorkItem { [weak self] in self?.afterglow.remove(code) }
        fades[code] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func flash(_ code: Int) {
        set(code, down: true)
        let work = DispatchWorkItem { [weak self] in self?.set(code, down: false) }
        flashes[code] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// Device-dependent flag bits (NX_DEVICE*KEYMASK), so left and right count separately.
    private static let modifierBits: [Int: UInt64] = [
        56: 0x02, 60: 0x04,        // shift
        59: 0x01, 62: 0x2000,      // control
        58: 0x20, 61: 0x40,        // option
        55: 0x08, 54: 0x10,        // command
        63: 0x80_0000,             // fn
    ]

    /// NX_KEYTYPE_* from the top row's media functions, onto the F key that carries it.
    private static let mediaKeyCodes: [Int: Int] = [
        3: 122, 2: 120,            // brightness down/up → F1, F2
        18: 98, 20: 98,            // previous, rewind → F7
        16: 100,                   // play → F8
        17: 101, 19: 101,          // next, fast → F9
        7: 109, 1: 103, 0: 111,    // mute, volume down, up → F10, F11, F12
    ]
}
