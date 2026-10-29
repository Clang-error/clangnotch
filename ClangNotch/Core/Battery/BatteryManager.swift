import AppKit
import Combine
import IOBluetooth
import IOKit.ps
import UserNotifications

struct BatteryPart: Equatable, Codable {
    let label: String   // "L" / "R" / "케이스"
    let percent: Int

    /// `label` doubles as a stored key ("케이스"), so translate only for display.
    var displayLabel: String { label == "케이스" ? L("케이스", "Case") : label }
}

struct BatteryDevice: Identifiable, Equatable, Codable {
    let id: String
    let name: String
    let symbol: String          // SF Symbol (애플 네이티브 기기 아이콘)
    let percent: Int
    let charging: Bool
    /// false면 실시간 값이 아니다 — 기기가 응답을 멈춰 마지막 값을 보여주는 중.
    let live: Bool
    /// 마지막으로 실제 값을 받은 시각. live일 땐 방금.
    var seenAt: Date
    /// 에어팟처럼 좌/우/케이스가 따로 잡히는 경우의 내역
    let parts: [BatteryPart]
    /// 맥 본체만: 충전 중이면 완충까지, 아니면 바닥날 때까지 남은 분. 계산 중이면 nil.
    var minutesLeft: Int? = nil
}

@MainActor
final class BatteryManager: ObservableObject {
    static let shared = BatteryManager()

    @Published private(set) var devices: [BatteryDevice] = []
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var isRefreshing = false

    /// 무선 아이폰·아이패드는 절전에 들어가면 탐색 목록에서 통째로 사라진다
    /// (실측: 15초 간격에서 45%만 응답, 값은 항상 일관). 사라졌다고 목록에서 빼면
    /// 화면이 깜빡이므로 마지막 값을 계속 들고 있고, 대신 언제 값인지 밝힌다.
    /// 만료 시한은 두지 않는다 — 안 쓰는 기기는 앱 재시작 때 자연히 정리된다.
    private var lastSeen: [String: BatteryDevice] = [:]

    /// 배터리 부족 알림은 기기당 한 번만 울리고, 충분히 충전된 뒤에 재장전한다.
    /// 재장전을 21%처럼 임계값 바로 위로 잡으면 20↔21을 오가며 알림이 폭주한다.
    private let alertThreshold = 20
    private let rearmThreshold = 30
    private var armed: [String: Bool] = [:]

    /// 알림을 받으려면 탭을 안 보고 있어도 계속 돌아야 한다. 대신 평소엔 성기게.
    private let idleInterval: TimeInterval = 300
    private let activeInterval: TimeInterval = 60

    private var timer: Timer?
    private var interval: TimeInterval = 0

    /// 맥 본체와 연결된 블루투스 기기는 외부 프로세스 없이 읽혀서 싸다. 헤더에 띄우는
    /// 에어팟 같은 값이 5분씩 늦지 않게 이것만 따로 자주 돈다(2026-09-27).
    private let fastInterval: TimeInterval = 60
    private var fastTimer: Timer?
    private var isFastRefreshing = false
    private var powerSource: CFRunLoopSource?
    private var bluetoothEvents: BluetoothEvents?

    private init() {
        // 닫힌 노치 순위는 1·2순위 두 칸이었다가 개수 제한 없는 목록이 됐다(2026-09-27). 한 번만 옮겨 온다.
        let defaults = UserDefaults.standard
        let legacySlots = ["closedBatteryPrimaryID", "closedBatterySecondaryID"]
        if defaults.object(forKey: "closedBatteryPriorityIDs") == nil {
            AppSettings.shared.closedBatteryPriorityIDs = legacySlots
                .compactMap { defaults.string(forKey: $0) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }
        for key in legacySlots + ["lowBatteryNotchSnoozed"] { defaults.removeObject(forKey: key) }

        lastSeen = Self.loadCache()
        // 첫 수집은 몇 초 걸리고, 그때 폰이 절전이면 아예 못 잡는다(실측 68초 뒤 등장).
        // 그동안 빈 화면을 보여주지 않도록 마지막으로 알던 값을 먼저 깔아둔다.
        if !lastSeen.isEmpty { merge([]) }
    }

    /// 앱 기동 시 호출 — 탭을 열지 않아도 알림 감시는 계속된다.
    func startMonitoring() {
        guard !DemoMode.isActive else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            Task { @MainActor in
                self.log("notif auth granted=\(granted) error=\(error?.localizedDescription ?? "none")")
            }
        }
        setPolling(idleInterval)
        startFastPath()
    }

    /// 60초 타이머 + 전원 변경 알림(충전기·잔량 변화)으로 싼 값만 갱신한다.
    private func startFastPath() {
        guard fastTimer == nil else { return }
        fastTimer = Timer.scheduledTimer(withTimeInterval: fastInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshFast() }
        }
        if let source = IOPSNotificationCreateRunLoopSource({ _ in
            Task { @MainActor in BatteryManager.shared.refreshFast() }
        }, nil)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSource = source
        }
    }

    /// 맥 + 연결된 블루투스만 읽는다. system_profiler와 iOS 조회는 느린 주기 몫이다.
    func refreshFast() {
        guard !isFastRefreshing, !DemoMode.isActive else { return }
        isFastRefreshing = true
        Task.detached(priority: .utility) {
            let found = Collector.bluetooth(connectedOnly: true) + Collector.mac()
            await MainActor.run {
                self.mergeFast(found)
                self.isFastRefreshing = false
            }
        }
    }

    /// 연결·해제 알림은 IOBluetooth가 백그라운드 수집으로 한 번 초기화된 뒤에 건다 —
    /// 메인에서 처음 부르면 데드락이다(refresh()의 경고 참고).
    private func registerBluetoothEventsIfNeeded() {
        guard bluetoothEvents == nil else { return }
        bluetoothEvents = BluetoothEvents { [weak self] in
            // 막 붙은 에어팟은 잔량을 몇 초 뒤에야 보고한다.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                self?.refreshFast()
            }
        }
    }

    /// Battery 탭이 보일 때 — 촘촘히 갱신.
    func start() { if !DemoMode.isActive { setPolling(activeInterval) } }

    /// 탭이 닫혀도 감시는 멈추지 않고 주기만 늘린다.
    func stop() { if !DemoMode.isActive { setPolling(idleInterval) } }

    private func setPolling(_ seconds: TimeInterval) {
        guard interval != seconds else { return }
        interval = seconds
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        // 노치가 열리고 닫힐 때마다 주기가 오가는데, 그때마다 재수집하면
        // 수집당 외부 프로세스를 5~6개씩 띄우며 초 단위로 폭주한다(실측).
        // 들고 있는 값이 새 주기보다 오래됐을 때만 다시 긁는다.
        let age = lastUpdated.map { Date().timeIntervalSince($0) }
        if age.map({ $0 > seconds }) ?? true { refresh() }
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true

        // ⚠️ 전부 메인 밖에서 돌려야 한다. 외부 프로세스 호출이 노치를 멈추는 것도 있지만,
        // 더 중요한 건 IOBluetooth다 — 첫 호출이 코디네이터를 초기화하는데 그게 메인 큐로
        // 보낸 블록을 세마포어로 기다려서, 메인에서 부르면 그대로 데드락이 난다(실측).
        Task.detached(priority: .utility) {
            let found = Collector.bluetooth() + Collector.macAndIOS()
            await MainActor.run {
                self.merge(found)
                self.lastUpdated = Date()
                self.isRefreshing = false
                self.registerBluetoothEventsIfNeeded()
            }
        }
    }

    /// 이번에 응답한 기기는 갱신하고, 빠진 기기는 창 안이면 마지막 값으로 되살린다.
    private func merge(_ fresh: [BatteryDevice]) {
        // 연결이 끊긴 기기는 값이 안 변해도 매번 "방금 확인"으로 찍혀서, 며칠 묵은
        // 값이 화면엔 방금 값처럼 보였다. 값이 실제로 움직였을 때만 시각을 새로 찍는다.
        // live인 기기는 화면에 나이를 안 띄우므로 그냥 지금으로 둔다.
        let stamped = keepingCaseLevel(fresh).map { device -> BatteryDevice in
            guard !device.live, let previous = lastSeen[device.id],
                  previous.percent == device.percent, previous.parts == device.parts
            else { return device }
            var device = device
            device.seenAt = previous.seenAt
            return device
        }
        for device in stamped { lastSeen[device.id] = device }

        let freshIDs = Set(stamped.map(\.id))
        var result = stamped

        for (id, cached) in lastSeen where !freshIDs.contains(id) {
            result.append(BatteryDevice(
                id: cached.id, name: cached.name, symbol: cached.symbol,
                percent: cached.percent, charging: cached.charging,
                live: false, seenAt: cached.seenAt, parts: cached.parts
            ))
        }

        // 마지막 값이 두 시간을 넘긴 비연결 기기는 목록에서 뺀다. 캐시에는 남겨 두므로
        // 다시 잡히면 바로 돌아오고, 밤새 자는 폰도 아침에 깨면 복귀한다.
        let cutoff = Date().addingTimeInterval(-Self.hideAfter)
        result.removeAll { !$0.live && $0.seenAt < cutoff }

        devices = Self.ordered(result)

        saveCache()
        trace(fresh: freshIDs)
        checkAlerts()
        rearmLowBatteryBadge()
    }

    /// 빠른 수집분만 갈아 끼운다. 빠른 수집에 안 잡힌 블루투스 기기는 방금 끊긴 것이다.
    private func mergeFast(_ fresh: [BatteryDevice]) {
        let fresh = keepingCaseLevel(fresh)
        for device in fresh { lastSeen[device.id] = device }
        let freshIDs = Set(fresh.map(\.id))
        let rest = devices.filter { !freshIDs.contains($0.id) }.map { device -> BatteryDevice in
            guard device.kindKey == "bt", device.live else { return device }
            return BatteryDevice(
                id: device.id, name: device.name, symbol: device.symbol,
                percent: device.percent, charging: device.charging,
                live: false, seenAt: device.seenAt, parts: device.parts
            )
        }
        devices = Self.ordered(rest + fresh)
        saveCache()
        checkAlerts()
        rearmLowBatteryBadge()
    }

    /// iPhone·iPad levels come from Homebrew's libimobiledevice; without it they just don't show.
    static var hasIOSTools: Bool { Collector.tool("idevice_id") != nil && Collector.tool("ideviceinfo") != nil }

    /// 아이폰 도구 줄's button: Homebrew (if missing) and libimobiledevice in a Terminal window.
    /// A `.command` file opens in Terminal without asking for Automation permission.
    static func installIOSTools() {
        let script = """
        #!/bin/zsh
        if [ ! -x /opt/homebrew/bin/brew ] && [ ! -x /usr/local/bin/brew ]; then
          /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        fi
        BREW=$(ls /opt/homebrew/bin/brew /usr/local/bin/brew 2>/dev/null | head -1)
        "$BREW" install libimobiledevice && echo "\n끝났습니다. 아이폰을 케이블로 연결하고 '이 컴퓨터 신뢰'를 누르세요. 이 창은 닫아도 됩니다."
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ClangNotch 아이폰 도구 설치.command")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            NSWorkspace.shared.open(url)
        } catch {
            debugLog("[Battery] install script failed: \(error)")
        }
    }

    // MARK: - 닫힌 노치 배터리 부족 표시

    /// 닫힌 노치 경고 순위, 앞이 높은 순위. 헤더 목록과는 따로 지정한다.
    var closedPriorityIDs: [String] {
        AppSettings.shared.closedBatteryPriorityIDs.split(separator: "\n").map(String.init)
    }

    /// 순위 기기 중 지금 부족한 것, 순위 순. 충전 중이면 곧 회복되므로 제외한다(알림과 같은 기준).
    var lowPriorityDevices: [BatteryDevice] {
        closedPriorityIDs.compactMap { id in
            devices.first { $0.id == id && $0.isConnected && $0.displayLevel <= alertThreshold && !$0.charging }
        }
    }

    /// 닫힌 노치에 띄울 기기 — 부족한 순위 기기 중 끄지 않은 첫 번째.
    /// 윗순위가 괜찮거나(20% 초과) 꺼져 있으면 다음 순위가 대신 뜬다.
    var closedNotchLowBattery: BatteryDevice? {
        let snoozed = snoozedIDs
        return lowPriorityDevices.first { !snoozed.contains($0.id) }
    }

    var snoozedIDs: Set<String> {
        Set(AppSettings.shared.lowBatteryNotchSnoozedIDs.split(separator: "\n").map(String.init))
    }

    func setSnoozed(_ snoozed: Bool, for id: String) {
        var ids = snoozedIDs
        if snoozed { ids.insert(id) } else { ids.remove(id) }
        AppSettings.shared.lowBatteryNotchSnoozedIDs = ids.sorted().joined(separator: "\n")
    }

    /// 끈 기기는 부족 기준을 넘어서면 다시 켠다. 순위에서 빠진 기기의 기록도 지운다.
    /// 연결이 끊긴 기기는 잔량을 모르니 그대로 둔다.
    private func rearmLowBatteryBadge() {
        let ids = snoozedIDs
        guard !ids.isEmpty else { return }
        let priority = Set(closedPriorityIDs)
        let kept = ids.filter { id in
            guard priority.contains(id) else { return false }
            guard let device = devices.first(where: { $0.id == id }), device.isConnected else { return true }
            return device.displayLevel <= alertThreshold
        }
        if kept != ids {
            AppSettings.shared.lowBatteryNotchSnoozedIDs = kept.sorted().joined(separator: "\n")
        }
    }

    /// 에어팟은 케이스가 닫히면 케이스 잔량 보고를 멈춘다. macOS 메뉴처럼 마지막 값을 이어 보여준다.
    /// 좌우가 따로 잡히는 이어버드만이다. 에어팟 맥스는 케이스 배터리가 없는데, 어쩌다 한 번 들어온
    /// 케이스 값이 이걸로 영영 남았다(2026-10-14: IOBluetooth는 케이스 0인데 59%가 계속 보임).
    private func keepingCaseLevel(_ fresh: [BatteryDevice]) -> [BatteryDevice] {
        fresh.map { device in
            guard device.parts.contains(where: { $0.label == "L" || $0.label == "R" }),
                  !device.parts.contains(where: { $0.label == "케이스" }),
                  let previous = lastSeen[device.id]?.parts.first(where: { $0.label == "케이스" })
            else { return device }
            return BatteryDevice(
                id: device.id, name: device.name, symbol: device.symbol,
                percent: device.percent, charging: device.charging,
                live: device.live, seenAt: device.seenAt, parts: device.parts + [previous]
            )
        }
    }

    /// 맥 → iOS → 나머지 순으로 고정해 순서가 튀지 않게 한다.
    private static func ordered(_ devices: [BatteryDevice]) -> [BatteryDevice] {
        let rank = ["mac": 0, "ios": 1]
        return devices.sorted {
            let a = rank[$0.kindKey] ?? 2, b = rank[$1.kindKey] ?? 2
            return a == b ? $0.name < $1.name : a < b
        }
    }

    // MARK: - 캐시 영속화

    private static let cacheKey = "batteryLastSeen"

    /// 안 쓰게 된 기기가 영영 남지 않도록 이 정도만 지나면 버린다.
    /// 밤새 자는 폰(수 시간)은 넉넉히 살아남는 폭.
    private static let cacheLifetime: TimeInterval = 7 * 24 * 60 * 60

    /// 화면에는 이보다 오래 값이 없는 비연결 기기를 보이지 않는다 (2026-09-22 사용자 요청).
    private static let hideAfter: TimeInterval = 2 * 60 * 60

    private func saveCache() {
        guard let data = try? JSONEncoder().encode(lastSeen) else { return }
        UserDefaults.standard.set(data, forKey: Self.cacheKey)
    }

    private static func loadCache() -> [String: BatteryDevice] {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let stored = try? JSONDecoder().decode([String: BatteryDevice].self, from: data)
        else { return [:] }
        let cutoff = Date().addingTimeInterval(-cacheLifetime)
        return stored.filter { $0.value.seenAt > cutoff }
    }

    // MARK: - 배터리 부족 알림

    private func checkAlerts() {
        for device in devices {
            // 맥은 macOS가 이미 저전력 경고를 띄우므로 중복이다.
            guard device.id != "mac" else { continue }
            // 캐시값으로 울리면 오작동이다. 실시간으로 확인된 것만.
            guard device.live else { continue }

            // 헤더와 같은 기준: 에어팟은 케이스를 뺀다. 케이스가 낮을 때마다 꺼낼 때 울렸다(2026-10-24).
            if device.displayLevel >= rearmThreshold {
                armed[device.id] = true
                continue
            }
            guard device.displayLevel <= alertThreshold, !device.charging,
                  armed[device.id] ?? true else { continue }

            armed[device.id] = false
            notify(device)
        }
    }

    private func notify(_ device: BatteryDevice) {
        let content = UNMutableNotificationContent()
        content.title = L("\(device.name) 배터리 부족", "\(device.name) battery low")
        content.body = L("\(device.displayLevel)% 남았습니다.", "\(device.displayLevel)% left.")
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "battery-\(device.id)", content: content, trigger: nil)
        )
        log("alert \(device.name) \(device.displayLevel)%")
    }

    // MARK: - 진단

    /// 아이폰이 목록에서 사라진다는 제보를 추적하기 위한 임시 기록.
    /// 회차마다 어떤 기기가 실시간이고 어떤 게 캐시인지 남긴다.
    private func trace(fresh: Set<String>) {
        let line = devices.map { d in
            "\(d.name)=\(d.percent)\(fresh.contains(d.id) ? "" : "?")"
        }.joined(separator: " ")
        log("[\(devices.count)] \(line)")
    }

    private func log(_ message: String) {
        let path = NSHomeDirectory() + "/04.SideProjects/battery-hub/notch.log"
        let entry = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        // 계속 도는 폴링이라 두면 무한히 자란다. 커지면 새로 시작.
        let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int ?? 0
        if size > 512 * 1024 { try? FileManager.default.removeItem(atPath: path) }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(entry.utf8))
            try? handle.close()
        } else {
            try? entry.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}

extension BatteryDevice {
    /// 헤더·닫힌 노치 기준 잔량. 좌우가 따로 잡히는 이어버드는 케이스를 빼고 더 낮은 쪽이다.
    var displayLevel: Int {
        parts.filter { $0.label == "L" || $0.label == "R" }.map(\.percent).min() ?? percent
    }

    /// 헤더·닫힌 노치용 아이콘. 이어버드가 한쪽만 잡히면 그쪽 한 알만 그린다.
    var compactSymbol: String {
        let sides = parts.filter { $0.label == "L" || $0.label == "R" }
        guard sides.count == 1 else { return symbol }
        let side = sides[0].label == "L" ? "left" : "right"
        switch symbol {
        case "airpodspro":   return "airpods.pro.\(side)"
        case "airpods":      return "airpod.\(side)"
        case "airpods.gen3": return "airpod.gen3.\(side)"
        default:             return symbol
        }
    }

    /// 지금 연결돼 있다고 볼 수 있는지. 블루투스는 끊기면 곧장 live가 꺼지지만,
    /// 무선 아이폰은 절전 중 응답을 자주 거르므로 최근에 잡혔으면 연결로 친다.
    var isConnected: Bool {
        live || (kindKey == "ios" && Date().timeIntervalSince(seenAt) < 15 * 60)
    }
}

private extension BatteryDevice {
    /// 정렬용 대분류. id 규칙에서 끌어낸다(mac 고정, iOS는 UDID, 블루투스는 MAC 주소).
    var kindKey: String {
        if id == "mac" { return "mac" }
        return id.contains("-") && id.count == 17 ? "bt" : "ios"
    }
}

// MARK: - 수집

private enum Collector {

    static func macAndIOS() -> [BatteryDevice] { mac() + ios() }

    // MARK: 맥 본체

    /// pmset과 같은 IOKit 전원 정보를 프로세스 없이 직접 읽는다. IsCharging은 "전원만
    /// 물리고 충전 안 함"일 때 false라, pmset 상태 문구로 가리던 것과 같은 의미다.
    static func mac() -> [BatteryDevice] {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return [] }
        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = desc[kIOPSCurrentCapacityKey] as? Int,
                  let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            let charging = desc[kIOPSIsChargingKey] as? Bool ?? false
            // -1 while macOS is still estimating.
            let minutes = desc[charging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey] as? Int ?? -1
            return [BatteryDevice(
                id: "mac", name: "MacBook", symbol: "macbook",
                percent: current * 100 / max, charging: charging,
                live: true, seenAt: Date(), parts: [],
                minutesLeft: minutes > 0 ? minutes : nil
            )]
        }
        return []
    }

    // MARK: iOS 기기 (libimobiledevice)

    private static func ios() -> [BatteryDevice] {
        guard let idevice = tool("idevice_id"), let info = tool("ideviceinfo") else { return [] }

        // USB와 네트워크 양쪽에 잡히는 기기가 있다. USB는 어디서든 되지만
        // 네트워크는 로컬 네트워크 권한이 있어야 열리므로 USB를 우선한다.
        let usb = Set(lines(shell(idevice, ["-l"])))
        let net = Set(lines(shell(idevice, ["-n"])))

        return usb.union(net).sorted().compactMap { udid -> BatteryDevice? in
            let flags = usb.contains(udid) ? [] : ["-n"]
            let battery = parseColonPairs(shell(info, flags + ["-u", udid, "-q", "com.apple.mobile.battery"]))
            guard let percent = battery["BatteryCurrentCapacity"].flatMap({ Int($0) }) else { return nil }

            let name = shell(info, flags + ["-u", udid, "-k", "DeviceName"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let product = shell(info, flags + ["-u", udid, "-k", "ProductType"])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            return BatteryDevice(
                id: udid,
                name: name.isEmpty ? String(udid.prefix(8)) : name,
                symbol: product.hasPrefix("iPad") ? "ipad" : "iphone",
                percent: percent,
                charging: battery["BatteryIsCharging"] == "true",
                live: true, seenAt: Date(), parts: []
            )
        }
    }

    // MARK: 블루투스 기기 (IOBluetooth)

    /// 두 소스가 정확히 상보적이라 섞어 써야 한다.
    /// - IOBluetooth: 연결된 기기만 실시간으로 갱신된다. 안 붙은 기기의 값은 이 프로세스가
    ///   처음 목록을 읽은 시점에 박제되어 영영 안 변한다(실측: 아이폰에 붙어 있던 에어팟
    ///   프로가 20시간 890회 내내 36% 고정, 같은 시각 실제값은 케이스 68·좌우 97).
    ///   대신 연결된 에어팟 맥스는 여기서만 나온다.
    /// - system_profiler: 호출마다 새 프로세스라 bluetoothd의 최신값을 그대로 준다.
    ///   대신 연결된 에어팟 맥스는 배터리 항목 자체를 안 싣는다.
    /// ⚠️ Info.plist에 `NSBluetoothAlwaysUsageDescription`이 없으면 TCC가 앱을 죽인다.
    static func bluetooth(connectedOnly: Bool = false) -> [BatteryDevice] {
        guard var paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else { return [] }
        if connectedOnly { paired = paired.filter { $0.isConnected() } }

        // 전부 연결돼 있고 이름도 다 알면 IOBluetooth 값이 다 실시간이라 외부 프로세스를 띄울 이유가 없다.
        let known = namesLock.withLock { names }
        let needsProfiler = paired.contains { device in
            !device.isConnected() || device.addressString.map { known[normalizedAddress($0)] == nil } ?? false
        }
        let profiler = needsProfiler ? profilerInfo() : (names: [:], levels: [:])
        let resolvedNames = known.merging(profiler.names) { $1 }
        if !profiler.names.isEmpty { namesLock.withLock { names = resolvedNames } }

        return paired.compactMap { device -> BatteryDevice? in
            let b = unsafeBitCast(device, to: BTBatteryDevice.self)
            guard let address = device.addressString else { return nil }

            var levels = (single: b.batteryPercentSingle, left: b.batteryPercentLeft,
                          right: b.batteryPercentRight, caseLevel: b.batteryPercentCase)
            if !device.isConnected(), let live = profiler.levels[normalizedAddress(address)] {
                levels = live
            } else if levels.caseLevel == 0, let cached = profiler.levels[normalizedAddress(address)]?.caseLevel {
                // 케이스가 닫히면 IOBluetooth는 케이스 값을 0으로 돌리지만 시스템은 마지막 값을 기억한다.
                levels.caseLevel = cached
            }

            // 0은 "값 없음"이다. 배터리를 보고하지 않는 기기(서드파티 BLE 키보드,
            // 애플워치, 페어링만 된 아이폰 등)를 걸러낸다.
            // 케이스는 좌우 이어버드가 있을 때만 있다. 에어팟 맥스는 케이스 배터리가 없는데
            // 케이스 59%가 들어온 적이 있다(bluetoothd 로그엔 7일 내내 본체뿐, 2026-10-14).
            if levels.left == 0 && levels.right == 0 { levels.caseLevel = 0 }
            let parts = [("L", levels.left), ("R", levels.right), ("케이스", levels.caseLevel)]
                .filter { $0.1 > 0 }
                .map { BatteryPart(label: $0.0, percent: $0.1) }
            let single = levels.single
            guard let worst = single > 0 ? single : parts.map(\.percent).min() else { return nil }

            return BatteryDevice(
                id: address,
                name: resolvedNames[normalizedAddress(address)] ?? device.name ?? address,
                symbol: symbol(for: device, b: b),
                percent: worst,
                charging: false,
                live: device.isConnected(),
                seenAt: Date(),
                parts: parts
            )
        }
    }

    /// 이름은 시스템 언어에 따라 "AirPods Max"/"에어팟 맥스"로 갈리므로 productID를 먼저 본다.
    private static func symbol(for device: IOBluetoothDevice, b: BTBatteryDevice) -> String {
        switch b.productID {
        case 0x200D, 0x202D: return "airpodsmax"
        case 0x200E, 0x2024: return "airpodspro"
        case 0x2013:         return "airpods.gen3"
        case 0x2002, 0x200F: return "airpods"
        default: break
        }
        switch device.deviceClassMajor {
        case 4:  return "headphones"                        // Audio
        case 5:  return device.deviceClassMinor == 1 ? "keyboard" : "magicmouse"
        default: return "questionmark.circle"
        }
    }

    private typealias Levels = (single: Int, left: Int, right: Int, caseLevel: Int)

    /// 주소별 기기 이름. IOBluetooth의 name은 기기가 스스로 알리는 영어 제품명("AirPods Max")이라
    /// 맥 블루투스 설정에 보이는 이름("에어팟 맥스")은 system_profiler에서만 나온다(2026-10-11).
    /// 빠른 수집은 system_profiler를 띄우지 않으므로 알아낸 이름을 들고 있는다.
    /// 느린 수집과 빠른 수집이 서로 다른 스레드에서 겹칠 수 있어 잠근다.
    private static var names: [String: String] = [:]
    private static let namesLock = NSLock()

    /// 주소로 찾은 `system_profiler`의 이름과 배터리 값. 하나도 못 읽으면 둘 다 빈 딕셔너리 —
    /// 호출부가 IOBluetooth 값을 그대로 쓴다.
    private static func profilerInfo() -> (names: [String: String], levels: [String: Levels]) {
        let out = shell("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"])
        guard let data = out.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = root["SPBluetoothDataType"] as? [[String: Any]]
        else { return ([:], [:]) }

        var names: [String: String] = [:]
        var result: [String: Levels] = [:]
        for section in sections {
            // 기기는 {"에어팟 프로": {...}} 하나짜리 딕셔너리로 감싸여 배열에 담긴다.
            for entry in ["device_connected", "device_not_connected"]
                .compactMap({ section[$0] as? [[String: Any]] }).joined() {
                for (name, value) in entry {
                    guard let info = value as? [String: Any],
                          let address = info["device_address"] as? String else { continue }
                    // 연결된 에어팟 맥스처럼 배터리 항목이 없는 기기도 이름은 있다.
                    names[normalizedAddress(address)] = name
                    // 값은 "68%" 형태의 문자열이다.
                    let level = { (key: String) -> Int in
                        Int((info[key] as? String)?.replacingOccurrences(of: "%", with: "") ?? "") ?? 0
                    }
                    let levels: Levels = (level("device_batteryLevelMain"), level("device_batteryLevelLeft"),
                                          level("device_batteryLevelRight"), level("device_batteryLevelCase"))
                    guard levels.single + levels.left + levels.right + levels.caseLevel > 0 else { continue }
                    result[normalizedAddress(address)] = levels
                }
            }
        }
        return (names, result)
    }

    /// IOBluetooth는 "30-d8-75-21-10-f1", system_profiler는 "30:D8:75:21:10:F1"로 준다.
    private static func normalizedAddress(_ address: String) -> String {
        address.lowercased().filter(\.isHexDigit)
    }

    // MARK: 도구

    /// libimobiledevice는 Homebrew로 깔리고, 아키텍처마다 경로가 다르다.
    static func tool(_ name: String) -> String? {
        ["/opt/homebrew/bin/", "/usr/local/bin/"]
            .map { $0 + name }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// 무선 기기가 응답하지 않으면 lockdownd 연결이 매달릴 수 있어 워치독을 건다.
    private static func shell(_ path: String, _ args: [String], timeout: TimeInterval = 5) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do { try process.run() } catch { return "" }

        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func lines(_ text: String) -> [String] {
        text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// "BatteryCurrentCapacity: 47" 형태의 ideviceinfo 출력을 딕셔너리로.
    private static func parseColonPairs(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in lines(text) {
            guard let range = line.range(of: ": ") else { continue }
            result[String(line[..<range.lowerBound])] = String(line[range.upperBound...])
        }
        return result
    }
}

/// IOBluetoothDevice의 비공개 배터리 프로퍼티. 공개 헤더에 없어 프로토콜로 브리징한다
/// (앱이 SidecarCore·CGS·MediaRemote에 쓰는 방식과 동일).
@objc private protocol BTBatteryDevice {
    @objc(batteryPercentSingle) var batteryPercentSingle: Int { get }
    @objc(batteryPercentLeft) var batteryPercentLeft: Int { get }
    @objc(batteryPercentRight) var batteryPercentRight: Int { get }
    @objc(batteryPercentCase) var batteryPercentCase: Int { get }
    @objc(productID) var productID: UInt16 { get }
}

/// IOBluetooth 연결·해제 알림을 받는 NSObject 어댑터. 알림은 메인 런루프로 온다.
private final class BluetoothEvents: NSObject {
    private let onChange: () -> Void
    private var connectNotification: IOBluetoothUserNotification?

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        super.init()
        // 등록 즉시 이미 연결된 기기마다 한 번씩 불린다 — 거기서 해제 알림도 건다.
        connectNotification = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(connected(_:device:)))
    }

    @objc private func connected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        device.register(forDisconnectNotification: self, selector: #selector(disconnected(_:device:)))
        onChange()
    }

    @objc private func disconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        notification.unregister()
        onChange()
    }
}

// MARK: - Demo

extension BatteryManager {
    /// `--demo`: made-up devices in place of this Mac's own (and its cached ones).
    func demoApply(_ devices: [BatteryDevice]) {
        self.devices = devices
        lastUpdated = Date()
    }
}
