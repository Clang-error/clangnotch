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
        /// Each bud's own level, and which of the buds and the case are charging. Known only from
        /// the case's advertisement; a card from the connection alone shows no charging.
        var leftLevel: Int? = nil
        var rightLevel: Int? = nil
        var leftCharging = false
        var rightCharging = false
        var caseCharging = false
        /// This Mac (`AirPodsArt.thisMac`) instead of a headset.
        var isThisMac = false
        /// The 미디어 드롭다운: what started playing, instead of a device.
        var media: NowPlaying? = nil

        /// A low battery card: buds 10 points or more apart split too, so it shows which one is low.
        var splitsOnLevels = false

        /// One bud charging in the case and the other out: the card shows each bud with its own
        /// battery instead of the pair.
        var splitsBuds: Bool {
            guard let left = leftLevel, let right = rightLevel else { return false }
            return leftCharging != rightCharging || (splitsOnLevels && abs(left - right) >= 10)
        }
    }

    enum Phase: Equatable { case hidden, dropping(Date), settled, rising }

    @Published private(set) var card: Card? { didSet { tellMediaCard() } }
    @Published private(set) var phase: Phase = .hidden { didSet { tellMediaCard() } }

    /// The notch's media wings hide while the 미디어 드롭다운 is out, and spring back once it has
    /// gone all the way back into the notch: coming back as it started to rise, they showed
    /// beside the blob still going up (user's recording, 2026-11-12).
    private func tellMediaCard() {
        NowPlayingMonitor.shared.setCardIsDown(phase != .hidden && card?.media != nil)
    }
    /// Name, renders and levels fade in just before the blob settles.
    @Published private(set) var contentVisible = false

    static let cardSize = CGSize(width: 340, height: 192)
    static let mediaCardSize = CGSize(width: 340, height: 168)
    private var cardSize: CGSize { card?.media != nil ? Self.mediaCardSize : Self.cardSize }
    /// Room around the card while it drops, for its overshoot.
    static let margin: CGFloat = 24
    static let gapBelowMenuBar: CGFloat = 10
    static let dropDuration: TimeInterval = 0.9
    static let riseDuration: TimeInterval = 0.65
    /// 설정 › 노치 › 드롭다운 머무는 시간, counted from when the card has settled.
    private static var visibleDuration: TimeInterval { TimeInterval(AppSettings.shared.foldSecondsAirPods) }
    /// Headphones (a Max, another headset) fold after this even with 자동으로 접기 off: they're on
    /// the head by then (user, 2026-11-10). Other cards then stay until closed.
    private static var headphonesDuration: TimeInterval { TimeInterval(AppSettings.shared.foldSecondsHeadphones) }
    private static var macDuration: TimeInterval { TimeInterval(AppSettings.shared.foldSecondsMac) }

    /// Buds put in the ears with the lid shut fold the same way: no lid will close on their card
    /// (user, 2026-11-12: with 자동으로 접기 off it stayed up for good).
    private var foldsAnyway: Bool {
        card.map { $0.symbol != nil || AirPodsArt.kind(for: $0.productID) == .headphones
            || AirPodsLidWatcher.shared.wornWithLidShut($0.address) } ?? false
    }

    /// This Mac's low battery card has its own switch (맥 배터리 부족 시 드롭다운 › 자동으로 접기):
    /// 10 s, or until closed.
    private var isMacCard: Bool { card?.isThisMac ?? false }

    /// The 미디어 드롭다운 always folds, whatever 자동으로 접기 says: it isn't about a device.
    private var isMediaCard: Bool { card?.media != nil }
    private static var mediaDuration: TimeInterval { TimeInterval(AppSettings.shared.foldSecondsMedia) }

    private var visibleTime: TimeInterval {
        if isMediaCard { return Self.mediaDuration }
        if isMacCard { return Self.macDuration }
        return foldsAnyway ? Self.headphonesDuration : Self.visibleDuration
    }

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
    /// AirPods Max colour codes seen in advertisements, by address. Kept across launches: a worn
    /// Max stops the scan, so after a relaunch its low battery card came in the default
    /// Starlight until it was taken off and put on again (2026-11-12).
    var knownColors: [String: UInt8] = (UserDefaults.standard.dictionary(forKey: AirPodsDropdown.colorsKey)
        as? [String: Int] ?? [:]).mapValues { UInt8(truncatingIfNeeded: $0) } {
        didSet {
            guard knownColors != oldValue else { return }
            UserDefaults.standard.set(knownColors.mapValues { Int($0) }, forKey: Self.colorsKey)
        }
    }
    private static let colorsKey = "airPodsKnownColors"

    private init() {}

    // MARK: - Trigger

    /// A Bluetooth device connected after launch (BatteryManager filters out the ones already
    /// connected then). AirPods report their levels a few seconds late, so wait for
    /// BatteryManager's next reading and go with whatever it has after a few seconds.
    func deviceConnected(address: String, productID: UInt16) {
        let settings = AppSettings.shared
        guard settings.enableAirPodsDropdown, settings.enableBattery, !DemoMode.isActive,
              AirPodsArt.kind(for: productID) != nil else { return }
        // A Max drops its card as it goes on the head (`AirPodsLidWatcher`), seconds before it
        // connects. Off the head it reconnects by itself every few minutes (bluetoothd: out of
        // ear, 2026-11-10), and each of those dropped a card that 자동으로 접기 off kept up.
        if AirPodsArt.kind(for: productID) == .headphones { return }
        // The advertisement just showed it (case opened, bud put in); the connection follows.
        if let opened = openedByCase[address], Date().timeIntervalSince(opened) < 5 { return }
        // The lid shut on the buds while the connection it started was still being made.
        if AirPodsLidWatcher.shared.caseShut(address) { return }
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
            guard let device else { return }
            refresh(Self.card(address: address, productID: productID, device: device))
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
                    self.refresh(card(device.percent))
                    return
                }
            }
        }
    }

    /// Running low (`BatteryManager`): the same card, for AirPods, a Max or another headset.
    func lowBattery(_ device: BatteryDevice) {
        guard AppSettings.shared.enableBattery, !DemoMode.isActive else { return }
        let productID = IOBluetoothDevice(addressString: device.id)
            .map { unsafeBitCast($0, to: BTBatteryDevice.self).productID } ?? 0
        guard AirPodsArt.kind(for: productID) != nil else {
            show(Card(address: device.id, productID: 0, name: device.name, level: device.displayLevel,
                      caseLevel: nil, symbol: "headphones"))
            return
        }
        _ = AirPodsArt.device(for: productID, color: knownColors[device.id])
        var card = Self.card(address: device.id, productID: productID, device: device)
        card.leftLevel = device.parts.first { $0.label == "L" }?.percent
        card.rightLevel = device.parts.first { $0.label == "R" }?.percent
        // Only one bud connected: that bud alone, as when it alone is in an ear.
        if (card.leftLevel == nil) != (card.rightLevel == nil) { card.side = card.leftLevel != nil ? "L" : "R" }
        // A bud charging in the case (the other one is the low one) keeps its bolt.
        if let charging = AirPodsLidWatcher.shared.charging(device.id) {
            card.leftCharging = charging.left
            card.rightCharging = charging.right
        }
        card.splitsOnLevels = true
        show(card)
    }

    /// `AirPodsLidWatcher` saw our case open. Levels come from BatteryManager when it has them,
    /// else from the advertisement's tenths. `drops` false is a bud leaving an ear: only a card
    /// that is up changes, to show who is still in.
    func caseOpened(address: String, productID: UInt16, level: Int?, caseLevel: Int?, side: String? = nil,
                    sides: (left: Int?, right: Int?)? = nil,
                    charging: (left: Bool, right: Bool, case: Bool)? = nil, drops: Bool = true) {
        if drops { openedByCase[address] = Date() }
        _ = AirPodsArt.device(for: productID, color: knownColors[address])
        _ = AirPodsArt.chargingCase
        let device = BatteryManager.shared.devices.first { $0.id == address }
        let known = Self.card(address: address, productID: productID, device: device)
        let sideLevel = side.flatMap { s in device?.parts.first { $0.label == s }?.percent }
        var new = Card(address: address, productID: productID, name: known.name,
                       level: side != nil ? (sideLevel ?? level) : (device == nil ? level : known.level),
                       caseLevel: device == nil ? caseLevel : known.caseLevel ?? caseLevel, side: side)
        // BatteryManager's levels are finer than the advertisement's tenths where it has them.
        new.leftLevel = device?.parts.first { $0.label == "L" }?.percent ?? sides?.left
        new.rightLevel = device?.parts.first { $0.label == "R" }?.percent ?? sides?.right
        if let charging {
            new.leftCharging = charging.left
            new.rightCharging = charging.right
            new.caseCharging = charging.case
        }
        if drops { show(new) } else { refresh(new) }
    }

    /// This Mac fell to 20% or 10% (`BatteryManager`). Its marketing name takes a
    /// system_profiler run the first time, so that happens off the main thread.
    func macLowBattery(level: Int) {
        guard AppSettings.shared.enableBattery, !DemoMode.isActive else { return }
        Task.detached(priority: .userInitiated) {
            let name = AirPodsArt.thisMacName
            await MainActor.run {
                var card = Card(address: "mac", productID: 0, name: name, level: level, caseLevel: nil)
                card.isThisMac = true
                AirPodsDropdown.shared.show(card)
            }
        }
    }

    /// `--demo --demo-scene macbattery`: this Mac running low, drawn as this Mac's model.
    func demoShowMacLow(level: Int) {
        var card = Card(address: "demo-mac", productID: 0, name: AirPodsArt.thisMacName, level: level, caseLevel: nil)
        card.isThisMac = true
        show(card)
    }

    /// `--demo --demo-scene airpodslow`: made-up low battery cards, as `lowBattery` builds them.
    func demoShowLow(max: Bool) {
        var card = Card(address: "demo-low", productID: max ? 0x202D : 0x2024, name: max ? "AirPods Max" : "AirPods Pro",
                        level: max ? 18 : 15, caseLevel: max ? nil : 62, color: max ? 0x12 : nil)
        if !max { card.leftLevel = 15; card.rightLevel = 71 }
        card.splitsOnLevels = true
        show(card)
    }

    /// `--demo --demo-scene airpods`: a made-up card, no real device behind it.
    func demoShow(max: Bool) {
        var card = Card(address: "demo", productID: max ? 0x202D : 0x2024, name: max ? "AirPods Max" : "AirPods Pro",
                        level: max ? 80 : 100, caseLevel: max ? nil : 40, color: max ? 0x12 : nil)
        if !max {   // just opened: both buds charging in the case
            card.leftLevel = 100; card.rightLevel = 100
            card.leftCharging = true; card.rightCharging = true
        }
        show(card)
    }

    /// Something started playing (`NowPlayingMonitor`). It never pushes out a device's card;
    /// a device's card (connected, running low) does push it out. Returns whether it is shown.
    @discardableResult
    func showMedia(_ playing: NowPlaying) -> Bool {
        guard !DemoMode.isActive, notchState != .open else { return false }
        if phase != .hidden, card?.media == nil { return false }
        show(Card(address: "media", productID: 0, name: playing.title, level: nil, caseLevel: nil, media: playing))
        return true
    }

    /// A media card could drop now: the notch is closed and no device's card, nor a media card
    /// already (that one changes in place), is up.
    var canDropMedia: Bool { !DemoMode.isActive && notchState != .open && phase == .hidden }

    /// What plays changed while its card is up (artwork, paused, the next track from its
    /// buttons): the card follows. Its time doesn't start over.
    func refreshMedia(_ playing: NowPlaying) {
        guard card?.media != nil, phase == .settled || isDropping else { return }
        card?.media = playing
    }

    /// The 미디어 드롭다운 was clicked: bring the app that plays to the front.
    private func openMediaApp(_ playing: NowPlaying) {
        dismiss()
        NowPlayingMonitor.openApp(of: playing)
    }

    /// Something is happening with the AirPods on the card (a bud leaving the case): start its
    /// time over, so taking the buds out and putting them in stays one card.
    func keepAlive(address: String) {
        guard card?.address == address, phase == .settled, !hovering else { return }
        scheduleHide(after: visibleTime)
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
            if phase == .settled, !hovering { scheduleHide(after: visibleTime) }
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
        // Same Space trap as the 조절창 (`SystemControlOSD.show`).
        NotchOverlaySpace.pin(panel)

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.dropDuration * 0.82) { [weak self] in
            guard let self, self.generation == current else { return }
            self.contentVisible = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.dropDuration) { [weak self] in
            guard let self, self.generation == current else { return }
            self.settle(on: screen)
        }
    }

    /// Fresh levels for the card that's up; nothing new to drop. A card being folded stays
    /// folded: `show` would bring it down again (lid shut just as the levels came in).
    private func refresh(_ new: Card) {
        guard card?.address == new.address, phase == .settled || isDropping else { return }
        show(new)
    }

    private var isDropping: Bool { if case .dropping = phase { true } else { false } }

    private func settle(on screen: NSScreen) {
        guard let panel else { return }
        // Only the card itself takes clicks from here on; the panel shrinks to it.
        phase = .settled
        panel.setFrame(cardFrame(on: screen), display: false)
        container?.settle()
        panel.ignoresMouseEvents = false
        scheduleHide(after: visibleTime)
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
        if let media = card?.media { openMediaApp(media); return }
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
            let left = hideDeadline.map { $0.timeIntervalSinceNow } ?? visibleTime
            scheduleHide(after: max(left, 1.5))
        }
    }

    private func scheduleHide(after seconds: TimeInterval) {
        hideWork?.cancel()
        hovering = false
        hideDeadline = Date().addingTimeInterval(seconds)
        // 설정 › 기능 › 에어팟 연결 알림 자동으로 접기, read when the time is up so switching it
        // off keeps a card that is already down. The demo scene and headphones always fold.
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let settings = AppSettings.shared
            let folds = self.isMediaCard || (self.isMacCard ? settings.macLowBatteryAutoHide
                : settings.airPodsDropdownAutoHide || self.foldsAnyway)
            guard folds || DemoMode.isActive else { return }
            self.dismiss()
        }
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
            hasHousing = true
        } else {
            // No camera housing: the width of the notch ClangNotch draws there, and the drop
            // hangs from the screen's top edge (2026-11-10, external display).
            notchWidth = getClosedNotchSize(screen: screen).width
            hasHousing = false
        }
    }

    private var notchWidth: CGFloat = 0
    private var hasHousing = true

    private var geometry: AirPodsBlobGeometry {
        AirPodsBlobGeometry(size: CGSize(width: cardSize.width + Self.margin * 2,
                                         height: cardTop + cardSize.height + Self.margin),
                            menuBar: menuBar, cardTop: cardTop, card: cardSize, notchWidth: notchWidth,
                            hasHousing: hasHousing)
    }

    private var fillColor: CGColor {
        let theme = NotchAppearance.shared.theme(AppSettings.shared)
        return theme.surface.map { NSColor($0).cgColor } ?? NSColor.black.cgColor
    }

    /// From the top of the screen to just under the card: the blob grows out of the notch.
    private func fullFrame(on screen: NSScreen) -> NSRect {
        let width = cardSize.width + Self.margin * 2
        let height = cardTop + cardSize.height + Self.margin
        return NSRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - height, width: width, height: height)
    }

    /// Exactly the card: anything larger would sit over the menu bar and eat its clicks.
    private func cardFrame(on screen: NSScreen) -> NSRect {
        let size = cardSize
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
