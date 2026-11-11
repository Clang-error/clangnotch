import Foundation

/// The `Stop` hook that lets the 다음 단계 드롭다운 answer the Claude app's next-step box
/// (설정 › 실험 기능). Its buttons send a user message in the app, which nothing outside
/// the app can do, so the answer goes in another way: the hook runs in the background after
/// the turn has ended (`asyncRewake`) and waits on the notch. A pick comes back as its
/// output, and its exit code 2 wakes the idle session with that text (measured 2026-11-11,
/// Claude Code 2.1.322, in a terminal session and in a stream-json one with stdin left open).
enum NextStepHooks {
    static let marker = "# ClangNotch next step"

    /// With nothing to answer, or ClangNotch not running, curl prints nothing and the hook
    /// ends quietly.
    static func command(port: UInt16, maxTime: Int) -> String {
        "out=$(curl -s --connect-timeout 0.2 --max-time \(maxTime) -X POST http://127.0.0.1:\(port)/next-step-hook -H 'Content-Type: application/json' --data-binary @- 2>/dev/null); if [ -n \"$out\" ]; then printf '%s\\n' \"$out\" >&2; exit 2; fi \(marker)"
    }

    /// Adds the hook, or with `enabled` false takes it out. Everything else in the file
    /// stays as it was.
    static func sync(in file: URL, port: UInt16, maxTime: Int, enabled: Bool) throws {
        let existing = FileManager.default.fileExists(atPath: file.path) ? try Data(contentsOf: file) : nil
        var settings: [String: Any] = [:]
        if let existing {
            guard let parsed = try JSONSerialization.jsonObject(with: existing) as? [String: Any] else {
                throw CocoaError(.propertyListReadCorrupt)
            }
            settings = parsed
        }

        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        let before = hooks["Stop"] as? [[String: Any]] ?? []
        // Without ours, and without a group ours leaves empty.
        var groups = before.compactMap { group -> [String: Any]? in
            let handlers = group["hooks"] as? [[String: Any]] ?? []
            let others = handlers.filter { ($0["command"] as? String)?.hasSuffix(marker) != true }
            guard others.count != handlers.count else { return group }
            var group = group
            group["hooks"] = others
            return others.isEmpty ? nil : group
        }
        if enabled {
            groups.append(["hooks": [[
                "type": "command", "command": command(port: port, maxTime: maxTime),
                "asyncRewake": true, "timeout": maxTime + 5,
            ] as [String: Any]]])
        }
        guard !NSArray(array: groups).isEqual(to: before) else { return }
        hooks["Stop"] = groups.isEmpty ? nil : groups
        settings["hooks"] = hooks.isEmpty ? nil : hooks
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let backup = file.appendingPathExtension("clangnotch-nextstep-bak")
        if let existing, !FileManager.default.fileExists(atPath: backup.path) {
            try existing.write(to: backup, options: .atomic)
        }
        try data.write(to: file.resolvingSymlinksInPath(), options: .atomic)
    }
}
