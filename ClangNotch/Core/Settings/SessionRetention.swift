import Foundation

/// How long a quiet session stays in the Sessions 카드, and which ones are pinned to stay
/// whatever the time (설정 › 에이전트 › "쉬는 세션이 목록에 남는 시간"; 세션 줄 우클릭 › 세션
/// 고정). Read straight from UserDefaults, under the keys `AppSettings` stores them with, so the
/// managers' scans compile without the settings object (`tests/run_activity_checks.py`).
enum SessionRetention {
    static let minutesKey = "sessionKeepMinutes"
    static let pinnedKey = "pinnedSessionIDs"
    static let defaultMinutes = 5
    /// Every listed session is watched and has its history loaded, so the time is bounded.
    static let minutesRange = 1...240

    /// Seconds a session stays listed after its last activity.
    static var keepSeconds: TimeInterval {
        let minutes = UserDefaults.standard.object(forKey: minutesKey) as? Int ?? defaultMinutes
        return TimeInterval(min(max(minutes, minutesRange.lowerBound), minutesRange.upperBound) * 60)
    }

    /// Session ids of both agents, as the 세션 줄 has them.
    static var pinned: Set<String> {
        Set((UserDefaults.standard.string(forKey: pinnedKey) ?? "").split(separator: "\n").map(String.init))
    }
}
