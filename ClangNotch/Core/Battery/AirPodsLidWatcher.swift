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
/// openings) while one of our AirPods is paired but not connected, and 8 s past the connection
/// the opening causes. Closing is read from the lid byte, and from the disconnection.
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

    private var stopWork: DispatchWorkItem?

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
        if !needsScan {
            // Just connected because the lid opened: keep listening a little for its frames.
            if stopWork == nil {
                let work = DispatchWorkItem { [weak self] in self?.stopWork = nil; self?.stop() }
                stopWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
            }
            return
        }
        stopWork?.cancel()
        stopWork = nil
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

    /// 1 s on, 2 s off. An opening case sends frames fast for several seconds, so a 2 s gap
    /// still catches it (2 s on / 8 s off missed openings, 2026-11-09).
    private func cycle() {
        guard let central, central.state == .poweredOn, !candidates.isEmpty, cycleWork == nil else { return }
        central.scanForPeripherals(withServices: nil, options: nil)
        scanning = true
        let pause = DispatchWorkItem { [weak self] in
            guard let self, self.scanning else { return }
            central.stopScan()
            self.scanning = false
            let resume = DispatchWorkItem { [weak self] in self?.cycleWork = nil; self?.cycle() }
            self.cycleWork = resume
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.pauseSeconds, execute: resume)
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
        let anyInEar = b[7] & 0x02 != 0
        let flags = b[9] >> 4
        let thisOut = flags & 0x2 == 0, otherOut = flags & 0x1 == 0
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
        // The lid bit tells the lid only while both buds sit in the case. With a bud out it comes
        // set though the lid is open: the card for one bud folded and the second bud dropped a new
        // one, while bluetoothd had the lid open throughout (2026-11-10). So the last word stands.
        let lidShut = outNow == 0 ? b[10] & 0x08 != 0 : wasShut
        let inEarCount = anyInEar ? outNow : 0
        // The first frame after a silence (app launch, scan resumed while worn) only tells us how
        // they're worn now; only later frames can show a bud going in.
        let wasInEar = silent ? inEarCount : before?.inEar ?? 0
        let moved = !silent && before?.out != outNow
        remember(id, Sighting(address: address, at: now, lidShut: lidShut, inEar: inEarCount, out: outNow))

        let closing = lidShut && !wasShut
        // Like an iPhone: the lid opening, one bud in, the second bud in. Nothing else while worn.
        let opening = !closing && (inEarCount > wasInEar || (inEarCount == 0 && !lidShut && wasShut))
        if opening { opened(id, address, at: now) }
        guard acts(id, for: address) else { return }

        if moved { AirPodsDropdown.shared.keepAlive(address: address) }
        if (inEarCount == 2) != (wasInEar == 2) { reevaluate() }
        if closing {
            AirPodsDropdown.shared.caseClosed(address: address)
            return
        }
        // A bud back in the case, or the last one out of an ear: the card that's up follows,
        // and nothing drops for it.
        let fewer = !silent && inEarCount < wasInEar
        guard opening || fewer else { return }
        // One bud in shows that bud; both, or neither, the pair.
        let side = inEarCount == 1 ? (leftOut ? "L" : "R") : nil
        let level = side == nil ? min(left, right) : side == "L" ? leftTenths : rightTenths
        AirPodsDropdown.shared.caseOpened(address: address, productID: model, level: tenths(level),
                                          caseLevel: tenths(caseTenths), side: side, drops: opening)
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

    /// AirPods Max have no lid but advertise whenever they're out of the Smart Case. The status
    /// byte's low bit turns on as they go on the head, several seconds before they connect
    /// (0x20 → 0x21 → 0x23, measured 2026-11-09), so a 0 → 1 edge drops the card. Byte 11 is
    /// the colour code.
    private func handleHeadphones(_ b: [UInt8], model: UInt16, from id: UUID) {
        // One Max of a model is ours; a second one nearby is told apart only by range, until
        // the Mac has connected to ours.
        guard b.count > 11, let ours = candidates.first(where: { $0.productID == model }) else { return }
        let address = ours.address
        let acting = acts(id, for: address)
        let worn = b[7] & 0x01 != 0
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
        guard putOn else { return }
        let nibbles = [Int(b[8] >> 4), Int(b[8] & 0x0F)].filter { $0 != 0xF }
        AirPodsDropdown.shared.caseOpened(address: address, productID: model,
                                          level: nibbles.max().flatMap(tenths), caseLevel: nil)
    }

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
