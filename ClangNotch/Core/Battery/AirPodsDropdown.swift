import AppKit
import Combine
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
    /// AirPods, headsets and this Mac.
    static let shared = AirPodsDropdown(isMedia: false)
    /// The 미디어 드롭다운, a card of its own (user, 2026-11-12): a pinned player no longer keeps
    /// the AirPods and battery cards from coming down.
    static let media = AirPodsDropdown(isMedia: true)

    let isMedia: Bool
    /// The other one of the two cards, for stacking under it.
    private var other: AirPodsDropdown { isMedia ? .shared : .media }

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
        /// Dropped by the connection alone (`deviceConnected`), drawn as the pair from the Mac's
        /// levels: no frame has said yet how it is worn.
        var awaitsFrame = false

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
    /// 설정 -> 기능 -> 배터리 알림 -> 날개에만: the card that's up is drawn in the closed notch's
    /// wings (`ClosedAirPodsWings`) instead of coming down in the panel. `card` and `phase` go on
    /// as for a card that came down (settled at once, no blob), so fresh levels, a bud taken out,
    /// the lid closing and 자동으로 접기 reach the wings the same way; only the panel stays away.
    /// With 자동으로 접기 off the wings stay until the lid closes, as the card does (user, 2026-11-19).
    @Published private(set) var inWings = false

    /// Connection, case and low battery cards go to the wings when 날개에만 is chosen (the low
    /// battery one too since the same day, user). This Mac's card still comes down.
    private func drawsInWings(_ card: Card) -> Bool {
        !isMedia && AppSettings.shared.airPodsDropdownWings && card.media == nil && !card.isThisMac
    }

    /// The notch's media wings hide while the 미디어 드롭다운 is out, and spring back once it has
    /// gone all the way back into the notch: coming back as it started to rise, they showed
    /// beside the blob still going up (user's recording, 2026-11-12).
    private func tellMediaCard() {
        guard isMedia else { return }
        NowPlayingMonitor.shared.setCardIsDown(phase != .hidden && card?.media != nil)
    }

    /// Where the other card's bottom edge is while it is down under the notch (not pinned away),
    /// so this one comes down under it; 0 when it isn't there.
    var stackDepth: CGFloat = 0 {
        didSet {
            guard stackDepth != oldValue, phase == .settled, !inWings, !pinned, let panel, let screen = NotchDetector.notchScreen else { return }
            layOut(on: screen)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.4
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 1.1, 0.4, 1)
                panel.animator().setFrame(cardFrame(on: screen), display: true)
            }
        }
    }

    /// This card's bottom edge from the top of the screen while it is down in its place.
    private var occupiedDepth: CGFloat {
        if inWings { return 0 }
        switch phase {
        case .dropping, .settled: return pinned ? 0 : cardTop + cardSize.height
        case .hidden, .rising: return 0
        }
    }
    /// Name, renders and levels fade in just before the blob settles.
    @Published private(set) var contentVisible = false

    static let cardSize = CGSize(width: 340, height: 192)
    static let mediaCardSize = CGSize(width: 340, height: 168)
    /// Room right of a settled media card for its close orb (`MediaCloseOrb`): pushing the card
    /// up to put it away wasn't something first-time users found (2026-11-18).
    static let closeOrbSpace: CGFloat = 34
    private var orbSpace: CGFloat { card?.media != nil ? Self.closeOrbSpace : 0 }
    private var cardSize: CGSize {
        card?.media != nil ? CGSize(width: Self.mediaCardSize.width, height: Self.mediaCardSize.height + volumeExtra) : Self.cardSize
    }
    /// The card's size now, for its content.
    var currentCardSize: CGSize { cardSize }
    /// The volume row's height while it shows in the media card (`MediaVolumeBand`), 0 otherwise.
    /// Kept through the fold, so the blob rises from the card as it was.
    @Published private var volumeExtra: CGFloat = 0
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
            || AirPodsLidWatcher.shared.wornWithLidShut($0.address) } ?? false || foldsSoon
    }

    /// Both buds in the ears (`AirPodsLidWatcher`): no bud is left in the case to tell its lid,
    /// so the card folds 2 s after the second bud went in, whatever 자동으로 접기 says, with no
    /// setting of its own (user, 2026-11-12).
    private var bothWorn: String?
    private var foldsSoon: Bool { card != nil && card?.address == bothWorn }
    private static let bothWornDuration: TimeInterval = 2

    func setBothWorn(_ worn: Bool, address: String) {
        if worn { bothWorn = address } else if bothWorn == address { bothWorn = nil }
        if worn { keepAlive(address: address) }
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
        if foldsSoon { return Self.bothWornDuration }
        return foldsAnyway ? Self.headphonesDuration : Self.visibleDuration
    }

    /// Set by the notch view. The card skips while the notch is open and leaves when it opens;
    /// a dropdown coming down only pushes it lower (`peekDepth`).
    var notchState: NotchState = .closed {
        didSet { if notchState == .open, !pinned { dismiss() } }
    }

    /// The 미디어 드롭다운's 핀: pinned, it doesn't fold and can be dragged anywhere on screen;
    /// unpinned, it glides back under the notch and folds after its usual time. A device's card
    /// waits meanwhile (2026-11-12, a first version; `shared` and `media` each have a panel).
    @Published private(set) var pinned = false
    private var dragStart: (mouse: NSPoint, origin: NSPoint)?

    func togglePin() {
        guard card?.media != nil, phase == .settled, let panel, let screen = NotchDetector.notchScreen else { return }
        pinned.toggle()
        if pinned {
            hideWork?.cancel()
            hideDeadline = nil
            // Its place under the notch is free for the other card.
            if other.stackDepth > 0 { other.stackDepth = 0 }
            return
        }
        // Back to its place, under the other card if that one is down there now.
        stackDepth = other.occupiedDepth
        layOut(on: screen)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.45
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 1.1, 0.4, 1)
            panel.animator().setFrame(cardFrame(on: screen), display: true)
        }
        if !hovering { scheduleHide(after: visibleTime) }
    }

    /// A bar inside the media card (the timeline, the volume row) is being dragged. Those drags
    /// start at once and the card's own at 3 pt, so the card sees this first and stays put: its
    /// drag runs alongside the bars', and a pinned card followed the bar's drag (user, 2026-11-18).
    static var barDragging = false

    /// Dragging a pinned card: it follows the pointer, wherever it goes.
    func drag(ended: Bool) {
        guard pinned, let panel, !Self.barDragging || ended else { return }
        if ended { dragStart = nil; return }
        let mouse = NSEvent.mouseLocation
        let start = dragStart ?? (mouse, panel.frame.origin)
        dragStart = start
        panel.setFrameOrigin(NSPoint(x: start.origin.x + mouse.x - start.mouse.x,
                                     y: start.origin.y + mouse.y - start.mouse.y))
    }

    /// How far a dropdown (완료, 질문, 권한 …) reaches down from the top of the screen, 0 when
    /// none is down. The card sits under it, and goes back up when it folds.
    var peekDepth: CGFloat = 0 {
        didSet {
            guard peekDepth != oldValue, phase == .settled, !inWings, !pinned, let panel, let screen = NotchDetector.notchScreen else { return }
            layOut(on: screen)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.4
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 1.1, 0.4, 1)
                panel.animator().setFrame(cardFrame(on: screen), display: true)
            }
            // The card stacked under this one moves with it.
            if other.stackDepth > 0 { other.stackDepth = occupiedDepth }
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
    /// The cursor is on the card (or its close orb): the countdown waits, and the orb shows.
    @Published private(set) var hovering = false
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

    private init(isMedia: Bool) {
        self.isMedia = isMedia
        guard isMedia else { return }
        // The publisher's value is the new one; the band's own property still holds the old one
        // here. Read off the band, the card was laid out for the row before it had one, and the
        // row came only with the next key (2026-11-18), so the card takes the value from here.
        volumeWatch = MediaVolumeBand.shared.$reading.dropFirst()
            .sink { [weak self] reading in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let came = (reading != nil) != (self.volumeReading != nil)
                    self.volumeReading = reading
                    if came { self.volumeRowChanged(reading != nil) }
                }
            }
    }

    private var volumeWatch: AnyCancellable?
    /// What the media card's volume row shows (`MediaVolumeBand`), nil while it doesn't.
    @Published private(set) var volumeReading: SystemControlReading?

    /// The volume row came or went while the card is down: the card grows down to hold it (its top
    /// stays), and waits to fold while it shows. The panel itself is never animated: AppKit lays a
    /// growing window's content out from its bottom edge on each step, and the card shook by a few
    /// points both times (user's recordings, 2026-11-18). It takes its size at once, growing before
    /// the card's shape stretches down to it and shrinking after the shape has come back up.
    private func volumeRowChanged(_ shown: Bool) {
        // Coming down: the size is taken when it settles.
        if isDropping { volumeExtra = shown ? MediaVolumeBand.rowHeight : 0 }
        guard phase == .settled, let panel, let screen = NotchDetector.notchScreen else { return }
        if shown {
            hideWork?.cancel()
        } else if !hovering {
            let left = hideDeadline.map { $0.timeIntervalSinceNow } ?? visibleTime
            scheduleHide(after: max(left, 1.5))
        }
        volumeResizes += 1
        let resize = volumeResizes
        let extra = MediaVolumeBand.rowHeight
        func frame() -> NSRect {
            var frame = cardFrame(on: screen)
            // Dragged somewhere: from where it is, top edge fixed.
            if pinned { frame.origin = NSPoint(x: panel.frame.minX, y: panel.frame.maxY - frame.height) }
            return frame
        }
        if shown {
            guard volumeExtra == 0 else { return }
            volumeExtra = extra
            panel.setFrame(frame(), display: false)
            container?.growSettled(by: extra)
        } else {
            guard volumeExtra > 0 else { return }
            container?.shrinkSettled(by: extra) { [weak self] in
                guard let self, self.volumeResizes == resize, self.phase == .settled else { return }
                self.volumeExtra = 0
                panel.setFrame(frame(), display: false)
            }
        }
    }

    /// Bumped by each volume row change, so a shrink that finishes after the row came back does nothing.
    private var volumeResizes = 0

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
        frameSaid = nil
        func card(_ device: BatteryDevice?) -> Card {
            var card = Self.card(address: address, productID: productID, device: device)
            card.awaitsFrame = true
            return card
        }
        show(card(BatteryManager.shared.devices.first { $0.id == address }))
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
            // What a frame said meanwhile (which bud is worn, what charges) stays, drawn again
            // with the fresh levels.
            if let said = frameSaid, said.address == address { said.again() } else { refresh(card(device)) }
        }
    }

    /// The card that is up for these AirPods came from the connection alone and no frame has
    /// spoken for it: `AirPodsLidWatcher` hands the pair's next frame over, whatever it says.
    func awaitsFrame(address: String) -> Bool {
        card?.address == address && card?.awaitsFrame == true && (phase == .settled || isDropping)
    }

    /// The last frame handed over since a connection dropped a card, for drawing it again when
    /// the Mac's fresh levels come.
    private var frameSaid: (address: String, again: () -> Void)?

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
        if drops {
            openedByCase[address] = Date()
            // The scan stops while both are worn, so their going back into the case can go
            // unseen: a fresh opening starts with the buds in the case.
            if bothWorn == address { bothWorn = nil }
        }
        frameSaid = (address, { [weak self] in
            self?.caseOpened(address: address, productID: productID, level: level, caseLevel: caseLevel, side: side,
                             sides: sides, charging: charging, drops: false)
        })
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

    /// A scripted demo scene folds its cards itself (`demoFold`), whatever this Mac's fold times
    /// are set to, so a recording comes out the same everywhere.
    var demoKeeps = false

    /// `--demo --demo-scene airpodslid`: the left bud leaves the open case. The card that is up
    /// splits into that bud and the one still charging, as `caseOpened(…, drops: false)` does.
    func demoTakeBudOut() {
        guard var card, card.address == "demo" else { return }
        card.leftCharging = false
        show(card)
    }

    /// The lid shut, or the script is done with the card.
    func demoFold() { dismiss() }

    /// `--demo --demo-scene media`: the 미디어 드롭다운 for a made-up track (`showMedia` is for
    /// the real thing and stays off in a demo).
    func demoShowMedia(_ playing: NowPlaying) {
        show(Card(address: "media", productID: 0, name: playing.title, level: nil, caseLevel: nil, media: playing))
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

    /// Nothing is left to play (the app quit, the tab closed, gone quiet for good). A pinned card
    /// stays and waits: the last track, stopped where it was, until something plays again and
    /// takes its place (user, 2026-11-12). It kept the track running on before.
    func mediaGone() {
        guard var media = card?.media, phase == .settled || isDropping else { return }
        media.elapsed = media.position(at: Date())
        media.elapsedAt = Date()
        media.isPlaying = false
        media.rate = 0
        card?.media = media
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
        guard notchState != .open || pinned, let screen = NotchDetector.notchScreen else { return }
        // Reconnected right after a drop-out: refresh the card that's up.
        // The same AirPods again (other bud in, fresh levels): update the card and give it
        // its full time again.
        if card?.address == new.address, phase == .settled || isDropping {
            card = new
            if phase == .settled, !hovering { scheduleHide(after: visibleTime) }
            return
        }
        if drawsInWings(new) {
            generation += 1
            hideWork?.cancel()
            hovering = false
            // A card that was down in the panel (this Mac's) gives way at once.
            if !inWings { panel?.orderOut(nil) }
            card = new
            inWings = true
            contentVisible = true
            phase = .settled
            if other.stackDepth > 0 { other.stackDepth = 0 }
            scheduleHide(after: visibleTime)
            return
        }
        inWings = false
        generation += 1
        let current = generation
        hideWork?.cancel()
        hovering = false
        if isMedia {
            // From the start of the drop: a key pressed while it comes down shows in the card too.
            MediaVolumeBand.shared.cardIsDown = true
            volumeExtra = MediaVolumeBand.shared.reading != nil ? MediaVolumeBand.rowHeight : 0
        }
        card = new
        contentVisible = false
        // The other card is already down there: come down under it.
        stackDepth = other.occupiedDepth
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
        container?.settledContentHeight = isMediaCard ? Self.mediaCardSize.height + MediaVolumeBand.rowHeight : 0
        container?.settle()
        panel.ignoresMouseEvents = false
        scheduleHide(after: visibleTime)
        if volumeExtra > 0 { hideWork?.cancel() }
    }

    func dismiss() {
        if inWings {
            // Nothing to fold: the wings let go of it and animate themselves.
            guard phase == .settled else { return }
            hideWork?.cancel()
            generation += 1
            contentVisible = false
            phase = .hidden
            card = nil
            inWings = false
            return
        }
        guard phase == .settled || isDropping, let panel, let screen = NotchDetector.notchScreen else { return }
        if pinned { pinned = false; dragStart = nil }
        hideWork?.cancel()
        generation += 1
        let current = generation
        var from = 1.0
        if case .dropping(let start) = phase { from = min(Date().timeIntervalSince(start) / Self.dropDuration, 1) }
        contentVisible = false
        phase = .rising
        if isMedia {
            MediaVolumeBand.shared.cardIsDown = false
            // A bar dragged as the card went may never end its drag.
            Self.barDragging = false
        }
        panel.ignoresMouseEvents = true
        panel.setFrame(fullFrame(on: screen), display: false)
        container?.rise(geometry, from: from)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.riseDuration * from) { [weak self] in
            guard let self, self.generation == current else { return }
            panel.orderOut(nil)
            self.phase = .hidden
            self.volumeExtra = 0
            self.card = nil
            self.stackDepth = 0
            // A card that came down under this one moves up into its place.
            if self.other.stackDepth > 0 { self.other.stackDepth = 0 }
        }
    }

    func openBatteryTab() {
        // A pinned card stays where it is; the app just comes forward.
        if let media = card?.media {
            if pinned { NowPlayingMonitor.openApp(of: media) } else { openMediaApp(media) }
            return
        }
        dismiss()
        NotificationCenter.default.post(name: .notchOpenBattery, object: nil)
    }

    /// The countdown stops while the cursor is on the card and goes on from where it was.
    func setHovering(_ inside: Bool) {
        guard phase == .settled, inside != hovering else { return }
        hovering = inside
        if isMediaCard { MediaVolumeBand.shared.hover(inside) }
        if inside {
            hideWork?.cancel()
        } else if volumeExtra == 0 {
            let left = hideDeadline.map { $0.timeIntervalSinceNow } ?? visibleTime
            scheduleHide(after: max(left, 1.5))
        }
    }

    private func scheduleHide(after seconds: TimeInterval) {
        guard !pinned, !demoKeeps else { return }
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
        cardTop = max(menuBar, peekDepth, stackDepth) + Self.gapBelowMenuBar
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

    /// Exactly the card (and a media card's close orb beside it, all under the menu bar):
    /// anything reaching up would sit over the menu bar and eat its clicks.
    private func cardFrame(on screen: NSScreen) -> NSRect {
        let size = cardSize
        return NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - cardTop - size.height,
                      width: size.width + orbSpace, height: size.height)
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
