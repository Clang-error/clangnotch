import AppKit
import AudioToolbox
import CoreAudio

/// Volume for outputs macOS can't turn down — HDMI/DisplayPort audio to a monitor's speaker
/// jack. Their driver has no volume or mute control at all (read off `DCPAVAudioDriver`,
/// 2026-10-14) and the V28UE ignores DDC/CI, so the only way is to turn the sound down before
/// it leaves: one global process tap mutes everything at the source and plays a scaled copy.
///
/// While the sound goes to such a device, ClangNotch takes the volume and mute keys itself
/// (an HID-level event tap, ahead of macOS and other apps) and shows the 조절창; for any
/// other output, and for brightness, the same tap hands the keys to `SystemControlOSD` while
/// 볼륨·밝기 표시 바꾸기 is on, and lets them through to macOS while it is off. At 100% there is no audio tap at all. Below that the tap stays up even through silence: starting it when sound
/// begins would let the first buffers out at full volume. If ClangNotch dies, macOS drops the
/// tap and the sound comes back at 100%.
@MainActor
final class SoftwareVolume {
    static let shared = SoftwareVolume()

    private static let levelsKey = "softwareVolumeLevels"
    /// Last level per output UID, so a restart doesn't come back at full volume.
    private var levels: [String: Double] {
        get { (UserDefaults.standard.dictionary(forKey: Self.levelsKey) as? [String: Double]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.levelsKey) }
    }
    private var muted = false
    private var running = false

    private var session: TapSession?
    /// What `session` was built for; a change means a new tap.
    private var sessionKey: String?
    private var building = false
    /// A tap that couldn't be made isn't retried for the same setup (no permission, say).
    private var failedKey: String?
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var keyTap: CFMachPort?
    private var keyTapSource: CFRunLoopSource?
    /// The output the keys are taken for, kept current by `apply()` so the key tap can decide
    /// without asking CoreAudio on every event.
    private var keyTarget: String?

    private init() {}

    /// Gain on the samples: the level squared, close to how macOS's own volume falls off
    /// (linear amplitude makes 50% only −6 dB). 1 while there is nothing to turn down.
    var multiplier: Float {
        guard running, AppSettings.shared.enableSoftwareVolume, let uid = Self.uncontrollableOutputUID() else { return 1 }
        if muted { return 0 }
        let level = Float(levels[uid] ?? 1)
        return level * level
    }

    func start() {
        guard !running else { return }
        running = true
        let listener: AudioObjectPropertyListenerBlock = { _, _ in
            Task { @MainActor in SoftwareVolume.shared.apply() }
        }
        var address = Self.defaultOutputAddress
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        // Helpers of excluded apps that start later must be left out of the tap too.
        var processes = Self.processListAddress
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &processes, .main, listener)
        deviceListener = listener
        startKeyTap()
        apply()
    }

    /// The key tap serves two switches, 볼륨·밝기 표시 바꾸기 and 모니터 소리 줄이기; either one
    /// keeps it up. Also brings back a tap that couldn't be made before Accessibility was allowed.
    func syncWithSettings() {
        let settings = AppSettings.shared
        guard settings.centerSystemBanners || settings.enableSoftwareVolume else {
            stop()
            return
        }
        start()
        startKeyTap()
        apply()
    }

    func stop() {
        guard running else { return }
        running = false
        if let deviceListener {
            var address = Self.defaultOutputAddress
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, deviceListener)
            var processes = Self.processListAddress
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &processes, .main, deviceListener)
        }
        deviceListener = nil
        stopKeyTap()
        apply()
    }

    // MARK: - Keys

    private static let soundUp = 0, soundDown = 1, mute = 7  // NX_KEYTYPE_*
    private static let step = 1.0 / 16

    /// A volume or mute key went down (or repeated) while the sound goes to `uid`.
    private func pressed(_ key: Int, for uid: String) {
        var level = levels[uid] ?? 1
        switch key {
        case Self.soundUp, Self.soundDown:
            let steps = (level / Self.step).rounded() + (key == Self.soundUp ? 1 : -1)
            level = min(max(steps * Self.step, 0), 1)
            levels[uid] = level
            muted = false
        default:
            muted.toggle()
        }
        apply()
        SystemControlOSD.shared.showSoftwareVolume(level: level, muted: muted)
    }

    private func startKeyTap() {
        guard keyTap == nil else { return }
        let mask = CGEventMask(1 << NX_SYSDEFINED)
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, _ in
                // Main run loop, so on the main thread.
                MainActor.assumeIsolated { SoftwareVolume.shared.handle(type, event) }
            },
            userInfo: nil
        ) else {
            debugLog("[SoftwareVolume] key tap failed (Accessibility?)")
            return
        }
        guard let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
            CFMachPortInvalidate(tap)
            return
        }
        keyTap = tap
        keyTapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func stopKeyTap() {
        if let keyTap { CGEvent.tapEnable(tap: keyTap, enable: false); CFMachPortInvalidate(keyTap) }
        if let keyTapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), keyTapSource, .commonModes) }
        keyTap = nil
        keyTapSource = nil
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let keyTap { CGEvent.tapEnable(tap: keyTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        // Media keys: subtype 8, key in the high half of data1, 0xA down / 0xB up after it.
        guard let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else {
            return Unmanaged.passUnretained(event)
        }
        let key = (ns.data1 & 0xFFFF_0000) >> 16
        let isDown = (ns.data1 & 0xFF00) >> 8 == 0xA
        let isRepeat = ns.data1 & 0x1 != 0
        // A running Key Test takes every key, these too: lit, not applied.
        if KeyTester.shared.mediaKey(key, isDown: isDown) { return nil }
        guard let uid = keyTarget, [Self.soundUp, Self.soundDown, Self.mute].contains(key) else {
            // Outputs and displays macOS can set itself: with 볼륨·밝기 표시 바꾸기 on the 조절창
            // sets them, so no system banner; off, the key goes to macOS as usual.
            guard AppSettings.shared.centerSystemBanners else { return Unmanaged.passUnretained(event) }
            let fine = ns.modifierFlags.isSuperset(of: [.option, .shift])
            return SystemControlOSD.shared.handleKey(key, isDown: isDown, isRepeat: isRepeat, fine: fine)
                ? nil : Unmanaged.passUnretained(event)
        }
        if isDown && (key != Self.mute || !isRepeat) { pressed(key, for: uid) }
        return nil
    }

    /// Brings the tap in line with the output device, the level and the per-app sessions.
    func apply() {
        // Switched off, these outputs' keys go the normal way (macOS shows it can't change them).
        keyTarget = running && AppSettings.shared.enableSoftwareVolume ? Self.uncontrollableOutputUID() : nil
        AudioMixerManager.shared.mainVolumeChanged()
        let gain = multiplier
        guard gain < 0.99, let uid = keyTarget, let me = Self.ownProcessObject() else {
            if let session {
                // After a switch to another output, apps take a moment to move over, and
                // whatever still reaches this device would come out at 100% without the tap.
                let switchedAway = sessionKey?.hasPrefix(keyTarget ?? "-") != true
                self.session = nil
                sessionKey = nil
                Task.detached(priority: .userInitiated) {
                    if switchedAway { try? await Task.sleep(for: .seconds(1)) }
                    session.stop()
                }
            }
            return
        }

        let excluded = [me] + AudioMixerManager.shared.tappedProcessObjects + Self.excludedAppProcessObjects()
        let key = uid + excluded.map(String.init).joined(separator: ",")
        if let session, key == sessionKey {
            session.gainBox.value = gain
            return
        }
        guard !building, key != failedKey else { return }
        building = true
        Task.detached(priority: .userInitiated) {
            // Only audio headed for this device: a global tap would also mute what apps send to
            // other outputs, e.g. Echoless writing the cleaned mic into BlackHole for Discord.
            let description = CATapDescription(excludingProcesses: excluded, deviceUID: uid, stream: 0)
            description.name = "ClangNotchSoftwareVolume"
            let fresh = TapSession(description: description, gain: gain, outputUID: uid)
            await MainActor.run {
                let shared = SoftwareVolume.shared
                shared.building = false
                // Swap new for old so nothing slips out unmuted in between.
                let old = shared.session
                shared.session = fresh
                shared.sessionKey = fresh == nil ? nil : key
                if let old { Task.detached(priority: .userInitiated) { old.stop() } }
                guard fresh != nil else {
                    shared.failedKey = key
                    debugLog("[SoftwareVolume] tap failed for \(uid)")
                    return
                }
                shared.apply()
            }
        }
    }

    // MARK: - Core Audio

    private static var defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)

    private static var processListAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)

    /// Processes of the apps excluded in Settings stay out of the tap. A replayed copy comes
    /// from ClangNotch, so e.g. Discord's Go Live (system audio minus Discord's own) streamed
    /// friends' voices (2026-11-09). Those apps are then turned with their own volume.
    private static func excludedAppProcessObjects() -> [AudioObjectID] {
        let prefixes = AppSettings.shared.softwareVolumeExcludedApps.split(separator: "\n").map(String.init)
        guard !prefixes.isEmpty else { return [] }
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = processListAddress
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter { obj in
            guard let bundleID = AudioMixerManager.strProp(obj, kAudioProcessPropertyBundleID) else { return false }
            return prefixes.contains { bundleID == $0 || bundleID.hasPrefix($0 + ".") }
        }
    }

    /// UID of the default output when it has no volume control of its own.
    private static func uncontrollableOutputUID() -> String? {
        guard let device = AudioMixerManager.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) else { return nil }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                                 mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        // HDMI answers "has" for the virtual volume but won't let it be set.
        var settable: DarwinBoolean = false
        guard AudioHardwareServiceIsPropertySettable(device, &address, &settable) != noErr || !settable.boolValue
        else { return nil }
        return AudioMixerManager.strProp(device, kAudioDevicePropertyDeviceUID)
    }

    /// ClangNotch's own audio process. Its replayed copies are output too, so the global tap
    /// must leave it out or it would tap itself.
    private static func ownProcessObject() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var pid = ProcessInfo.processInfo.processIdentifier
        var object = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != 0 ? object : nil
    }
}
