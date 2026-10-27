//
//  MissionControlDetector.swift
//  ClangNotch
//
//  Detects whether Mission Control / App Exposé / Launchpad is on screen. Those put a
//  Spaces strip along the top of the display — exactly where the notch panel lives — so
//  reaching for a Space would hover the notch open and let it swallow those clicks.
//

import AppKit
import CoreGraphics

enum MissionControlDetector {
    /// `frontmostApplication` does NOT change when Mission Control opens (measured: the
    /// previous app stays frontmost), so that common check is useless here.
    ///
    /// The Dock's own window is no help either: Mission Control and the auto-hidden Dock
    /// revealed by hovering both show the same Dock window (layer 20, full screen), so
    /// keying on it hid the notch whenever the cursor touched the Dock.
    ///
    /// What only Mission Control adds: full-width `WindowManager` windows on positive
    /// layers (19 = the overlay, 14 = the Spaces strip, measured on macOS 27.0). Stage
    /// Manager's own strip lives on layer 0, so it doesn't count.
    static func isActive() -> Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        let screenWidth = NSScreen.screens.map(\.frame.width).min() ?? 0
        return windows.contains { window in
            let bounds = window[kCGWindowBounds as String] as? [String: Any]
            return (window[kCGWindowOwnerName as String] as? String) == "WindowManager"
                && (window[kCGWindowLayer as String] as? Int ?? 0) > 0
                && (bounds?["Width"] as? Double ?? 0) >= screenWidth
        }
    }
}
