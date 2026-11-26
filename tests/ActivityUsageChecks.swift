import Foundation

@main
struct ActivityUsageChecks {
    @MainActor static func main() throws {
        // A day saved before tokens were counted keeps its numbers.
        let old = Data(#"{"date":"2026-11-20","sessions":["claude:a"],"seconds":120,"folders":{"app":120}}"#.utf8)
        let day = try JSONDecoder().decode(AgentActivityLog.Day.self, from: old)
        precondition(day.sessions == ["claude:a"] && day.seconds == 120 && day.usage == AgentActivityLog.Usage(),
                     "an old day decodes with no usage instead of failing")
        let totals = try JSONDecoder().decode(AgentActivityLog.Totals.self, from: Data(#"{"sessions":3,"seconds":60,"folders":{}}"#.utf8))
        precondition(totals.sessions == 3 && totals.usage.tokens == 0, "old earlier totals decode too")

        let log = AgentActivityLog.shared
        log.reset()
        log.addTokens(1_000, model: "claude-opus-5-5[1m]")
        log.addTokens(500, model: "claude-opus-5-5")
        log.addTokens(700, model: "gpt-6-luna")
        log.addTokens(0, model: "claude-haiku-5-5")
        let lines = (0..<100).map { _ in "x" }.joined(separator: "\n")
        log.addChange(ToolChange.claude(toolName: "Edit", input: ["file_path": "/a", "old_string": "a\nb", "new_string": lines]))
        log.addChange(nil)
        let usage = log.totals(.today).usage
        precondition(usage.tokens == 2_200, "tokens add up")
        precondition(usage.models == ["Opus 5.5": 1_500, "GPT-6 Luna": 700] && usage.topModel == "Opus 5.5",
                     "one model under its short name, 1M context or not; no entry for nothing")
        precondition(usage.added == 100 && usage.removed == 2, "changed lines are counted before the 세션 화면's cap")
        precondition(log.totals(.week).usage == usage && log.totals(.all).usage == usage)
        log.reset()
        print("ActivityUsageChecks: all passed")
    }
}
