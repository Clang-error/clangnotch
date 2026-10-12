//
//  MissionControlDetector.swift
//  ClangNotch
//
//  Detects whether Mission Control / App Exposé / Launchpad is on screen. Those put a
//  Spaces strip along the top of the display — exactly where the notch panel lives — so
//  reaching for a Space would hover the notch open and let it swallow those clicks.
//

import Foundation
import CoreGraphics

enum MissionControlDetector {
    /// `frontmostApplication` does NOT change when Mission Control opens (measured: the
    /// previous app stays frontmost), so that common check is useless here.
    ///
    /// What does change: Dock-owned windows normally sit only on the desktop layer (a
    /// large negative value), and Mission Control adds Dock windows on positive layers
    /// (18 and 20 as measured on macOS 26.5). Any positive-layer Dock window means one of
    /// these overlays is up. Counting windows would also work but is far more brittle.
    static func isActive() -> Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        return windows.contains { window in
            (window[kCGWindowOwnerName as String] as? String) == "Dock"
                && (window[kCGWindowLayer as String] as? Int ?? 0) > 0
        }
    }
}
