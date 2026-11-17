import Foundation

/// When a Codex rollout last showed real work (a turn event, a tool call or its output, reasoning,
/// an assistant reply), as opposed to a write from opening a thread, a setting or an import.
///
/// The file is walked backwards a chunk at a time, keeping only line boundaries, until a line
/// that counts is recent; older ones only raise the latest date seen (a replayed record can sit
/// after newer work). A long line is judged by its start, which holds the timestamp and types.
/// The walk stops after `scanBudget` bytes with what it has. GitHub issue #3 (2026-11-17): a 2 GB rollout with 46 MB
/// lines hung the notch for 90 s, because every walk re-split a growing tail and went on to the
/// first line of the file when nothing was recent.
enum CodexActivityScan {
    static let chunkSize = 1 << 20
    /// Longer lines are judged by their first `headSize` bytes instead of being parsed whole.
    static let fullLineLimit = 512 * 1024
    static let headSize = 16 * 1024
    /// How far back to look; past it the latest date found so far is the answer.
    static let scanBudget: UInt64 = 64 << 20

    static func latestActivity(in handle: FileHandle, fileSize: UInt64, recentAfter threshold: Date) -> Date? {
        var latest: Date?
        func take(_ date: Date?) -> Bool {
            guard let date else { return false }
            latest = max(latest ?? .distantPast, date)
            return date > threshold
        }
        var lineEnd = fileSize
        var position = fileSize
        while position > 0 {
            if fileSize - position >= scanBudget { return latest }
            let start = position > UInt64(chunkSize) ? position - UInt64(chunkSize) : 0
            handle.seek(toFileOffset: start)
            let chunk = handle.readData(ofLength: Int(position - start))
            var cursor = chunk.count
            while let newline = lastNewline(in: chunk, before: cursor) {
                let lineStart = start + UInt64(newline) + 1
                if take(activityDate(ofLineIn: handle, from: lineStart, to: lineEnd)) { return latest }
                lineEnd = start + UInt64(newline)
                cursor = newline
            }
            position = start
        }
        _ = take(activityDate(ofLineIn: handle, from: 0, to: lineEnd))
        return latest
    }

    private static func lastNewline(in data: Data, before end: Int) -> Int? {
        data.withUnsafeBytes { raw -> Int? in
            guard let bytes = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            var i = end - 1
            while i >= 0 {
                if bytes[i] == 0x0A { return i }
                i -= 1
            }
            return nil
        }
    }

    private static func activityDate(ofLineIn handle: FileHandle, from start: UInt64, to end: UInt64) -> Date? {
        guard end > start else { return nil }
        let length = Int(end - start)
        handle.seek(toFileOffset: start)
        if length <= fullLineLimit {
            let line = handle.readData(ofLength: length)
            guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
            return activityDate(json: json)
        }
        let head = handle.readData(ofLength: headSize)
        return activityDate(head: String(decoding: head, as: UTF8.self))
    }

    static func activityDate(json: [String: Any]) -> Date? {
        guard let payload = json["payload"] as? [String: Any],
              let type = json["type"] as? String,
              let eventType = payload["type"] as? String,
              counts(type: type, eventType: eventType, turnID: payload["turn_id"] as? String ?? "",
                     assistant: payload["role"] as? String == "assistant", phase: payload["phase"] as? String ?? ""),
              let timestamp = json["timestamp"] as? String else { return nil }
        return date(timestamp)
    }

    /// A line too long to parse: its start reads `{"timestamp":"…","type":"…","payload":{"type":"…"`.
    static func activityDate(head: String) -> Date? {
        guard let payloadStart = head.range(of: "\"payload\":{"),
              let type = firstString(after: "\"type\":\"", in: head[..<payloadStart.lowerBound]),
              let eventType = firstString(after: "\"type\":\"", in: head[payloadStart.upperBound...]),
              let timestamp = firstString(after: "\"timestamp\":\"", in: head[...]) else { return nil }
        let phase = head.contains("\"phase\":\"final_answer\"") ? "final_answer"
            : head.contains("\"phase\":\"commentary\"") ? "commentary" : ""
        guard counts(type: type, eventType: eventType,
                     turnID: head.contains("\"turn_id\":\"external-import-turn-") ? "external-import-turn-" : "",
                     assistant: head.contains("\"role\":\"assistant\""), phase: phase) else { return nil }
        return date(timestamp)
    }

    /// A record too long to parse, as a small one with what its start carries: the timestamp,
    /// types, the call id that ends a running tool, the tool's name and the first characters of
    /// its output (for "Exit code: N"). A message whose phase isn't in its start is dropped
    /// rather than read as a final answer.
    static func compactRecord(head: String) -> [String: Any]? {
        guard let payloadStart = head.range(of: "\"payload\":{"),
              let type = firstString(after: "\"type\":\"", in: head[..<payloadStart.lowerBound]) else { return nil }
        let body = head[payloadStart.upperBound...]
        guard let eventType = firstString(after: "\"type\":\"", in: body) else { return nil }
        var payload: [String: Any] = ["type": eventType]
        for key in ["call_id", "name", "role", "phase", "turn_id"] {
            if let value = firstString(after: "\"\(key)\":\"", in: body) { payload[key] = value }
        }
        if eventType == "message", payload["phase"] == nil, payload["role"] as? String == "assistant" { return nil }
        if let open = body.range(of: "\"output\":\"") {
            payload["output"] = String(body[open.upperBound...].prefix(64).prefix { $0 != "\"" && $0 != "\\" })
        }
        var record: [String: Any] = ["type": type, "payload": payload]
        if let timestamp = firstString(after: "\"timestamp\":\"", in: head[...]) { record["timestamp"] = timestamp }
        return record
    }

    private static func counts(type: String, eventType: String, turnID: String, assistant: Bool, phase: String) -> Bool {
        let isTurn = type == "event_msg"
            && ["task_started", "task_complete", "turn_aborted", "agent_reasoning"].contains(eventType)
            && !turnID.hasPrefix("external-import-turn-")
        let isToolOrReasoning = type == "response_item"
            && ["function_call", "custom_tool_call", "function_call_output", "custom_tool_call_output", "reasoning"].contains(eventType)
        let isResponse = type == "response_item" && eventType == "message" && assistant
            && ["commentary", "final_answer"].contains(phase)
        return isTurn || isToolOrReasoning || isResponse
    }

    private static func firstString(after marker: String, in text: Substring) -> String? {
        guard let open = text.range(of: marker),
              let close = text[open.upperBound...].firstIndex(of: "\"") else { return nil }
        return String(text[open.upperBound..<close])
    }

    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let plain = ISO8601DateFormatter()

    private static func date(_ text: String) -> Date? { fractional.date(from: text) ?? plain.date(from: text) }
}
