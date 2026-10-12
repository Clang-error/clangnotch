//
//  RemoteClaudeManager.swift
//  ClangNotch
//
//  Mirrors Claude Code sessions running on SSH hosts into the notch.
//

import Foundation

/// For each host alias in `AppSettings.remoteClaudeHosts` this (1) installs a hook script and
/// the hook entries that call it into the host's `~/.claude`, then (2) holds an SSH reverse
/// tunnel so the host's `~/.claude/clangnotch.sock` reaches this app's receiver. The receiver's
/// `/claude-hook` route hands those events to `ClaudeCodeManager.handleRemoteHook`.
/// Everything runs through `/usr/bin/ssh` with the user's own `~/.ssh/config` and keys.
@MainActor
final class RemoteClaudeManager: ObservableObject {
    static let shared = RemoteClaudeManager()

    /// Human-readable connection state per host, for Settings.
    @Published private(set) var statuses: [String: String] = [:]

    private var hosts: [String] = []
    private var tunnels: [String: Process] = [:]
    /// Write end of each tunnel's stdin. Held open for the tunnel's lifetime — see `openTunnel`.
    private var tunnelInputs: [String: Pipe] = [:]
    private var retryTasks: [String: Task<Void, Never>] = [:]
    private var failures: [String: Int] = [:]
    /// Bumped on every `apply()` so work started for an older host list gives up.
    private var generation = 0

    private nonisolated static let remoteScriptPath = "~/.claude/clangnotch-hook.sh"
    private nonisolated static let hookCommand = "$HOME/.claude/clangnotch-hook.sh"
    private nonisolated static let hookEvents = ["UserPromptSubmit", "PreToolUse", "PostToolUse", "Notification", "Stop", "SessionEnd"]
    /// Never share (or tear down) the user's interactive ControlMaster connection; the alive
    /// probes bound a stalled install and notice a dead tunnel within ~45s.
    private nonisolated static let baseOptions = [
        "-T", "-o", "BatchMode=yes", "-o", "ControlMaster=no", "-o", "ControlPath=none",
        "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
    ]

    private init() {}

    /// Re-reads the host list from settings and reconnects every host.
    func apply() {
        stopAll()
        generation += 1
        var seen = Set<String>()
        hosts = AppSettings.shared.remoteClaudeHosts
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        statuses = [:]
        for host in hosts {
            // The alias is baked into a shell script and passed to ssh as an argument.
            guard !host.hasPrefix("-"), host.allSatisfy({ $0.isLetter || $0.isNumber || "._@-".contains($0) }) else {
                statuses[host] = L("잘못된 호스트 별칭", "Invalid host alias")
                continue
            }
            connect(host)
        }
    }

    func stopAll() {
        retryTasks.values.forEach { $0.cancel() }
        retryTasks = [:]
        // Cleared before terminating so `tunnelClosed` treats these exits as intentional.
        let running = tunnels
        tunnels = [:]
        tunnelInputs = [:]
        running.values.forEach { $0.terminate() }
        hosts.forEach { ClaudeCodeManager.shared.removeRemoteSessions(host: $0) }
        failures = [:]
    }

    // MARK: - Connection

    private func connect(_ host: String) {
        let generation = generation
        statuses[host] = L("훅 설치 중…", "Installing hook…")
        Task {
            let remoteHome: String
            do {
                remoteHome = try await Self.install(on: host)
            } catch {
                guard self.generation == generation else { return }
                scheduleRetry(host, reason: error.localizedDescription)
                return
            }
            guard self.generation == generation else { return }
            openTunnel(host, remoteHome: remoteHome)
        }
    }

    private func openTunnel(_ host: String, remoteHome: String) {
        let port = AppSettings.shared.telemetryOtlpPort
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = Self.baseOptions + [
            "-o", "ExitOnForwardFailure=yes",
            // A per-user socket rather than a TCP port: no clash with anything on the host, and
            // `install` deletes a stale one first. A TCP bind left by a half-dead session (after
            // sleep) would block reconnecting until the host's sshd noticed, possibly for hours.
            "-R", "\(remoteHome)/.claude/clangnotch.sock:127.0.0.1:\(port)",
            host,
            // Reads our stdin pipe: however this app exits (even SIGKILL) the pipe closes,
            // `cat` ends and the tunnel with it, instead of lingering on the host.
            "cat >/dev/null",
        ]
        let input = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        process.terminationHandler = { [weak self] process in
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            Task { @MainActor in self?.tunnelClosed(host, process: process, stderr: message) }
        }
        do {
            try process.run()
        } catch {
            scheduleRetry(host, reason: error.localizedDescription)
            return
        }
        tunnels[host] = process
        tunnelInputs[host] = input
        statuses[host] = L("연결 중…", "Connecting…")

        // ssh reports a refused forward only after logging in, so call it up once it survives that.
        Task {
            try? await Task.sleep(for: .seconds(5))
            guard tunnels[host] === process else { return }
            statuses[host] = L("연결됨", "Connected")
            // Back off from scratch only once the tunnel has proven stable.
            try? await Task.sleep(for: .seconds(55))
            guard tunnels[host] === process else { return }
            failures[host] = 0
        }
    }

    private func tunnelClosed(_ host: String, process: Process, stderr: String) {
        guard tunnels[host] === process else { return }
        tunnels[host] = nil
        tunnelInputs[host] = nil
        // No more events (not even Stop) can arrive; don't leave rows reading as working.
        ClaudeCodeManager.shared.removeRemoteSessions(host: host)
        scheduleRetry(host, reason: Self.lastLine(stderr) ?? L("연결 끊김", "Disconnected"))
    }

    private func scheduleRetry(_ host: String, reason: String) {
        let attempt = failures[host, default: 0]
        failures[host] = attempt + 1
        let delay = min(60, 5 << min(attempt, 4))
        statuses[host] = L("\(reason) — \(delay)초 후 재시도", "\(reason) — retrying in \(delay)s")
        retryTasks[host] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.connect(host)
        }
    }

    // MARK: - Host setup

    /// Writes the hook script, checks its dependencies, clears a stale tunnel socket, and merges
    /// the hook entries into the host's `~/.claude/settings.json` (backed up first, written only
    /// when something is missing). Returns the host's home directory for the socket path.
    private nonisolated static func install(on host: String) async throws -> String {
        let script = hookScript.replacingOccurrences(of: "__HOST__", with: host)
        let output = try await ssh(host, command: """
            set -e; mkdir -p ~/.claude; cat > \(remoteScriptPath); chmod +x \(remoteScriptPath); \
            command -v curl >/dev/null || { echo '\(L("호스트에 curl이 없습니다", "curl is missing on the host"))' >&2; exit 3; }; \
            command -v jq >/dev/null || command -v python3 >/dev/null || { echo '\(L("호스트에 jq나 python3가 없습니다", "jq or python3 is missing on the host"))' >&2; exit 3; }; \
            rm -f ~/.claude/clangnotch.sock; echo "$HOME"; \
            if [ -f ~/.claude/settings.json ]; then cat ~/.claude/settings.json; fi
            """, input: Data(script.utf8))
        let (homeLine, current) = output.firstIndex(of: "\n").map {
            (String(output[..<$0]), String(output[output.index(after: $0)...]))
        } ?? (output, "")
        let remoteHome = homeLine.trimmingCharacters(in: .whitespaces)
        guard remoteHome.hasPrefix("/") else { throw RemoteClaudeError(L("호스트의 홈 디렉터리를 읽지 못했습니다", "Couldn't read the host's home directory")) }

        var settings: [String: Any] = [:]
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let parsed = try? JSONSerialization.jsonObject(with: Data(current.utf8)) as? [String: Any] else {
                throw RemoteClaudeError(L("호스트의 ~/.claude/settings.json이 순수 JSON이 아니어서 건드리지 않았습니다", "Host's ~/.claude/settings.json isn't plain JSON; left untouched"))
            }
            settings = parsed
        }

        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        var changed = false
        for event in hookEvents {
            var groups = hooks[event] as? [[String: Any]] ?? []
            let installed = groups.contains { group in
                (group["hooks"] as? [[String: Any]])?.contains { $0["command"] as? String == hookCommand } == true
            }
            guard !installed else { continue }
            groups.append(["hooks": [["type": "command", "command": hookCommand]]])
            hooks[event] = groups
            changed = true
        }
        guard changed else { return remoteHome }
        settings["hooks"] = hooks

        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        // A dropped connection ends the remote `cat` like a normal EOF, so the byte count is what
        // proves the upload is whole. Copying into the file (not `mv`) keeps a dotfiles symlink.
        _ = try await ssh(host, command: """
            f=~/.claude/settings.json; t="$f.clangnotch-tmp"; cat > "$t"; \
            [ "$(wc -c < "$t")" -eq \(data.count) ] || { rm -f "$t"; echo '\(L("업로드가 중간에 끊겨 settings.json을 건드리지 않았습니다", "Upload was cut short; settings.json left untouched"))' >&2; exit 4; }; \
            cp "$f" "$f.clangnotch-bak" 2>/dev/null || true; cat "$t" > "$f"; rm -f "$t"
            """, input: data)
        return remoteHome
    }

    /// Runs one command on `host`, feeding `input` to its stdin. Returns stdout.
    private nonisolated static func ssh(_ host: String, command: String, input: Data) async throws -> String {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = baseOptions + ["-o", "ConnectTimeout=10", host, command]
            let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = stderr
            // A failed login closes ssh's stdin early; get an error instead of a fatal SIGPIPE.
            _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            try process.run()
            try? stdin.fileHandleForWriting.write(contentsOf: input)
            try? stdin.fileHandleForWriting.close()
            let output = stdout.fileHandleForReading.readDataToEndOfFile()
            let errors = stderr.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw RemoteClaudeError(lastLine(String(decoding: errors, as: UTF8.self))
                    ?? L("ssh가 상태 \(process.terminationStatus)로 종료됨", "ssh exited with status \(process.terminationStatus)"))
            }
            return String(decoding: output, as: UTF8.self)
        }.value
    }

    private nonisolated static func lastLine(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline).last.map { String($0).trimmingCharacters(in: .whitespaces) }
    }

    /// Installed as `~/.claude/clangnotch-hook.sh`. Trims each event to the few fields the
    /// notch shows (PostToolUse carries the whole tool output) and posts it in the
    /// background so Claude never waits on the network. Prints nothing: UserPromptSubmit
    /// hook output would be added to Claude's context.
    private nonisolated static let hookScript = #"""
        #!/bin/sh
        # Installed by ClangNotch: forwards Claude Code hook events to the Mac through the
        # SSH reverse tunnel the app keeps open. Remove the "clangnotch-hook.sh" entries
        # from ~/.claude/settings.json to uninstall.
        host='__HOST__'
        payload=$(cat)
        if command -v jq >/dev/null 2>&1; then
          body=$(printf '%s' "$payload" | jq -c --arg host "$host" '{session_id, hook_event_name, cwd, tool_name, tool_use_id, notification_type,
            prompt: ((.prompt // "") | .[0:300]),
            tool_input: (if .tool_name == "AskUserQuestion" then .tool_input elif (.tool_input | type) == "object" then (.tool_input | with_entries(select(.value | type == "string") | .value |= .[0:200])) else null end),
            clangnotch_host: $host}') || exit 0
        else
          body=$(printf '%s' "$payload" | python3 -c '
        import json, sys
        d = json.load(sys.stdin)
        o = {k: d.get(k) for k in ("session_id", "hook_event_name", "cwd", "tool_name", "tool_use_id", "notification_type")}
        o["prompt"] = (d.get("prompt") or "")[:300]
        t = d.get("tool_input")
        o["tool_input"] = t if d.get("tool_name") == "AskUserQuestion" else ({k: v[:200] for k, v in t.items() if isinstance(v, str)} if isinstance(t, dict) else None)
        o["clangnotch_host"] = sys.argv[1]
        print(json.dumps(o))
        ' "$host") || exit 0
        fi
        ( curl -s -m 3 --unix-socket "$HOME/.claude/clangnotch.sock" -X POST http://localhost/claude-hook -H 'Content-Type: application/json' --data-binary "$body" & ) </dev/null >/dev/null 2>&1
        exit 0

        """#
}

struct RemoteClaudeError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
