import Foundation

/// The five sounds. Each is read from the file of its name (`letter.wav` …) in the user's
/// sound pack folder.
enum TypingSoundKind: Int, CaseIterable {
    case letter, punctuation, space, special, mouse

    var fileName: String { String(describing: self) }

    /// By macOS hardware key code. A key in no list sounds as a letter, the arrows among them.
    static func forKey(_ code: Int) -> TypingSoundKind {
        switch code {
        case 49:
            return .space
        case 24, 27, 30, 33, 39, 41, 43, 44, 47, 50:
            return .punctuation
        case 36, 42, 48, 51, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 76,
             96, 97, 98, 99, 100, 101, 103, 105, 106, 107, 109, 111, 113, 114, 117, 118, 120, 122:
            return .special
        default:
            return .letter
        }
    }

    /// The bit of a flags-changed event that is set while the modifier key `code` is down: the
    /// device-dependent bits, which tell left from right. A release clears it, so only the
    /// press sounds.
    static func modifierBit(forKey code: Int) -> UInt64? {
        switch code {
        case 59: return 0x01        // left control
        case 56: return 0x02        // left shift
        case 60: return 0x04        // right shift
        case 55: return 0x08        // left command
        case 54: return 0x10        // right command
        case 58: return 0x20        // left option
        case 61: return 0x40        // right option
        case 62: return 0x2000      // right control
        case 57: return 0x10000     // caps lock
        case 63: return 0x800000    // fn
        default: return nil
        }
    }
}

/// Up to 32 sounds at once, summed into the two output channels. `trigger` comes from the
/// input thread and `render` from the audio thread. They share `lock`, which the audio thread
/// only ever tries: taken, it plays a buffer of silence instead of waiting. Everything the
/// audio thread reads is in memory allocated once, so it never allocates either.
final class TypingSoundMixer {
    static let voiceCount = 32

    private struct Sample {
        var left: UnsafeMutablePointer<Float>?
        var right: UnsafeMutablePointer<Float>?
        var frames = 0
    }

    private struct Voice {
        var kind = -1
        var position = 0
        var born: UInt64 = 0
    }

    private let samples = UnsafeMutablePointer<Sample>.allocate(capacity: TypingSoundKind.allCases.count)
    private let voices = UnsafeMutablePointer<Voice>.allocate(capacity: TypingSoundMixer.voiceCount)
    /// How loud each kind plays, 1 as recorded.
    private let levels = UnsafeMutablePointer<Float>.allocate(capacity: TypingSoundKind.allCases.count)
    private let next = UnsafeMutablePointer<Int>.allocate(capacity: 1)
    private let level = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    private let lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
    /// In `mach_absolute_time` ticks. A sound the output reaches later than this after its key
    /// is late: the output was not running and takes about 0.2 s to start. Of the keys pressed
    /// meanwhile only the last sounds, instead of all at once.
    private let staleAfter: UInt64

    init(staleAfter seconds: Double = 0.1) {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        staleAfter = UInt64(seconds * 1e9) * UInt64(timebase.denom) / UInt64(timebase.numer)
        samples.initialize(repeating: Sample(), count: TypingSoundKind.allCases.count)
        levels.initialize(repeating: 1, count: TypingSoundKind.allCases.count)
        voices.initialize(repeating: Voice(), count: Self.voiceCount)
        next.initialize(to: 0)
        level.initialize(to: 1)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        for kind in 0..<TypingSoundKind.allCases.count {
            samples[kind].left?.deallocate()
            samples[kind].right?.deallocate()
        }
        samples.deallocate()
        levels.deallocate()
        voices.deallocate()
        next.deallocate()
        level.deallocate()
        lock.deallocate()
    }

    /// The sound of `kind`, at the output's sample rate; empty channels leave it silent. Sounds
    /// of this kind that are still playing stop.
    func set(_ kind: TypingSoundKind, left: [Float], right: [Float]) {
        let frames = min(left.count, right.count)
        var sample = Sample()
        if frames > 0 {
            let l = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            let r = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            l.initialize(from: left, count: frames)
            r.initialize(from: right, count: frames)
            sample = Sample(left: l, right: r, frames: frames)
        }
        os_unfair_lock_lock(lock)
        let old = samples[kind.rawValue]
        samples[kind.rawValue] = sample
        for voice in 0..<Self.voiceCount where voices[voice].kind == kind.rawValue {
            voices[voice].kind = -1
        }
        os_unfair_lock_unlock(lock)
        old.left?.deallocate()
        old.right?.deallocate()
    }

    /// How loud `kind` plays from now on, sounds of it already playing included.
    func setLevel(_ level: Float, for kind: TypingSoundKind) {
        os_unfair_lock_lock(lock)
        levels[kind.rawValue] = level
        os_unfair_lock_unlock(lock)
    }

    /// Multiplied into the output, before the peaks of overlapping sounds are clipped.
    var gain: Float {
        get {
            os_unfair_lock_lock(lock)
            defer { os_unfair_lock_unlock(lock) }
            return level.pointee
        }
        set {
            os_unfair_lock_lock(lock)
            level.pointee = newValue
            os_unfair_lock_unlock(lock)
        }
    }

    /// Whether a sound is still to be heard.
    var isPlaying: Bool {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return (0..<Self.voiceCount).contains { voices[$0].kind >= 0 }
    }

    /// Starts the sound of `kind` beside those already playing; the oldest of 32 gives way.
    func trigger(_ kind: TypingSoundKind, at time: UInt64 = mach_absolute_time()) {
        os_unfair_lock_lock(lock)
        if samples[kind.rawValue].frames > 0 {
            voices[next.pointee] = Voice(kind: kind.rawValue, position: 0, born: time)
            next.pointee = (next.pointee + 1) % Self.voiceCount
        }
        os_unfair_lock_unlock(lock)
    }

    /// Not begun, and its key went down longer ago than `staleAfter`.
    private func isLate(_ voice: Voice, _ now: UInt64) -> Bool {
        voice.kind >= 0 && voice.position == 0 && now > voice.born && now - voice.born > staleAfter
    }

    /// Fills `frames` frames of both channels. The audio thread's call.
    func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int,
                now: UInt64 = mach_absolute_time()) {
        left.update(repeating: 0, count: frames)
        right.update(repeating: 0, count: frames)
        guard os_unfair_lock_trylock(lock) else { return }
        var newestLate: UInt64 = 0
        for index in 0..<Self.voiceCount where isLate(voices[index], now) {
            newestLate = max(newestLate, voices[index].born)
        }
        for index in 0..<Self.voiceCount {
            let voice = voices + index
            let kind = voice.pointee.kind
            guard kind >= 0 else { continue }
            let position = voice.pointee.position
            let sample = samples[kind]
            guard let l = sample.left, let r = sample.right,
                  !(isLate(voice.pointee, now) && voice.pointee.born != newestLate)
            else {
                voice.pointee.kind = -1
                continue
            }
            let count = min(sample.frames - position, frames)
            let level = levels[kind]
            for i in 0..<count {
                left[i] += l[position + i] * level
                right[i] += r[position + i] * level
            }
            voice.pointee.position = position + count
            if position + count == sample.frames { voice.pointee.kind = -1 }
        }
        let gain = level.pointee
        os_unfair_lock_unlock(lock)
        for i in 0..<frames {
            left[i] = max(-1, min(1, left[i] * gain))
            right[i] = max(-1, min(1, right[i] * gain))
        }
    }
}
