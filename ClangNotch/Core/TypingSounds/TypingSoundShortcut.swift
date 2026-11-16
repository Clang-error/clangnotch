import AppKit
import Carbon.HIToolbox

/// The key of the user's choosing that turns 입력 효과음 on and off. It is a system hot key
/// (Carbon), not something heard on the key tap: it works while the tap is down, which is
/// whenever the sounds are off, and the key goes to no other app while it is set.
@MainActor
final class TypingSoundShortcut {
    var pressed: () -> Void = {}
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var current: (key: Int, modifiers: UInt) = (-1, 0)

    /// Esc, which ends 설정's recording of a shortcut without one.
    nonisolated static let escapeKey = kVK_Escape

    /// The modifiers a shortcut is made of, out of an event's.
    nonisolated static func modifiers(of flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags.intersection([.control, .option, .shift, .command])
    }

    /// A letter alone would be taken from all typing: ⌃, ⌥ or ⌘ has to be held.
    nonisolated static func isUsable(_ flags: NSEvent.ModifierFlags) -> Bool {
        !flags.intersection([.control, .option, .command]).isEmpty
    }

    /// What the key types on the Latin layout, whatever input source is on: under Korean the
    /// event's own characters are a jamo.
    nonisolated static func character(forKey key: Int) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layout = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = layout.withUnsafeBytes { bytes in
            UCKeyTranslate(bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress, UInt16(key),
                           UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                           OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeys, characters.count, &length, &characters)
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length)
    }

    /// As menus write it: "⌃⌥M". `characters`: the key's own, modifiers left out.
    nonisolated static func label(key: Int, modifiers flags: NSEvent.ModifierFlags, characters: String?) -> String {
        var label = ""
        if flags.contains(.control) { label += "⌃" }
        if flags.contains(.option) { label += "⌥" }
        if flags.contains(.shift) { label += "⇧" }
        if flags.contains(.command) { label += "⌘" }
        let named = [kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_Escape: "⎋",
                     kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
                     kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
                     kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12"]
        if let name = named[key] { return label + name }
        let character = (characters ?? "").uppercased()
        return label + (character.isEmpty ? "?" : character)
    }

    /// Takes the key with these modifiers (`NSEvent.ModifierFlags`), or none when `key` is
    /// below 0. False when macOS refuses it.
    @discardableResult
    func register(key: Int, modifiers: UInt) -> Bool {
        if key == current.key, modifiers == current.modifiers { return key < 0 || hotKey != nil }
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        current = (key, modifiers)
        guard key >= 0 else { return true }
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetEventDispatcherTarget(), { _, _, context in
                guard let context else { return noErr }
                let shortcut = Unmanaged<TypingSoundShortcut>.fromOpaque(context).takeUnretainedValue()
                Task { @MainActor in shortcut.pressed() }
                return noErr
            }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        }
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        var carbon = 0
        if flags.contains(.control) { carbon |= controlKey }
        if flags.contains(.option) { carbon |= optionKey }
        if flags.contains(.shift) { carbon |= shiftKey }
        if flags.contains(.command) { carbon |= cmdKey }
        // 'CNTS'
        let id = EventHotKeyID(signature: 0x434E_5453, id: 1)
        return RegisterEventHotKey(UInt32(key), UInt32(carbon), id, GetEventDispatcherTarget(), 0, &hotKey) == noErr
            && hotKey != nil
    }
}
