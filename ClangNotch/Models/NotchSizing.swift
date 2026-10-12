// NotchSizing.swift
// Sizing constants and helpers for the notch UI

import SwiftUI

// MARK: - Fixed Sizes

/// Shadow padding around the window
let shadowPadding: CGFloat = 20

/// Extra bottom spacing to allow the closed-state glow to render fully
let closedNotchGlowPadding: CGFloat = 24

/// Fixed outer size shared by every expanded tab.
let openNotchSize: CGSize = .init(width: 600, height: 540)
let questionNotchWidth: CGFloat = 420
let maximumPeekHeight: CGFloat = 340
// The inward shoulder consumes 19pt before the 16pt content margin.
let expandedNotchInset: CGFloat = 35

/// Collapsing to the closed notch. A curve that stops exactly at the target, not a spring:
/// the 0.8 spring overshot inside the physical notch and sprang back, and a critically
/// damped one crept the last few points so slowly it read as a second, slower push inward.
let notchCloseDuration: TimeInterval = 0.3
let notchCloseAnimation = Animation.timingCurve(0.25, 0.8, 0.35, 1, duration: notchCloseDuration)

/// Open toolbar height. The view reserves the physical notch height separately
/// above this toolbar so the camera housing cannot obscure its controls.
let openHeaderHeight: CGFloat = 56

/// Window size (includes shadow padding)
// The transparent hosting window also accommodates closed wings and shadows.
// Its size must not determine the visible surface or the click-through region.
let windowSize: CGSize = .init(width: 760, height: openNotchSize.height + shadowPadding)

/// Corner radius for open/closed states
let cornerRadiusInsets = (
    opened: (top: CGFloat(19), bottom: CGFloat(24)),
    closed: (top: CGFloat(6), bottom: CGFloat(14))
)

// MARK: - Dynamic Sizing

/// Get the closed notch size for a screen
@MainActor
func getClosedNotchSize(screen: NSScreen? = nil) -> CGSize {
    let selectedScreen = screen ?? NotchDetector.notchScreen

    var notchHeight: CGFloat = 32
    var notchWidth: CGFloat = 185

    if let screen = selectedScreen {
        // Calculate notch width from auxiliary areas
        if let topLeftPadding = screen.auxiliaryTopLeftArea?.width,
           let topRightPadding = screen.auxiliaryTopRightArea?.width {
            notchWidth = screen.frame.width - topLeftPadding - topRightPadding + 4
        }

        // Get height from safe area or menu bar
        if screen.safeAreaInsets.top > 0 {
            // Mac with notch
            notchHeight = screen.safeAreaInsets.top
        } else {
            // Mac without notch - use menu bar height
            notchHeight = screen.frame.maxY - screen.visibleFrame.maxY
            if notchHeight < 24 { notchHeight = 32 }
        }
    }

    return CGSize(width: notchWidth, height: notchHeight + 2)
}
