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
        let anyDisconnected = enabled && (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? [])
            .contains { device in !device.isConnected() && paired.contains { $0.address == device.addressString } }
        if candidates.isEmpty {
            stop()
            return
        }
        if !anyDisconnected {
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

        guard rssi >= Self.nearRSSI, rssi < 0 else { return }
        // The case keeps advertising for a while after the card folds by itself.
        if let last = lastSeen[ours.address], Date().timeIntervalSince(last) < 20 { lastSeen[ours.address] = Date(); return }
        lastSeen[ours.address] = Date()
        AirPodsDropdown.shared.caseOpened(address: ours.address, productID: model,
                                          level: tenths(min(left, right)), caseLevel: tenths(caseTenths))
    }

    /// The buds disconnected (lid closed on them): the next opening counts again.
    func forget(address: String) {
        lastSeen[address] = nil
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
