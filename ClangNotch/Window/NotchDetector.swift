import AppKit

struct NotchDetector {

    // MARK: - Primary display resolution

    /// The user's primary display (the screen with the menu bar, set in System Settings).
    ///
    /// `NSScreen.main` follows **keyboard focus** — when Sidecar connects and the iPad
    /// briefly receives focus, the notch window jumps to the iPad. `screens.first` is
    /// always the primary display regardless of focus, and Sidecar iPads are never primary.
    /// This also works when an external monitor is set as primary at home.
    static var notchScreen: NSScreen? {
        if usesBuiltInDisplay, let notched = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            return notched
        }
        return NSScreen.screens.first ?? NSScreen.main
    }

    /// `--notch-display builtin`: the MacBook's own notch even while an external display is
    /// primary, for checking the notch there without changing the display arrangement.
    private static let usesBuiltInDisplay: Bool = {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--notch-display"), index + 1 < args.count else { return false }
        return args[index + 1] == "builtin"
    }()
}
