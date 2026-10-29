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
}
