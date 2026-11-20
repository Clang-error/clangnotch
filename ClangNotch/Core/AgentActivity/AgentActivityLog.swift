import Foundation

/// 오늘 and 완료 기록, pages of the Agents tab's Sessions card (`SessionCardPages`, 2026-11-19):
/// what finished work adds up to (today, the last 7 days, everything since 2026-11-21), and the
/// latest finishes with their answer's first line. Fed by each manager's `lastCompletedTurn`,
/// nothing read from the session files; kept in UserDefaults so a relaunch keeps them.
/// Only the last 7 days are kept day by day; an older day is folded into `earlier`, one set of
/// totals, so what is stored stays the same size however long the app runs.
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
    }

    /// What a span of days adds up to, as the 오늘 page shows it.
    struct Totals: Codable, Equatable {
        var sessions = 0
        var seconds: Double = 0
        var folders: [String: Double] = [:]

        var topFolder: String? { folders.max { $0.value < $1.value }?.key }

        mutating func add(seconds: Double, folders: [String: Double]) {
            self.seconds += seconds
            self.folders.merge(folders, uniquingKeysWith: +)
        }
    }

    /// The 오늘 page's 오늘 / 7일 / 전체.
    enum Span: String, CaseIterable, Identifiable {
        case today, week, all

        var id: String { rawValue }

        var title: String {
            switch self {
            case .today: return L("오늘", "Today")
            case .week: return L("7일", "7 days")
            case .all: return L("전체", "All")
            }
        }
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

    /// The last 7 days that had work, oldest first.
    @Published private(set) var days: [Day]
    /// The days before those, folded together.
    @Published private(set) var earlier: Totals
    @Published private(set) var finishes: [Finish]
    /// The terminal app a session last finished a turn in: 터미널 앱's 자동.
    private(set) var lastTerminalApp: String? {
        didSet { UserDefaults.standard.set(lastTerminalApp, forKey: Self.terminalKey) }
    }

    private static let daysKey = "agentActivityDays"
    private static let earlierKey = "agentActivityEarlier"
    private static let terminalKey = "agentActivityLastTerminal"
    private static let finishesKey = "agentActivityFinishes"
    private static let keptFinishes = 20
    private static let keptDays = 7

    private init() {
        let defaults = UserDefaults.standard
        let decoder = JSONDecoder()
        var days = defaults.data(forKey: Self.daysKey).flatMap { try? decoder.decode([Day].self, from: $0) } ?? []
        // One day only, before the days were kept (until 2026-11-21).
        if days.isEmpty, let day = defaults.data(forKey: "agentActivityDay").flatMap({ try? decoder.decode(Day.self, from: $0) }) {
            days = [day]
        }
        defaults.removeObject(forKey: "agentActivityDay")
        self.days = days
        earlier = defaults.data(forKey: Self.earlierKey).flatMap { try? decoder.decode(Totals.self, from: $0) } ?? Totals()
        finishes = defaults.data(forKey: Self.finishesKey).flatMap { try? decoder.decode([Finish].self, from: $0) } ?? []
        // 최근 세션's list, before it became 완료 기록 the same day.
        defaults.removeObject(forKey: "agentActivityRecent")
        lastTerminalApp = defaults.string(forKey: Self.terminalKey)
        if foldOldDays() { save() }
    }

    /// A terminal session finished a turn in this app.
    func terminalUsed(_ bundleID: String) {
        if lastTerminalApp != bundleID { lastTerminalApp = bundleID }
    }

    /// Today's numbers: empty once the date has moved on.
    var today: Day {
        let date = Self.dateString(Date())
        return days.last(where: { $0.date == date }) ?? Day(date: date)
    }

    /// What `span` adds up to. A session that finished turns on several days counts once.
    func totals(_ span: Span) -> Totals {
        let first: String
        switch span {
        case .today: first = Self.dateString(Date())
        case .week: first = Self.firstKeptDate()
        case .all: first = ""
        }
        var totals = span == .all ? earlier : Totals()
        var sessions = Set<String>()
        for day in days where day.date >= first {
            sessions.formUnion(day.sessions)
            totals.add(seconds: day.seconds, folders: day.folders)
        }
        totals.sessions += sessions.count
        return totals
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
        if let index = days.lastIndex(where: { $0.date == today.date }) { days[index] = today } else { days.append(today) }
        foldOldDays()

        let entry = Finish(agent: agent, sessionId: turn.sessionId, conversationId: conversationId, title: title,
                           folder: folder, model: model, inApp: inApp, headline: turn.headline, finished: Date())
        finishes = Array(([entry] + finishes).prefix(Self.keptFinishes))
        save()
    }

    /// Nothing recorded at all: no day, no earlier totals, no finishes.
    var isEmpty: Bool { days.isEmpty && earlier == Totals() && finishes.isEmpty }

    /// 설정 -> 에이전트 -> Sessions 카드 기록 초기화: every day, the earlier totals and 완료 기록.
    func reset() {
        days = []
        earlier = Totals()
        finishes = []
        save()
    }

    /// Folds the days before the last 7 into `earlier`. A day's session still in a later kept day
    /// isn't counted yet: it is counted with the last of its days. Returns whether anything moved.
    @discardableResult
    private func foldOldDays() -> Bool {
        let first = Self.firstKeptDate()
        let old = days.filter { $0.date < first }.sorted { $0.date < $1.date }
        guard !old.isEmpty else { return false }
        let kept = days.filter { $0.date >= first }.sorted { $0.date < $1.date }
        for (index, day) in old.enumerated() {
            let later = Set((old[(index + 1)...] + kept).flatMap(\.sessions))
            earlier.sessions += day.sessions.filter { !later.contains($0) }.count
            earlier.add(seconds: day.seconds, folders: day.folders)
        }
        days = kept
        return true
    }

    private func save() {
        let defaults = UserDefaults.standard
        let encoder = JSONEncoder()
        defaults.set(try? encoder.encode(days), forKey: Self.daysKey)
        defaults.set(try? encoder.encode(earlier), forKey: Self.earlierKey)
        defaults.set(try? encoder.encode(finishes), forKey: Self.finishesKey)
    }

    /// The first date of the last 7 days, today included.
    private static func firstKeptDate() -> String {
        let date = Calendar.current.date(byAdding: .day, value: -(keptDays - 1), to: Date()) ?? Date()
        return dateString(date)
    }

    private static func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
