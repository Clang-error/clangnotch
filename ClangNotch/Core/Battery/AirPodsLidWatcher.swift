import CoreBluetooth
import IOBluetooth

/// Drops the 에어팟 드롭다운 the moment an AirPods case opens, as an iPhone does, and folds it
/// when the case closes. A case broadcasts a BLE "proximity" advertisement (Apple type 0x07)
/// while it is open; its plain part carries the model, battery tenths and a lid byte.
///
/// Whose case it is can't be proven: the encrypted half needs a key the Mac doesn't keep (none
/// of the MobileBluetooth keychain keys decrypt it, measured 2026-11-09). So an advertisement
/// counts as ours by fingerprint: the model of one of our paired, not-connected AirPods, its
/// left/right/case tenths matching what BatteryManager last saw for it, and close range.
/// Other people's AirPods pass that too, so each peripheral keeps its own lid and ear state, and
/// once the Mac has connected to a pair right after a peripheral showed an opening, only that
/// peripheral counts as the pair (`owners`).
///
/// Scanning runs 1 s in every 3 (nonstop measured about 4.5% of a core; 2 s in 10 missed
/// openings) while one of our AirPods is paired but not connected or not fully worn, and 1 s
/// in 10 once every pair is connected and fully worn. Closing is read from the lid byte, and from the disconnection.
@MainActor
final class AirPodsLidWatcher: NSObject, CBCentralManagerDelegate {
    static let shared = AirPodsLidWatcher()

    private override init() {
        super.init()
        // A pair proven before this launch is taken to be around until an hour shows otherwise.
        heard = owners.mapValues { _ in Date() }
        // 설정 › 기능 › 에어팟 연결 알림 (or 배터리 잔량) switched: start or stop scanning now,
        // not at the next Bluetooth change.
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let settings = AppSettings.shared
                let enabled = settings.enableAirPodsDropdown && settings.enableBattery
                guard enabled != AirPodsLidWatcher.shared.lastEnabled else { return }
                AirPodsLidWatcher.shared.lastEnabled = enabled
                AirPodsLidWatcher.shared.reevaluate()
                if !enabled { AirPodsDropdown.shared.dismiss() }
            }
        }
    }
    private var lastEnabled = true

    private struct Paired { let address: String; let productID: UInt16 }

    private var central: CBCentralManager?
    private var candidates: [Paired] = []
    private var scanning = false
    private var cycleWork: DispatchWorkItem?
    private static let scanSeconds: TimeInterval = 1
    private static let pauseSeconds: TimeInterval = 2
    /// Advertisements arrive here and only AirPods frames in range go on to the main thread.
    private let queue = DispatchQueue(label: "AirPodsLidWatcher", qos: .utility)

    /// What one peripheral last said. Kept per peripheral, not per pair: where many people carry
    /// AirPods, another pair of our model passes the fingerprint, and its frames mixed into ours
    /// turned a lid we had just shut back into an open one, dropping the card again (2026-11-10:
    /// 40 other pairs heard in half an hour, several nearer than `nearRSSI`).
    private struct Sighting {
        let address: String
        var at: Date
        var lidShut = false
        /// Buds in an ear; 1 for a Max on a head.
        var inEar: Int
        /// Buds out of the case.
        var out = 0
        /// Which buds sit in the case, where they charge.
        var leftIn = false
        var rightIn = false
        /// The last frame that said the lid is open.
        var openSeenAt: Date?
    }
    private var sightings: [UUID: Sighting] = [:]

    /// The peripheral proven to be each pair, by address. Our AirPods come under the identifier
    /// the Mac keeps for the paired device (the Pro's proof is the one bluetoothd logs with its
    /// serial numbers, 2026-11-10). A stranger's identifier changes with its address.
    private var owners: [String: UUID] = (UserDefaults.standard.dictionary(forKey: AirPodsLidWatcher.ownersKey)
        as? [String: String] ?? [:]).compactMapValues(UUID.init)
    private static let ownersKey = "airPodsPeripheralIDs"
    /// When each proven pair last gave a sign of being here: a frame from its peripheral, or
    /// the Mac losing it after a spell of not listening.
    private var heard: [String: Date] = [:]
    /// When a peripheral last showed an opening (lid open, bud in, Max on), and when the Mac last
    /// connected to each pair. An opening with the connection right behind it proves the peripheral.
    private var openings: [UUID: (address: String, at: Date)] = [:]
    private var connections: [String: Date] = [:]
    /// Max last known off the head, for a frame from a peripheral with no sighting of its own.
    private var takenOff: Set<String> = []

    /// Ours read -51…-78 at the desk, often -67…-75 for the first frames after opening; another
    /// Pro 2 in the room read -92…-104 (2026-11-09).
    private static let nearRSSI = -82

    /// Every pair connected and fully worn: nothing to drop for, so the scan only checks in.
    private var slow = false
    private static let slowPauseSeconds: TimeInterval = 9

    /// Called once IOBluetooth is up, and on every connect / disconnect.
    func reevaluate() {
        let settings = AppSettings.shared
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []).compactMap { device -> Paired? in
            guard let address = device.addressString else { return nil }
            let productID = unsafeBitCast(device, to: BTBatteryDevice.self).productID
            return AirPodsArt.kind(for: productID) != nil ? Paired(address: address, productID: productID) : nil
        }
        let enabled = settings.enableAirPodsDropdown && settings.enableBattery && !DemoMode.isActive
        candidates = enabled ? paired : []
        // Keep listening until every one of our AirPods is connected and fully worn: both buds in
        // (the second bud and a case reopened while still connected show up only here), or the Max on.
        // Only a proven peripheral's word counts: a stranger's worn pair would stop the scan for ours.
        let connected = Set((IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? [])
            .filter { $0.isConnected() }.compactMap(\.addressString))
        let needsScan = enabled && paired.contains { p in
            guard connected.contains(p.address) else { return true }
            guard AirPodsArt.kind(for: p.productID) == .headphones else { return said(p.address)?.inEar != 2 }
            // A Max coming off folds its card, and only the scan sees that. It matters while the
            // card stays up (자동으로 접기 off); otherwise the card is long gone by then.
            return said(p.address)?.inEar != 1 || !settings.airPodsDropdownAutoHide
        }
        if candidates.isEmpty {
            stop()
            return
        }
        // Fully worn the scan used to stop, and a bud going back into the case went unseen: the
        // pair stayed "both worn", nothing scanned, and the next opening dropped no card
        // (2026-11-12). It goes on at 1 s in 10 instead.
        let wasSlow = slow
        slow = !needsScan
        if wasSlow, !slow, !scanning {
            cycleWork?.cancel()
            cycleWork = nil
        }
        if central == nil {
            central = CBCentralManager(delegate: self, queue: queue)
        } else {
            cycle()
        }
    }

    private func stop() {
        cycleWork?.cancel()
        cycleWork = nil
        if scanning { central?.stopScan() }
        scanning = false
    }

    /// While a case of ours stands open (up to a minute from its opening), the scan runs nonstop,
    /// so the lid shutting folds the card within a frame instead of the next 1 s window.
    private var listensNonstop: Bool {
        if Self.traceAll { return true }
        guard let at = lastOpening, Date().timeIntervalSince(at) < 60 else { return false }
        return sightings.values.contains { !$0.lidShut && Date().timeIntervalSince($0.at) < 4 }
    }
    private var lastOpening: Date?

    /// 1 s on, 2 s off. An opening case sends frames fast for several seconds, so a 2 s gap
    /// still catches it (2 s on / 8 s off missed openings, 2026-11-09).
    private func cycle() {
        guard let central, central.state == .poweredOn, !candidates.isEmpty, cycleWork == nil else { return }
        // Without duplicates a scan reports our pair once (both buds share one peripheral), so
        // a nonstop scan has to allow them.
        let nonstop = listensNonstop
        central.scanForPeripherals(withServices: nil,
                                   options: nonstop ? [CBCentralManagerScanOptionAllowDuplicatesKey: true] : nil)
        scanning = true
        let pause = DispatchWorkItem { [weak self] in
            guard let self, self.scanning else { return }
            if self.listensNonstop {
                self.cycleWork = nil
                self.cycle()
                return
            }
            central.stopScan()
            self.scanning = false
            let resume = DispatchWorkItem { [weak self] in self?.cycleWork = nil; self?.cycle() }
            self.cycleWork = resume
            DispatchQueue.main.asyncAfter(deadline: .now() + (self.slow ? Self.slowPauseSeconds : Self.pauseSeconds),
                                          execute: resume)
        }
        cycleWork = pause
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.scanSeconds, execute: pause)
    }

    // MARK: - CBCentralManagerDelegate

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let on = central.state == .poweredOn
        DispatchQueue.main.async { MainActor.assumeIsolated { on ? self.cycle() : self.stop() } }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi: NSNumber) {
        guard let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
              data.count >= 11, data[0] == 0x4C, data[1] == 0x00, data[2] == 0x07,
              rssi.intValue >= Self.nearRSSI, rssi.intValue < 0 else { return }
        let bytes = [UInt8](data)
        let id = peripheral.identifier
        DispatchQueue.main.async { MainActor.assumeIsolated { self.handle(bytes, from: id) } }
    }

    // MARK: - Matching

    private func handle(_ b: [UInt8], from id: UUID) {
        let model = UInt16(b[5]) | UInt16(b[6]) << 8
        if AirPodsArt.kind(for: model) == .headphones {
            handleHeadphones(b, model: model, from: id)
            return
        }
        let left = Int(b[8] >> 4), right = Int(b[8] & 0x0F), caseTenths = Int(b[9] & 0x0F)
        // The proven peripheral needs no fingerprint: its levels may have moved since
        // BatteryManager last read them (used with the iPhone for an afternoon). Anyone else
        // passes by fingerprint, for a pair still unproven before one that has its peripheral.
        let fits: (Paired) -> Bool = { $0.productID == model && self.matches($0.address, left, right, caseTenths) }
        guard let ours = candidates.first(where: { $0.productID == model && owners[$0.address] == id })
                ?? candidates.first(where: { proven($0.address) == nil && fits($0) })
                ?? candidates.first(where: fits)
        else { return }

        // Lid byte bit 3 is set while the lid is shut (32/33 open → 3B/3C shut → 34 open, measured
        // 2026-11-09). Status bit 1 is set while a bud is in an ear (51 → 53). Both buds advertise
        // in turn with their own counters, but these bits agree.
        let address = ours.address
        // Each bud says whether it (0x02) and the other bud (0x08) are in an ear. Frames with 0x20
        // clear come from the left bud, whose level is the high battery nibble (right bud in
        // alone showed as left with the opposite reading, 2026-11-09).
        let leftSpeaking = b[7] & 0x20 == 0
        // Status 0x02 means some bud is in an ear (both buds set it with one in: 53 and 33). Which
        // buds are out of the case comes from the charging flags in the case byte's high nibble,
        // from the sender's side: 0x2 it is charging, 0x1 the other is (B = both in the case,
        // 9 / A = one out; 2026-11-09). A bud out of the case while some bud is in counts as in.
        // With a bud out and the lid shut, the case is out of the buds' reach: the case level
        // nibble reads 0xF and the charging flags say nothing (8F). The lid bit stays clear then,
        // so this is how a lid shut on a bud in an ear shows (traced 2026-11-12: 98 / A8 with the
        // lid open, 8F once shut, with one bud or both in the ears). Each bud's own ear bits are
        // still right then: 0x02 it is in an ear, 0x08 the other is.
        let caseOutOfReach = b[9] & 0x0F == 0x0F
        let anyInEar = b[7] & 0x02 != 0
        let flags = b[9] >> 4
        // A bud speaking while the case is out of reach is out of it; the other is out if it is
        // in an ear, else taken to be in the case.
        let thisOut = caseOutOfReach ? true : flags & 0x2 == 0
        let otherOut = caseOutOfReach ? b[7] & 0x08 != 0 : flags & 0x1 == 0
        let leftOut = leftSpeaking ? thisOut : otherOut
        let rightOut = leftSpeaking ? otherOut : thisOut
        let leftTenths = leftSpeaking ? Int(b[8] >> 4) : Int(b[8] & 0x0F)
        let rightTenths = leftSpeaking ? Int(b[8] & 0x0F) : Int(b[8] >> 4)
        let now = Date()
        let before = sightings[id]
        // A frame after 10 s of silence is a fresh opening even if the closing frames were missed.
        let silent = before.map { now.timeIntervalSince($0.at) > 10 } ?? true
        let wasShut = silent ? true : before?.lidShut ?? true
        let outNow = (leftOut ? 1 : 0) + (rightOut ? 1 : 0)
        // The lid bit (32/33 open, 3A/3B shut). With a bud out, only frames whose lid byte reads
        // 3x/5x carry it: the bud in the case sends 1x, with no lid in it, and keeps sending for a
        // few seconds after the lid shuts. The worn bud's frame turns 31 → 39 as the lid shuts, 4 s
        // before the case drops out of its reach (8F); nonstop trace 2026-11-12, opened, a bud
        // put in and shut 3 s apart. 8F also lingers 1–2 s after an opening (the card dropped,
        // folded and dropped again), so it only means shut 3 s past the last open frame. With
        // both buds out no bud is in the case to reach it: 8F with the lid open (2026-11-12), so
        // the lid stays as last known.
        let carriesLid = outNow == 0 || b[10] & 0x60 != 0
        let openSeenAt = carriesLid && b[10] & 0x08 == 0 ? now : silent ? nil : before?.openSeenAt
        let lidShut: Bool
        if carriesLid {
            lidShut = b[10] & 0x08 != 0
        } else if caseOutOfReach && outNow < 2 {
            lidShut = openSeenAt.map { now.timeIntervalSince($0) >= 3 } ?? true || wasShut
        } else {
            // No word on the lid: as it was, and after a silence taken as shut, so the next frame
            // that carries the lid open counts as an opening.
            lidShut = wasShut
        }
        let inEarCount = caseOutOfReach ? (b[7] & 0x02 != 0 ? 1 : 0) + (b[7] & 0x08 != 0 ? 1 : 0)
            : anyInEar ? outNow : 0
        // The first frame after a silence (app launch, scan resumed while worn) only tells us how
        // they're worn now; only later frames can show a bud going in.
        let wasInEar = silent ? inEarCount : before?.inEar ?? 0
        let moved = !silent && before?.out != outNow
        remember(id, Sighting(address: address, at: now, lidShut: lidShut, inEar: inEarCount, out: outNow,
                              leftIn: !leftOut, rightIn: !rightOut, openSeenAt: openSeenAt))

        trace(b, id: id, leftSpeaking: leftSpeaking, out: outNow, inEar: inEarCount, lidShut: lidShut)
        let closing = lidShut && !wasShut
        // The lid opening (worn or not: shut on a bud in an ear and opened again, the card comes
        // back until the lid shuts, user 2026-11-12), one bud in, the second bud in. After a
        // silence only a frame that carries the lid says it is open: worn, the scan had stopped,
        // and a lid opened minutes later on one bud in an ear dropped nothing (2026-11-12).
        let lidOpened = !lidShut && wasShut && (inEarCount == 0 || !silent || carriesLid)
        let signal = !closing && (inEarCount > wasInEar || lidOpened)
        if signal { opened(id, address, at: now) }
        // The second bud going in drops nothing: the card that's up folds soon (`setBothWorn`).
        let opening = signal && inEarCount < 2
        if closing || opening { traceNote(closing ? "→ fold (lid shut)" : "→ drop") }
        guard acts(id, for: address) else { return }

        if moved { AirPodsDropdown.shared.keepAlive(address: address) }
        let wornChanged = (inEarCount == 2) != (wasInEar == 2)
        // While checking in slowly a frame can come after a silence, which hides the change.
        if wornChanged || (slow && inEarCount < 2) { reevaluate() }
        if wornChanged { AirPodsDropdown.shared.setBothWorn(inEarCount == 2, address: address) }
        if closing {
            AirPodsDropdown.shared.caseClosed(address: address)
            return
        }
        // A bud back in the case, or the last one out of an ear: the card that's up follows,
        // and nothing drops for it.
        let fewer = !silent && inEarCount < wasInEar
        // A bud leaving or going back into the case changes what's charging: the card follows.
        guard opening || fewer || moved else { return }
        // One bud in shows that bud; both, or neither, the pair.
        let side = inEarCount == 1 ? (leftOut ? "L" : "R") : nil
        let level = side == nil ? min(left, right) : side == "L" ? leftTenths : rightTenths
        // A bud in the case is charging (its flag above). The case's own charging is flag 0x4:
        // B7 off the charger, F7 on it (2026-11-11).
        let caseCharging = flags & 0x4 != 0
        AirPodsDropdown.shared.caseOpened(address: address, productID: model, level: tenths(level),
                                          caseLevel: tenths(caseTenths), side: side,
                                          sides: (tenths(leftTenths), tenths(rightTenths)),
                                          charging: (!leftOut, !rightOut, caseCharging), drops: opening)
    }

    // MARK: - Frame trace

    /// `defaults write com.clangerror.ClangNotch airPodsFrameTrace -bool true`: each new frame of
    /// our pair, and how it was read, to ~/Library/Logs/ClangNotch/airpods-frames.log. Only the
    /// installed app hears the advertisements, so this is how a case is studied. Off by default.
    private var lastTraced: [Bool: [UInt8]] = [:]
    /// `airPodsFrameTraceAll` as well: every frame, with the peripheral, and the scan runs
    /// nonstop with duplicates so the log shows how often each bud speaks. For a study only.
    private static var traceAll: Bool { UserDefaults.standard.bool(forKey: "airPodsFrameTraceAll") }

    private func trace(_ b: [UInt8], id: UUID, leftSpeaking: Bool, out: Int, inEar: Int, lidShut: Bool) {
        guard UserDefaults.standard.bool(forKey: "airPodsFrameTrace") else { return }
        // The counter bytes past 11 change every frame; the state is in 7…10.
        let state = Array(b.prefix(11))
        if !Self.traceAll {
            guard lastTraced[leftSpeaking] != state else { return }
        }
        lastTraced[leftSpeaking] = state
        let hex = b.map { String(format: "%02X", $0) }.joined(separator: " ")
        let read = "out=\(out) inEar=\(inEar) lidShut=\(lidShut)"
        let peripheral = Self.traceAll ? "\(id.uuidString.prefix(4)) " : ""
        appendTrace("\(peripheral)\(leftSpeaking ? "L" : "R") b7=\(String(format: "%02X", b[7])) b8=\(String(format: "%02X", b[8])) b9=\(String(format: "%02X", b[9])) b10=\(String(format: "%02X", b[10])) \(read) | \(hex)")
    }

    /// What the card was told, between the frames.
    private func traceNote(_ text: String) {
        guard UserDefaults.standard.bool(forKey: "airPodsFrameTrace") else { return }
        appendTrace(text)
    }

    private func appendTrace(_ text: String) {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/ClangNotch")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("airpods-frames.log")
        let time = Date().formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute().second()
            .secondFraction(.fractional(2)))
        let line = "\(time) \(text)\n"
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: file)
        }
    }

    // MARK: - Whose frames

    private func remember(_ id: UUID, _ sighting: Sighting) {
        if sightings[id] == nil {
            // New peripherals pass by all day; one gone ten minutes has nothing left to say.
            let proven = Set(owners.values)
            sightings = sightings.filter { proven.contains($0.key) || sighting.at.timeIntervalSince($0.value.at) < 600 }
        }
        sightings[id] = sighting
        if owners[sighting.address] == id { heard[sighting.address] = sighting.at }
    }

    /// The pair's proven peripheral, while the pair has given a sign within the hour (a shut case
    /// by the Mac speaks every few minutes). Longer than that and the pair is elsewhere, or the
    /// proof was a stranger's after all and went with its address: the fingerprint decides again.
    private func proven(_ address: String) -> UUID? {
        guard let id = owners[address], let at = heard[address], Date().timeIntervalSince(at) < 3600 else { return nil }
        return id
    }

    /// What a pair's proven peripheral last said. Nobody else's word is taken for the pair itself.
    private func said(_ address: String) -> Sighting? {
        proven(address).flatMap { sightings[$0] }
    }

    /// Before a pair's peripheral is proven the fingerprint decides; after, only that peripheral.
    private func acts(_ id: UUID, for address: String) -> Bool {
        proven(address).map { $0 == id } ?? true
    }

    private func opened(_ id: UUID, _ address: String, at now: Date) {
        openings = openings.filter { now.timeIntervalSince($0.value.at) < 10 }
        openings[id] = (address, now)
        lastOpening = now
        prove(address)
    }

    /// The Mac connected to one of our AirPods, which an opening brings about within seconds.
    func connected(address: String) {
        connections[address] = Date()
        prove(address)
    }

    private func prove(_ address: String) {
        guard let connection = connections[address] else { return }
        // The opening comes first and the connection a few seconds behind (2.5 s measured); the
        // scan can hand the opening over up to 3 s late.
        let near = openings.filter {
            $0.value.address == address && (-10.0...3.0).contains($0.value.at.timeIntervalSince(connection))
        }
        // The one already proven opened too, or gave a sign just now: it stays, and the opening
        // was a stranger's that happened to fall in these seconds.
        if let current = owners[address],
           near[current] != nil || heard[address].map({ Date().timeIntervalSince($0) <= 10 }) == true { return }
        // Two openings in the same seconds: no telling which was ours. A later connection will.
        guard near.count == 1, let id = near.keys.first else { return }
        owners[address] = id
        heard[address] = Date()
        UserDefaults.standard.set(owners.mapValues(\.uuidString), forKey: Self.ownersKey)
    }

    /// Whether the pair just said its lid is shut with both buds inside.
    func caseShut(_ address: String) -> Bool {
        guard let last = said(address), Date().timeIntervalSince(last.at) <= 10 else { return false }
        return last.lidShut && last.out == 0
    }

    /// Buds out of a case last known shut, as when they lay on the desk and went into the ears:
    /// nothing will close the lid on the card, so it folds by itself (`AirPodsDropdown`).
    func wornWithLidShut(_ address: String) -> Bool {
        guard let last = said(address), Date().timeIntervalSince(last.at) <= 30 else { return false }
        return last.lidShut && last.out > 0
    }

    /// What is charging, by the pair's own peripheral's last word: a bud in the case, a Max on
    /// its cable (both sides alike). Bluetooth's battery levels don't tell. nil without a word in
    /// the last 30 s, so silence is never taken for "not charging" or "charging": a worn Max
    /// stops the scan, and its cable going in or out after that goes unheard.
    func charging(_ address: String) -> (left: Bool, right: Bool)? {
        guard let last = said(address), Date().timeIntervalSince(last.at) <= 30 else { return nil }
        if let cable = maxCharging[address] { return (cable, cable) }
        return (last.leftIn, last.rightIn)
    }

    /// The buds disconnected (lid closed on them): the next opening counts again. Only a lid
    /// just seen shut on both buds is kept, so a connection that comes straight back drops nothing.
    func forget(address: String) {
        let now = Date()
        sightings = sightings.filter {
            $0.value.address != address
                || ($0.value.lidShut && $0.value.out == 0 && now.timeIntervalSince($0.value.at) <= 10)
        }
        // The scan was off while they were worn, so the pair went unheard without having left.
        if owners[address] != nil, !scanning, cycleWork == nil { heard[address] = now }
        // Max disconnect once taken off and put down; the next frame is a putting-on.
        if candidates.contains(where: { $0.address == address && AirPodsArt.kind(for: $0.productID) == .headphones }) {
            takenOff.insert(address)
        }
    }

    /// AirPods Max have no lid but advertise whenever they're out of the Smart Case. Status bit
    /// 0x02 is on while they're on the head, as for buds in an ear: 0x20 → 0x23 / 0x2B on, 0x29 /
    /// 0x21 off, 0x20 put down (2026-11-10). The low bit, read as worn before, stays on for
    /// seconds after they come off (0x29), so the card didn't fold and putting them back on in
    /// that time dropped nothing. A 0 → 1 edge of 0x02 drops the card. Byte 11 is the colour code.
    private func handleHeadphones(_ b: [UInt8], model: UInt16, from id: UUID) {
        // One Max of a model is ours; a second one nearby is told apart only by range, until
        // the Mac has connected to ours.
        guard b.count > 11, let ours = candidates.first(where: { $0.productID == model }) else { return }
        let address = ours.address
        let acting = acts(id, for: address)
        let worn = b[7] & 0x02 != 0
        let was = sightings[id].map { $0.inEar == 1 } ?? (acting && takenOff.contains(address) ? false : nil)
        if acting {
            if worn { takenOff.remove(address) } else { takenOff.insert(address) }
        }
        let now = Date()
        remember(id, Sighting(address: address, at: now, inEar: worn ? 1 : 0))
        let putOn = worn && was == false
        if putOn { opened(id, address, at: now) }
        guard acting else { return }

        AirPodsDropdown.shared.knownColors[address] = b[11]
        if was != worn { reevaluate() }
        // Taken off. Out of the Smart Case a Max stays awake and connected, so no disconnection
        // comes to fold the card.
        if was == true, !worn { AirPodsDropdown.shared.caseClosed(address: address) }
        // On the cable the case byte's high nibble drops its 0x8 (8F → 0F, back to 8F unplugged;
        // 2026-11-11). A card that's up follows the cable; plugging in drops nothing by itself.
        let charging = (b[9] >> 4) & 0x8 == 0
        let chargingChanged = maxCharging[address].map { $0 != charging } ?? false
        maxCharging[address] = charging
        guard putOn || chargingChanged else { return }
        let nibbles = [Int(b[8] >> 4), Int(b[8] & 0x0F)].filter { $0 != 0xF }
        let level = nibbles.max().flatMap(tenths)
        AirPodsDropdown.shared.caseOpened(address: address, productID: model, level: level, caseLevel: nil,
                                          sides: (level, level), charging: (charging, charging, false),
                                          drops: putOn)
    }

    private var maxCharging: [String: Bool] = [:]

    /// Plain tenths against BatteryManager's last levels, a tenth either way. 0xF means unknown.
    private func matches(_ address: String, _ left: Int, _ right: Int, _ caseTenths: Int) -> Bool {
        guard let device = BatteryManager.shared.devices.first(where: { $0.id == address }) else { return true }
        let known = Dictionary(device.parts.map { ($0.label, $0.percent) }, uniquingKeysWith: { a, _ in a })
        func close(_ tenthsValue: Int, _ percent: Int?) -> Bool {
            guard tenthsValue != 0xF, let percent else { return true }
            return abs(min(tenthsValue, 10) - min(percent / 10, 10)) <= 1
        }
        // Left and right swap places depending on which bud is primary.
        let sides = (close(left, known["L"]) && close(right, known["R"])) || (close(left, known["R"]) && close(right, known["L"]))
        return sides && close(caseTenths, known["케이스"])
    }

    private func tenths(_ value: Int) -> Int? { value == 0xF ? nil : min(value, 10) * 10 }
}
