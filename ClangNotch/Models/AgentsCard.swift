import Foundation

/// The Agents tab's cards that can be reordered (설정 -> 에이전트 -> Agents 탭 카드). NEEDS YOU
/// isn't one of them: what waits on an answer always comes first.
enum AgentsCard: String, CaseIterable, Identifiable {
    case claudeUsage, codexUsage, tasks, sessions

    var id: String { rawValue }

    /// The saved order, then any card it doesn't name yet in the order they always had.
    static func order(from stored: String) -> [AgentsCard] {
        var saved: [AgentsCard] = []
        for name in stored.split(separator: ",") {
            if let card = AgentsCard(rawValue: String(name)), !saved.contains(card) { saved.append(card) }
        }
        return saved + allCases.filter { !saved.contains($0) }
    }

    static func stored(_ cards: [AgentsCard]) -> String { cards.map(\.rawValue).joined(separator: ",") }
}
