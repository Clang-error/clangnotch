import AppKit
import AudioToolbox
import Combine
import os

/// 설정 › 실험 기능 › "입력 효과음": a sound for every key and mouse button that goes down,
/// macOS's auto-repeat included, from sound files of the user's own. None ships with the app:
/// up to five files in `packFolder`, read when the switch turns on.
///
/// The keys are only listened to, on a thread of their own, so nothing here can hold typing
/// up; which key it was decides the sound and is neither kept nor logged. A shortcut of the
/// user's choosing turns the switch off and on (`TypingSoundShortcut`), and the 복사 방울
/// says which.
///
/// With "헤드폰·이어폰일 때만" on, the keys are listened to only while the sound goes to
/// headphones (`TypingSoundOutputKind`), so nothing comes out of speakers or a monitor. Nor
/// are they while the output is muted or turned all the way down: nothing would be heard, and
/// the output would still be kept up for it.
@MainActor
final class TypingSounds: ObservableObject {
    static let shared = TypingSounds()

    /// `paused`: not listening, for the output it is on or because that is silent.
    enum Status { case off, on, noPack, noPermission, paused }
    @Published private(set) var status = Status.off
    /// The sound output while it is one "헤드폰·이어폰일 때만" can't tell the kind of, a USB
    /// device say: 설정 then shows a switch to let it in.
    @Published private(set) var askedOutput: (uid: String, name: String)?

    /// `~/Library/Application Support/ClangNotch/TypingSounds`, holding `letter.wav`,
    /// `punctuation.wav`, `space.wav`, `special.wav` and `mouse.wav`. A kind without its file
    /// is silent.
    static let packFolder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ClangNotch/TypingSounds", isDirectory: true)

    private let mixer = TypingSoundMixer()
    private lazy var output = TypingSoundOutput(mixer: mixer)
    /// Turned on or off by the shortcut, for the drop that says so (`ClipboardOrbView`).
    let toggled = PassthroughSubject<Bool, Never>()

    private var input: TypingSoundInput?
    private let shortcut = TypingSoundShortcut()
    private var outputListener: AudioObjectPropertyListenerBlock?
    /// The output whose mute and volume are listened to.
    private var levelWatch: (device: AudioObjectID, listener: AudioObjectPropertyListenerBlock)?

    private init() {
        shortcut.pressed = { [weak self] in self?.toggle() }
    }

    /// Takes the shortcut set in 설정, or lets it go. False when macOS won't give it. Not in a
    /// demo copy: beside the installed one the key would turn the switch twice.
    @discardableResult
    func syncShortcut() -> Bool {
        let settings = AppSettings.shared
        return shortcut.register(key: DemoMode.isActive ? -1 : settings.experimentalTypingSoundsShortcutKey,
                                 modifiers: UInt(settings.experimentalTypingSoundsShortcutModifiers))
    }

    /// While 설정 records a new one, the old one must reach it as keys.
    func releaseShortcut() {
        shortcut.register(key: -1, modifiers: 0)
    }

    private func toggle() {
        let on = !AppSettings.shared.experimentalTypingSounds
        AppSettings.shared.experimentalTypingSounds = on
        syncWithSettings()
        toggled.send(on)
    }

    func syncWithSettings() {
        syncShortcut()
        // A demo copy beside the installed one would sound every key twice.
        guard AppSettings.shared.experimentalTypingSounds, !DemoMode.isActive else {
            stop()
            status = .off
            return
        }
        var loaded = 0
        for kind in TypingSoundKind.allCases {
            let sound = Self.read(Self.packFolder.appendingPathComponent(kind.fileName + ".wav"))
            mixer.set(kind, left: sound?.left ?? [], right: sound?.right ?? [])
            if sound != nil { loaded += 1 }
        }
        guard loaded > 0 else {
            stop()
            status = .noPack
            return
        }
        mixer.gain = SoftwareVolume.shared.multiplier
        applyVolumes()
        watchOutput(true)
        listen()
    }

    /// Starts listening to the keys, or stops where nothing is to be heard: the output is
    /// silent, or with "헤드폰·이어폰일 때만" on isn't headphones. The tap goes, and the output
    /// with it, so a sound in the air ends there.
    private func listen() {
        let headphonesOnly = AppSettings.shared.experimentalTypingSoundsHeadphonesOnly
        let device = Self.currentOutput()
        watchLevel(of: device?.id)
        let asked = headphonesOnly && device?.kind == .unknown ? device : nil
        if asked?.uid != askedOutput?.uid { askedOutput = asked.map { ($0.uid, $0.name) } }
        // No output at all is no reason to stop: the switch off, the sounds follow any output.
        let plays = (device?.kind ?? .speakers).plays(headphonesOnly: headphonesOnly,
                                                       allowed: device.map { allows($0.uid) } ?? false)
        let silent = mixer.gain <= 0 || device.map { Self.isSilent($0.id) } ?? false
        guard plays, !silent else {
            input?.stop()
            output.stop()
            if status != .paused { status = .paused }
            return
        }
        let input = self.input ?? TypingSoundInput(mixer: mixer, output: output)
        guard input.start() else {
            // Accessibility covers a listen-only tap; without either permission macOS asks here.
            CGRequestListenEventAccess()
            status = .noPermission
            return
        }
        self.input = input
        if status != .on { status = .on }
    }

    /// Muted, or turned all the way down, by a control macOS has for it. An output without
    /// one (a monitor) is turned down by 모니터 소리 줄이기, which is in the mixer's gain.
    private static func isSilent(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                                 mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var settable: DarwinBoolean = false
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue,
           AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted) == noErr, muted != 0 {
            return true
        }
        address.mSelector = kAudioHardwareServiceDeviceProperty_VirtualMainVolume
        var volume: Float32 = 1
        size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
            && AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume) == noErr && volume <= 0
    }

    /// Hears of `device`'s mute and volume changing, and no longer of the one before.
    private func watchLevel(of device: AudioObjectID?) {
        guard device != levelWatch?.device else { return }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                                 mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        let selectors = [kAudioDevicePropertyMute, kAudioHardwareServiceDeviceProperty_VirtualMainVolume]
        if let (old, listener) = levelWatch {
            for selector in selectors {
                address.mSelector = selector
                AudioObjectRemovePropertyListenerBlock(old, &address, .main, listener)
            }
            levelWatch = nil
        }
        guard let device else { return }
        let listener: AudioObjectPropertyListenerBlock = { _, _ in
            Task { @MainActor in TypingSounds.shared.outputChanged() }
        }
        for selector in selectors {
            address.mSelector = selector
            AudioObjectAddPropertyListenerBlock(device, &address, .main, listener)
        }
        levelWatch = (device, listener)
    }

    /// The default output: its UID, its name as macOS shows it, and what it is.
    private static func currentOutput() -> (id: AudioObjectID, uid: String, name: String, kind: TypingSoundOutputKind)? {
        guard let device = AudioMixerManager.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice),
              let uid = AudioMixerManager.strProp(device, kAudioDevicePropertyDeviceUID) else { return nil }
        // The headphone jack is a device of its own on Apple silicon, and the built-in
        // device's data source ('hdpn') on older Macs.
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDataSource,
                                                 mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var source: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let jack = uid == "BuiltInHeadphoneOutputDevice"
            || (AudioObjectGetPropertyData(device, &address, 0, nil, &size, &source) == noErr && source == 0x6864_706E)
        return (device, uid, AudioMixerManager.strProp(device, kAudioObjectPropertyName) ?? uid,
                TypingSoundOutputKind(transport: AudioMixerManager.transportType(device), jack: jack))
    }

    /// Whether the user let the output `uid` in under "헤드폰·이어폰일 때만".
    func allows(_ uid: String) -> Bool {
        AppSettings.shared.experimentalTypingSoundsAllowedOutputs.split(separator: "\n").contains { $0 == uid }
    }

    func allow(_ uid: String, _ allowed: Bool) {
        var uids = AppSettings.shared.experimentalTypingSoundsAllowedOutputs.split(separator: "\n").map(String.init)
        uids.removeAll { $0 == uid }
        if allowed { uids.append(uid) }
        AppSettings.shared.experimentalTypingSoundsAllowedOutputs = uids.joined(separator: "\n")
        outputChanged()
    }

    private static var defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)

    /// Hears of the sound output changing, while the sounds are on.
    private func watchOutput(_ watch: Bool) {
        let system = AudioObjectID(kAudioObjectSystemObject)
        if watch, outputListener == nil {
            let listener: AudioObjectPropertyListenerBlock = { _, _ in
                Task { @MainActor in TypingSounds.shared.outputChanged() }
            }
            guard AudioObjectAddPropertyListenerBlock(system, &Self.defaultOutputAddress, .main, listener) == noErr
            else { return }
            outputListener = listener
        } else if !watch, let listener = outputListener {
            AudioObjectRemovePropertyListenerBlock(system, &Self.defaultOutputAddress, .main, listener)
            outputListener = nil
        }
    }

    private func outputChanged() {
        // Without a sound or the permission there is nothing to start, and no reason to ask again.
        guard outputListener != nil, status == .on || status == .paused else { return }
        listen()
    }

    /// ClangNotch's own sound doesn't pass through 모니터 소리 줄이기's tap, so its level is
    /// applied here.
    func setGain(_ gain: Float) {
        let silent = mixer.gain <= 0
        mixer.gain = gain
        if silent != (gain <= 0) { outputChanged() }
    }

    /// "키보드 소리 크기" for the four key sounds and "클릭 소리 크기" for the mouse's.
    func applyVolumes() {
        let keys = Float(AppSettings.shared.experimentalTypingSoundsKeyVolume)
        let mouse = Float(AppSettings.shared.experimentalTypingSoundsMouseVolume)
        for kind in TypingSoundKind.allCases {
            mixer.setLevel(kind == .mouse ? mouse : keys, for: kind)
        }
    }

    /// Plays `kind` once, for a slider that was just let go. Nothing while the sounds are off.
    func preview(_ kind: TypingSoundKind) {
        guard status == .on else { return }
        mixer.trigger(kind)
        output.touch()
    }

    func openPackFolder() {
        try? FileManager.default.createDirectory(at: Self.packFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Self.packFolder)
    }

    private func stop() {
        watchOutput(false)
        watchLevel(of: nil)
        askedOutput = nil
        input?.stop()
        input = nil
        output.stop()
    }

    /// The file's sound as the output plays it (48 kHz, two channels), up to 10 seconds of it.
    private static func read(_ url: URL) -> (left: [Float], right: [Float])? {
        var opened: ExtAudioFileRef?
        guard ExtAudioFileOpenURL(url as CFURL, &opened) == noErr, let file = opened else { return nil }
        defer { ExtAudioFileDispose(file) }
        var format = TypingSoundOutput.format
        guard ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat,
                                      UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &format) == noErr
        else { return nil }

        let chunk = 4096
        let limit = Int(format.mSampleRate) * 10
        let l = UnsafeMutablePointer<Float>.allocate(capacity: chunk)
        let r = UnsafeMutablePointer<Float>.allocate(capacity: chunk)
        let buffers = AudioBufferList.allocate(maximumBuffers: 2)
        defer { l.deallocate(); r.deallocate(); free(buffers.unsafeMutablePointer) }
        var left = [Float](), right = [Float]()
        while left.count < limit {
            let bytes = UInt32(chunk * MemoryLayout<Float>.size)
            buffers[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes, mData: l)
            buffers[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes, mData: r)
            var frames = UInt32(chunk)
            guard ExtAudioFileRead(file, &frames, buffers.unsafeMutablePointer) == noErr, frames > 0 else { break }
            left.append(contentsOf: UnsafeBufferPointer(start: l, count: Int(frames)))
            right.append(contentsOf: UnsafeBufferPointer(start: r, count: Int(frames)))
        }
        return left.isEmpty ? nil : (left, right)
    }
}

/// The default output unit, which follows the system's output device. It runs only around
/// the sounds: a running output keeps the audio device up and the Mac from idle sleep
/// (coreaudiod holds the assertion), so it starts on a key and stops after `idle` of none.
/// Starting takes 0.1 to 0.2 s (HDMI, 2026-11-16), which the first sound after a stop comes
/// late by, so it stays up through pauses in typing.
final class TypingSoundOutput {
    /// 48 kHz, two channels, each in a buffer of its own.
    static let format = AudioStreamBasicDescription(
        mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
        mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 32,
        mReserved: 0)
    private static let idle: UInt64 = 120_000_000_000

    private let mixer: TypingSoundMixer
    private let queue = DispatchQueue(label: "com.clangerror.ClangNotch.typing-sounds")
    /// When a sound was last started, and whether the unit is up or on its way up.
    private let touched = OSAllocatedUnfairLock(initialState: (last: UInt64(0), up: false))
    // Both on `queue`.
    private var unit: AudioUnit?
    private var timer: DispatchSourceTimer?

    init(mixer: TypingSoundMixer) {
        self.mixer = mixer
    }

    /// A sound was just started. Called for every key, so it only notes the time unless the
    /// unit has to come up.
    func touch() {
        let start = touched.withLock { state -> Bool in
            state.last = DispatchTime.now().uptimeNanoseconds
            if state.up { return false }
            state.up = true
            return true
        }
        if start { queue.async { self.start() } }
    }

    func stop() {
        queue.async {
            self.touched.withLock { $0.up = false }
            self.halt()
            if let unit = self.unit {
                AudioUnitUninitialize(unit)
                AudioComponentInstanceDispose(unit)
                self.unit = nil
            }
        }
    }

    private func start() {
        if unit == nil { unit = Self.makeUnit(for: mixer) }
        guard let unit, AudioOutputUnitStart(unit) == noErr else {
            touched.withLock { $0.up = false }
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in self?.stopIfIdle() }
        timer.resume()
        self.timer = timer
    }

    private func stopIfIdle() {
        guard !mixer.isPlaying else { return }
        let idle = touched.withLock { state -> Bool in
            guard DispatchTime.now().uptimeNanoseconds - state.last > Self.idle else { return false }
            state.up = false
            return true
        }
        if idle { halt() }
    }

    private func halt() {
        timer?.cancel()
        timer = nil
        if let unit { AudioOutputUnitStop(unit) }
    }

    private static func makeUnit(for mixer: TypingSoundMixer) -> AudioUnit? {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_DefaultOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { return nil }
        var made: AudioUnit?
        guard AudioComponentInstanceNew(component, &made) == noErr, let unit = made else { return nil }
        var format = Self.format
        var callback = AURenderCallbackStruct(
            inputProc: { context, _, _, _, frames, data in
                guard let data else { return noErr }
                let buffers = UnsafeMutableAudioBufferListPointer(data)
                guard buffers.count == 2, let left = buffers[0].mData, let right = buffers[1].mData else { return noErr }
                Unmanaged<TypingSoundMixer>.fromOpaque(context).takeUnretainedValue()
                    .render(left: left.assumingMemoryBound(to: Float.self),
                            right: right.assumingMemoryBound(to: Float.self), frames: Int(frames))
                return noErr
            },
            inputProcRefCon: Unmanaged.passUnretained(mixer).toOpaque())
        guard AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format,
                                   UInt32(MemoryLayout<AudioStreamBasicDescription>.size)) == noErr,
              AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback,
                                   UInt32(MemoryLayout<AURenderCallbackStruct>.size)) == noErr,
              AudioUnitInitialize(unit) == noErr
        else {
            AudioComponentInstanceDispose(unit)
            return nil
        }
        return unit
    }
}

/// A listen-only tap for key and mouse-button presses, on a thread of its own: the main
/// thread isn't woken for every key, and a busy main thread doesn't delay the sound.
final class TypingSoundInput {
    private let mixer: TypingSoundMixer
    private let output: TypingSoundOutput
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    init(mixer: TypingSoundMixer, output: TypingSoundOutput) {
        self.mixer = mixer
        self.output = output
    }

    /// False when macOS refuses the tap (no permission). Already listening, it stays as it is.
    func start() -> Bool {
        guard tap == nil else { return true }
        // No `.flagsChanged`: the modifiers make no sound.
        let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | 1 << $1.rawValue }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: mask,
            callback: { _, type, event, context in
                if let context {
                    Unmanaged<TypingSoundInput>.fromOpaque(context).takeUnretainedValue().handle(type, event)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        else { return false }
        self.tap = tap
        let ready = DispatchSemaphore(value: 0)
        // The thread holds on to `self` until its run loop stops, past a callback still running.
        let thread = Thread { [self] in
            runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(runLoop, source, .commonModes)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "TypingSounds"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
        if let runLoop { CFRunLoopStop(runLoop) }
        self.tap = nil
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .keyDown:
            play(.forKey(Int(event.getIntegerValueField(.keyboardEventKeycode))))
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            play(.mouse)
        default:
            break
        }
    }

    private func play(_ kind: TypingSoundKind) {
        mixer.trigger(kind)
        output.touch()
    }
}
