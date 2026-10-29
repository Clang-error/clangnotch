// NetworkInfoManager.swift
// Name of the network the Mac is currently using.

import AppKit
import Foundation
import Combine
import CoreLocation
import CoreWLAN
import SystemConfiguration

@MainActor
final class NetworkInfoManager: NSObject, ObservableObject {
    static let shared = NetworkInfoManager()

    /// The Wi-Fi SSID when Location Services allow it, otherwise the network
    /// service's name ("Wi-Fi", "Ethernet", "iPhone USB"…).
    @Published private(set) var name: String = L("알 수 없음", "Unknown")
    /// Exact SSID only; never substitute a service name when identifying a hotspot.
    @Published private(set) var ssid: String?
    /// True while the SSID is hidden behind a permission the user hasn't granted.
    @Published private(set) var ssidBlocked = false
    /// Mirrors the location manager so Settings can show where the permission stands.
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined

    private let location = CLLocationManager()
    private var authorizationRefreshTask: Task<Void, Never>?
    private var restoresAccessoryActivationPolicy = false

    var hasLocationAccess: Bool {
        // macOS reports the functionally-equivalent location grant as `.authorized`.
        // Treat both representations as sufficient for CoreWLAN's SSID lookup.
        authorization == .authorized || authorization == .authorizedAlways
    }

    private override init() {
        super.init()
        location.delegate = self
        authorization = location.authorizationStatus
        readCurrent()

        // The permission can be granted or revoked in System Settings while the app
        // is running — catch up when the user comes back, not just on the next refresh.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Accessory apps do not reliably receive didBecomeActive after the
            // user returns from System Settings.
            Task { @MainActor in self?.refresh() }
        }
    }

    /// macOS 14+ hides the SSID behind Location Services — CoreWLAN just returns nil
    /// without it. Re-reads what we're allowed to read; never prompts on its own.
    func refresh() {
        authorization = location.authorizationStatus
        readCurrent()
    }

    /// Shows the system prompt, or sends the user to System Settings once macOS has
    /// stopped offering one. Driven from Settings so it isn't a one-shot at launch —
    /// this app has no Dock icon, and a prompt missed there was unrecoverable.
    func requestAccess() {
        switch location.authorizationStatus {
        case .notDetermined:
            // A prompt for an LSUIElement app opens behind whatever is in front,
            // so bring the app forward first. The next run-loop turn is required:
            // Core Location otherwise still sees the non-activating notch panel.
            if NSApp.activationPolicy() == .accessory {
                restoresAccessoryActivationPolicy = NSApp.setActivationPolicy(.regular)
            }
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, self.location.authorizationStatus == .notDetermined else { return }
                self.location.requestAlwaysAuthorization()
                // On macOS, beginning the one-shot location service makes the
                // authorization request visible for LSUIElement applications.
                self.location.startUpdatingLocation()
                self.watchAuthorizationChange()
            }
        case .denied, .restricted:
            openLocationSettings()
            watchAuthorizationChange()
        default:
            refresh()
        }
    }

    func openLocationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") else { return }
        NSWorkspace.shared.open(url)
    }

    private func readCurrent() {
        if DemoMode.isActive {
            ssid = "Studio Wi-Fi"
            ssidBlocked = false
            name = "Studio Wi-Fi"
            return
        }
        let interface = CWWiFiClient.shared().interface()
        let wanted = AppSettings.shared.enableNetworkName
        let authorized = hasLocationAccess
        ssid = (wanted && authorized) ? interface?.ssid() : nil

        ssidBlocked = wanted && !authorized && interface?.powerOn() == true
        name = ssid ?? serviceName() ?? L("알 수 없음", "Unknown")
    }

    /// System Settings can update Location Services without invoking the delegate
    /// for an accessory app. Poll briefly only after a permission action.
    private func watchAuthorizationChange() {
        authorizationRefreshTask?.cancel()
        authorizationRefreshTask = Task { [weak self] in
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self else { return }
                self.refresh()
                if self.hasLocationAccess {
                    self.restoreAccessoryActivationPolicy()
                    return
                }
            }
            self?.restoreAccessoryActivationPolicy()
        }
    }

    private func restoreAccessoryActivationPolicy() {
        guard restoresAccessoryActivationPolicy else { return }
        NSApp.setActivationPolicy(.accessory)
        restoresAccessoryActivationPolicy = false
    }

    /// The primary service's user-facing name, straight out of the network
    /// configuration — no permission involved.
    private func serviceName() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "ClangNotch" as CFString, nil, nil),
              let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let service = global["PrimaryService"] as? String,
              let setup = SCDynamicStoreCopyValue(store, "Setup:/Network/Service/\(service)" as CFString) as? [String: Any]
        else { return nil }
        return setup["UserDefinedName"] as? String
    }
}

extension NetworkInfoManager: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.refresh()
            if manager.authorizationStatus != .notDetermined {
                self.restoreAccessoryActivationPolicy()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        Task { @MainActor in
            self.refresh()
            if status != .notDetermined {
                self.restoreAccessoryActivationPolicy()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        manager.stopUpdatingLocation()
        Task { @MainActor in self.refresh() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        manager.stopUpdatingLocation()
        Task { @MainActor in self.refresh() }
    }
}
