import SwiftUI

/// The orange dot before "Needs OK" in the right wing, breathing while a tool waits for approval.
struct NeedsOKDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// A hidden notch (full-screen app, Mission Control) is only at alpha 0, and a repeating
    /// animation keeps drawing there: it rests until the notch is back.
    @ObservedObject private var ui = UICoordinator.shared
    @State private var bright = false

    var body: some View {
        Circle()
            .fill(Color.orange)
            .frame(width: 8, height: 8)
            .scaleEffect(bright ? 1.2 : 0.9)
            .opacity(bright ? 1 : 0.6)
            .onAppear { breathe(ui.isVisible) }
            .onChange(of: ui.isVisible) { _, visible in breathe(visible) }
    }

    private func breathe(_ on: Bool) {
        if on {
            // Reduce Motion holds the bright frame.
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                bright = true
            }
        } else {
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) { bright = false }
        }
    }
}
