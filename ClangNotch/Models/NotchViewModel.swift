// NotchViewModel.swift
// View model for notch state and animations

import SwiftUI
import Combine

enum NotchState {
    case closed
    case open
    case peeking
}

@MainActor
final class NotchViewModel: ObservableObject {
    @Published private(set) var notchState: NotchState = .closed
    @Published var notchSize: CGSize
    @Published var closedNotchSize: CGSize
    /// True while a collapse from the open panel or a dropdown is still travelling onto the
    /// physical notch. The surface stays drawn until it lands, instead of being scaled away
    /// mid-flight by the closed-notch dismiss effect.
    @Published private(set) var isSettlingClosed = false
    private var settleTask: Task<Void, Never>?

    private var animationSpring: Animation {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? .interactiveSpring(response: 0.38, dampingFraction: 0.8, blendDuration: 0)
            : notchOpenSpring
    }
    private var peekTask: Task<Void, Never>?
    private var closedPresentationWidth: CGFloat
    private var hasMeasuredClosedPresentation = false

    init() {
        let size = getClosedNotchSize()
        self.notchSize = size
        self.closedNotchSize = size
        self.closedPresentationWidth = size.width

        // Recompute the notch shape when displays change (connect/disconnect external).
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                self?.recomputeNotchSize()
            }
        }
    }

    private func recomputeNotchSize() {
        let size = getClosedNotchSize()
        closedNotchSize = size
        if notchState == .closed {
            notchSize = CGSize(width: max(size.width, closedPresentationWidth), height: size.height)
        }
    }

    /// The closed wings are content-sized. Keep their rendered outer width as the
    /// next resize animation's real starting point instead of the camera width.
    func updateClosedPresentationWidth(_ width: CGFloat) {
        guard notchState == .closed else { return }
        let measuredWidth = max(closedNotchSize.width, width)
        guard abs(measuredWidth - closedPresentationWidth) > 0.5 else { return }
        closedPresentationWidth = measuredWidth

        if hasMeasuredClosedPresentation {
            withAnimation(closedWingResizeAnimation) {
                notchSize = CGSize(width: measuredWidth, height: closedNotchSize.height)
            }
        } else {
            hasMeasuredClosedPresentation = true
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                notchSize = CGSize(width: measuredWidth, height: closedNotchSize.height)
            }
        }
    }

    /// Once the closed surface has shrunk into the camera, reset its invisible
    /// layout so the next entrance starts from the physical notch width.
    func resetClosedPresentationAfterDismiss() {
        guard notchState == .closed else { return }
        closedPresentationWidth = closedNotchSize.width
        hasMeasuredClosedPresentation = false
        notchSize = closedNotchSize
    }

    func open(size: CGSize = openNotchSize) {
        peekTask?.cancel()
        endSettling()
        // State change inside the animated transaction so header/content swaps
        // crossfade with the resize instead of popping.
        withAnimation(animationSpring) {
            notchState = .open
            notchSize = size
        }
    }

    func resizeOpen(to size: CGSize) {
        guard notchState == .open else { return }
        withAnimation(animationSpring) { notchSize = size }
    }

    /// Resizes a dropdown in place; unlike `peek` it may pass `maximumPeekHeight`.
    func resizePeek(to size: CGSize) {
        guard notchState == .peeking else { return }
        withAnimation(animationSpring) { notchSize = size }
    }

    /// How the notch is collapsing right now; the view animates its size with the same curve.
    private(set) var closeAnimation = notchCloseAnimation
    /// How long that collapse takes.
    private(set) var closeDuration = notchCloseDuration

    func close() {
        peekTask?.cancel()
        collapseToClosed()
    }

    /// Folds a dropdown away (`dropdownFoldAnimation`); the open notch still closes with `close()`.
    func fold() {
        peekTask?.cancel()
        collapseToClosed(animation: dropdownFoldAnimation, duration: dropdownFoldDuration)
    }

    private func collapseToClosed(animation: Animation = notchCloseAnimation, duration: TimeInterval = notchCloseDuration) {
        let wasExpanded = notchState != .closed
        closeAnimation = animation
        closeDuration = duration
        withAnimation(animation) {
            notchSize = CGSize(width: closedPresentationWidth, height: closedNotchSize.height)
            notchState = .closed
            if wasExpanded { isSettlingClosed = true }
        }
        guard wasExpanded else { return }
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.isSettlingClosed = false
        }
    }

    private func endSettling() {
        settleTask?.cancel()
        isSettlingClosed = false
    }

    /// Briefly expand the notch to show a notification, then return to closed state
    func peek(duration: TimeInterval?, additionalHeight: CGFloat = 60, width: CGFloat = questionNotchWidth) {
        guard notchState != .open else { return }

        peekTask?.cancel()
        endSettling()

        // Expand to a smaller "peek" size
        let peekSize = CGSize(
            width: width,
            height: min(maximumPeekHeight, closedNotchSize.height + additionalHeight)
        )

        withAnimation(animationSpring) {
            notchState = .peeking
            notchSize = peekSize
        }

        if let duration {
            peekTask = Task {
                try? await Task.sleep(for: .seconds(duration))
                guard !Task.isCancelled else { return }

                await MainActor.run { collapseToClosed() }
            }
        }
    }
}
