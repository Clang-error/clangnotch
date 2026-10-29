import AppKit
import SwiftUI
import Combine

@MainActor
public final class UICoordinator: ObservableObject {
    public static let shared = UICoordinator()

    @Published private(set) var isVisible: Bool = true

    private var notchPanel: NotchPanel?
    private var menuBarController: MenuBarController?

    private init() {
        observeFullScreen()
        observeScreenChanges()
        observeMouse()
    }

    // MARK: - Click pass-through

    private var mouseTimer: Timer?
    private var mouseMonitors: [Any] = []
    private(set) var cursorOverNotch = false

    /// The notch window covers a large transparent area. A window only lets clicks fall
    /// through to apps below when `ignoresMouseEvents == true` (returning nil from
    /// hitTest is NOT enough). So we track the cursor and only capture events while it's
    /// over the interactive notch region.
    private func observeMouse() {
        let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            self?.updateCursorState()
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            self?.updateCursorState()
            return event
        }
        mouseMonitors = [global, local].compactMap { $0 }
        // Fallback for when the cursor rests without generating move events.
        mouseTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateCursorState() }
        }
    }

    /// Re-evaluates click pass-through right away. The 0.2 s poll doesn't fire while a
    /// modal alert runs its own run loop, so callers that open one release the mouse first.
    func refreshClickThrough() {
        updateCursorState()
    }

    private func updateCursorState() {
        guard let panel = notchPanel else { return }
        guard isVisible else { return }
        let f = panel.frame
        let w = panel.notchInteractiveSize.width
        let h = panel.notchInteractiveSize.height
        // Interactive region: top-centered within the panel (screen coords, bottom-left).
        // Extend above the screen top (+20) so a cursor flicked to the very top edge still
        // counts — contains() treats maxY as exclusive and the cursor clamps to screen top.
        let region = CGRect(x: f.midX - w / 2, y: f.maxY - h, width: w, height: h + 20)
        // The 1s visibility poll can lag Mission Control appearing by up to a second, and
        // that's exactly when the cursor is racing to the top. `&&` short-circuits, so the
        // window-list check only runs while the cursor is actually over the notch.
        let mouse = NSEvent.mouseLocation
        let localPoint = CGPoint(x: mouse.x - region.minX, y: max(0.001, f.maxY - mouse.y))
        let insideShape = panel.notchInteractiveShape?.path(in: CGRect(origin: .zero, size: panel.notchInteractiveSize))
            .contains(localPoint) ?? true
        let over = region.contains(mouse) && insideShape && !MissionControlDetector.isActive()

        panel.ignoresMouseEvents = !over
        if over != cursorOverNotch {
            cursorOverNotch = over
            NotificationCenter.default.post(
                name: over ? .notchCursorEntered : .notchCursorExited, object: nil)
        }
    }

    // MARK: - Display changes

    /// Reposition the notch onto the built-in notched display when monitors are
    /// connected/disconnected (otherwise it ends up off-screen or misaligned).
    private func observeScreenChanges() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))  // let the screen list settle
                self?.handleScreenChange()
            }
        }
    }

    private func handleScreenChange() {
        if notchPanel == nil {
            setupNotchPanel()
        } else {
            repositionNotchPanel()
        }
        // Re-assert visibility unless a full-screen app or Mission Control is active.
        if !FullScreenDetector.isFullScreenActive() && !MissionControlDetector.isActive() { show() }
    }

    private func repositionNotchPanel() {
        guard let panel = notchPanel, let screen = NotchDetector.notchScreen else { return }
        let f = screen.frame
        let frame = NSRect(
            x: f.origin.x + (f.width - windowSize.width) / 2,
            y: f.origin.y + f.height - windowSize.height,
            width: windowSize.width,
            height: windowSize.height
        )
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }

    // MARK: - Full-screen detection

    private var fullScreenPollTimer: Timer?
    private var lastFullScreen: Bool?

    /// Poll the active-Space type (cheap CGS call) and hide the notch in full-screen.
    /// Space-change notifications are unreliable on recent macOS, so polling is primary.
    private func observeFullScreen() {
        fullScreenPollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.applyFullScreenVisibility() }
        }
    }

    private func applyFullScreenVisibility() {
        // Mission Control puts its Spaces strip right where the notch lives, so hide there
        // too — otherwise reaching for a Space opens the notch and it eats the clicks.
        let shouldHide = FullScreenDetector.isFullScreenActive() || MissionControlDetector.isActive()
        guard shouldHide != lastFullScreen else { return }  // only act on change
        lastFullScreen = shouldHide
        if shouldHide { hide() } else { show() }
    }

    public func setupUI() {
        // Macs without a notch get the same bar at the top centre of the screen.
        setupNotchPanel()

        // Always setup menu bar as fallback/additional control
        setupMenuBar()
    }

    private func setupNotchPanel() {
        guard let screen = NotchDetector.notchScreen else { return }

        let screenFrame = screen.frame

        // Window is fixed size, positioned at top center
        let windowX = screenFrame.origin.x + (screenFrame.width - windowSize.width) / 2
        let windowY = screenFrame.origin.y + screenFrame.height - windowSize.height

        let frame = NSRect(
            x: windowX,
            y: windowY,
            width: windowSize.width,
            height: windowSize.height
        )

        let panel = NotchPanel(contentRect: frame)
        panel.setContent {
            ClangNotchContentView()
        }

        // Show the panel
        panel.orderFrontRegardless()

        notchPanel = panel
    }

    private func setupMenuBar() {
        menuBarController = MenuBarController()
        menuBarController?.setup()
    }

    /// Update the click-through region: only the visible notch accepts clicks,
    /// the rest of the (large, transparent) window passes through.
    func setInteractiveSize(_ size: CGSize, shape: NotchShape? = nil) {
        notchPanel?.notchInteractiveSize = size
        notchPanel?.notchInteractiveShape = shape
    }

    public func show() {
        isVisible = true
        notchPanel?.alphaValue = 1
        notchPanel?.ignoresMouseEvents = true  // pass-through by default; monitor enables over notch
        updateCursorState()
    }

    public func hide() {
        isVisible = false
        notchPanel?.alphaValue = 0
        notchPanel?.ignoresMouseEvents = true
    }
}

extension Notification.Name {
    static let notchCursorEntered = Notification.Name("notchCursorEntered")
    static let notchCursorExited = Notification.Name("notchCursorExited")
}
