import Foundation

/// 오늘 and 완료 기록, pages of the Agents tab's Sessions card (`SessionCardPages`, 2026-11-19):
/// what the day's finished work adds up to, and the latest finishes with their answer's first
/// line. Fed by each manager's `lastCompletedTurn`, nothing read from the session files; kept in
/// UserDefaults so a relaunch keeps the day and the list.
@MainActor
final class AgentActivityLog: ObservableObject {
    static let shared = AgentActivityLog()

    enum Agent: String, Codable { case claude, codex }

    /// One day's numbers.
    struct Day: Codable, Equatable {
        /// yyyy-MM-dd, local time.
        var date: String
        /// The sessions that finished a turn that day (agent:id).
        var sessions: [String] = []
        /// Their turns' time added up, in seconds.
        var seconds: Double = 0
        /// Turn time per folder name, for 가장 많이 쓴 폴더.
        var folders: [String: Double] = [:]

        var topFolder: String? { folders.max { $0.value < $1.value }?.key }
    }

    /// A session finishing its work, as 완료 기록 shows it and goes back to it.
    struct Finish: Codable, Equatable, Identifiable {
        var id = UUID()
        let agent: Agent
        let sessionId: String
        /// Claude's conversation id: the desktop app's store and `claude --resume` take it.
        var conversationId: String?
        var title: String
        var folder: String
        var model: String?
        /// Ran in the Claude or Codex app, so the app can open it again; else a terminal or editor.
        var inApp: Bool
        /// The closing answer's first line, as the 완료 드롭다운 shows it.
        var headline: String?
        var finished: Date

        /// The session it belongs to (agent:id), as the list's rows know it.
        var sessionKey: String { "\(agent.rawValue):\(sessionId)" }
    }

    @Published private(set) var day: Day
    @Published private(set) var finishes: [Finish]
    /// The terminal app a session last finished a turn in: 터미널 앱's 자동.
    private(set) var lastTerminalApp: String? {
        didSet { UserDefaults.standard.set(lastTerminalApp, forKey: Self.terminalKey) }
    }

    private static let dayKey = "agentActivityDay"
    private static let terminalKey = "agentActivityLastTerminal"
    private static let finishesKey = "agentActivityFinishes"
    private static let keptFinishes = 20

    private init() {
        let defaults = UserDefaults.standard
        day = defaults.data(forKey: Self.dayKey).flatMap { try? JSONDecoder().decode(Day.self, from: $0) }
            ?? Day(date: Self.dateString(Date()))
        finishes = defaults.data(forKey: Self.finishesKey).flatMap { try? JSONDecoder().decode([Finish].self, from: $0) } ?? []
        // 최근 세션's list, before it became 완료 기록 the same day.
        defaults.removeObject(forKey: "agentActivityRecent")
        lastTerminalApp = defaults.string(forKey: Self.terminalKey)
    }

    /// A terminal session finished a turn in this app.
    func terminalUsed(_ bundleID: String) {
        if lastTerminalApp != bundleID { lastTerminalApp = bundleID }
    }

    /// Today's numbers: empty once the date has moved on.
    var today: Day {
        let date = Self.dateString(Date())
        return day.date == date ? day : Day(date: date)
    }

    /// A session finished its work: it counts toward today and goes first in 완료 기록.
    func record(_ turn: CompletedTurn, agent: Agent, conversationId: String?, title: String,
                folder: String, model: String?, inApp: Bool) {
        var today = self.today
        let key = "\(agent.rawValue):\(turn.sessionId)"
        if !today.sessions.contains(key) { today.sessions.append(key) }
        let seconds = max(0, turn.elapsed ?? 0)
        today.seconds += seconds
        if !folder.isEmpty { today.folders[folder, default: 0] += seconds }
        day = today

        let entry = Finish(agent: agent, sessionId: turn.sessionId, conversationId: conversationId, title: title,
                           folder: folder, model: model, inApp: inApp, headline: turn.headline, finished: Date())
        finishes = Array(([entry] + finishes).prefix(Self.keptFinishes))

        let defaults = UserDefaults.standard
        defaults.set(try? JSONEncoder().encode(day), forKey: Self.dayKey)
        defaults.set(try? JSONEncoder().encode(finishes), forKey: Self.finishesKey)
    }

    private static func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
