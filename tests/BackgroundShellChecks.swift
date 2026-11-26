import Foundation

/// The pure parts of background shells (셸 줄) that the 세션 화면 shows: the command kept whole,
/// a Monitor's event lines, and a Bash shell's output tail.
@main
struct BackgroundShellChecks {
    static func main() {
        // The command is kept whole; the tool's argument stays cut for the lists.
        let long = "cd apps/web && " + String(repeating: "x", count: 200)
        var tool = ClaudeToolExecution(id: "t", toolName: "Bash", argument: ClaudeToolExecution.argument(from: ["command": long]), startTime: Date())
        tool.command = ClaudeToolExecution.command(from: ["command": long])
        precondition(tool.argument?.count == 50 && tool.command == long, "argument cut at 50, command whole")
        precondition(ClaudeToolExecution.command(from: ["command": String(repeating: "y", count: 5000)])?.count == 4000, "capped at 4000")
        let shell = ClaudeBackgroundShells.started(by: ["backgroundTaskId": "b1"], tool: tool,
                                                   resultText: "Output is being written to: /tmp/x/tasks/b1.output", at: Date())
        precondition(shell?.command == long && shell?.outputFile == "/tmp/x/tasks/b1.output", "the shell keeps the command whole")

        // A Monitor event block: every non-empty line, the last one as `event`.
        let block = "<task-notification>\n<task-id>m1</task-id>\n<event>first\n\n  second  \nthird</event>\n</task-notification>"
        let notice = ClaudeBackgroundShells.notices(in: block).first
        precondition(notice?.eventLines == ["first", "second", "third"] && notice?.event == "third", "event lines")

        // Output tail: escapes dropped, \r rewrites keep their last version, indentation kept,
        // blank lines out, a cut first line skipped unless the file was read from its start.
        func tail(_ text: String, fromStart: Bool = true, count: Int = 20) -> [String] {
            ClaudeBackgroundShells.tail(of: Data(text.utf8), count: count, fromStart: fromStart)
        }
        precondition(tail("\u{1B}[32mready\u{1B}[0m in 412 ms\n") == ["ready in 412 ms"], "colour codes dropped")
        precondition(tail("10%\r50%\r100%\ndone\n") == ["100%", "done"], "a progress line keeps its last state")
        precondition(tail("a\r\nb\r\n") == ["a", "b"], "CRLF endings")
        precondition(tail("  ➜  Local:   http://localhost:3000/   \n") == ["  ➜  Local:   http://localhost:3000/"], "indentation kept, trailing space dropped")
        precondition(tail("one\n\n   \ntwo\n") == ["one", "two"], "blank lines out")
        precondition(tail("ut of a line\nwhole\n", fromStart: false) == ["whole"], "a cut first line is skipped")
        precondition(tail("only part of one line", fromStart: false) == ["only part of one line"], "unless it is all there is")
        precondition(tail((1...30).map(String.init).joined(separator: "\n"), count: 3) == ["28", "29", "30"], "the last lines")
        print("BackgroundShellChecks: all passed")
    }
}
