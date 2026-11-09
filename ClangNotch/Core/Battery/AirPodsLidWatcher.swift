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
///
/// Scanning runs 1 s in every 3 (nonstop measured about 4.5% of a core; 2 s in 10 missed
/// openings) while one of our AirPods is paired but not connected, and 8 s past the connection
/// the opening causes. Closing is read from the disconnection, not from the advertisement.
@MainActor
final class AirPodsLidWatcher: NSObject, CBCentralManagerDelegate {
    static let shared = AirPodsLidWatcher()

    private override init() {
        super.init()
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
    private var lastSeen: [String: Date] = [:]

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
        let connected = Set((IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? [])
            .filter { $0.isConnected() }.compactMap(\.addressString))
        let needsScan = enabled && paired.contains { p in
            guard connected.contains(p.address) else { return true }
            return AirPodsArt.kind(for: p.productID) == .headphones ? lastWorn[p.address] != true : budInEar[p.address] != 2
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
        let strength = rssi.intValue
        DispatchQueue.main.async { MainActor.assumeIsolated { self.handle(bytes, rssi: strength) } }
    }

    // MARK: - Matching

    private func handle(_ b: [UInt8], rssi: Int) {
        let model = UInt16(b[5]) | UInt16(b[6]) << 8
        if AirPodsArt.kind(for: model) == .headphones {
            handleHeadphones(b, model: model, rssi: rssi)
            return
        }
        let left = Int(b[8] >> 4), right = Int(b[8] & 0x0F), caseTenths = Int(b[9] & 0x0F)
        guard let ours = candidates.first(where: { $0.productID == model && matches($0.address, left, right, caseTenths) })
        else { return }

        // Lid byte bit 3 is set while the lid is shut (32/33 open → 3B/3C shut → 34 open, measured
        // 2026-11-09). Status bit 1 is set while a bud is in an ear (51 → 53). Both buds advertise
        // in turn with their own counters, but these bits agree. A frame after 10 s of silence is a
        // fresh opening even if the closing frames were missed.
        let address = ours.address
        let lidShut = b[10] & 0x08 != 0
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
        let silent = lastSeen[address].map { now.timeIntervalSince($0) > 10 } ?? true
        lastSeen[address] = now
        let wasShut = silent ? true : lidWasShut[address] ?? true
        let inEarCount = anyInEar ? (leftOut ? 1 : 0) + (rightOut ? 1 : 0) : 0
        // The first frame after a silence (app launch, scan resumed while worn) only tells us how
        // they're worn now; only later frames can show a bud going in.
        let wasInEar = silent ? inEarCount : budInEar[address] ?? 0
        let outNow = (leftOut ? 1 : 0) + (rightOut ? 1 : 0)
        if !silent, let before = budsOut[address], before != outNow {
            AirPodsDropdown.shared.keepAlive(address: address)
        }
        budsOut[address] = outNow
        lidWasShut[address] = lidShut
        budInEar[address] = inEarCount
        if (inEarCount == 2) != (wasInEar == 2) { reevaluate() }

        if lidShut, !wasShut {
            AirPodsDropdown.shared.caseClosed(address: address)
            return
        }
        guard rssi >= Self.nearRSSI, rssi < 0 else { return }
        // Like an iPhone: one bud in shows that bud, the second shows both. Nothing else while worn.
        if inEarCount > wasInEar {
            if inEarCount == 1 {
                let isLeft = leftOut
                AirPodsDropdown.shared.caseOpened(address: address, productID: model,
                                                  level: tenths(isLeft ? leftTenths : rightTenths),
                                                  caseLevel: tenths(caseTenths), side: isLeft ? "L" : "R")
            } else {
                AirPodsDropdown.shared.caseOpened(address: address, productID: model,
                                                  level: tenths(min(left, right)), caseLevel: tenths(caseTenths))
            }
            return
        }
        guard inEarCount == 0, !lidShut, wasShut else { return }
        AirPodsDropdown.shared.caseOpened(address: address, productID: model,
                                          level: tenths(min(left, right)), caseLevel: tenths(caseTenths))
    }

    private var lidWasShut: [String: Bool] = [:]
    private var budInEar: [String: Int] = [:]
    private var budsOut: [String: Int] = [:]

    /// The buds disconnected (lid closed on them): the next opening counts again.
    func forget(address: String) {
        lastSeen[address] = nil
        lidWasShut[address] = nil
        budInEar[address] = nil
        budsOut[address] = nil
        // Max disconnect once taken off and put down; the next frame is a putting-on.
        lastWorn[address] = false
    }

    /// AirPods Max have no lid but advertise whenever they're out of the Smart Case. The status
    /// byte's low bit turns on as they go on the head, several seconds before they connect
    /// (0x20 → 0x21 → 0x23, measured 2026-11-09), so a 0 → 1 edge drops the card. Byte 11 is
    /// the colour code.
    private var lastWorn: [String: Bool] = [:]

    private func handleHeadphones(_ b: [UInt8], model: UInt16, rssi: Int) {
        // One Max of a model is ours; a second one nearby is told apart only by range.
        guard b.count > 11, let ours = candidates.first(where: { $0.productID == model }) else { return }
        AirPodsDropdown.shared.knownColors[ours.address] = b[11]
        let worn = b[7] & 0x01 != 0
        let was = lastWorn[ours.address]
        lastWorn[ours.address] = worn
        if was != worn { reevaluate() }
        guard worn, was == false else { return }
        let nibbles = [Int(b[8] >> 4), Int(b[8] & 0x0F)].filter { $0 != 0xF }
        AirPodsDropdown.shared.caseOpened(address: ours.address, productID: model,
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
