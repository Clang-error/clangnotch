import Foundation

/// 이 세션 드롭다운 끄기 (a session row's context menu, 2026-11-26): sessions whose finishes
/// and shell failures drop no dropdown; the wing's Done still shows, as when the session's
/// app is in front. A question or permission request still comes down: the agent waits on it.
/// Apart from 이 세션 소리 끄기 (`NotchSounds`), which silences sounds and the haptic.
@MainActor
enum QuietSessions {
    static func isQuiet(_ sessionId: String) -> Bool {
        ids.contains(sessionId)
    }

    static func toggle(_ sessionId: String) {
        var ids = ids
        if ids.remove(sessionId) == nil { ids.insert(sessionId) }
        AppSettings.shared.quietDropdownSessionIDs = ids.sorted().joined(separator: "\n")
    }

    private static var ids: Set<String> {
        Set(AppSettings.shared.quietDropdownSessionIDs.split(separator: "\n").map(String.init))
    }
}
