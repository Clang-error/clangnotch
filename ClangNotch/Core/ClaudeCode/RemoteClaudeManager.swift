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
/// Everything runs through `/usr/bin/ssh` with the user's own `~/.ssh/config` and keys; what ssh
/// has to ask goes through `SSHAskpass` (`SSHHost`).
///
/// A host that can't run the setup (Windows has no POSIX shell; no curl, jq or python3) is read
/// instead, as Codex hosts are: a `RemoteSessionFollower` sends its transcripts' new lines and
/// `ClaudeCodeManager.handleRemoteTranscript` turns them into the same events. Nothing is
/// installed there; approval prompts, which only a hook reports, don't show for it.
@MainActor
final class RemoteClaudeManager: ObservableObject {
    static let shared = RemoteClaudeManager()

    /// Human-readable connection state per host, for Settings.
    @Published private(set) var statuses: [String: String] = [:]

    private var hosts: [String] = []
    private var tunnels: [String: Process] = [:]
    /// Write end of each tunnel's stdin. Held open for the tunnel's lifetime — see `openTunnel`.
    private var tunnelInputs: [String: Pipe] = [:]
    /// Followers of the hosts that are read instead of hooked.
    private var readers: [String: RemoteSessionFollower] = [:]
    private var retryTasks: [String: Task<Void, Never>] = [:]
    private var failures: [String: Int] = [:]
    /// Bumped whenever a host is stopped, so an install still running for it gives up.
    private var generations: [String: Int] = [:]

    private nonisolated static let remoteScriptPath = "~/.claude/clangnotch-hook.sh"
    private nonisolated static let hookCommand = "$HOME/.claude/clangnotch-hook.sh"
    private nonisolated static let hookEvents = ["UserPromptSubmit", "PreToolUse", "PostToolUse", "Notification", "Stop", "SessionEnd"]

    private init() {}

    /// Launch: every host from scratch, without asking anything.
    func apply() {
        stopAll()
        sync()
    }

    /// Follows the host list in settings: hosts that left it are dropped, new ones connected.
    /// `asking` is the host the user just added: its questions (trust it? password?) may open a window.
    func sync(asking: String? = nil) {
        let settings = AppSettings.shared
        let wanted = settings.remoteClaudeEnabled ? SSHHost.list(settings.remoteClaudeHosts) : []
        for host in hosts where !wanted.contains(host) { stop(host) }
        for host in wanted where !hosts.contains(host) {
            guard SSHHost.isValid(host) else {
                statuses[host] = L("잘못된 주소", "Invalid address")
                continue
            }
            connect(host, interactive: host == asking)
        }
        hosts = wanted
        statuses = statuses.filter { wanted.contains($0.key) }
    }

    /// 다시 연결: this host again, and this time it may ask.
    func reconnect(_ host: String) {
        guard hosts.contains(host), SSHHost.isValid(host) else { return }
        stop(host)
        connect(host, interactive: true)
    }

    func stopAll() {
        hosts.forEach(stop)
        hosts = []
    }

    private func stop(_ host: String) {
        retryTasks.removeValue(forKey: host)?.cancel()
        generations[host, default: 0] += 1
        // Cleared before terminating so `tunnelClosed` treats this exit as intentional.
        let process = tunnels.removeValue(forKey: host)
        tunnelInputs[host] = nil
        process?.terminate()
        readers.removeValue(forKey: host)?.stop()
        ClaudeCodeManager.shared.removeRemoteSessions(host: host)
        failures[host] = nil
    }

    // MARK: - Connection

    private func connect(_ host: String, interactive: Bool = false) {
        let generation = generations[host, default: 0]
        statuses[host] = L("훅 설치 중…", "Installing hook…")
        Task {
            let remoteHome: String
            do {
                remoteHome = try await Self.install(on: host, interactive: interactive)
            } catch {
                guard self.generations[host, default: 0] == generation else { return }
                // The host can't take the hooks: its transcripts are read instead.
                if (error as? RemoteClaudeError)?.cannotSetUp == true {
                    read(host, interactive: interactive)
                    return
                }
                // Waiting on the user (a host to confirm, a password).
                if (error as? RemoteClaudeError)?.needsUser == true {
                    statuses[host] = error.localizedDescription
                } else {
                    scheduleRetry(host, reason: error.localizedDescription)
                }
                return
            }
            guard self.generations[host, default: 0] == generation else { return }
            openTunnel(host, remoteHome: remoteHome, interactive: interactive)
        }
    }

    /// The hookless way in: follow the host's transcripts (`RemoteSessionFollower`).
    private func read(_ host: String, interactive: Bool) {
        let follower = RemoteSessionFollower(host: host, source: .claude, sink: .lines { file, lines, skew, history in
            // In order, on the main thread: the lines are a conversation.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    ClaudeCodeManager.shared.handleRemoteTranscript(host: host, file: file, lines: lines, skew: skew, history: history)
                }
            }
        }) { [weak self] event in
            guard let self, self.readers[host] != nil else { return }
            switch event {
            case .status(let text):
                self.statuses[host] = text
            case .connected:
                self.statuses[host] = L("연결됨 · 대화 기록 읽기 (훅 없이: 질문·권한 대기는 내용 없이 표시)",
                                        "Connected · reading transcripts (no hooks: questions and approvals show without their text)")
            case .stateFile(let name, let content):
                ClaudeCodeManager.shared.handleRemoteRegistry(host: host, file: name, content: content)
            case .dropped:
                ClaudeCodeManager.shared.removeRemoteSessions(host: host)
            case .agentRunning, .sessionFile:
                break
            }
        }
        readers[host] = follower
        follower.start(interactive: interactive)
    }

    private func openTunnel(_ host: String, remoteHome: String, interactive: Bool) {
        let port = AppSettings.shared.hookPort
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = SSHHost.options + [
            "-o", "ExitOnForwardFailure=yes",
            // A per-user socket rather than a TCP port: no clash with anything on the host, and
            // `install` deletes a stale one first. A TCP bind left by a half-dead session (after
            // sleep) would block reconnecting until the host's sshd noticed, possibly for hours.
            "-R", "\(remoteHome)/.claude/clangnotch.sock:127.0.0.1:\(port)",
        ] + SSHHost.destination(host) + [
            // Reads our stdin pipe: however this app exits (even SIGKILL) the pipe closes,
            // `cat` ends and the tunnel with it, instead of lingering on the host.
            "cat >/dev/null",
        ]
        process.environment = SSHHost.environment(for: host, interactive: interactive)
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
        let failure = SSHHost.failure(stderr, host: host)
        if failure.needsUser {
            statuses[host] = failure.message
        } else {
            scheduleRetry(host, reason: failure.message)
        }
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
    private nonisolated static func install(on host: String, interactive: Bool) async throws -> String {
        let script = hookScript.replacingOccurrences(of: "__HOST__", with: host)
        // The first words stop a host without a POSIX shell before anything is written: cmd.exe
        // runs the `exit`, and Windows PowerShell 5.1 refuses to parse `||` at all.
        let output = try await ssh(host, command: """
            uname >/dev/null 2>&1 || exit 9; set -e; mkdir -p ~/.claude; cat > \(remoteScriptPath); chmod +x \(remoteScriptPath); \
            command -v curl >/dev/null || { echo '\(L("호스트에 curl이 없습니다", "curl is missing on the host"))' >&2; exit 3; }; \
            command -v jq >/dev/null || command -v python3 >/dev/null || { echo '\(L("호스트에 jq나 python3가 없습니다", "jq or python3 is missing on the host"))' >&2; exit 3; }; \
            rm -f ~/.claude/clangnotch.sock; echo "$HOME"; \
            if [ -f ~/.claude/settings.json ]; then cat ~/.claude/settings.json; fi
            """, input: Data(script.utf8), interactive: interactive)
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
            """, input: data, interactive: interactive)
        return remoteHome
    }

    /// Runs one command on `host`, feeding `input` to its stdin. Returns stdout.
    private nonisolated static func ssh(_ host: String, command: String, input: Data, interactive: Bool) async throws -> String {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = SSHHost.options + SSHHost.destination(host) + [command]
            process.environment = SSHHost.environment(for: host, interactive: interactive)
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
                let stderr = String(decoding: errors, as: UTF8.self)
                // 255 is ssh itself (no connection, no login).
                if process.terminationStatus == 255 {
                    let failure = SSHHost.failure(stderr, host: host)
                    throw RemoteClaudeError(failure.message, needsUser: failure.needsUser)
                }
                // The host ran the command and it failed. Our own complaints (no curl, a cut
                // upload) come in plain text; a Windows host answers the sh syntax with an
                // error in its own code page. Neither gets better by trying again: such a host
                // is read instead (`read`).
                let line = lastLine(stderr) ?? ""
                let readable = !line.isEmpty && !line.unicodeScalars.contains("\u{FFFD}")
                throw RemoteClaudeError(readable ? line
                    : L("호스트가 훅 설치 명령을 실행하지 못했습니다", "The host couldn't run the hook setup"),
                    needsUser: true, cannotSetUp: true)
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
    /// Retrying by itself is pointless (`SSHHost.Failure`).
    let needsUser: Bool
    /// The host answered but can't run the hook setup.
    let cannotSetUp: Bool
    init(_ message: String, needsUser: Bool = false, cannotSetUp: Bool = false) {
        self.message = message
        self.needsUser = needsUser
        self.cannotSetUp = cannotSetUp
    }
    var errorDescription: String? { message }
}
