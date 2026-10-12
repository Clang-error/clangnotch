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
        NSScreen.screens.first ?? NSScreen.main
    }

    // MARK: - Notch detection

    /// Check if the primary screen has a notch using auxiliaryTopLeftArea
    static func hasNotch() -> Bool {
        guard let screen = notchScreen else { return false }

        if let leftArea = screen.auxiliaryTopLeftArea, leftArea.width > 0 {
            return true
        }

        if screen.safeAreaInsets.top > 0 {
            return true
        }

        return false
    }
}
