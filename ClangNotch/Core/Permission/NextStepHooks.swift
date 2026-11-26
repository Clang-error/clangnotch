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
    static func command(socket: String, maxTime: Int) -> String {
        "out=$(\(HookSocket.curl("/next-step-hook", socket: socket, maxTime: maxTime)) 2>/dev/null); if [ -n \"$out\" ]; then printf '%s\\n' \"$out\" >&2; exit 2; fi \(marker)"
    }

    /// Adds the hook, or with `enabled` false takes it out. Everything else in the file
    /// stays as it was.
    static func sync(in file: URL, socket: String, maxTime: Int, enabled: Bool) throws {
        try HookSettingsFile.sync(file, event: "Stop", marker: marker, backupSuffix: "clangnotch-nextstep-bak",
                                  group: enabled ? ["hooks": [[
                                      "type": "command", "command": command(socket: socket, maxTime: maxTime),
                                      "asyncRewake": true, "timeout": maxTime + 5,
                                  ] as [String: Any]]] : nil)
    }
}

/// One ClangNotch hook in a `settings.json` that comes and goes with a setting.
enum HookSettingsFile {
    /// Takes out `event`'s handlers ending in `marker` (and a group that leaves empty), then
    /// adds `group` if there is one. Everything else in the file stays as it was; the first
    /// change keeps a copy of the file beside it.
    static func sync(_ file: URL, event: String, marker: String, backupSuffix: String, group: [String: Any]?) throws {
        let existing = FileManager.default.fileExists(atPath: file.path) ? try Data(contentsOf: file) : nil
        var settings: [String: Any] = [:]
        if let existing {
            guard let parsed = try JSONSerialization.jsonObject(with: existing) as? [String: Any] else {
                throw CocoaError(.propertyListReadCorrupt)
            }
            settings = parsed
        }

        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        let before = hooks[event] as? [[String: Any]] ?? []
        // Without ours, and without a group ours leaves empty.
        var groups = before.compactMap { group -> [String: Any]? in
            let handlers = group["hooks"] as? [[String: Any]] ?? []
            let others = handlers.filter { ($0["command"] as? String)?.hasSuffix(marker) != true }
            guard others.count != handlers.count else { return group }
            var group = group
            group["hooks"] = others
            return others.isEmpty ? nil : group
        }
        if let group { groups.append(group) }
        guard !NSArray(array: groups).isEqual(to: before) else { return }
        hooks[event] = groups.isEmpty ? nil : groups
        settings["hooks"] = hooks.isEmpty ? nil : hooks
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let backup = file.appendingPathExtension(backupSuffix)
        if let existing, !FileManager.default.fileExists(atPath: backup.path) {
            try existing.write(to: backup, options: .atomic)
        }
        try data.write(to: file.resolvingSymlinksInPath(), options: .atomic)
    }
}
