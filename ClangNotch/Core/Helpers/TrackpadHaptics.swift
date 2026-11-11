import AppKit
import IOKit

/// Trackpad taps that land while ClangNotch is in the background. `NSHapticFeedbackManager`
/// only plays for the frontmost app, and the notch never is, so this drives the trackpad's
/// actuator through the private MultitouchSupport framework (as HapticKey does), falling
/// back to the public API if that framework can't be loaded.
@MainActor
enum TrackpadHaptics {
    private typealias CreateFn = @convention(c) (UInt64) -> UnsafeMutableRawPointer?
    private typealias OpenFn = @convention(c) (UnsafeMutableRawPointer) -> Int32
    private typealias ActuateFn = @convention(c) (UnsafeMutableRawPointer, Int32, UInt32, Float, Float) -> Int32

    private static let framework = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW)
    private static let create = symbol("MTActuatorCreateFromDeviceID", as: CreateFn.self)
    private static let open = symbol("MTActuatorOpen", as: OpenFn.self)
    private static let actuate = symbol("MTActuatorActuate", as: ActuateFn.self)
    private static var actuators: [(pointer: UnsafeMutableRawPointer, builtIn: Bool)] = []

    /// `strength` 1 (lightest) … 8 (firmest). 1–6 are the actuator's own waveform IDs; 6 is
    /// as hard as it hits, so 7 and 8 repeat it 2 and 3 times 40ms apart to feel heavier.
    /// (IDs 15 and 16 also exist but can't be felt on the built-in trackpad.)
    static func tap(strength: Int) {
        let level = min(max(strength, 1), 8)
        pulse(id: Int32(min(level, 6)))
        for extra in 0..<max(level - 6, 0) {
            Task {
                try? await Task.sleep(for: .milliseconds(40 * (extra + 1)))
                pulse(id: 6)
            }
        }
    }

    private static func pulse(id: Int32) {
        if actuators.isEmpty { actuators = openActuators() }
        // Lid shut (clamshell): the built-in trackpad is under it, so it stays still; a Magic
        // Trackpad still gets the tap (user, 2026-11-11). The public fallback can't tell them apart.
        let lidClosed = Self.lidClosed
        guard let actuate, !actuators.isEmpty else {
            if !lidClosed { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
            return
        }
        let targets = actuators.filter { !(lidClosed && $0.builtIn) }
        guard !targets.isEmpty else { return }
        // A trackpad that went away (Magic Trackpad off) fails; look again next time.
        if !targets.contains(where: { actuate($0.pointer, id, 0, 0, 2) == 0 }) {
            actuators = []
        }
    }

    /// IOPMrootDomain's AppleClamshellState: the MacBook's lid is shut.
    private static var lidClosed: Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        return IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, nil, 0)?
            .takeRetainedValue() as? Bool ?? false
    }

    /// Every multitouch device's actuator: the built-in trackpad ("MT Built-In") and any Magic Trackpad.
    private static func openActuators() -> [(pointer: UnsafeMutableRawPointer, builtIn: Bool)] {
        guard let create, let open else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleMultitouchDevice"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [(pointer: UnsafeMutableRawPointer, builtIn: Bool)] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let id = IORegistryEntryCreateCFProperty(service, "Multitouch ID" as CFString, nil, 0)?
                    .takeRetainedValue() as? UInt64,
                  let actuator = create(id), open(actuator) == 0 else { continue }
            let builtIn = IORegistryEntryCreateCFProperty(service, "MT Built-In" as CFString, nil, 0)?
                .takeRetainedValue() as? Bool ?? false
            result.append((actuator, builtIn))
        }
        return result
    }

    private static func symbol<T>(_ name: String, as: T.Type) -> T? {
        guard let framework, let pointer = dlsym(framework, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }
}
