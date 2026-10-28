import AppKit

/// The two notch sounds: `done` when a turn finishes, `attention` when a permission request
/// or a question drops in. Both follow `AppSettings.notchSoundsEnabled` and skip muted sessions.
@MainActor
enum NotchSounds {
    private static let done = load("done")
    private static let attention = load("attention")

    static func playDone(for sessionId: String? = nil) { play(done, sessionId) }
    static func playAttention(for sessionId: String? = nil) { play(attention, sessionId) }

    static func isMuted(_ sessionId: String) -> Bool {
        mutedSessionIDs.contains(sessionId)
    }

    static func toggleMute(_ sessionId: String) {
        var ids = mutedSessionIDs
        if ids.remove(sessionId) == nil { ids.insert(sessionId) }
        AppSettings.shared.mutedSoundSessionIDs = ids.sorted().joined(separator: "\n")
    }

    private static var mutedSessionIDs: Set<String> {
        Set(AppSettings.shared.mutedSoundSessionIDs.split(separator: "\n").map(String.init))
    }

    private static func play(_ sound: NSSound?, _ sessionId: String?) {
        guard AppSettings.shared.notchSoundsEnabled, let sound else { return }
        if let sessionId, isMuted(sessionId) { return }
        if AppSettings.shared.muteSoundsWhenLocked, screenIsLocked { return }
        sound.stop()
        sound.volume = Float(AppSettings.shared.notchSoundsVolume)
        sound.play()
    }

    /// Read on demand from the login session, so nothing has to watch lock notifications.
    private static var screenIsLocked: Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    private static func load(_ name: String) -> NSSound? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "wav") else {
            debugLog("[NotchSounds] Missing \(name).wav in the bundle")
            return nil
        }
        return NSSound(contentsOf: url, byReference: true)
    }
}
