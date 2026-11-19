import ApplicationServices
import Foundation

/// macOS switches an active event tap off when it waits too long on it, and also when the app
/// loses Accessibility. Turning it straight back on is right in the first case and freezes the
/// whole Mac's keyboard and mouse in the second: every event waits on the tap again until macOS
/// gives up on it, over and over, until ClangNotch quits (user, 2026-11-19: removing the app from
/// the Accessibility list to add it again with "+"). So a switched-off tap comes back only while
/// Accessibility still allows it; otherwise every tap that holds input is taken down.
enum EventTapRecovery {
    /// From a tap's callback on `.tapDisabledByTimeout` or `.tapDisabledByUserInput`.
    static func tapWasDisabled(_ tap: CFMachPort?) {
        guard let tap else { return }
        if AXIsProcessTrusted() {
            CGEvent.tapEnable(tap: tap, enable: true)
        } else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { KeyboardLockManager.shared.accessibilityLost() }
            }
        }
    }
}
