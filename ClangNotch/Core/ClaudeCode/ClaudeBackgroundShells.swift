import Foundation

/// Reading background shells out of a Claude Code transcript, and when the turn that waits
/// on them may be announced. No state of its own, so `tests/BackgroundShellChecks.swift`
/// runs it on real line shapes.
///
/// Measured 2026-11-26 (Claude Code 2.1.332):
/// - A Bash call's result carries `toolUseResult.backgroundTaskId` when the shell runs on in
///   the background: asked for (`run_in_background`) or moved there on its timeout. A Monitor's
///   carries `taskId` and `timeoutMs`. The result text names a Bash shell's output file.
/// - The end is a `<task-notification>` with that `<task-id>` and a `<status>` (completed,
///   failed, killed, stopped). The same block comes as a `queue-operation` enqueue, a
///   `queued_command` attachment while a turn runs, and a user line that starts a turn. A
///   Monitor's output lines come as blocks with an `<event>` and no status. The tag also
///   carries Stop-hook feedback and other notices, which name no tracked task.
/// - While only shells run, the session's registry record says `status: shell`; each Monitor
///   event starts a turn (`busy`) and it goes back to `shell` after.
enum ClaudeBackgroundShells {
    /// A notification block about one task.
    struct Notice: Equatable {
        let taskId: String
        /// nil for a Monitor's output line.
        let status: String?
        let exitCode: Int?
        /// A Monitor event's last non-empty line.
        let event: String?
        /// All of a Monitor event's non-empty lines, for the 세션 화면.
        var eventLines: [String] = []

        /// A real failure: exit codes 143 and 144 are a signal ending the shell (the session
        /// closing it, a timeout), which reads as stopped, not as the command failing.
        var isFailure: Bool { status == "failed" && exitCode != 143 && exitCode != 144 }
    }

    /// A turn waiting on shells is announced once they have printed nothing for this long.
    static let quietLimit: TimeInterval = 600
    /// ...or once it has waited this long in all, whatever they print (a dev server's log).
    static let waitLimit: TimeInterval = 1800
    /// Output lines the 세션 화면 shows for a shell, and Monitor event lines a shell keeps.
    static let keptEvents = 20
    static let tailLines = 20
    /// How much of a Bash shell's output file is read for its last lines.
    static let tailBytes = 16 * 1024

    /// The shell a tool result line started, if it started one. `tool` is the call it
    /// answers, for the name; `resultText` the result's text, for the output file.
    static func started(by toolUseResult: [String: Any], tool: ClaudeToolExecution?,
                        resultText: String?, at date: Date) -> ClaudeBackgroundShell? {
        let isMonitor: Bool
        let taskId: String
        if let id = toolUseResult["backgroundTaskId"] as? String {
            (isMonitor, taskId) = (false, id)
        } else if tool?.toolName == "Monitor", let id = toolUseResult["taskId"] as? String {
            (isMonitor, taskId) = (true, id)
        } else {
            return nil
        }
        let description = tool?.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = tool?.argument?
            .split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) }
        let title = [description, command].compactMap { $0 }.first { !$0.isEmpty } ?? (isMonitor ? "Monitor" : "Bash")
        let outputFile = resultText.flatMap { text -> String? in
            guard let range = text.range(of: "Output is being written to: ") else { return nil }
            var path = String(text[range.upperBound...].prefix { !$0.isWhitespace })
            if path.hasSuffix(".") { path.removeLast() }
            return path.hasSuffix(".output") ? path : nil
        }
        return ClaudeBackgroundShell(id: taskId, isMonitor: isMonitor, title: title, startTime: date,
                                     outputFile: isMonitor ? nil : outputFile, command: tool?.command ?? tool?.argument)
    }

    /// The text a line carries notifications in, whichever of its shapes it is.
    static func notificationText(in json: [String: Any]) -> String? {
        let text: String?
        switch json["type"] as? String {
        case "queue-operation": text = json["content"] as? String
        case "attachment": text = (json["attachment"] as? [String: Any])?["prompt"] as? String
        case "user": text = (json["message"] as? [String: Any])?["content"] as? String
        default: text = nil
        }
        guard let text, text.contains("<task-notification>") || text.contains("didn't finish before") else { return nil }
        return text
    }

    /// Every task notification block in `text`.
    static func notices(in text: String) -> [Notice] {
        var notices: [Notice] = []
        var rest = text[...]
        while let open = rest.range(of: "<task-notification>") {
            let after = rest[open.upperBound...]
            let close = after.range(of: "</task-notification>")
            let block = close.map { after[..<$0.lowerBound] } ?? after
            rest = close.map { after[$0.upperBound...] } ?? ""
            guard let taskId = tag("task-id", in: block) else { continue }
            let summary = tag("summary", in: block)
            let exitCode = summary.flatMap { summary -> Int? in
                guard let range = summary.range(of: "exit code ") else { return nil }
                return Int(summary[range.upperBound...].prefix { $0.isNumber })
            }
            let eventLines = (tag("event", in: block) ?? "").split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            notices.append(Notice(taskId: taskId, status: tag("status", in: block), exitCode: exitCode,
                                  event: eventLines.last, eventLines: eventLines))
        }
        return notices
    }

    /// Task ids a new process reports as left unfinished by the one before it ("N background
    /// shell command tasks didn't finish before the previous session ended. Task ids: b…, b…").
    static func abandoned(in text: String) -> [String] {
        guard text.contains("didn't finish before"), let range = text.range(of: "Task ids: ") else { return [] }
        return text[range.upperBound...].prefix { $0 != "\n" && $0 != "<" }
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "."))) }
            .filter { !$0.isEmpty }
    }

    /// Whether a turn that has waited since `since` on `holding` (the shells still holding
    /// it) may be announced now: none is left, or they have been quiet for `quietLimit`, or
    /// it has waited `waitLimit` in all.
    static func releasesWait(since: Date, holding: [ClaudeBackgroundShell], now: Date) -> Bool {
        guard !holding.isEmpty else { return true }
        let quietSince = max(since, holding.compactMap(\.lastOutput).max() ?? since)
        return now.timeIntervalSince(quietSince) >= quietLimit || now.timeIntervalSince(since) >= waitLimit
    }

    /// The last `count` lines of a shell's output as a terminal would leave them: escape
    /// sequences dropped, a line rewritten with \r kept as its last version, blank lines out.
    /// `data` is the end of the file, so its first line may be cut and is skipped unless it is all.
    static func tail(of data: Data, count: Int = tailLines, fromStart: Bool) -> [String] {
        let text = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
            // "\r\n" is one Character to Swift, so it would split on neither.
            .replacingOccurrences(of: "\r\n", with: "\n")
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if !fromStart, lines.count > 1 { lines.removeFirst() }
        return Array(lines
            .map { line -> String in
                let shown = line.split(separator: "\r").last.map(String.init) ?? ""
                return shown.replacingOccurrences(of: "[\\p{Cc}&&[^\\t]]", with: "", options: .regularExpression)
                    .replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .suffix(count))
    }

    private static func tag(_ name: String, in block: Substring) -> String? {
        guard let open = block.range(of: "<\(name)>"),
              let close = block[open.upperBound...].range(of: "</\(name)>") else { return nil }
        let value = block[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
