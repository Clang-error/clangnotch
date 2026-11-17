import Foundation

// GitHub issue #3: a 2 GB Codex rollout with 46 MB lines hung the notch for 90 s while the scan
// for its latest activity re-split a growing tail and read on to the first line. These files
// recreate the shapes; each scan must give the right date and stay well under a second.

@main
struct CodexActivityScanChecks {
    static let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("clangnotch-activity-scan-\(UUID().uuidString)")

    static func stamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func work(_ date: Date, _ type: String = "function_call", padding: Int = 0) -> String {
        "{\"timestamp\":\"\(stamp(date))\",\"type\":\"response_item\",\"payload\":{\"type\":\"\(type)\",\"output\":\"\(String(repeating: "x", count: padding))\"}}"
    }

    static func settings(_ date: Date, padding: Int = 0) -> String {
        "{\"timestamp\":\"\(stamp(date))\",\"type\":\"event_msg\",\"payload\":{\"type\":\"thread_settings_applied\",\"pad\":\"\(String(repeating: "y", count: padding))\"}}"
    }

    static func scan(_ name: String, _ lines: [String], recentAfter threshold: Date) -> (Date?, TimeInterval) {
        let file = folder.appendingPathComponent(name + ".jsonl")
        FileManager.default.createFile(atPath: file.path, contents: Data((lines.joined(separator: "\n") + "\n").utf8))
        let handle = try! FileHandle(forReadingFrom: file)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: file) }
        let size = handle.seekToEndOfFile()
        let began = Date()
        let result = CodexActivityScan.latestActivity(in: handle, fileSize: size, recentAfter: threshold)
        return (result, Date().timeIntervalSince(began))
    }

    static func check(_ ok: Bool, _ what: String) {
        guard ok else { print("FAIL: \(what)"); exit(1) }
    }

    static func same(_ a: Date?, _ b: Date) -> Bool { a.map { abs($0.timeIntervalSince(b)) < 0.01 } ?? false }

    static func main() {
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let now = Date()
        let recent = now.addingTimeInterval(-60), old = now.addingTimeInterval(-86_400 * 3)
        let threshold = now.addingTimeInterval(-300)
        let meta = "{\"timestamp\":\"\(stamp(old))\",\"type\":\"session_meta\",\"payload\":{\"id\":\"t\",\"cwd\":\"/x\"}}"
        let big = 46 * 1024 * 1024

        var (date, seconds) = scan("small", [meta, work(old), work(recent)], recentAfter: threshold)
        check(same(date, recent), "a recent tool call is the latest activity")

        (date, seconds) = scan("huge-output-last", [meta, work(old), work(recent, "function_call_output", padding: big)], recentAfter: threshold)
        check(same(date, recent), "a 46 MB tool output line is read by its start and counts")
        check(seconds < 1, "a 46 MB last line is scanned in under a second (took \(seconds) s)")

        (date, seconds) = scan("huge-settings-last", [meta, work(recent), settings(now, padding: big)], recentAfter: threshold)
        check(same(date, recent), "a 46 MB settings line doesn't count and doesn't hide the work before it")
        check(seconds < 1, "a 46 MB settings line is skipped in under a second (took \(seconds) s)")

        (date, _) = scan("replayed", [meta, work(recent), work(old)], recentAfter: threshold)
        check(same(date, recent), "an older replayed record after newer work doesn't hide it")

        (date, _) = scan("all-old", [meta, work(old.addingTimeInterval(-60)), work(old), settings(now)], recentAfter: threshold)
        check(same(date, old), "with nothing recent, the latest older activity is the answer")

        // Work only at the very start, then 100 MB of lines that don't count: past the budget.
        let filler = (0..<100).map { _ in settings(old, padding: 1024 * 1024) }
        (date, seconds) = scan("long-quiet", [meta, work(recent)] + filler, recentAfter: threshold)
        check(date == nil, "work further back than the budget isn't searched for")
        check(seconds < 1, "a 100 MB quiet tail stops at the budget in under a second (took \(seconds) s)")

        // A live session's huge tool output: read whole by the line buffer, judged by its start.
        let output = "{\"timestamp\":\"\(stamp(recent))\",\"type\":\"response_item\",\"payload\":{\"type\":\"function_call_output\",\"call_id\":\"call_7\",\"output\":\"Exit code: 1\\nWall time\(String(repeating: "z", count: big))\"}}"
        var buffer = JSONLLineBuffer()
        let bytes = Data((output + "\n").utf8)
        let began = Date()
        var lines: [String] = []
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + 64 * 1024, bytes.count)
            lines += buffer.append(bytes.subdata(in: offset..<end))
            offset = end
        }
        let took = Date().timeIntervalSince(began)
        check(lines.count == 1 && lines[0].utf8.count == output.utf8.count, "a 46 MB line arriving in 64 KB pieces comes out once, whole")
        check(took < 1, "the line buffer takes a 46 MB line in pieces in under a second (took \(took) s)")
        let record = CodexActivityScan.compactRecord(head: String(lines[0].prefix(CodexActivityScan.headSize)))
        let payload = record?["payload"] as? [String: Any]
        check(payload?["type"] as? String == "function_call_output" && payload?["call_id"] as? String == "call_7",
              "a huge output's start keeps the call id that ends its tool")
        check((payload?["output"] as? String)?.hasPrefix("Exit code: 1") == true, "and the exit code at the start of its output")
        check(record?["timestamp"] as? String == stamp(recent), "and its timestamp")
        let draft = "{\"timestamp\":\"\(stamp(recent))\",\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":["
        check(CodexActivityScan.compactRecord(head: draft) == nil, "an assistant message with no phase in its start isn't taken for a final answer")
        check(CodexActivityScan.compactRecord(head: draft.replacingOccurrences(of: "\"role\":\"assistant\"", with: "\"role\":\"assistant\",\"phase\":\"commentary\"")) != nil,
              "one whose start names its phase is kept")

        print("CodexActivityScanChecks: all passed")
    }
}
