import Foundation

/// "곧 압축될 수 있음": a session close to its automatic compaction, for the 세션 줄's 미리보기
/// 줄 and the 세션 화면's context bar (user, 2026-11-13).
///
/// Claude Code compacts about 33k short of its window: 967k of 1M in 93 compactions on this
/// Mac. It also applies summaries it prepared in the background anywhere past 200k, which
/// nothing announces, so the note only covers the point it can't get past. Codex compacted at
/// 89 and 95% of its window (two seen). The note starts a little before either.
enum ContextCompaction {
    enum Agent { case claude, codex }

    static func isNear(_ agent: Agent, used: Int, limit: Int) -> Bool {
        guard limit > 0, used > 0 else { return false }
        switch agent {
        case .claude: return Double(used) >= Double(max(limit - 33_000, 0)) * 0.9
        case .codex: return Double(used) >= Double(limit) * 0.85
        }
    }

    static func percent(used: Int, limit: Int) -> Int {
        limit > 0 ? min(100, Int((Double(used) / Double(limit) * 100).rounded())) : 0
    }

    static func note(used: Int, limit: Int) -> String {
        let p = percent(used: used, limit: limit)
        return L("컨텍스트 \(p)% · 곧 압축될 수 있음", "Context \(p)% · may compact soon")
    }
}
