import Foundation

/// The model a session runs, named short for the 세션 줄's badge and the 세션 화면 (2026-11-19):
/// "claude-opus-5-5" → "Opus 5.5", "claude-3-5-sonnet-20241022" → "Sonnet 3.5",
/// "gpt-6.1-sol" → "GPT-6.1 Sol", "gpt-5-codex" → "GPT-5 Codex". The family and its number
/// only: no context size or date. Anything else is shown as it comes.
enum ModelName {
    static func short(_ id: String) -> String? {
        var id = id.lowercased()
        if let bracket = id.firstIndex(of: "[") { id = String(id[..<bracket]) }
        // "<synthetic>": Claude Code's own messages (an API error), no model at all.
        guard !id.isEmpty, !id.hasPrefix("<") else { return nil }
        let parts = id.split(separator: "-").map(String.init)
        if parts.first == "claude" {
            // Dates ("20241022") go; the family is the first word, its number the digits around it.
            let rest = parts.dropFirst().filter { !($0.count == 8 && $0.allSatisfy(\.isNumber)) }
            guard let family = rest.first(where: { $0.first?.isLetter == true }) else { return id }
            let number = rest.filter { $0.allSatisfy(\.isNumber) }.joined(separator: ".")
            return number.isEmpty ? family.capitalized : "\(family.capitalized) \(number)"
        }
        if parts.first == "gpt", parts.count >= 2 {
            return (["GPT-" + parts[1]] + parts.dropFirst(2).map(\.capitalized)).joined(separator: " ")
        }
        return id
    }
}
