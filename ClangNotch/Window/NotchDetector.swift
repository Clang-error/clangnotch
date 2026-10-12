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

    /// Get the notch area dimensions
    private static func getNotchInfo() -> (width: CGFloat, height: CGFloat)? {
        guard let screen = notchScreen else { return nil }

        let leftArea = screen.auxiliaryTopLeftArea
        let rightArea = screen.auxiliaryTopRightArea

        if let left = leftArea, let right = rightArea, (left.width > 0 || right.width > 0) {
            let screenWidth = screen.frame.width
            let notchWidth = screenWidth - left.width - right.width
            let notchHeight = max(left.height, right.height, 32)
            return (width: notchWidth, height: notchHeight)
        }

        if screen.safeAreaInsets.top > 0 {
            return (width: 200, height: screen.safeAreaInsets.top)
        }

        return nil
    }

    /// Get the notch frame for the closed/minimal state
    static func notchFrame() -> NSRect? {
        guard let screen = notchScreen else { return nil }

        let screenFrame = screen.frame
        let notchInfo = getNotchInfo()
        let notchWidth: CGFloat = min(notchInfo?.width ?? 200, 220)
        let notchHeight: CGFloat = notchInfo?.height ?? 32

        let notchX = screenFrame.origin.x + (screenFrame.width - notchWidth) / 2
        let notchY = screenFrame.origin.y + screenFrame.height - notchHeight

        return NSRect(x: notchX, y: notchY, width: notchWidth, height: notchHeight)
    }

    /// Get the expanded notch frame
    static func expandedNotchFrame() -> NSRect? {
        guard let screen = notchScreen else { return nil }

        let screenFrame = screen.frame
        let notchInfo = getNotchInfo()
        let notchHeight = notchInfo?.height ?? 32

        let expandedWidth: CGFloat = 400
        let expandedHeight: CGFloat = 200

        let expandedX = screenFrame.origin.x + (screenFrame.width - expandedWidth) / 2
        let expandedY = screenFrame.origin.y + screenFrame.height - expandedHeight - notchHeight

        return NSRect(x: expandedX, y: expandedY, width: expandedWidth, height: expandedHeight)
    }

    /// Get menu bar frame (for non-notch Macs)
    static func menuBarFrame() -> NSRect? {
        guard let screen = notchScreen else { return nil }

        let screenFrame = screen.frame
        let menuBarHeight: CGFloat = 28

        let width: CGFloat = 220
        let height: CGFloat = menuBarHeight

        let x = screenFrame.origin.x + (screenFrame.width - width) / 2
        let y = screenFrame.origin.y + screenFrame.height - height

        return NSRect(x: x, y: y, width: width, height: height)
    }
}

