import CoreAudio
import AppKit
import Combine

/// Thread-safe gain holder read by the realtime IOProc.
final class GainBox: @unchecked Sendable {
    private var _v: Float
    private let lock = NSLock()
    init(_ v: Float) { _v = v }
    var value: Float {
        get { lock.lock(); defer { lock.unlock() }; return _v }
        set { lock.lock(); _v = newValue; lock.unlock() }
    }
}

struct AudioApp: Identifiable {
    let pid: pid_t
    let processObjectID: AudioObjectID
    let bundleID: String
    let name: String
    let icon: NSImage?
    var gain: Float
    var id: pid_t { pid }
}

/// One active per-app volume session: taps a process (muting it at the source) and plays
/// a gain-adjusted copy to the default output. Only alive while gain < 1.0.
final class TapSession {
    let gainBox: GainBox
    /// The output the copy plays to; it doesn't follow a switch to another device.
    let outputUID: String
    private var tapID = AudioObjectID(0)
    private var aggID = AudioObjectID(0)
    private var procID: AudioDeviceIOProcID?

    convenience init?(processObjectID: AudioObjectID, gain: Float, outputUID: String) {
        let desc = CATapDescription(stereoMixdownOfProcesses: [processObjectID])
        desc.name = "ClangNotchMix"
        self.init(description: desc, gain: gain, outputUID: outputUID)
    }

    init?(description desc: CATapDescription, gain: Float, outputUID: String) {
        gainBox = GainBox(gain)
        self.outputUID = outputUID

        desc.muteBehavior = .mutedWhenTapped
        guard AudioHardwareCreateProcessTap(desc, &tapID) == noErr,
              let tapUID = AudioMixerManager.strProp(tapID, kAudioTapPropertyUID) else { return nil }

        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "ClangNotchMixAgg",
            kAudioAggregateDeviceUIDKey: "clangnotch.mix.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID]],
            kAudioAggregateDeviceTapAutoStartKey: 1,
        ]
        guard AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggID) == noErr else {
            AudioHardwareDestroyProcessTap(tapID); return nil
        }

        let box = gainBox
        let s = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, nil) { (_, inData, _, outData, _) in
            let g = box.value
            let inB = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
            let outB = UnsafeMutableAudioBufferListPointer(outData)
            let count = min(inB.count, outB.count)
            for i in 0..<count {
                guard let ip = inB[i].mData, let op = outB[i].mData else { continue }
                let n = min(Int(inB[i].mDataByteSize), Int(outB[i].mDataByteSize)) / MemoryLayout<Float>.size
                let isp = ip.bindMemory(to: Float.self, capacity: n)
                let osp = op.bindMemory(to: Float.self, capacity: n)
                for j in 0..<n { osp[j] = isp[j] * g }
            }
            if outB.count > inB.count {
                for i in inB.count..<outB.count {
                    if let op = outB[i].mData { memset(op, 0, Int(outB[i].mDataByteSize)) }
                }
            }
        }
        guard s == noErr, procID != nil else {
            AudioHardwareDestroyAggregateDevice(aggID)
            AudioHardwareDestroyProcessTap(tapID)
            return nil
        }
        AudioDeviceStart(aggID, procID)
    }

    func stop() {
        if let procID {
            AudioDeviceStop(aggID, procID)
            AudioDeviceDestroyIOProcID(aggID, procID)
        }
        if aggID != 0 { AudioHardwareDestroyAggregateDevice(aggID) }
        if tapID != 0 { AudioHardwareDestroyProcessTap(tapID) }
    }
}

@MainActor
final class AudioMixerManager: ObservableObject {
    static let shared = AudioMixerManager()

    @Published private(set) var apps: [AudioApp] = []
    /// Name of an app currently capturing the mic *while output is Bluetooth* — that's when
    /// tapping the BT output can stutter the call. We only warn (never lock); the user decides.
    /// nil when output isn't Bluetooth or nothing holds the mic.
    @Published private(set) var micHolder: String?

    private var sessions: [pid_t: TapSession] = [:]
    /// pids with a TapSession creation in flight on a background thread (see `applyGain`).
    private var pendingCreations: Set<pid_t> = []
    private var timer: Timer?

    private static let gainsKey = "audioMixerGains"
    /// Per-app volume keyed by bundleID, persisted so it survives app restarts.
    /// (pid changes every relaunch — of ClangNotch *and* the target app — so it can't be
    /// the key.) 100% isn't stored; it's the default and absence means full volume.
    private var savedGains: [String: Float] {
        get { (UserDefaults.standard.dictionary(forKey: Self.gainsKey) as? [String: Float]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.gainsKey) }
    }

    private init() {}

    func start() {
        guard !DemoMode.isActive else { return }
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        for s in sessions.values { s.stop() }
        sessions = [:]
        SoftwareVolume.shared.apply()
    }

    /// Processes with their own session. A second tap still hears a process another tap
    /// muted (measured 2026-10-14), so `SoftwareVolume`'s global tap must leave these out.
    var tappedProcessObjects: [AudioObjectID] {
        apps.filter { sessions[$0.pid] != nil }.map(\.processObjectID)
    }

    /// The software main volume moved; per-app copies bypass its global tap, so scale them too.
    func mainVolumeChanged() {
        for app in apps { sessions[app.pid]?.gainBox.value = app.gain * SoftwareVolume.shared.multiplier }
    }

    /// Warn (don't lock) when an app holds the mic while output is Bluetooth — that's when a
    /// tap can stutter the call. Speakers/wired output → no warning (tap can't touch the mic).
    private func updateMicWarning() {
        let outBT = Self.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
            .map { Self.transportType($0) == kAudioDeviceTransportTypeBluetooth } ?? false
        micHolder = outBT ? Self.micCapturingAppName() : nil
    }

    func setGain(_ gain: Float, for app: AudioApp) {
        // Demo apps aren't real processes: only the slider moves.
        if DemoMode.isActive {
            if let i = apps.firstIndex(where: { $0.pid == app.pid }) { apps[i].gain = gain }
            return
        }
        var g = savedGains
        if gain >= 0.99 { g[app.bundleID] = nil } else { g[app.bundleID] = gain }
        savedGains = g
        applyGain(gain, pid: app.pid, processObjectID: app.processObjectID)
        if let i = apps.firstIndex(where: { $0.pid == app.pid }) { apps[i].gain = gain }
    }

    /// `TapSession` creation/teardown calls blocking CoreAudio HAL APIs (process tap +
    /// aggregate device creation, which can also wait on the audio-capture TCC prompt on
    /// first use). Running that on the main thread froze the whole app whenever a volume
    /// slider was touched, so both paths are dispatched to a background task; only the
    /// `sessions`/`pendingCreations` bookkeeping happens back on the main actor.
    private func applyGain(_ gain: Float, pid: pid_t, processObjectID: AudioObjectID) {
        if let s = sessions[pid] {
            if gain >= 0.99 {
                sessions[pid] = nil
                Task.detached(priority: .userInitiated) { s.stop() }
                SoftwareVolume.shared.apply()
            } else {
                s.gainBox.value = gain * SoftwareVolume.shared.multiplier
            }
            return
        }
        guard gain < 0.99, !pendingCreations.contains(pid), let uid = Self.defaultOutputUID() else { return }
        pendingCreations.insert(pid)
        Task.detached(priority: .userInitiated) { [weak self] in
            let session = TapSession(processObjectID: processObjectID, gain: gain, outputUID: uid)
            guard let self else { session?.stop(); return }
            await MainActor.run {
                self.pendingCreations.remove(pid)
                guard let session, let app = self.apps.first(where: { $0.pid == pid }) else {
                    session?.stop()
                    return
                }
                // The user may have moved the slider back to 100% while creation was in flight.
                if app.gain >= 0.99 {
                    Task.detached(priority: .userInitiated) { session.stop() }
                } else {
                    session.gainBox.value = app.gain * SoftwareVolume.shared.multiplier
                    self.sessions[pid] = session
                    SoftwareVolume.shared.apply()
                }
            }
        }
    }

    private func refresh() {
        updateMicWarning()
        // After an output switch, drop sessions still playing to the old device; the loop
        // below rebuilds them for the new one.
        let outputUID = Self.defaultOutputUID()
        for (pid, s) in sessions where s.outputUID != outputUID {
            sessions[pid] = nil
            Task.detached(priority: .userInitiated) { s.stop() }
            SoftwareVolume.shared.apply()
        }
        let outputting = Self.outputtingProcesses()
        let saved = savedGains
        var list: [AudioApp] = []
        var livePids = Set<pid_t>()
        for (obj, pid) in outputting {
            livePids.insert(pid)
            let running = NSRunningApplication(processIdentifier: pid)
            let bundleID = Self.strProp(obj, kAudioProcessPropertyBundleID) ?? (running?.bundleIdentifier ?? "?")
            let (name, icon) = Self.appInfo(bundleID: bundleID, helper: running)
            let gain = saved[bundleID] ?? 1.0
            list.append(AudioApp(pid: pid, processObjectID: obj, bundleID: bundleID,
                                 name: name, icon: icon, gain: gain))
            // Restore a saved <100% gain once the app starts outputting again.
            if gain < 0.99 && sessions[pid] == nil {
                applyGain(gain, pid: pid, processObjectID: obj)
            }
        }
        // Tear down sessions for apps that stopped outputting / quit (keep the saved gain).
        for (pid, s) in sessions where !livePids.contains(pid) {
            s.stop(); sessions[pid] = nil
            SoftwareVolume.shared.apply()
        }
        apps = list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func shortName(_ bundleID: String) -> String {
        bundleID.split(separator: ".").last.map(String.init) ?? bundleID
    }

    /// Audio comes from helper processes (e.g. com.hnc.Discord.helper.Renderer,
    /// com.apple.WebKit.GPU). Resolve the parent/main app so we can show its real name
    /// and icon instead of the bare helper.
    private static func appInfo(bundleID: String, helper: NSRunningApplication?) -> (String, NSImage?) {
        var mainID = bundleID
        for marker in [".helper", ".Helper"] {
            if let r = bundleID.range(of: marker) { mainID = String(bundleID[..<r.lowerBound]); break }
        }
        if bundleID.contains("WebKit") { mainID = "com.apple.Safari" }  // WebKit GPU → Safari (best guess)

        let mainApp = NSRunningApplication.runningApplications(withBundleIdentifier: mainID).first
        let name = mainApp?.localizedName ?? helper?.localizedName ?? shortName(mainID)
        let icon = mainApp?.icon ?? helper?.icon
        return (name, icon)
    }

    // MARK: - Core Audio helpers (nonisolated so TapSession's init can use them)

    nonisolated static func outputtingProcesses() -> [(AudioObjectID, pid_t)] {
        let sys = AudioObjectID(kAudioObjectSystemObject)
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let selfBundle = Bundle.main.bundleIdentifier
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var sz: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(sys, &a, 0, nil, &sz) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(sz) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(sys, &a, 0, nil, &sz, &ids) == noErr else { return [] }
        return ids.compactMap { obj in
            guard boolProp(obj, kAudioProcessPropertyIsRunningOutput), let pid = pidProp(obj),
                  pid != selfPID else { return nil }
            // Exclude ClangNotch itself (its own tap playback shows up as audio output).
            if let b = strProp(obj, kAudioProcessPropertyBundleID), b == selfBundle { return nil }
            return (obj, pid)
        }
    }

    nonisolated static func boolProp(_ o: AudioObjectID, _ s: AudioObjectPropertySelector) -> Bool {
        var a = AudioObjectPropertyAddress(mSelector: s, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(o, &a) else { return false }
        var sz = UInt32(MemoryLayout<UInt32>.size); var v: UInt32 = 0
        return AudioObjectGetPropertyData(o, &a, 0, nil, &sz, &v) == noErr && v != 0
    }

    nonisolated static func pidProp(_ o: AudioObjectID) -> pid_t? {
        var a = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(o, &a) else { return nil }
        var sz = UInt32(MemoryLayout<pid_t>.size); var pid: pid_t = 0
        return AudioObjectGetPropertyData(o, &a, 0, nil, &sz, &pid) == noErr ? pid : nil
    }

    nonisolated static func strProp(_ o: AudioObjectID, _ s: AudioObjectPropertySelector) -> String? {
        var a = AudioObjectPropertyAddress(mSelector: s, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(o, &a) else { return nil }
        var sz = UInt32(MemoryLayout<CFString?>.size); var cf: Unmanaged<CFString>? = nil
        guard AudioObjectGetPropertyData(o, &a, 0, nil, &sz, &cf) == noErr, let cf else { return nil }
        return cf.takeRetainedValue() as String
    }

    /// Name of the first app capturing mic input (excluding ourselves). Resolves helper
    /// processes to their parent app (e.g. Discord renderer → "Discord").
    static func micCapturingAppName() -> String? {
        let sys = AudioObjectID(kAudioObjectSystemObject)
        let selfPID = ProcessInfo.processInfo.processIdentifier
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var sz: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(sys, &a, 0, nil, &sz) == noErr else { return nil }
        var ids = [AudioObjectID](repeating: 0, count: Int(sz) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(sys, &a, 0, nil, &sz, &ids) == noErr else { return nil }
        for obj in ids {
            guard boolProp(obj, kAudioProcessPropertyIsRunningInput),
                  let pid = pidProp(obj), pid != selfPID else { continue }
            let running = NSRunningApplication(processIdentifier: pid)
            let bundleID = strProp(obj, kAudioProcessPropertyBundleID) ?? (running?.bundleIdentifier ?? "")
            return appInfo(bundleID: bundleID, helper: running).0
        }
        return nil
    }

    nonisolated static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioObjectID? {
        let sys = AudioObjectID(kAudioObjectSystemObject)
        var a = AudioObjectPropertyAddress(mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var dev = AudioObjectID(0); var sz = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(sys, &a, 0, nil, &sz, &dev) == noErr, dev != 0 else { return nil }
        return dev
    }

    nonisolated static func transportType(_ dev: AudioObjectID) -> UInt32 {
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var t: UInt32 = 0; var sz = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(dev, &a, 0, nil, &sz, &t) == noErr else { return 0 }
        return t
    }

    nonisolated static func defaultOutputUID() -> String? {
        let sys = AudioObjectID(kAudioObjectSystemObject)
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var dev = AudioObjectID(0); var sz = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(sys, &a, 0, nil, &sz, &dev) == noErr else { return nil }
        return strProp(dev, kAudioDevicePropertyDeviceUID)
    }
}

// MARK: - Demo

extension AudioMixerManager {
    /// `--demo`: made-up apps with no audio taps behind them.
    func demoApply(_ apps: [AudioApp]) {
        self.apps = apps
    }
}
