import AppKit
import IOBluetooth
import SwiftUI

extension Notification.Name {
    /// The 에어팟 드롭다운 was clicked: open the notch on the Battery tab.
    static let notchOpenBattery = Notification.Name("notchOpenBattery")
}

/// 에어팟 드롭다운: when AirPods connect, a blob stretches down out of the notch and snaps
/// off into a rounded card with the name and battery levels. It lives in its own panel, like
/// the 조절창, so the closed notch's wings can change width under it without redrawing it.
@MainActor
final class AirPodsDropdown: ObservableObject {
    static let shared = AirPodsDropdown()

    struct Card: Equatable {
        let address: String
        let productID: UInt16
        let name: String
        /// Lower of the two buds, or the headphones' single level.
        let level: Int?
        let caseLevel: Int?
        /// AirPods Max colour code, from its advertisement.
        var color: UInt8? = nil
        /// "L" or "R" when only that bud is in an ear: the card shows just that bud and its level.
        var side: String? = nil
        /// A headset that isn't AirPods: drawn with this SF Symbol, since there's no render of it.
        var symbol: String? = nil
    }

    enum Phase: Equatable { case hidden, dropping(Date), settled, rising }

    @Published private(set) var card: Card?
    @Published private(set) var phase: Phase = .hidden
    /// Name, renders and levels fade in just before the blob settles.
    @Published private(set) var contentVisible = false

    static let cardSize = CGSize(width: 340, height: 192)
    /// Room around the card while it drops, for its overshoot.
    static let margin: CGFloat = 24
    static let gapBelowMenuBar: CGFloat = 10
    static let dropDuration: TimeInterval = 0.9
    static let riseDuration: TimeInterval = 0.65
    private static let visibleDuration: TimeInterval = 6

    /// Set by the notch view. The card skips while the notch is open and leaves when it opens;
    /// a dropdown coming down only pushes it lower (`peekDepth`).
    var notchState: NotchState = .closed {
        didSet { if notchState == .open { dismiss() } }
    }

    /// How far a dropdown (완료, 질문, 권한 …) reaches down from the top of the screen, 0 when
    /// none is down. The card sits under it, and goes back up when it folds.
    var peekDepth: CGFloat = 0 {
        didSet {
            guard peekDepth != oldValue, phase == .settled, let panel, let screen = NotchDetector.notchScreen else { return }
            layOut(on: screen)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.4
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 1.1, 0.4, 1)
                panel.animator().setFrame(cardFrame(on: screen), display: true)
            }
        }
    }

    private var panel: NSPanel?
    private var container: AirPodsDropdownContainer?
    /// Where the notch ends and how far the card's top sits below the top of the screen.
    private var menuBar: CGFloat = 32
    private var cardTop: CGFloat = 42
    private var waitTask: Task<Void, Never>?
    private var hideWork: DispatchWorkItem?
    private var hideDeadline: Date?
    private var hovering = false
    private var generation = 0
    /// When a case opening last dropped a card, by address.
    private var openedByCase: [String: Date] = [:]
    /// AirPods Max colour codes seen in advertisements, by address.
    var knownColors: [String: UInt8] = [:]

    private init() {}

    // MARK: - Trigger

    /// A Bluetooth device connected after launch (BatteryManager filters out the ones already
    /// connected then). AirPods report their levels a few seconds late, so wait for
    /// BatteryManager's next reading and go with whatever it has after a few seconds.
    func deviceConnected(address: String, productID: UInt16) {
        let settings = AppSettings.shared
        guard settings.enableAirPodsDropdown, settings.enableBattery, !DemoMode.isActive,
              AirPodsArt.kind(for: productID) != nil else { return }
        // The advertisement just showed it (case opened, bud put in); the connection follows.
        if let opened = openedByCase[address], Date().timeIntervalSince(opened) < 5 { return }
        // Missed by the scan: drop it now with the levels last known, and fill in fresh ones below.
        _ = AirPodsArt.device(for: productID, color: knownColors[address])
        _ = AirPodsArt.chargingCase
        show(Self.card(address: address, productID: productID,
                       device: BatteryManager.shared.devices.first { $0.id == address }))
        waitTask?.cancel()
        waitTask = Task { @MainActor in
            var device: BatteryDevice?
            for _ in 0..<12 {
                try? await Task.sleep(for: .milliseconds(500))
                if Task.isCancelled { return }
                device = BatteryManager.shared.devices.first { $0.id == address && $0.live }
                if device != nil { break }
            }
            // Fresh levels for the card that's up; nothing new to drop.
            guard let device, card?.address == address else { return }
            show(Self.card(address: address, productID: productID, device: device))
        }
    }

    /// Another Bluetooth headset connected (B&W Px8 …): the same card with a headphones symbol and
    /// the one level macOS has for it, under its address from IOBluetooth or under its name from
    /// the accessory list. That level often comes a few seconds after the connection.
    func headsetConnected(address: String, name: String) {
        let settings = AppSettings.shared
        guard settings.enableAirPodsDropdown, settings.enableBattery, !DemoMode.isActive else { return }
        func reading() -> BatteryDevice? {
            let devices = BatteryManager.shared.devices
            return devices.first { $0.id == address } ?? devices.first { $0.id.hasPrefix("acc:") && $0.name == name }
        }
        func card(_ level: Int?) -> Card {
            Card(address: address, productID: 0, name: name, level: level, caseLevel: nil, symbol: "headphones")
        }
        show(card(reading()?.percent))
        waitTask?.cancel()
        waitTask = Task { @MainActor in
            for _ in 0..<12 {
                try? await Task.sleep(for: .milliseconds(500))
                if Task.isCancelled { return }
                if let device = reading(), device.live {
                    if self.card?.address == address { self.show(card(device.percent)) }
                    return
                }
            }
        }
    }

    /// `AirPodsLidWatcher` saw our case open. Levels come from BatteryManager when it has them,
    /// else from the advertisement's tenths.
    func caseOpened(address: String, productID: UInt16, level: Int?, caseLevel: Int?, side: String? = nil) {
        openedByCase[address] = Date()
        _ = AirPodsArt.device(for: productID, color: knownColors[address])
        _ = AirPodsArt.chargingCase
        let device = BatteryManager.shared.devices.first { $0.id == address }
        let known = Self.card(address: address, productID: productID, device: device)
        let sideLevel = side.flatMap { s in device?.parts.first { $0.label == s }?.percent }
        show(Card(address: address, productID: productID, name: known.name,
                  level: side != nil ? (sideLevel ?? level) : (device == nil ? level : known.level),
                  caseLevel: device == nil ? caseLevel : known.caseLevel ?? caseLevel, side: side))
    }

    /// `--demo --demo-scene airpods`: a made-up card, no real device behind it.
    func demoShow(max: Bool) {
        show(Card(address: "demo", productID: max ? 0x202D : 0x2024, name: max ? "AirPods Max" : "AirPods Pro",
                  level: max ? 80 : 100, caseLevel: max ? nil : 40, color: max ? 0x12 : nil))
    }

    /// Something is happening with the AirPods on the card (a bud leaving the case): start its
    /// time over, so taking the buds out and putting them in stays one card.
    func keepAlive(address: String) {
        guard card?.address == address, phase == .settled, !hovering else { return }
        scheduleHide(after: Self.visibleDuration)
    }

    /// Our case closed: fold its card at once.
    func caseClosed(address: String) {
        guard card?.address == address else { return }
        dismiss()
    }

    private static func card(address: String, productID: UInt16, device: BatteryDevice?) -> Card {
        let parts: [BatteryPart] = device?.parts ?? []
        let sides: [Int] = parts.filter { $0.label == "L" || $0.label == "R" }.map(\.percent)
        let fallbackName = AirPodsArt.kind(for: productID) == .headphones ? "AirPods Max" : "AirPods"
        return Card(address: address, productID: productID,
                    name: device?.name ?? fallbackName,
                    level: sides.min() ?? device?.percent,
                    caseLevel: parts.first { $0.label == "케이스" }?.percent)
    }

    // MARK: - Showing

    private func show(_ new: Card) {
        var new = new
        if new.color == nil { new.color = knownColors[new.address] }
        guard notchState != .open, let screen = NotchDetector.notchScreen else { return }
        // Reconnected right after a drop-out: refresh the card that's up.
        // The same AirPods again (other bud in, fresh levels): update the card and give it
        // its full time again.
        if card?.address == new.address, phase == .settled || isDropping {
            card = new
            if phase == .settled, !hovering { scheduleHide(after: Self.visibleDuration) }
            return
        }
        generation += 1
        let current = generation
        hideWork?.cancel()
        hovering = false
        card = new
        contentVisible = false
        layOut(on: screen)
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.ignoresMouseEvents = true
        panel.setFrame(fullFrame(on: screen), display: false)
        phase = .dropping(Date())
        container?.drop(geometry, color: fillColor)
        panel.orderFrontRegardless()

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.dropDuration * 0.82) { [weak self] in
            guard let self, self.generation == current else { return }
            self.contentVisible = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.dropDuration) { [weak self] in
            guard let self, self.generation == current else { return }
            self.settle(on: screen)
        }
    }

    private var isDropping: Bool { if case .dropping = phase { true } else { false } }

    private func settle(on screen: NSScreen) {
        guard let panel else { return }
        // Only the card itself takes clicks from here on; the panel shrinks to it.
        phase = .settled
        panel.setFrame(cardFrame(on: screen), display: false)
        container?.settle()
        panel.ignoresMouseEvents = false
        scheduleHide(after: Self.visibleDuration)
    }

    func dismiss() {
        guard phase == .settled || isDropping, let panel, let screen = NotchDetector.notchScreen else { return }
        hideWork?.cancel()
        generation += 1
        let current = generation
        var from = 1.0
        if case .dropping(let start) = phase { from = min(Date().timeIntervalSince(start) / Self.dropDuration, 1) }
        contentVisible = false
        phase = .rising
        panel.ignoresMouseEvents = true
        panel.setFrame(fullFrame(on: screen), display: false)
        container?.rise(geometry, from: from)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.riseDuration * from) { [weak self] in
            guard let self, self.generation == current else { return }
            panel.orderOut(nil)
            self.phase = .hidden
            self.card = nil
        }
    }

    func openBatteryTab() {
        dismiss()
        NotificationCenter.default.post(name: .notchOpenBattery, object: nil)
    }

    /// The countdown stops while the cursor is on the card and goes on from where it was.
    func setHovering(_ inside: Bool) {
        guard phase == .settled, inside != hovering else { return }
        hovering = inside
        if inside {
            hideWork?.cancel()
        } else {
            let left = hideDeadline.map { $0.timeIntervalSinceNow } ?? Self.visibleDuration
            scheduleHide(after: max(left, 1.5))
        }
    }

    private func scheduleHide(after seconds: TimeInterval) {
        hideWork?.cancel()
        hovering = false
        hideDeadline = Date().addingTimeInterval(seconds)
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    // MARK: - Geometry

    private func layOut(on screen: NSScreen) {
        menuBar = max(screen.safeAreaInsets.top, screen.frame.maxY - screen.visibleFrame.maxY)
        cardTop = max(menuBar, peekDepth) + Self.gapBelowMenuBar
        if screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea?.width,
           let right = screen.auxiliaryTopRightArea?.width {
            notchWidth = screen.frame.width - left - right
        } else {
            notchWidth = 0
        }
    }

    private var notchWidth: CGFloat = 0

    private var geometry: AirPodsBlobGeometry {
        AirPodsBlobGeometry(size: CGSize(width: Self.cardSize.width + Self.margin * 2,
                                         height: cardTop + Self.cardSize.height + Self.margin),
                            menuBar: menuBar, cardTop: cardTop, card: Self.cardSize, notchWidth: notchWidth)
    }

    private var fillColor: CGColor {
        let theme = NotchAppearance.shared.theme(AppSettings.shared)
        return theme.surface.map { NSColor($0).cgColor } ?? NSColor.black.cgColor
    }

    /// From the top of the screen to just under the card: the blob grows out of the notch.
    private func fullFrame(on screen: NSScreen) -> NSRect {
        let width = Self.cardSize.width + Self.margin * 2
        let height = cardTop + Self.cardSize.height + Self.margin
        return NSRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - height, width: width, height: height)
    }

    /// Exactly the card: anything larger would sit over the menu bar and eat its clicks.
    private func cardFrame(on screen: NSScreen) -> NSRect {
        let size = Self.cardSize
        return NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - cardTop - size.height,
                      width: size.width, height: size.height)
    }

    private func makePanel() -> NSPanel {
        let panel = AirPodsDropdownPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                         backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Under the notch (mainMenu + 3), so the blob's root hides behind it.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        let container = AirPodsDropdownContainer(model: self)
        self.container = container
        panel.contentView = container
        return panel
    }
}

private final class AirPodsDropdownPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
