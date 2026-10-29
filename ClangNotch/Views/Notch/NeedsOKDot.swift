import SwiftUI

/// The orange dot before "Needs OK" in the right wing, breathing while a tool waits for approval.
struct NeedsOKDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bright = false

    var body: some View {
        Circle()
            .fill(Color.orange)
            .frame(width: 8, height: 8)
            .scaleEffect(bright ? 1.2 : 0.9)
            .opacity(bright ? 1 : 0.6)
            .onAppear {
                // Reduce Motion holds the bright frame.
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    bright = true
                }
            }
    }
}
