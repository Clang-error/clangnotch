//
//  FullScreenDetector.swift
//  ClangNotch
//
//  Detects whether the active Space is a full-screen Space via private SkyLight (CGS)
//  APIs. A full-screen app lives on its own Space whose "type" is 4 — `visibleFrame`
//  / window-list checks don't work across Spaces, but this does.
//

import Foundation
import AppKit
import CoreGraphics

enum FullScreenDetector {
    private typealias ConnFn = @convention(c) () -> Int32
    private typealias SpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?

    private static let handle = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)

    private static let connID: Int32 = {
        guard let h = handle, let sym = dlsym(h, "CGSMainConnectionID") else { return 0 }
        return unsafeBitCast(sym, to: ConnFn.self)()
    }()

    private static let copySpaces: SpacesFn? = {
        guard let h = handle, let sym = dlsym(h, "CGSCopyManagedDisplaySpaces") else { return nil }
        return unsafeBitCast(sym, to: SpacesFn.self)
    }()

    /// Full-screen Space type returned by CGS.
    private static let fullScreenSpaceType = 4

    /// True if the Space currently shown on the notch's display (primary screen) is a
    /// full-screen Space. Full-screen apps on *other* displays are ignored, so a
    /// full-screen window on a secondary monitor no longer hides the notch.
    static func isFullScreenActive() -> Bool {
        guard connID != 0, let copySpaces,
              let displays = copySpaces(connID)?.takeRetainedValue() as? [[String: Any]]
        else { return false }

        let notchUUID = notchDisplayUUID()
        for display in displays {
            guard isNotchDisplay(display, uuid: notchUUID) else { continue }
            if let current = display["Current Space"] as? [String: Any] {
                return (current["type"] as? Int) == fullScreenSpaceType
            }
            return false
        }
        return false
    }

    /// Match the CGS display entry to the display the notch lives on.
    private static func isNotchDisplay(_ display: [String: Any], uuid: String?) -> Bool {
        guard let id = display["Display Identifier"] as? String else { return false }
        if let uuid, id == uuid { return true }
        // Single-display setups (and some configs) report the main display as "Main".
        if id == "Main", NotchDetector.notchScreen == NSScreen.screens.first { return true }
        return false
    }

    /// UUID string of the primary display (where the notch panel is placed).
    private static func notchDisplayUUID() -> String? {
        guard let screen = NotchDetector.notchScreen,
              let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return nil }
        let displayID = CGDirectDisplayID(num.uint32Value)
        guard let cfUUID = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, cfUUID) as String
    }
}
