import SwiftUI

/// The volume row the 미디어 드롭다운 grows while it is down (user, 2026-11-18): a volume key, the
/// mute key or the AirPods Max crown shows here instead of in the 조절창, which came up over the
/// card and hid it. The row hangs under the controls, the card grows by `rowHeight` to hold it,
/// and it goes after `visibleTime` without a press. Its bar can be dragged too. Brightness keys
/// still go to the 조절창.
@MainActor
final class MediaVolumeBand: ObservableObject {
    static let shared = MediaVolumeBand()

    /// The row and the gap above it.
    static let rowHeight: CGFloat = 26
    private static let visibleTime: TimeInterval = 2

    /// Set by the media card (`AirPodsDropdown.media`, settled) and the attached dropdown (the
    /// notch view): one of them is down and can take the row.
    var cardIsDown = false { didSet { if !cardIsDown, !attachedIsDown { hideNow() } } }
    var attachedIsDown = false { didSet { if !cardIsDown, !attachedIsDown { hideNow() } } }

    /// What the row shows; nil while it is hidden.
    @Published private(set) var reading: SystemControlReading?
    /// Bumped when a key is pressed again at an end of the range, to bounce that icon (as the 조절창).
    @Published private(set) var minBounce = 0
    @Published private(set) var maxBounce = 0
    @Published private(set) var dragging = false

    private var hideWork: DispatchWorkItem?
    private var pollTimer: Timer?

    private init() {}

    /// From the 조절창 (`SystemControlOSD.show`): true when the row shows `reading` instead.
    /// `polls`: the crown's banner gives one event for a whole turn, so the value is followed.
    func take(_ reading: SystemControlReading, polls: Bool) -> Bool {
        guard reading.kind != .brightness, cardIsDown || attachedIsDown else { return false }
        show(reading)
        pollTimer?.invalidate()
        pollTimer = nil
        if polls {
            pollTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
                MainActor.assumeIsolated {
                    let band = MediaVolumeBand.shared
                    guard !band.dragging, let new = SystemControlOSD.currentVolumeReading(), new != band.reading else { return }
                    band.show(new)
                }
            }
        }
        return true
    }

    /// The bar dragged to `fraction` (0...1).
    func drag(to fraction: Double) {
        dragging = true
        hideWork?.cancel()
        if let new = SystemControlOSD.shared.setVolume(min(max(fraction, 0), 1)) { show(new, scheduling: false) }
    }

    func endDrag() {
        dragging = false
        scheduleHide()
    }

    private func show(_ new: SystemControlReading, scheduling: Bool = true) {
        if let previous = reading, previous.kind != .brightness {
            if new.fraction <= 0, previous.fraction <= 0, !dragging { minBounce += 1 }
            if new.fraction >= 1, previous.fraction >= 1, !dragging { maxBounce += 1 }
        }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { reading = new }
        if scheduling { scheduleHide() }
    }

    private func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem { MainActor.assumeIsolated { MediaVolumeBand.shared.hideNow() } }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.visibleTime, execute: work)
    }

    private func hideNow() {
        hideWork?.cancel()
        hideWork = nil
        pollTimer?.invalidate()
        pollTimer = nil
        dragging = false
        guard reading != nil else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { reading = nil }
    }
}
