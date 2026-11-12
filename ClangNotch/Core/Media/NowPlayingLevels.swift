import Accelerate
import Combine
import CoreAudio
import Foundation
import os

/// The 음파 막대 follow the sound of what plays: a read-only Core Audio tap on the process that
/// makes it (the Now Playing client's pid, Safari's WebKit.GPU for a video), six bands from an
/// FFT, 20 times a second.
///
/// Read-only, unlike the per-app volume's tap: the process keeps playing as before (unmuted) and
/// the tap's aggregate device has no output device, so nothing is sent to the speakers or the
/// headphones. The volume tap broke another app's Bluetooth microphone once real audio went
/// through it to AirPods (2026-08-08), so while the output is Bluetooth and an app holds the
/// microphone this tap isn't made at all and the bars bounce by themselves.
@MainActor
final class NowPlayingLevels {
    static let shared = NowPlayingLevels()

    /// Six levels 0…1 (low to high), or nil while nothing is read (the bars then animate by themselves).
    let bands = CurrentValueSubject<[Float]?, Never>(nil)

    private var tap: LevelTap?
    private var pid: pid_t?
    private var generation = 0
    private var guardTimer: Timer?
    private let queue = DispatchQueue(label: "com.clangerror.ClangNotch.levels", qos: .userInitiated)
    nonisolated static let log = Logger(subsystem: "com.clangerror.ClangNotch", category: "NowPlayingLevels")

    private init() {}

    /// Called with every change of what plays.
    func follow(_ playing: NowPlaying?) {
        guard let playing, playing.isPlaying, let pid = playing.pid,
              AppSettings.shared.enableNowPlaying, AppSettings.shared.enableNowPlayingLevels,
              !DemoMode.isActive, Self.isSafe else {
            stop()
            return
        }
        guard pid != self.pid else { return }
        stop()
        self.pid = pid
        generation += 1
        let mine = generation
        // Making a tap can wait on the audio capture permission prompt: off the main thread.
        queue.async { [queue] in
            let made = LevelTap(pid: pid, queue: queue) { levels in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard NowPlayingLevels.shared.generation == mine else { return }
                        NowPlayingLevels.shared.bands.send(levels)
                    }
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let levels = NowPlayingLevels.shared
                    guard levels.generation == mine, let made else {
                        if let made { queue.async { made.stop() } }
                        return
                    }
                    levels.tap = made
                    levels.startGuard()
                }
            }
        }
    }

    func stop() {
        generation += 1
        guardTimer?.invalidate()
        guardTimer = nil
        if let tap { queue.async { tap.stop() } }
        tap = nil
        pid = nil
        if bands.value != nil { bands.send(nil) }
    }

    /// A call can start on AirPods while music plays: look again every few seconds.
    private func startGuard() {
        guardTimer?.invalidate()
        guardTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard !NowPlayingLevels.isSafe else { return }
                NowPlayingLevels.log.info("Bluetooth output with the mic in use: levels off")
                NowPlayingLevels.shared.stop()
            }
        }
    }

    private static var isSafe: Bool {
        guard let output = AudioMixerManager.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) else { return true }
        let transport = AudioMixerManager.transportType(output)
        let bluetooth = transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
        return !bluetooth || AudioMixerManager.micCapturingAppName() == nil
    }
}

/// One tap and its aggregate device, reading only.
final class LevelTap {
    private var tapID = AudioObjectID(0)
    private var aggID = AudioObjectID(0)
    private var procID: AudioDeviceIOProcID?

    init?(pid: pid_t, queue: DispatchQueue, onLevels: @escaping ([Float]) -> Void) {
        var process = AudioObjectID(0)
        var pidValue = pid
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                         UInt32(MemoryLayout<pid_t>.size), &pidValue, &size, &process) == noErr,
              process != 0 else {
            NowPlayingLevels.log.info("pid \(pid) plays no audio of its own")
            return nil
        }
        let description = CATapDescription(stereoMixdownOfProcesses: [process])
        description.name = "ClangNotchLevels"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        let status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr, let tapUID = AudioMixerManager.strProp(tapID, kAudioTapPropertyUID) else {
            NowPlayingLevels.log.error("tap not made (\(status)); audio capture may not be allowed")
            return nil
        }
        // No sub-device: nothing is played anywhere, only the tap is read.
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "ClangNotchLevelsAgg",
            kAudioAggregateDeviceUIDKey: "clangnotch.levels.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: 1]],
            kAudioAggregateDeviceTapAutoStartKey: 1,
        ]
        guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggID) == noErr else {
            AudioHardwareDestroyProcessTap(tapID)
            NowPlayingLevels.log.error("aggregate device not made")
            return nil
        }
        let analyzer = LevelAnalyzer(sampleRate: Self.sampleRate(of: aggID))
        var first = true
        let made = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, queue) { _, input, _, _, _ in
            if first { first = false; NowPlayingLevels.log.info("first audio from pid \(pid)") }
            if let levels = analyzer.push(UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))) {
                onLevels(levels)
            }
        }
        guard made == noErr, procID != nil, AudioDeviceStart(aggID, procID) == noErr else {
            stop()
            NowPlayingLevels.log.error("levels didn't start")
            return nil
        }
        NowPlayingLevels.log.info("reading levels of pid \(pid)")
    }

    func stop() {
        if let procID {
            AudioDeviceStop(aggID, procID)
            AudioDeviceDestroyIOProcID(aggID, procID)
        }
        procID = nil
        if aggID != 0 { AudioHardwareDestroyAggregateDevice(aggID) }
        if tapID != 0 { AudioHardwareDestroyProcessTap(tapID) }
        aggID = 0
        tapID = 0
    }

    private static func sampleRate(of device: AudioObjectID) -> Double {
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr && rate > 0 ? rate : 48_000
    }
}

/// Six bands from a 1024-point FFT of the mono mix, each against its own recent average so
/// quiet and loud songs both move the bars with their beat, quick to rise and quick to fall.
final class LevelAnalyzer {
    private static let log2n: vDSP_Length = 10
    private static let size = 1 << 10
    static let bandCount = 6
    private static let edges: [Double] = [60, 180, 500, 1_200, 3_000, 6_500, 14_000]

    private let setup: FFTSetup
    private let hop: Int
    private let bins: [Range<Int>]
    private var ring = [Float](repeating: 0, count: size)
    private var write = 0
    private var sinceLast = 0
    private var window = [Float](repeating: 0, count: size)
    private var frame = [Float](repeating: 0, count: size)
    private var real = [Float](repeating: 0, count: size / 2)
    private var imag = [Float](repeating: 0, count: size / 2)
    private var power = [Float](repeating: 0, count: size / 2)
    private var mono = [Float](repeating: 0, count: 4096)
    private var peaks = [Float](repeating: 1e-6, count: bandCount)
    private var shown = [Float](repeating: 0, count: bandCount)
    private var overallAverage: Float = 0

    init(sampleRate: Double) {
        setup = vDSP_create_fftsetup(Self.log2n, FFTRadix(kFFTRadix2))!
        hop = Int(sampleRate / 20)
        let binWidth = sampleRate / Double(Self.size)
        bins = (0..<Self.bandCount).map { band in
            let low = max(1, Int(Self.edges[band] / binWidth))
            let high = max(low + 1, min(Self.size / 2, Int(Self.edges[band + 1] / binWidth)))
            return low..<high
        }
        vDSP_hann_window(&window, vDSP_Length(Self.size), Int32(vDSP_HANN_NORM))
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// New audio; levels every 50 ms (20 a second: 30 cost a percent more for no visible gain). vDSP does the per-sample work: Swift loops over
    /// 96,000 samples a second cost several percent of a core in a debug build.
    func push(_ buffers: UnsafeMutableAudioBufferListPointer) -> [Float]? {
        guard let buffer = buffers.first, let data = buffer.mData else { return nil }
        let channels = max(1, Int(buffer.mNumberChannels))
        let frames = min(Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channels, mono.count)
        guard frames > 0 else { return nil }
        let samples = data.bindMemory(to: Float.self, capacity: frames * channels)
        mono.withUnsafeMutableBufferPointer { out in
            let dest = out.baseAddress!
            if channels >= 2 {
                vDSP_vadd(samples, vDSP_Stride(channels), samples + 1, vDSP_Stride(channels), dest, 1, vDSP_Length(frames))
                var half: Float = 0.5
                vDSP_vsmul(dest, 1, &half, dest, 1, vDSP_Length(frames))
            } else {
                dest.update(from: samples, count: frames)
            }
            ring.withUnsafeMutableBufferPointer { ringPtr in
                var copied = 0
                while copied < frames {
                    let run = min(frames - copied, Self.size - write)
                    (ringPtr.baseAddress! + write).update(from: dest + copied, count: run)
                    write = (write + run) & (Self.size - 1)
                    copied += run
                }
            }
        }
        sinceLast += frames
        guard sinceLast >= hop else { return nil }
        sinceLast = 0
        return analyze()
    }

    private func analyze() -> [Float] {
        let n = Self.size
        // Oldest first: the ring from `write` on, then its start.
        ring.withUnsafeBufferPointer { ringPtr in
            frame.withUnsafeMutableBufferPointer { framePtr in
                let tail = n - write
                framePtr.baseAddress!.update(from: ringPtr.baseAddress! + write, count: tail)
                (framePtr.baseAddress! + tail).update(from: ringPtr.baseAddress!, count: write)
            }
        }
        vDSP_vmul(frame, 1, window, 1, &frame, 1, vDSP_Length(n))
        real.withUnsafeMutableBufferPointer { realPtr in
            imag.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                frame.withUnsafeBufferPointer { framePtr in
                    framePtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, Self.log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(n / 2))
            }
        }
        var levels = [Float](repeating: 0, count: Self.bandCount)
        // The whole sound's beat too, so every bar lifts with a kick, not only the low ones.
        var overall: Float = 0
        power.withUnsafeBufferPointer { vDSP_meanv($0.baseAddress! + 1, 1, &overall, vDSP_Length(Self.size / 2 - 1)) }
        overallAverage = overallAverage <= 1e-9 ? overall : overallAverage + (overall - overallAverage) * 0.08
        let beat: Float = overall < 1e-8 ? 0 : min(1, max(0, 0.5 + log2(max(overall / max(overallAverage, 1e-9), 1e-3)) / 2.4))
        for band in 0..<Self.bandCount {
            let range = bins[band]
            var mean: Float = 0
            power.withUnsafeBufferPointer { vDSP_meanv($0.baseAddress! + range.lowerBound, 1, &mean, vDSP_Length(range.count)) }
            // Each band against its own average of the last second or so, on a log scale, a
            // third of it the whole sound's beat: a beat springs the bars up, the gap after it
            // drops them, a held sound sits halfway. Against the recent loudest (before) a song
            // that stayed loud kept the bars near the top, moving a little (user, 2026-11-12).
            // On a synthetic drum loop the held-pad band now moves 0.32 of its height, was 0.07.
            peaks[band] = peaks[band] <= 1e-6 ? mean : peaks[band] + (mean - peaks[band]) * 0.08
            let ratio = mean / max(peaks[band], 1e-9)
            let own: Float = mean < 1e-8 ? 0 : min(1, max(0, 0.5 + log2(max(ratio, 1e-3)) / 2.4))
            let target = own * 0.65 + beat * 0.35
            let speed: Float = target > shown[band] ? 0.85 : 0.4
            shown[band] += (target - shown[band]) * speed
            levels[band] = shown[band]
        }
        return levels
    }
}
