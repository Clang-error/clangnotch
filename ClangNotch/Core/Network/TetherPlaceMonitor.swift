// TetherPlaceMonitor.swift
// Nags from the notch while the Mac is on the iPhone hotspot at a saved place
// (home, work…) — somewhere real Wi-Fi exists and mobile data is being burned.

import AppKit
import CoreLocation
import CoreWLAN
import Network

struct TetherPlace: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    let latitude: Double
    let longitude: Double
    var radius: Double = 200
}

/// A new value per detection, so the notch fires even when the place is unchanged.
struct TetherAlert: Equatable {
    let id = UUID()
    let placeName: String
}

@MainActor
final class TetherPlaceMonitor: NSObject, ObservableObject {
    static let shared = TetherPlaceMonitor()

    @Published private(set) var places: [TetherPlace] = [] {
        didSet { save() }
    }
    @Published private(set) var alert: TetherAlert?
    /// The saved place the Mac is tethering at right now; stays set until tethering ends,
    /// so the warning survives a missed notch alert.
    @Published private(set) var activePlaceName: String?
    /// Whole minutes tethering at the current place, for the closed notch's "집 · 12분". Counted
    /// from when this app judged the Mac to be there — arriving home already on the hotspot
    /// starts from 0, not from the start of the connection — and from 0 after an app relaunch.
    @Published private(set) var connectedMinutes = 0
    private var placeSince: Date?

    var connectedLabel: String {
        switch connectedMinutes {
        case ..<1:  return "방금"
        case ..<60: return "\(connectedMinutes)분"
        default:
            let hours = connectedMinutes / 60, minutes = connectedMinutes % 60
            return minutes == 0 ? "\(hours)시간" : "\(hours)시간 \(minutes)분"
        }
    }
    @Published private(set) var isLocating = false
    @Published private(set) var lastError: String?

    /// The SSID check is cheap, so it runs often enough to catch a new connection quickly;
    /// the location fix and the alert repeat on the slower cadence while tethering lasts.
    private let pollInterval: TimeInterval = 60
    private let alertInterval: TimeInterval = 10 * 60
    /// Leaving a place on the same hotspot changes nothing on the network, so only a location
    /// check notices it. While warning at a place, check this often; the alert keeps its pace.
    private let placeRecheckInterval: TimeInterval = 2 * 60
    private var lastAlert: Date?
    private static let storageKey = "tetherPlaces"

    private let location = CLLocationManager()
    /// Network changes (hotspot ↔ Wi-Fi) arrive here the moment they happen; the timer is
    /// only the fallback. The OS wakes us on a change, so this costs nothing while idle.
    private let pathMonitor = NWPathMonitor()
    private var timer: Timer?
    private var lastCheck: Date?
    private var awaitingCheck = false
    private var pendingPlaceName: String?
    private var fixTimeoutTask: Task<Void, Never>?

    private override init() {
        super.init()
        location.delegate = self
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let stored = try? JSONDecoder().decode([TetherPlace].self, from: data) {
            places = stored
        }
    }

    /// Called at launch — the alert has to fire without any tab being open.
    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        pathMonitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        pathMonitor.start(queue: .main)
        // Sleeping at one place and waking at another can keep the same hotspot connection,
        // so the last verdict can't stand until the next 10-minute check.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.recheck() }
        }
        tick()
    }

    func addCurrentLocation(named name: String) {
        guard !name.isEmpty else { return }
        pendingPlaceName = name
        isLocating = true
        lastError = nil
        requestFreshFix()
    }

    func remove(_ id: TetherPlace.ID) {
        places.removeAll { $0.id == id }
        recheck()
    }

    func rename(_ name: String, for id: TetherPlace.ID) {
        guard let index = places.firstIndex(where: { $0.id == id }) else { return }
        places[index].name = name
    }

    func setRadius(_ radius: Double, for id: TetherPlace.ID) {
        guard let index = places.firstIndex(where: { $0.id == id }) else { return }
        places[index].radius = radius
        recheck()
    }

    /// The place list changed while tethering — judge it now, not at the next 10-minute check.
    private func recheck() {
        lastCheck = nil
        tick()
    }

    private var isOnHotspot: Bool {
        let hotspot = AppSettings.shared.tworldHotspotSSID
        return !hotspot.isEmpty && CWWiFiClient.shared().interface()?.ssid() == hotspot
    }

    private func tick() {
        guard !places.isEmpty, NetworkInfoManager.shared.hasLocationAccess else {
            setActivePlace(nil)
            return
        }
        guard isOnHotspot else {
            // Off the hotspot: the next connection alerts right away.
            lastCheck = nil
            setActivePlace(nil)
            return
        }
        if let placeSince {
            let minutes = Int(Date().timeIntervalSince(placeSince) / 60)
            if connectedMinutes != minutes { connectedMinutes = minutes }
        }
        let checkInterval = activePlaceName == nil ? alertInterval : placeRecheckInterval
        if let lastCheck, Date().timeIntervalSince(lastCheck) < checkInterval { return }
        lastCheck = Date()
        awaitingCheck = true
        requestFreshFix()
    }

    /// `requestLocation()` hands back whatever fix locationd has cached, and after a wake that
    /// is where the Mac last was — home, while it is now somewhere else. Updates run until a
    /// fresh fix arrives (`handleFix` skips the cached one), or the timeout gives up.
    private func requestFreshFix() {
        location.startUpdatingLocation()
        fixTimeoutTask?.cancel()
        fixTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            self?.handleFailure()
        }
    }

    private func stopLocating() {
        location.stopUpdatingLocation()
        fixTimeoutTask?.cancel()
        fixTimeoutTask = nil
    }

    private func handleFix(_ fix: CLLocation) {
        guard fix.horizontalAccuracy >= 0, fix.timestamp.timeIntervalSinceNow > -30 else { return }
        stopLocating()
        let coordinate = fix.coordinate
        if let name = pendingPlaceName {
            places.append(TetherPlace(name: name, latitude: coordinate.latitude, longitude: coordinate.longitude))
            pendingPlaceName = nil
            isLocating = false
            // Adding the place you're tethering at should warn right away. This fix is where
            // you stand, so judge it now instead of waiting for the next 10-minute check.
            if isOnHotspot {
                lastCheck = Date()
                awaitingCheck = true
            }
        }
        if awaitingCheck {
            awaitingCheck = false
            let here = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            // The hotspot can drop while the fix is on its way.
            let place = isOnHotspot ? places.first(where: {
                here.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude)) <= $0.radius
            }) : nil
            let previousPlaceName = activePlaceName
            setActivePlace(place?.name)
            // A new place alerts at once; staying put repeats it only every `alertInterval`.
            if let place, place.name != previousPlaceName
                || lastAlert.map({ Date().timeIntervalSince($0) >= alertInterval }) ?? true {
                lastAlert = Date()
                alert = TetherAlert(placeName: place.name)
            }
        }
    }

    /// Only publishes real changes — the menu bar redraws its icon on every emission.
    private func setActivePlace(_ name: String?) {
        guard activePlaceName != name else { return }
        activePlaceName = name
        placeSince = name == nil ? nil : Date()
        if connectedMinutes != 0 { connectedMinutes = 0 }
    }

    private func handleFailure() {
        stopLocating()
        if pendingPlaceName != nil {
            lastError = "현재 위치를 받지 못했습니다. 잠시 후 다시 시도하세요."
        }
        if awaitingCheck {
            // Unconfirmed is not "still at the place": drop the warning until the next check.
            setActivePlace(nil)
        }
        pendingPlaceName = nil
        isLocating = false
        awaitingCheck = false
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(places) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}

extension TetherPlaceMonitor: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let fix = locations.last else { return }
        Task { @MainActor in self.handleFix(fix) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Updates keep trying after this one; the timeout decides when to give up.
        if (error as? CLError)?.code == .locationUnknown { return }
        Task { @MainActor in self.handleFailure() }
    }
}
