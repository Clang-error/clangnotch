import Foundation

struct AgentInputOption: Equatable {
    let label: String
    let description: String
}

struct AgentInputQuestion: Equatable {
    let header: String
    let question: String
    let options: [AgentInputOption]
    var multiSelect = false
}


/// A turn that just finished normally; the 완료 드롭다운 shows it and the Done wing opens its session.
struct CompletedTurn: Equatable {
    let id = UUID()
    let sessionId: String
    /// The final answer text as written; `headline` is what the dropdown shows.
    let answer: String
    let elapsed: TimeInterval?

    /// First line of the answer that has words in it, with Markdown markers stripped.
    var headline: String? {
        for line in answer.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: CharacterSet(charactersIn: "#*>-`_ \t"))
            if !text.isEmpty { return text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "") }
        }
        return nil
    }
}

/// What an editing tool changed, for the 세션 화면's diff: the removed and added lines,
/// taken from the tool's own input (no file is read), capped so history stays small.
struct ToolChange: Equatable {
    enum Kind { case removed, added }

    struct Line: Equatable {
        let kind: Kind
        let text: String
    }

    let file: String
    let lines: [Line]

    static let maxLines = 60
    private static let maxLineLength = 200

    /// Claude's Edit, MultiEdit and Write.
    static func claude(toolName: String, input: Any?) -> ToolChange? {
        guard let input = input as? [String: Any], let path = input["file_path"] as? String else { return nil }
        var lines: [Line] = []
        switch toolName {
        case "Edit":
            lines = edit(input["old_string"] as? String, input["new_string"] as? String)
        case "MultiEdit":
            for edit in input["edits"] as? [[String: Any]] ?? [] {
                lines += self.edit(edit["old_string"] as? String, edit["new_string"] as? String)
            }
        case "Write":
            lines = split(input["content"] as? String, .added)
        default:
            return nil
        }
        return make(file: path, lines: lines)
    }

    /// Codex's patch: `*** Update File:` headers and +/- lines. Newer Codex calls it from
    /// inside an `exec` script (`tools.apply_patch("*** Begin Patch\\n…")`), escaped as a
    /// string literal, so the patch is cut out and unescaped first.
    static func patch(_ text: String) -> ToolChange? {
        guard let start = text.range(of: "*** Begin Patch") else { return nil }
        var body = String(text[start.lowerBound...])
        if let end = body.range(of: "*** End Patch") { body = String(body[..<end.upperBound]) }
        if !body.contains("\n") {
            body = body.replacingOccurrences(of: "\\\\", with: "\u{0}")
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\t", with: "\t")
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\u{0}", with: "\\")
        }
        var file = ""
        var lines: [Line] = []
        for raw in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            for prefix in ["*** Add File: ", "*** Update File: ", "*** Delete File: "] where line.hasPrefix(prefix) {
                if file.isEmpty { file = String(line.dropFirst(prefix.count)) }
            }
            if line.hasPrefix("+"), !line.hasPrefix("+++") {
                lines.append(Line(kind: .added, text: String(line.dropFirst())))
            } else if line.hasPrefix("-"), !line.hasPrefix("---") {
                lines.append(Line(kind: .removed, text: String(line.dropFirst())))
            }
        }
        return make(file: file, lines: lines)
    }

    private static func edit(_ old: String?, _ new: String?) -> [Line] {
        split(old, .removed) + split(new, .added)
    }

    private static func split(_ text: String?, _ kind: Kind) -> [Line] {
        guard let text, !text.isEmpty else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: false).map {
            Line(kind: kind, text: String($0.prefix(maxLineLength)))
        }
    }

    private static func make(file: String, lines: [Line]) -> ToolChange? {
        guard !lines.isEmpty else { return nil }
        return ToolChange(file: file, lines: Array(lines.prefix(maxLines)))
    }
}
