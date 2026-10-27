import Foundation

/// Copies the JSON Claude Code feeds the user's status line to `/claude-hook`, for the one
/// thing its JSONL never says: the session's real context window (`context_window_size`,
/// 200k or 1M). The user's own status line command keeps running after it, unchanged.
/// Without a status line nothing is installed — adding one would replace Claude's footer hints.
enum StatuslineBridge {
    static let marker = ": ClangNotch statusline;"

    static func prefix(port: UInt16) -> String {
        "\(marker) input=$(cat); printf '%s' \"$input\" | curl -s --connect-timeout 0.2 --max-time 1 -X POST http://127.0.0.1:\(port)/claude-hook -H 'Content-Type: application/json' --data-binary @- >/dev/null 2>&1 & printf '%s' \"$input\" | "
    }

    static func install(in file: URL, port: UInt16) throws {
        guard let existing = FileManager.default.contents(atPath: file.path),
              var settings = try JSONSerialization.jsonObject(with: existing) as? [String: Any],
              var statusLine = settings["statusLine"] as? [String: Any],
              statusLine["type"] as? String == "command",
              var command = statusLine["command"] as? String else { return }

        // Already wrapped (perhaps for another port): unwrap back to the user's command first.
        if command.hasPrefix(marker), let range = command.range(of: "& printf '%s' \"$input\" | ") {
            command = String(command[range.upperBound...])
        }
        let wrapped = prefix(port: port) + command
        guard wrapped != statusLine["command"] as? String else { return }
        statusLine["command"] = wrapped
        settings["statusLine"] = statusLine
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let backup = file.appendingPathExtension("clangnotch-statusline-bak")
        if !FileManager.default.fileExists(atPath: backup.path) {
            try existing.write(to: backup, options: .atomic)
        }
        try data.write(to: file.resolvingSymlinksInPath(), options: .atomic)
    }
}
