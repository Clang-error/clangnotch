import Foundation
import IOKit.ps

/// Whether the Mac runs on the adapter, for battery saver. IOKit calls back on every
/// power source change, so nothing polls.
@MainActor
public final class PowerStateMonitor: ObservableObject {
    public static let shared = PowerStateMonitor()

    @Published public private(set) var isCharging = true

    private var runLoopSource: CFRunLoopSource?

    private init() {
        refresh()
        let context = Unmanaged.passUnretained(self).toOpaque()
        runLoopSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<PowerStateMonitor>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in monitor.refresh() }
        }, context)?.takeRetainedValue()
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
        }
    }

    /// A desktop Mac reports AC power too, so it never counts as on battery.
    private func refresh() {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let source = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String?
        let charging = source != kIOPSBatteryPowerValue
        if charging != isCharging { isCharging = charging }
    }
}
