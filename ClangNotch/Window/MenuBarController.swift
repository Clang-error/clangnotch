import AppKit
import SwiftUI
import Combine

@MainActor
final class MenuBarController: NSObject {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var eventMonitor: Any?
    private var cancellables = Set<AnyCancellable>()
    private var settingsCancellable: AnyCancellable?
    private var animationTimer: Timer?
    private var animationKey: String?
    private var animationFrames: [NSImage] = []
    private var animationIndex = 0
    private var frameCache: [String: [NSImage]] = [:]

    // Working-state palettes; each flows left to right while that agent runs.
    private static let claudeColors = [NSColor(srgbRed: 1.0, green: 0.62, blue: 0.18, alpha: 1), NSColor(srgbRed: 1.0, green: 0.31, blue: 0.48, alpha: 1)]
    private static let codexColors = [NSColor(srgbRed: 0.18, green: 0.49, blue: 1.0, alpha: 1), NSColor(srgbRed: 0.15, green: 0.83, blue: 0.90, alpha: 1)]
    private static let bothColors: [NSColor] = [.systemOrange, .systemBlue]
    // Idle is the same notch in a mid grey: a thin outline vanished next to the white
    // template icons around it. Colour alone separates idle from the flowing states.
    private static let idleGray = NSColor(white: 0.75, alpha: 1)
    private static let frameCount = 20
    private static let frameInterval: TimeInterval = 0.1

    func setup() {
        updateMenuBarVisibility()
        settingsCancellable = AppSettings.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateMenuBarVisibility()
            }

        // Force the menu bar icon visible while the keyboard is locked, even if the
        // user normally keeps it hidden — it's the fallback toggle when the notch
        // itself isn't reachable (e.g. behind a full-screen app).
        TetherPlaceMonitor.shared.$activePlaceName
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateIconForCurrentState() }
            .store(in: &cancellables)

        KeyboardLockManager.shared.$isLocked
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateMenuBarVisibility()
                self?.updateIconForCurrentState()
            }
            .store(in: &cancellables)

        // The icon follows what the agents are doing, not whether the OTLP server is up.
        // objectWillChange fires before the mutation, so settle briefly before reading.
        Publishers.MergeMany(
            ClaudeCodeManager.shared.objectWillChange.eraseToAnyPublisher(),
            CodexManager.shared.objectWillChange.eraseToAnyPublisher()
        )
        .debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)
        .sink { [weak self] _ in
            self?.updateIconForCurrentState()
        }
        .store(in: &cancellables)
    }

    private func updateMenuBarVisibility() {
        // Stays visible whenever the Keyboard Lock feature is enabled at all (not just
        // while actively locked) — otherwise the icon flickers in/out on every
        // lock/unlock, which reads as broken rather than as a safety fallback.
        let shouldShow = AppSettings.shared.showMenuBarItem
            || AppSettings.shared.enableKeyboardLock
            || KeyboardLockManager.shared.isLocked
        if shouldShow {
            if statusItem == nil {
                setupStatusItemAndPopover()
                updateIconForCurrentState()
            }
        } else if let statusItem {
            closePopover()
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
                self.eventMonitor = nil
            }
            popover = nil
        }
    }

    private func setupStatusItemAndPopover() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem?.button {
            button.image = Self.notchGlyph(colors: [Self.idleGray])
            button.action = #selector(togglePopover)
            button.target = self
        }

        let popover = NSPopover()
        popover.contentSize = NSSize(width: 300, height: 400)
        popover.behavior = .transient
        popover.animates = true
        // The usage cards are shared with the notch and drawn for a dark surface.
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.contentViewController = NSHostingController(rootView: AgentMenuBarContentView())
        self.popover = popover

        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePopover()
        }
    }

    private func updateIconForCurrentState() {
        updateIcon(for: MenuBarActivity.current)
    }

    private func updateIcon(for activity: MenuBarActivity) {
        guard let button = statusItem?.button else { return }

        // Keyboard-locked takes priority — you want to see this at a glance without
        // opening the dropdown.
        if KeyboardLockManager.shared.isLocked {
            var lockConfig = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
            lockConfig = lockConfig.applying(.init(paletteColors: [.systemGreen]))
            button.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Keyboard Locked")?
                .withSymbolConfiguration(lockConfig)
            button.contentTintColor = nil
            return
        }

        // Tethering at a saved place stays red until it ends — easy to miss otherwise.
        if TetherPlaceMonitor.shared.activePlaceName != nil {
            stopAnimation()
            button.contentTintColor = nil
            button.image = Self.notchGlyph(colors: [.systemRed])
            return
        }

        // A grey notch means idle. While an agent works it takes on a gradient
        // that flows across it — orange→pink for Claude, blue→cyan for Codex, orange↔blue
        // when both run — and it turns solid red when one is waiting on you. Colours are
        // baked in: this status button ignores template masking and contentTintColor.
        button.contentTintColor = nil
        switch activity {
        case .idle:
            stopAnimation()
            button.image = Self.notchGlyph(colors: [Self.idleGray])
        case .working(let claude, let codex, _):
            let key: String
            let colors: [NSColor]
            if claude && codex { key = "both"; colors = Self.bothColors }
            else if claude { key = "claude"; colors = Self.claudeColors }
            else if codex { key = "codex"; colors = Self.codexColors }
            else { key = "other"; colors = [.systemGreen] }
            startAnimation(key: key, colors: colors)
        case .needsPermission, .awaitingAnswer:
            stopAnimation()
            button.image = Self.notchGlyph(colors: [.systemRed])
        }
    }

    /// Frames are rendered once per palette and only swapped afterwards, so a tick costs one
    /// image assignment. 10 fps reads as a smooth drift at 18 pt. Deliberately not paused by
    /// battery saver: the user wants the motion to stay.
    private func startAnimation(key: String, colors: [NSColor]) {
        if animationKey == key, animationTimer != nil { return }
        stopAnimation()
        if frameCache[key] == nil {
            frameCache[key] = (0..<Self.frameCount).map { frame in
                Self.notchGlyph(colors: colors, phase: CGFloat(frame) / CGFloat(Self.frameCount))
            }
        }
        animationKey = key
        animationFrames = frameCache[key] ?? []
        animationIndex = 0
        statusItem?.button?.image = animationFrames.first
        guard animationFrames.count > 1 else { return }
        let timer = Timer(timeInterval: Self.frameInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                // stopAnimation() can empty the frames between the timer firing and this
                // task running; `% 0` here trapped the whole UI on 2026-09-22.
                guard let self, let button = self.statusItem?.button, !self.animationFrames.isEmpty else { return }
                self.animationIndex = (self.animationIndex + 1) % self.animationFrames.count
                button.image = self.animationFrames[self.animationIndex]
            }
        }
        // .common keeps it moving while menus and the popover are tracking events.
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    private func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
        animationKey = nil
        animationFrames = []
    }

    /// The app's own silhouette: a strip of menu bar with the notch hanging from it,
    /// rasterised at 1x and 2x. Two colours fill as a left-to-right gradient that repeats;
    /// `phase` (0..<1) slides it one full period so consecutive frames loop seamlessly.
    private static func notchGlyph(colors: [NSColor], phase: CGFloat = 0) -> NSImage {
        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side))
        for scale in [1.0, 2.0] as [CGFloat] {
            let pixels = Int(side * scale)
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let context = NSGraphicsContext(bitmapImageRep: rep) else { continue }
            rep.size = image.size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            // Path coordinates below are y-down; the bitmap context is y-up.
            context.cgContext.translateBy(x: 0, y: CGFloat(pixels))
            context.cgContext.scaleBy(x: scale, y: -scale)
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 1.5, y: 5))
            path.line(to: NSPoint(x: 16.5, y: 5))
            path.line(to: NSPoint(x: 16.5, y: 7.5))
            path.line(to: NSPoint(x: 13, y: 7.5))
            path.appendArc(from: NSPoint(x: 13, y: 13), to: NSPoint(x: 5, y: 13), radius: 3)
            path.appendArc(from: NSPoint(x: 5, y: 13), to: NSPoint(x: 5, y: 7.5), radius: 3)
            path.line(to: NSPoint(x: 5, y: 7.5))
            path.line(to: NSPoint(x: 1.5, y: 7.5))
            path.close()
            colors[0].set()
            if colors.count > 1,
               let gradient = NSGradient(colorsAndLocations: (colors[0], 0), (colors[1], 0.25), (colors[0], 0.5),
                                         (colors[1], 0.75), (colors[0], 1)) {
                // Two periods across 4× the glyph width, starting one period to the left so the
                // visible window never leaves it; increasing phase slides the pattern rightward.
                path.addClip()
                let bounds = path.bounds
                let period = bounds.width * 2
                gradient.draw(in: NSRect(x: bounds.minX - period + phase * period, y: bounds.minY,
                                         width: period * 2, height: bounds.height), angle: 0)
            } else {
                path.fill()
            }
            NSGraphicsContext.restoreGraphicsState()
            image.addRepresentation(rep)
        }
        image.accessibilityDescription = "ClangNotch"
        return image
    }

    @objc private func togglePopover() {
        guard let popover = popover, let button = statusItem?.button else { return }

        if popover.isShown {
            closePopover()
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func closePopover() {
        popover?.performClose(nil)
    }

    deinit {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
