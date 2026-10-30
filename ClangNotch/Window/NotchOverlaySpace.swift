import AppKit

/// Moves the notch panel out of the desktop Spaces into a private SkyLight space, the way the
/// Dock lives outside them.
///
/// Stage Manager treats any window on the desktop Space as part of the current stage: when it
/// rearranged a large window (clicking an app icon in the strip), it slid the notch along with
/// that window and then off toward the strip (2026-10-30). A window in no desktop Space is left
/// alone. `SLSSpaceAddWindowsAndRemoveFromSpaces` with selector 0x7 also removes it from the
/// desktop Spaces; the older `CGSAddWindowsToSpaces` only added it and left it there.
///
/// Absolute level 0 keeps ordinary window levels: the app's own menus and tooltips still draw
/// above the panel (checked). Membership is read back with mask 0xF, the only one that lists
/// a private space. Missing symbols leave the panel where it is.
enum NotchOverlaySpace {
    private typealias ConnectionFn = @convention(c) () -> Int32
    private typealias CreateFn = @convention(c) (Int32, Int32, CFDictionary?) -> UInt64
    private typealias SetLevelFn = @convention(c) (Int32, UInt64, Int32) -> Int32
    private typealias ShowFn = @convention(c) (Int32, CFArray) -> Int32
    private typealias MoveWindowsFn = @convention(c) (Int32, UInt64, CFArray, Int32) -> Int32
    private typealias CopySpacesFn = @convention(c) (Int32, Int32, CFArray) -> CFArray?

    private struct SkyLight {
        let connection: Int32
        let create: CreateFn
        let setLevel: SetLevelFn
        let show: ShowFn
        let moveWindows: MoveWindowsFn
        let copySpaces: CopySpacesFn
    }

    private static let skyLight: SkyLight? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else {
            return nil
        }
        func load<T>(_ name: String, as _: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: T.self) }
        }
        guard let connection = load("SLSMainConnectionID", as: ConnectionFn.self),
              let create = load("SLSSpaceCreate", as: CreateFn.self),
              let setLevel = load("SLSSpaceSetAbsoluteLevel", as: SetLevelFn.self),
              let show = load("SLSShowSpaces", as: ShowFn.self),
              let moveWindows = load("SLSSpaceAddWindowsAndRemoveFromSpaces", as: MoveWindowsFn.self),
              let copySpaces = load("SLSCopySpacesForWindows", as: CopySpacesFn.self)
        else { return nil }
        return SkyLight(connection: connection(), create: create, setLevel: setLevel, show: show,
                        moveWindows: moveWindows, copySpaces: copySpaces)
    }()

    private static var spaceID: UInt64?

    /// Safe to call repeatedly; does nothing once the window is in the space.
    static func pin(_ window: NSWindow) {
        guard let skyLight, window.windowNumber > 0, let space = space(skyLight) else { return }
        guard !contains(window, space: space, skyLight) else { return }
        _ = skyLight.moveWindows(skyLight.connection, space, [NSNumber(value: window.windowNumber)] as CFArray, 0x7)
        debugLog("[NotchSpace] pinned: \(contains(window, space: space, skyLight))")
    }

    private static func space(_ skyLight: SkyLight) -> UInt64? {
        if let spaceID { return spaceID }
        let space = skyLight.create(skyLight.connection, 1, nil)
        guard space != 0 else { return nil }
        _ = skyLight.setLevel(skyLight.connection, space, 0)
        _ = skyLight.show(skyLight.connection, [NSNumber(value: space)] as CFArray)
        spaceID = space
        return space
    }

    private static func contains(_ window: NSWindow, space: UInt64, _ skyLight: SkyLight) -> Bool {
        let spaces = skyLight.copySpaces(skyLight.connection, 0xF, [NSNumber(value: window.windowNumber)] as CFArray)
        return (spaces as? [NSNumber])?.contains { $0.uint64Value == space } == true
    }
}
