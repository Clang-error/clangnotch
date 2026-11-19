import Foundation

/// 오늘 한 일 and 최근 세션, for the Agents tab's Sessions card while no session is listed
/// (`IdleSessionPages`, 2026-11-19): what the day's finished turns add up to, and the last
/// sessions that finished one. Fed by each manager's `lastCompletedTurn`, nothing read from the
/// session files; kept in UserDefaults so a relaunch keeps the day and the list.
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

    /// A session that finished a turn, as 최근 세션 shows it and goes back to it.
    struct Recent: Codable, Equatable, Identifiable {
        let agent: Agent
        let sessionId: String
        /// Claude's conversation id: the desktop app's store and `claude --resume` take it.
        var conversationId: String?
        var title: String
        var folder: String
        var model: String?
        /// Ran in the Claude or Codex app, so the app can open it again; else a terminal or editor.
        var inApp: Bool
        var finished: Date

        var id: String { "\(agent.rawValue):\(sessionId)" }
    }

    @Published private(set) var day: Day
    @Published private(set) var recent: [Recent]
    /// The terminal app a session last finished a turn in: 터미널 앱's 자동.
    private(set) var lastTerminalApp: String? {
        didSet { UserDefaults.standard.set(lastTerminalApp, forKey: Self.terminalKey) }
    }

    private static let dayKey = "agentActivityDay"
    private static let terminalKey = "agentActivityLastTerminal"
    private static let recentKey = "agentActivityRecent"
    private static let keptRecent = 10

    private init() {
        let defaults = UserDefaults.standard
        day = defaults.data(forKey: Self.dayKey).flatMap { try? JSONDecoder().decode(Day.self, from: $0) }
            ?? Day(date: Self.dateString(Date()))
        recent = defaults.data(forKey: Self.recentKey).flatMap { try? JSONDecoder().decode([Recent].self, from: $0) } ?? []
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

    /// A turn finished: it counts toward today and puts its session first in 최근 세션.
    func record(_ turn: CompletedTurn, agent: Agent, conversationId: String?, title: String,
                folder: String, model: String?, inApp: Bool) {
        var today = self.today
        let key = "\(agent.rawValue):\(turn.sessionId)"
        if !today.sessions.contains(key) { today.sessions.append(key) }
        let seconds = max(0, turn.elapsed ?? 0)
        today.seconds += seconds
        if !folder.isEmpty { today.folders[folder, default: 0] += seconds }
        day = today

        let entry = Recent(agent: agent, sessionId: turn.sessionId, conversationId: conversationId, title: title,
                           folder: folder, model: model, inApp: inApp, finished: Date())
        recent = [entry] + recent.filter { $0.id != entry.id }.prefix(Self.keptRecent - 1)

        let defaults = UserDefaults.standard
        defaults.set(try? JSONEncoder().encode(day), forKey: Self.dayKey)
        defaults.set(try? JSONEncoder().encode(recent), forKey: Self.recentKey)
    }

    private static func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
