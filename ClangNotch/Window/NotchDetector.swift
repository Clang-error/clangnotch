import AppKit

struct NotchDetector {

    // MARK: - Primary display resolution

    /// The user's primary display (the screen with the menu bar, set in System Settings).
    ///
    /// `NSScreen.main` follows **keyboard focus** — when Sidecar connects and the iPad
    /// briefly receives focus, the notch window jumps to the iPad. `screens.first` is
    /// always the primary display regardless of focus, and Sidecar iPads are never primary.
    /// This also works when an external monitor is set as primary at home.
    ///
    /// 설정 › 노치 › "표시할 디스플레이" can name another display instead; while that one isn't
    /// connected the notch is back on the primary one.
    static var notchScreen: NSScreen? {
        if usesBuiltInDisplay, let notched = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            return notched
        }
        if let chosen = chosenScreen, NSScreen.screens.contains(chosen) { return chosen }
        return NSScreen.screens.first ?? NSScreen.main
    }

    // MARK: - The display picked in 설정

    /// "표시할 디스플레이"'s value for the primary display; any other value is a display's UUID.
    static let mainDisplay = "main"
    static let displayKey = "notchDisplay"

    /// The picked display, looked up when the setting or the displays change and not on every
    /// read of `notchScreen`. nil: the primary display, or one that isn't connected.
    nonisolated(unsafe) private static var chosenScreen: NSScreen? = findChosenScreen()

    /// Call after the displays change.
    static func refreshChosenDisplay() {
        chosenScreen = findChosenScreen()
    }

    /// Call after the setting changes: the notch moves and takes the new display's measures.
    static func displayChoiceChanged() {
        refreshChosenDisplay()
        NotificationCenter.default.post(name: .notchDisplayChanged, object: nil)
    }

    private static func findChosenScreen() -> NSScreen? {
        guard let uuid = UserDefaults.standard.string(forKey: displayKey), uuid != mainDisplay else { return nil }
        return NSScreen.screens.first { Self.uuid(of: $0) == uuid }
    }

    /// The display's UUID, which it keeps across reconnects.
    static func uuid(of screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(CGDirectDisplayID(number.uint32Value))?.takeRetainedValue()
        else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    /// The connected displays, for the picker. `isMain`: the primary one, which the picker
    /// already has as "주 디스플레이".
    static var displays: [(uuid: String, name: String, isMain: Bool)] {
        NSScreen.screens.enumerated().compactMap { index, screen in
            uuid(of: screen).map { ($0, screen.localizedName, index == 0) }
        }
    }

    /// `--notch-display builtin`: the MacBook's own notch even while an external display is
    /// primary, for checking the notch there without changing the display arrangement.
    private static let usesBuiltInDisplay: Bool = {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--notch-display"), index + 1 < args.count else { return false }
        return args[index + 1] == "builtin"
    }()
}

extension Notification.Name {
    /// 설정 › 노치 › "표시할 디스플레이" changed (`NotchDetector.displayChoiceChanged`).
    static let notchDisplayChanged = Notification.Name("notchDisplayChanged")
}
