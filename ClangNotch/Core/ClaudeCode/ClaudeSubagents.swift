import Foundation

/// Reads the subagents a Claude session is running from their own files. An Agent tool
/// call's work is not in the session's transcript: it goes to
/// `<conversation>/subagents/agent-<id>.jsonl`, with `agent-<id>.meta.json` beside it
/// (`description`, `agentType`, and `finished` once it has ended).
enum ClaudeSubagents {
    /// Subagents in `directory` that have not finished, oldest first. One whose transcript
    /// has been silent for `quietLimit` is left out: a subagent that was stopped never gets
    /// `finished`, and it would otherwise stay listed for good.
    static func unfinished(in directory: URL, quietLimit: TimeInterval) -> [ClaudeSubagent] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .creationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys)) else { return [] }

        let now = Date()
        var found: [(started: Date, subagent: ClaudeSubagent)] = []
        for transcript in files where transcript.pathExtension == "jsonl" {
            let name = transcript.deletingPathExtension().lastPathComponent
            guard let values = try? transcript.resourceValues(forKeys: keys),
                  let modified = values.contentModificationDate, now.timeIntervalSince(modified) < quietLimit,
                  let data = try? Data(contentsOf: directory.appendingPathComponent(name + ".meta.json")),
                  let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  meta["finished"] as? Bool != true else { continue }
            let awaited = meta["requestShape"] as? String == "foreground" && meta["spawnDepth"] as? Int == 1
            let started = values.creationDate ?? modified
            found.append((started, ClaudeSubagent(
                id: name.hasPrefix("agent-") ? String(name.dropFirst(6)) : name,
                description: meta["description"] as? String ?? "",
                agentType: meta["agentType"] as? String ?? "",
                awaitedToolUseId: awaited ? meta["toolUseId"] as? String : nil,
                tool: runningTool(in: transcript),
                startTime: started
            )))
        }
        return found.sorted { ($0.started, $0.subagent.id) < ($1.started, $1.subagent.id) }.map(\.subagent)
    }

    /// The tool a subagent is running: the last tool_use in its transcript's tail that has
    /// no result yet. The tail is enough, since nothing is written while a tool runs.
    private static func runningTool(in transcript: URL) -> ClaudeToolExecution? {
        guard let handle = try? FileHandle(forReadingFrom: transcript) else { return nil }
        defer { try? handle.close() }
        let size = handle.seekToEndOfFile()
        let start = size > tailBytes ? size - tailBytes : 0
        handle.seek(toFileOffset: start)
        guard var data = try? handle.readToEnd() else { return nil }
        if start > 0, let newline = data.firstIndex(of: 0x0A) { data.removeSubrange(...newline) }

        var running: [ClaudeToolExecution] = []
        for line in data.split(separator: 0x0A) {
            // Only transcript messages with a tool block. The request dumps are the big lines,
            // replay earlier tool_use blocks, and are told by how they begin without parsing.
            guard !line.starts(with: requestDump), line.range(of: toolBlock) != nil,
                  let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = json["type"] as? String, type == "assistant" || type == "user",
                  let content = (json["message"] as? [String: Any])?["content"] as? [[String: Any]] else { continue }
            for block in content {
                switch block["type"] as? String {
                case "tool_use":
                    guard let id = block["id"] as? String, let name = block["name"] as? String else { continue }
                    // The line's own time, so the same tool reads the same on every scan.
                    let started = (json["timestamp"] as? String).flatMap { timestamps.date(from: $0) } ?? .distantPast
                    var tool = ClaudeToolExecution(id: id, toolName: name,
                                                   argument: ClaudeToolExecution.argument(from: block["input"]),
                                                   startTime: started)
                    tool.description = (block["input"] as? [String: Any])?["description"] as? String
                    running.append(tool)
                case "tool_result":
                    running.removeAll { $0.id == block["tool_use_id"] as? String }
                default:
                    break
                }
            }
        }
        return running.last
    }

    private static let tailBytes: UInt64 = 128 * 1024
    private static let requestDump = Data(#"{"type":"api-request"#.utf8)
    private static let toolBlock = Data(#""type":"tool_"#.utf8)

    private static let timestamps: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
