import AppKit
import SwiftUI

/// The borderless, see-through window the notch is drawn in. It is far larger than the
/// visible notch; `UICoordinator` lets clicks through everywhere outside
/// `notchInteractiveSize` / `notchInteractiveShape`.
final class NotchPanel: NSPanel {
    var notchInteractiveSize = CGSize(width: 250, height: 40)
    var notchInteractiveShape: NotchShape?

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel, .utilityWindow, .hudWindow],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        appearance = NSAppearance(named: .darkAqua)
        // Above the menu bar, so the notch can cover it.
        level = .mainMenu + 3
        // On every Space and fixed in place while Spaces slide. Not on full-screen Spaces:
        // the notch hides there anyway (`UICoordinator.applyFullScreenVisibility`).
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    }

    func setContent<Content: View>(@ViewBuilder content: () -> Content) {
        contentView = NSHostingView(rootView: content())
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
