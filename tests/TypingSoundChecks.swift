import CoreAudio
import Foundation

@main
struct TypingSoundChecks {
    static let frames = 128

    /// One buffer of the mixer's output.
    static func render(_ mixer: TypingSoundMixer, now: UInt64 = 0) -> (left: [Float], right: [Float]) {
        var left = [Float](repeating: 9, count: frames), right = [Float](repeating: 9, count: frames)
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                mixer.render(left: l.baseAddress!, right: r.baseAddress!, frames: frames, now: now)
            }
        }
        return (left, right)
    }

    static func main() {
        // Which sound a key makes.
        for arrow in 123...126 { precondition(TypingSoundKind.forKey(arrow) == .letter, "arrows sound as letters") }
        precondition(TypingSoundKind.forKey(0) == .letter && TypingSoundKind.forKey(49) == .space, "A, space")
        precondition(TypingSoundKind.forKey(43) == .punctuation, "comma")
        precondition(TypingSoundKind.forKey(51) == .special && TypingSoundKind.forKey(117) == .special
                     && TypingSoundKind.forKey(36) == .special, "backspace, delete, return")
        precondition(TypingSoundKind.allCases.map(\.fileName) == ["letter", "punctuation", "space", "special", "mouse"],
                     "the file names")
        // A modifier sounds on the press only: its own side's bit is set then.
        precondition(TypingSoundKind.modifierBit(forKey: 56) == 0x02 && TypingSoundKind.modifierBit(forKey: 60) == 0x04,
                     "left and right shift have their own bits")
        precondition(TypingSoundKind.modifierBit(forKey: 0) == nil, "a letter is no modifier")

        // "헤드폰·이어폰일 때만": Bluetooth and the headphone jack play, speakers and a display
        // don't, and a USB output only once the user has let it in.
        let bluetooth = TypingSoundOutputKind(transport: kAudioDeviceTransportTypeBluetooth, jack: false)
        let jack = TypingSoundOutputKind(transport: kAudioDeviceTransportTypeBuiltIn, jack: true)
        let speakers = TypingSoundOutputKind(transport: kAudioDeviceTransportTypeBuiltIn, jack: false)
        let display = TypingSoundOutputKind(transport: kAudioDeviceTransportTypeHDMI, jack: false)
        let usb = TypingSoundOutputKind(transport: kAudioDeviceTransportTypeUSB, jack: false)
        precondition(bluetooth == .headphones && jack == .headphones
                     && TypingSoundOutputKind(transport: kAudioDeviceTransportTypeBluetoothLE, jack: false) == .headphones,
                     "Bluetooth and the jack are headphones")
        precondition(speakers == .speakers && display == .speakers
                     && TypingSoundOutputKind(transport: kAudioDeviceTransportTypeDisplayPort, jack: false) == .speakers,
                     "the Mac's and a display's are speakers")
        precondition(usb == .unknown, "USB doesn't tell")
        for kind in [bluetooth, speakers, display, usb] {
            precondition(kind.plays(headphonesOnly: false, allowed: false), "the switch off, every output plays")
        }
        precondition(bluetooth.plays(headphonesOnly: true, allowed: false) && jack.plays(headphonesOnly: true, allowed: false),
                     "headphones play")
        precondition(!speakers.plays(headphonesOnly: true, allowed: true) && !display.plays(headphonesOnly: true, allowed: true),
                     "speakers don't, whatever was allowed")
        precondition(!usb.plays(headphonesOnly: true, allowed: false) && usb.plays(headphonesOnly: true, allowed: true),
                     "USB plays once let in")

        let mixer = TypingSoundMixer(staleAfter: 0.1)
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let second = UInt64(1e9) * UInt64(timebase.denom) / UInt64(timebase.numer)

        // Nothing loaded: nothing to play.
        mixer.trigger(.letter, at: 0)
        precondition(!mixer.isPlaying, "a kind without a sound starts nothing")
        precondition(render(mixer).left.allSatisfy { $0 == 0 }, "and the buffer is silence, not what was in it")

        // 300 frames of 0.2 on the left and 0.1 on the right: two and a bit buffers long.
        mixer.set(.letter, left: [Float](repeating: 0.2, count: 300), right: [Float](repeating: 0.1, count: 300))
        mixer.set(.mouse, left: [Float](repeating: 0.5, count: 10), right: [Float](repeating: 0.5, count: 10))

        // Presses overlap instead of cutting each other off, and the sum is clipped at 1.
        for _ in 0..<13 { mixer.trigger(.letter, at: 0) }
        var out = render(mixer)
        precondition(out.left.allSatisfy { $0 == 1 }, "13 × 0.2 clips at 1")
        precondition(out.right.allSatisfy { abs($0 - 1) < 1e-5 }, "13 × 0.1 clips at 1 too")
        precondition(mixer.isPlaying, "the sounds go on into the next buffer")
        _ = render(mixer)
        out = render(mixer)
        precondition(out.left[43] == 1 && out.left[44] == 0, "each ends after its 300 frames")
        precondition(!mixer.isPlaying, "and its voice is free again")

        // The gain scales before the clip.
        mixer.gain = 0.5
        mixer.trigger(.letter, at: 0)
        precondition(abs(render(mixer).left[0] - 0.1) < 1e-6, "half the level")
        mixer.gain = 1
        while mixer.isPlaying { _ = render(mixer) }

        // Each kind has a level of its own, and a sound that is playing follows it.
        mixer.setLevel(0.5, for: .letter)
        mixer.trigger(.letter, at: 0)
        mixer.trigger(.mouse, at: 0)
        precondition(abs(render(mixer).left[0] - 0.6) < 1e-6, "the letter at half, the click as it was: 0.1 + 0.5")
        mixer.setLevel(2, for: .letter)
        precondition(abs(render(mixer).left[0] - 0.4) < 1e-6, "the letter still playing, now doubled")
        mixer.setLevel(1, for: .letter)
        while mixer.isPlaying { _ = render(mixer) }

        // More than 32 at once: the oldest give way.
        for _ in 0..<40 { mixer.trigger(.mouse, at: 0) }
        precondition(abs(render(mixer).right[0] - 1) < 1e-6 && !mixer.isPlaying, "32 × 0.5 clipped, all ended in one buffer")

        // The output was starting (0.2 s) while three keys went down: only the last of the late
        // ones sounds, beside the one that is in time.
        mixer.trigger(.mouse, at: 0)
        mixer.trigger(.mouse, at: second / 50)
        mixer.trigger(.mouse, at: second / 25)
        mixer.trigger(.mouse, at: second / 5 - second / 20)
        precondition(render(mixer, now: second / 5).left[0] == 1 && !mixer.isPlaying, "the last late one and the one in time: 2 × 0.5")
        // A lone key after a pause still sounds, late.
        mixer.trigger(.mouse, at: second)
        precondition(render(mixer, now: second + second / 5).left[0] == 0.5, "a lone late sound plays")
        // Lateness counts only before the first frame: a long sound is not cut mid-way.
        mixer.trigger(.letter, at: 0)
        _ = render(mixer, now: 0)
        precondition(render(mixer, now: second).left[0] == 0.2, "a sound that has started plays on")

        // A new pack stops the sounds of the old one and frees the kind when empty.
        mixer.trigger(.letter, at: 0)
        mixer.set(.letter, left: [], right: [])
        precondition(!mixer.isPlaying, "replacing a sound stops it")
        mixer.trigger(.letter, at: 0)
        precondition(!mixer.isPlaying, "an emptied kind is silent")

        print("PASS: key kinds, modifier bits, outputs for headphones only, overlap and clip, voice completion, gain, a level per kind, 32 voices, keys during the output's start, pack reload")
    }
}
