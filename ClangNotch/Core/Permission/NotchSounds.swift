import AppKit

/// The two notch sounds: `done` when a turn finishes, `attention` when a permission request
/// or a question drops in. Both follow `AppSettings.notchSoundsEnabled`.
@MainActor
enum NotchSounds {
    private static let done = load("done")
    private static let attention = load("attention")

    static func playDone() { play(done) }
    static func playAttention() { play(attention) }

    private static func play(_ sound: NSSound?) {
        guard AppSettings.shared.notchSoundsEnabled, let sound else { return }
        sound.stop()
        sound.volume = Float(AppSettings.shared.notchSoundsVolume)
        sound.play()
    }

    private static func load(_ name: String) -> NSSound? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "wav") else {
            debugLog("[NotchSounds] Missing \(name).wav in the bundle")
            return nil
        }
        return NSSound(contentsOf: url, byReference: true)
    }
}
