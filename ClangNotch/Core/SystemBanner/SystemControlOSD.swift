import AppKit
import AudioToolbox
import CoreAudio
import SwiftUI

/// What the 조절창 shows right now.
struct SystemControlReading: Equatable {
    enum Kind { case volume, mute, brightness }
    var kind: Kind
    var title: String
    var fraction: Double
    var badge: String
    /// Battery of the Bluetooth headphones the sound goes to, if BatteryManager knows it.
    var battery: Int? = nil
}

/// ClangNotch's own volume/brightness HUD ("조절창"), drawn at the top center just below
/// the menu bar in place of macOS's system banner. Modeled on BetterDisplay's OSD, but
/// ClangNotch doesn't need BetterDisplay for any of it.
///
/// Keys: `SoftwareVolume`'s key tap hands them to `handleKey`, which sets the value itself so
/// macOS never puts up its banner. The AirPods Max crown: macOS puts up its banner,
/// `SystemBannerCenterer` tries to move it off screen (ignored since macOS 27.2) and calls
/// `showVolume`; the value is read here and polled while the HUD is up. Outputs macOS can't turn down: `SoftwareVolume` takes the keys and
/// calls `showSoftwareVolume`.
@MainActor
final class SystemControlOSD: ObservableObject {
    static let shared = SystemControlOSD()

    @Published private(set) var reading: SystemControlReading?
    /// Drives the glass materialize/dematerialize; `reading` stays put while it fades out.
    @Published private(set) var shown = false
    /// Bumped when a key is pressed again at an end of the range, to bounce that icon.
    @Published private(set) var minBounce = 0
    @Published private(set) var maxBounce = 0
    /// Digits roll down while the value drops and up while it rises.
    @Published private(set) var countsDown = false

    /// The window is the visible pill plus room for its shadow, as in BetterDisplay.
    static let pillSize = CGSize(width: 292, height: 64)
    static let shadowPadding: CGFloat = 40
    private static let gapBelowMenuBar: CGFloat = 10
    private static let visibleDuration: TimeInterval = 1.5

    private var panel: ActiveLookingPanel?
    private var hideWork: DispatchWorkItem?
    private var pollTimer: Timer?
    private var showGeneration = 0
    /// Both values as they stood when the HUD last picked what to show.
    private var volumeBaseline: SystemControlReading?
    private var brightnessBaseline: SystemControlReading?
    /// A key step is 1/16 (0.0625); auto-brightness drifts far less within one showing.
    private static let switchThreshold = 0.03

    private init() {}

    func start() {
        SoftwareVolume.shared.start()
    }

    func stop() {
        SoftwareVolume.shared.stop()
        hide()
    }

    /// macOS put up its own volume banner (keys or the AirPods Max crown).
    func showVolume(on screen: NSScreen?) {
        show(Self.currentVolumeReading(), on: screen, pollsSystem: true)
    }

    /// ClangNotch's own volume for an output macOS can't turn down (`SoftwareVolume`).
    func showSoftwareVolume(level: Double, muted: Bool) {
        show(Self.volumeReading(fraction: level, muted: muted), on: NSScreen.main)
    }

    /// macOS put up its own brightness banner.
    func showBrightness(on screen: NSScreen?) {
        show(Self.currentBrightnessReading(), on: screen, pollsSystem: true)
    }

    // MARK: - Keys

    private static let soundUp = 0, soundDown = 1, brightnessUp = 2, brightnessDown = 3, mute = 7  // NX_KEYTYPE_*

    /// A volume, mute or brightness key from `SoftwareVolume`'s key tap. Since macOS 27.2
    /// MenuBarAgent puts its banner back wherever it is moved (tested 2026-10-24), so the key
    /// is kept from macOS and the value set here; a value set directly puts up no banner.
    /// False lets the key through to macOS. ⌥⇧ steps in quarters, as macOS does.
    func handleKey(_ key: Int, isDown: Bool, isRepeat: Bool, fine: Bool) -> Bool {
        let step = fine ? 1.0 / 64 : 1.0 / 16
        switch key {
        case Self.soundUp, Self.soundDown, Self.mute:
            guard let device = AudioMixerManager.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice),
                  let reading = Self.currentVolumeReading(),
                  Self.isSettable(device, key == Self.mute ? kAudioDevicePropertyMute
                                                           : kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
            else { return false }
            guard isDown else { return true }
            if key == Self.mute {
                guard !isRepeat else { return true }
                Self.setVolumeProperty(device, kAudioDevicePropertyMute, UInt32(reading.kind == .mute ? 0 : 1))
            } else {
                let fraction = Self.stepped(reading.fraction, by: key == Self.soundUp ? step : -step)
                Self.setVolumeProperty(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, Float32(fraction))
                if reading.kind == .mute { Self.setVolumeProperty(device, kAudioDevicePropertyMute, UInt32(0)) }
            }
            showVolume(on: NSScreen.main)
            return true
        case Self.brightnessUp, Self.brightnessDown:
            guard let id = Self.builtInDisplayID, let reading = Self.currentBrightnessReading(), let setBrightness = Self.setBrightness
            else { return false }
            guard isDown else { return true }
            _ = setBrightness(id, Float(Self.stepped(reading.fraction, by: key == Self.brightnessUp ? step : -step)))
            showBrightness(on: Self.screen(for: id))
            return true
        default:
            return false
        }
    }

    /// One key step from `value`, landing on the step grid like macOS.
    private static func stepped(_ value: Double, by step: Double) -> Double {
        min(max(((value / abs(step)).rounded() + (step > 0 ? 1 : -1)) * abs(step), 0), 1)
    }

    private static func isSettable(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var settable: DarwinBoolean = false
        return AudioHardwareServiceIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }

    private static func setVolumeProperty<T>(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: T) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value = value
        AudioHardwareServiceSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<T>.size), &value)
    }

    // MARK: - Showing

    private func show(_ reading: SystemControlReading?, on screen: NSScreen?, pollsSystem: Bool = false) {
        guard let reading else { return }
        if shown, let previous = self.reading, previous.kind == reading.kind {
            if reading.fraction <= 0, previous.fraction <= 0 { minBounce += 1 }
            if reading.fraction >= 1, previous.fraction >= 1 { maxBounce += 1 }
            if reading.fraction != previous.fraction { countsDown = reading.fraction < previous.fraction }
        }
        showGeneration += 1

        let panel = self.panel ?? makePanel()
        self.panel = panel
        if !shown {
            // A fresh appearance starts from this value instead of sliding from the last one.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { self.reading = reading }
            place(panel, on: screen ?? NSScreen.main ?? NSScreen.screens.first)
            panel.orderFrontRegardless()
        }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
            self.reading = reading
            shown = true
        }

        pollTimer?.invalidate()
        pollTimer = nil
        if pollsSystem {
            // macOS reuses its banner while it is up — for a turning crown, and when the
            // other key is pressed (brightness → volume) — so no new window event arrives.
            // Follow both values directly instead.
            volumeBaseline = Self.currentVolumeReading()
            brightnessBaseline = Self.currentBrightnessReading()
            pollTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
                MainActor.assumeIsolated { SystemControlOSD.shared.pollTick() }
            }
        }
        scheduleHide()
    }

    private func pollTick() {
        guard let reading else { return }
        let showsBrightness = reading.kind == .brightness
        let other = showsBrightness ? Self.currentVolumeReading() : Self.currentBrightnessReading()
        let otherBaseline = showsBrightness ? volumeBaseline : brightnessBaseline
        if let other, let otherBaseline,
           other.kind != otherBaseline.kind || abs(other.fraction - otherBaseline.fraction) >= Self.switchThreshold {
            // The other key took over: show it, and measure further switches from here.
            volumeBaseline = Self.currentVolumeReading()
            brightnessBaseline = Self.currentBrightnessReading()
            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { self.reading = other }
            scheduleHide()
            return
        }
        guard let new = showsBrightness ? Self.currentBrightnessReading() : Self.currentVolumeReading(),
              new != reading else { return }
        if new.fraction != reading.fraction { countsDown = new.fraction < reading.fraction }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { self.reading = new }
        scheduleHide()
    }

    private func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem { MainActor.assumeIsolated { SystemControlOSD.shared.hide() } }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.visibleDuration, execute: work)
    }

    private func hide() {
        hideWork?.cancel()
        hideWork = nil
        pollTimer?.invalidate()
        pollTimer = nil
        guard let panel, shown else { return }
        let generation = showGeneration
        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
            shown = false
        } completion: {
            // A new value may have arrived during the fade.
            if SystemControlOSD.shared.showGeneration == generation { panel.orderOut(nil) }
        }
    }

    private func makePanel() -> ActiveLookingPanel {
        let size = CGSize(width: Self.pillSize.width + Self.shadowPadding * 2,
                          height: Self.pillSize.height + Self.shadowPadding * 2)
        let panel = ActiveLookingPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: SystemControlOSDView(osd: self))
        return panel
    }

    private func place(_ panel: NSPanel, on screen: NSScreen?) {
        guard let screen else { return }
        let menuBarHeight = max(screen.safeAreaInsets.top, screen.frame.maxY - screen.visibleFrame.maxY)
        let pillTop = screen.frame.maxY - menuBarHeight - Self.gapBelowMenuBar
        panel.setFrameOrigin(NSPoint(x: screen.frame.midX - panel.frame.width / 2,
                                     y: pillTop + Self.shadowPadding - panel.frame.height))
    }

    // MARK: - Readings

    private static func volumeReading(fraction: Double, muted: Bool) -> SystemControlReading {
        let device = AudioMixerManager.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
        let title = device.flatMap { AudioMixerManager.strProp($0, kAudioObjectPropertyName) } ?? L("사운드", "Sound")
        return SystemControlReading(kind: muted ? .mute : .volume, title: title, fraction: fraction,
                                    badge: muted ? L("음소거", "Muted") : "\(Int((fraction * 100).rounded()))%",
                                    battery: device.flatMap(bluetoothBattery))
    }

    /// CoreAudio's UID for Bluetooth output starts with the device address
    /// ("AC-90-85-…:output"), which is also BatteryManager's id for it.
    private static func bluetoothBattery(_ device: AudioObjectID) -> Int? {
        guard [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE]
                .contains(AudioMixerManager.transportType(device)),
              let uid = AudioMixerManager.strProp(device, kAudioDevicePropertyDeviceUID) else { return nil }
        let address = hexDigits(uid.prefix(17))
        return BatteryManager.shared.devices.first { $0.live && hexDigits($0.id) == address }?.displayLevel
    }

    private static func hexDigits<S: StringProtocol>(_ text: S) -> String {
        text.lowercased().filter(\.isHexDigit)
    }

    private static func currentVolumeReading() -> SystemControlReading? {
        guard let device = AudioMixerManager.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) else { return nil }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                                 mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioHardwareServiceGetPropertyData(device, &address, 0, nil, &size, &volume) == noErr else { return nil }
        address.mSelector = kAudioDevicePropertyMute
        var muted: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        let hasMute = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted) == noErr
        return volumeReading(fraction: Double(volume), muted: hasMute && muted != 0)
    }

    private static func brightnessReading(fraction: Double, displayID: CGDirectDisplayID) -> SystemControlReading {
        let percent = fraction * 100
        var badge = "\(Int(percent.rounded()))%"
        if CGDisplayIsBuiltin(displayID) != 0 {
            badge += " • \(formatNits(builtInNits(percent: percent))) " + L("니트", "nits")
        }
        let title = CGDisplayIsBuiltin(displayID) != 0
            ? L("내장 디스플레이", "Built-in Display")
            : screen(for: displayID)?.localizedName ?? L("디스플레이", "Display")
        return SystemControlReading(kind: .brightness, title: title, fraction: fraction, badge: badge)
    }

    private static var builtInDisplayID: CGDirectDisplayID? {
        NSScreen.screens.compactMap(displayID(of:)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    private static func currentBrightnessReading() -> SystemControlReading? {
        guard let id = builtInDisplayID, let getBrightness else { return nil }
        var value: Float = 0
        guard getBrightness(id, &value) == 0 else { return nil }
        return brightnessReading(fraction: Double(value), displayID: id)
    }

    /// `DisplayServicesGetBrightness` from the private DisplayServices framework, looked up at runtime.
    private static let getBrightness: (@convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32)? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
              let symbol = dlsym(handle, "DisplayServicesGetBrightness")
        else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32).self)
    }()

    /// `DisplayServicesSetBrightness`, the setter beside it.
    private static let setBrightness: (@convention(c) (CGDirectDisplayID, Float) -> Int32)? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
              let symbol = dlsym(handle, "DisplayServicesSetBrightness")
        else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (CGDirectDisplayID, Float) -> Int32).self)
    }()

    /// Built-in panel nits at BetterDisplay's brightness percent, read off its OSD at all 17
    /// key steps on this MacBook (2026-10-14). Below 25% BetterDisplay dims in software.
    private static let builtInNitsTable: [(percent: Double, nits: Double)] = [
        (0, 0), (6.25, 0.20), (12.5, 0.91), (18.75, 2.3), (25, 4.5), (31.25, 9.3), (37.5, 19),
        (43.75, 36), (50, 60), (56.25, 92), (62.5, 134), (68.75, 185), (75, 246),
        (81.25, 317), (87.5, 400), (93.75, 494), (100, 600),
    ]

    private static func builtInNits(percent: Double) -> Double {
        let p = min(max(percent, 0), 100)
        guard let upper = builtInNitsTable.firstIndex(where: { $0.percent >= p }), upper > 0 else {
            return builtInNitsTable[0].nits
        }
        let (p0, n0) = builtInNitsTable[upper - 1]
        let (p1, n1) = builtInNitsTable[upper]
        let t = (p - p0) / (p1 - p0)
        // The curve is close to exponential, so step geometrically between points (linearly next to 0).
        return n0 > 0 ? n0 * pow(n1 / n0, t) : n0 + (n1 - n0) * t
    }

    private static func formatNits(_ nits: Double) -> String {
        if nits >= 10 { return String(Int(nits.rounded())) }
        if nits >= 1 { return String(format: "%.1f", nits) }
        return String(format: "%.2f", nits)
    }

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    private static func screen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { displayID(of: $0) == id }
    }
}

/// Liquid Glass only draws its clear, lensing look in a window that appears key and active;
/// anywhere else it falls back to frosted blur. Like BetterDisplay's OSDPanel, answer the
/// appearance checks (two of them private AppKit selectors) without ever becoming key, so
/// typing stays where it is. If AppKit renames them the glass just turns frosted again.
final class ActiveLookingPanel: NSPanel {
    @objc(_hasActiveAppearance) private func hasActiveAppearancePrivate() -> Bool { true }
    @objc(_hasKeyAppearance) private func hasKeyAppearancePrivate() -> Bool { true }
    @objc(hasKeyAppearance) private func appearsKey() -> Bool { true }
}
