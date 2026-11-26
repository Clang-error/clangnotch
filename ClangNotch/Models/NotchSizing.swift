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
/// The 세션 화면 widens the open notch for its step list and diff side by side.
let sessionDetailNotchSize: CGSize = .init(width: 720, height: openNotchSize.height)
/// The 권한·완료 드롭다운: commands, paths and answers need more room than the 420pt notices.
let permissionNotchWidth: CGFloat = 520
/// The 미디어 드롭다운 when it comes down attached to the notch: its visible body is the card's
/// 340 (`AirPodsDropdown.mediaCardSize`), the window 19 wider each side for the notch's top
/// corners (`cornerRadiusInsets.opened.top`). Narrower than the 완료 드롭다운.
let mediaNotchWidth: CGFloat = 340 + 2 * 19
let maximumPeekHeight: CGFloat = 340
/// The 질문 드롭다운 after its 확대 버튼: about half the screen across and three fifths down,
/// so a Claude question with long options reads without scrolling.
@MainActor
func expandedQuestionSize(screen: NSScreen? = NotchDetector.notchScreen) -> CGSize {
    let frame = screen?.frame.size ?? CGSize(width: 1512, height: 982)
    return CGSize(width: min(1100, (frame.width * 0.55).rounded()),
                  height: min(700, (frame.height * 0.62).rounded()))
}
// The inward shoulder consumes 19pt before the 16pt content margin.
let expandedNotchInset: CGFloat = 35

/// Collapsing to the closed notch. A curve that stops exactly at the target, not a spring:
/// the 0.8 spring overshot inside the physical notch and sprang back, and a critically
/// damped one crept the last few points so slowly it read as a second, slower push inward.
let notchCloseDuration: TimeInterval = 0.3
let notchCloseAnimation = Animation.timingCurve(0.25, 0.8, 0.35, 1, duration: notchCloseDuration)

/// A dropdown going away: slower and eased at both ends. With `notchCloseAnimation` it lost
/// 80% of its height in the first few frames and read as cut off.
let dropdownFoldDuration: TimeInterval = 0.45
let dropdownFoldAnimation = Animation.timingCurve(0.4, 0, 0.2, 1, duration: dropdownFoldDuration)

/// The closed wings growing or shrinking for a new label. The black surface, the glow and
/// the wing content all use this one curve, so the content never lands before its edge.
let closedWingResizeAnimation = Animation.timingCurve(0.22, 0.7, 0.25, 1, duration: 0.3)

/// Opening and dropping a dropdown overshoot a little and settle — the notch feels springy
/// going out and stays tidy coming back (`notchCloseAnimation`).
let notchOpenSpring = Animation.spring(response: 0.5, dampingFraction: 0.72)

/// Open toolbar height. The view reserves the physical notch height separately
/// above this toolbar so the camera housing cannot obscure its controls.
let openHeaderHeight: CGFloat = 56

/// Window size (includes shadow padding)
// The transparent hosting window also accommodates closed wings and shadows.
// Its size must not determine the visible surface or the click-through region.
// Wide and tall enough for the largest surface, `expandedQuestionSize`.
let windowSize: CGSize = .init(width: 1140, height: 700 + shadowPadding)

/// Corner radius for open/closed states
let cornerRadiusInsets = (
    opened: (top: CGFloat(19), bottom: CGFloat(24)),
    closed: (top: CGFloat(6), bottom: CGFloat(14))
)

// MARK: - Island

/// 설정 › 실험 기능 › "외부 모니터에서 다이내믹 아일랜드" (2026-11-23): on a display that isn't the
/// Mac's own, the notch is the OLED MacBook Pro's Dynamic Island, a black pill floating under the
/// screen's top edge, instead of a shape hanging from it.
enum NotchIsland {
    /// The closed pill and how far below the top edge it floats. Apple published no figure (as
    /// of 2026-11-23); measured from its 2026-10-28 lineup photo of the 14- and 16-inch PROLED
    /// models, which draws both screens at one scale (1041px for 1512pt, 1197px for 1728pt):
    /// a 40×21px capsule 6px under the edge on each, so ±1.5pt.
    static let width: CGFloat = 58
    static let height: CGFloat = 30
    static let floatGap: CGFloat = 9

    /// `--island-preview`: with the setting on, the island on the built-in display too, hung below
    /// its camera housing, for looking at it without an external display (user, 2026-11-23).
    static let preview = CommandLine.arguments.contains("--island-preview")

    /// How far below the screen's top edge the pill floats: `floatGap`, plus the camera housing
    /// in a preview.
    @MainActor
    static var gap: CGFloat {
        floatGap + (preview ? NotchDetector.notchScreen?.safeAreaInsets.top ?? 0 : 0)
    }

    /// On for `screen` when the setting is on and it is the notch's display and not built in.
    /// The user asked for external displays only: the built-in one keeps its camera housing, or
    /// on a Mac without one, the usual shape.
    @MainActor
    static func isOn(on screen: NSScreen? = NotchDetector.notchScreen) -> Bool {
        guard AppSettings.shared.experimentalExternalIsland, let screen, screen == NotchDetector.notchScreen,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return false }
        return preview || CGDisplayIsBuiltin(CGDirectDisplayID(number.uint32Value)) == 0
    }

}

// MARK: - Dynamic Sizing

/// Get the closed notch size for a screen
@MainActor
func getClosedNotchSize(screen: NSScreen? = nil) -> CGSize {
    let selectedScreen = screen ?? NotchDetector.notchScreen
    // `NotchShape` sets the sides `cornerRadiusInsets.closed.top` in from the frame, so the
    // frame is that much wider each side than the pill it draws.
    if NotchIsland.isOn(on: selectedScreen) {
        return CGSize(width: NotchIsland.width + 2 * cornerRadiusInsets.closed.top, height: NotchIsland.height)
    }

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

    // +1: at exactly the safe-area height the notch read as tucked inside the camera housing and
    // half of the glow stroke went under it; +2 (upstream) hung visibly below it.
    return CGSize(width: notchWidth, height: notchHeight + 1)
}
