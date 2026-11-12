//
//  RemoteCodexManager.swift
//  ClangNotch
//
//  Mirrors Codex sessions running on SSH hosts into the notch.
//

import Foundation

/// For each host alias in `AppSettings.remoteCodexHosts` this holds one SSH connection on which a
/// small follower script sends what the host's Codex appends to its session files
/// (`~/.codex/sessions/**/rollout-*.jsonl`), and writes that into a file of the same name under
/// `CodexSession.remoteMirrorRoot/<host>/`. `CodexManager` scans that folder next to this Mac's own sessions, so a
/// remote session works like a local one: wings, questions, Done, the 세션 화면.
///
/// Nothing is installed or changed on the host (unlike `RemoteClaudeManager`'s hooks): the script
/// travels with the command and only reads. Codex writes everything the notch shows into its
/// session files, which hooks would only repeat, and Codex hooks need trusting on each host.
/// What the files don't carry stays local-only: approval requests (a hook) and answering
/// questions from the notch (Codex's own sockets).
///
/// The follower is POSIX `sh` (Linux, macOS, WSL, Git Bash) or Windows PowerShell 5.1; whichever
/// answers with the hello line is used. Everything runs through `/usr/bin/ssh` with the user's
/// own `~/.ssh/config` and keys; what ssh has to ask goes through `SSHAskpass` (`SSHHost`).
@MainActor
final class RemoteCodexManager: ObservableObject {
    static let shared = RemoteCodexManager()

    /// Human-readable connection state per host, for Settings.
    @Published private(set) var statuses: [String: String] = [:]

    private enum Shell: String { case sh, powershell }

    private var hosts: [String] = []
    private var followers: [String: Process] = [:]
    private var writers: [String: RemoteCodexMirror] = [:]
    /// Write end of the pipe each PowerShell follower's `sshWatch` reads, held open for the
    /// follower's lifetime.
    private var inputs: [String: Pipe] = [:]
    /// The shell that answered on each host, tried first the next time.
    private var shells: [String: Shell] = [:]
    /// Followers that got as far as their hello line.
    private var greeted: Set<ObjectIdentifier> = []
    private var hostsWithCodex: Set<String> = []
    private var retryTasks: [String: Task<Void, Never>] = [:]
    private var failures: [String: Int] = [:]

    private init() {}

    /// Whether some Codex process runs on the host, by its follower's last word. A session left
    /// working by a Codex that is gone is cleared on this (`CodexManager.clearEndedSessions`).
    func codexRunning(on host: String) -> Bool { hostsWithCodex.contains(host) }

    /// Launch, or the agent switched on or off: every host from scratch, without asking anything.
    func apply() {
        stopAll()
        try? FileManager.default.removeItem(at: CodexSession.remoteMirrorRoot)
        sync()
    }

    /// Follows the host list in settings: hosts that left it are dropped, new ones connected.
    /// `asking` is the host the user just added: its questions (trust it? password?) may open a window.
    func sync(asking: String? = nil) {
        let wanted = AppSettings.shared.enableCodexJSONL && !DemoMode.isActive
            ? SSHHost.list(AppSettings.shared.remoteCodexHosts) : []
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
        greeted = []
    }

    private func stop(_ host: String) {
        retryTasks.removeValue(forKey: host)?.cancel()
        // Cleared before terminating so `followerClosed` treats this exit as intentional.
        let process = followers.removeValue(forKey: host)
        closeInputs(host)
        process?.terminate()
        removeMirror(host)
        failures[host] = nil
    }

    // MARK: - Connection

    private func connect(_ host: String, interactive: Bool = false) {
        start(host, shell: shells[host] ?? .sh, interactive: interactive)
    }

    private func start(_ host: String, shell: Shell, interactive: Bool) {
        let directory = CodexSession.remoteMirrorRoot.appendingPathComponent(host, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        let input = Pipe(), output = Pipe(), errors = Pipe()
        switch shell {
        case .sh:
            // The script goes in on stdin: whatever the login shell is (fish, csh), nothing of
            // it has to survive that shell's quoting.
            process.arguments = SSHHost.options + SSHHost.destination(host) + ["sh"]
        case .powershell:
            // -EncodedCommand reads the same from cmd.exe and from PowerShell as the default shell.
            let encoded = Self.powerShellFollower.data(using: .utf16LittleEndian)!.base64EncodedString()
            // Through `sshWatch`, which ends ssh when this app is gone: see below.
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", Self.sshWatch, "sh"] + SSHHost.options + SSHHost.destination(host) + [
                "powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand \(encoded)",
            ]
        }
        process.environment = SSHHost.environment(for: host, interactive: interactive)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        let writer = RemoteCodexMirror(directory: directory) { [weak self] event in
            Task { @MainActor in self?.handle(event, host: host, shell: shell, process: process) }
        }
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { writer.receive(data) }
        }
        process.terminationHandler = { [weak self] process in
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            Task { @MainActor in
                self?.followerClosed(host, shell: shell, interactive: interactive, process: process, stderr: message)
            }
        }
        do {
            try process.run()
        } catch {
            scheduleRetry(host, reason: error.localizedDescription)
            return
        }
        // A failed login closes ssh's stdin early; get an error instead of a fatal SIGPIPE.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        switch shell {
        case .sh:
            try? input.fileHandleForWriting.write(contentsOf: Data(Self.shFollower.utf8))
            try? input.fileHandleForWriting.close()
        case .powershell:
            // Left open for `sshWatch`. An sh follower needs none: it dies on its next write.
            inputs[host] = input
        }

        followers[host] = process
        writers[host] = writer
        statuses[host] = L("연결 중…", "Connecting…")
    }

    private func handle(_ event: RemoteCodexMirror.Event, host: String, shell: Shell, process: Process) {
        guard followers[host] === process else { return }
        switch event {
        case .hello(let skew):
            greeted.insert(ObjectIdentifier(process))
            shells[host] = shell
            // A clock that far off would hide every session: the notch only shows recent work.
            statuses[host] = skew == 0 ? L("연결됨", "Connected")
                : L("연결됨 · 호스트 시계 \(Int(abs(skew)))초 차이 보정", "Connected · host clock \(Int(abs(skew)))s off, corrected")
            // Back off from scratch only once the connection has proven stable.
            Task {
                try? await Task.sleep(for: .seconds(60))
                guard followers[host] === process else { return }
                failures[host] = 0
            }
        case .heartbeat(let codexRunning):
            if codexRunning { hostsWithCodex.insert(host) } else { hostsWithCodex.remove(host) }
        case .sessionFile:
            // Don't wait out the 10 s scan for a session that just started.
            CodexManager.shared.scanForSessions()
        case .failed:
            process.terminate()
        }
    }

    private func followerClosed(_ host: String, shell: Shell, interactive: Bool, process: Process, stderr: String) {
        let hadGreeted = greeted.remove(ObjectIdentifier(process)) != nil
        guard followers[host] === process else { return }
        followers[host] = nil
        closeInputs(host)
        // No more lines can arrive; don't leave rows reading as working.
        removeMirror(host)
        // ssh itself failing is 255. Anything else before the hello is the host not having this
        // shell (Windows has no sh): the other one gets its turn before giving up.
        if !hadGreeted, process.terminationStatus != 255, shell == .sh, shells[host] == nil {
            start(host, shell: .powershell, interactive: interactive)
            return
        }
        if !hadGreeted, process.terminationStatus != 255 {
            shells[host] = nil
            scheduleRetry(host, reason: L("호스트에서 sh도 PowerShell도 실행하지 못했습니다", "Neither sh nor PowerShell ran on the host"))
            return
        }
        let failure = SSHHost.failure(stderr, host: host)
        // Waiting on the user (a host to confirm, a password): trying again alone can't help.
        if failure.needsUser, !hadGreeted {
            statuses[host] = failure.message
            return
        }
        scheduleRetry(host, reason: failure.message)
    }

    /// Closed by hand: the `Process` keeps its pipe alive, and `sshWatch` waits on this end.
    private func closeInputs(_ host: String? = nil) {
        for key in host.map({ [$0] }) ?? Array(inputs.keys) {
            try? inputs.removeValue(forKey: key)?.fileHandleForWriting.close()
        }
    }

    private func removeMirror(_ host: String) {
        writers.removeValue(forKey: host)?.stop()
        hostsWithCodex.remove(host)
        CodexManager.shared.removeRemoteSessions(host: host)
        try? FileManager.default.removeItem(at: CodexSession.remoteMirrorRoot.appendingPathComponent(host, isDirectory: true))
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

    // MARK: - Followers

    // Both speak the same lines on stdout, read by `RemoteCodexMirror`:
    //   @C <shell> <unix time>          once, at the start
    //   @F <file name> <kind> <bytes>   followed by that many bytes of the file
    //   @H <0|1>                        every 3 s: whether a Codex process runs on the host
    // The files are looked at every second, and every 3 s once nothing has changed for a minute:
    // at one second the Linux follower took 1.4% of a core and the Windows one 0.6% (2026-11-12).
    // A file modified in the last 5 minutes, or later, is sent as `meta` (its first line), then
    // `tail` (the rest) or `part` (its last 256 KB, starting mid-line); what it grows by after
    // that as `data`. Files are followed by their size: a file Codex holds open keeps a stale
    // modification time in a Windows folder listing.

    /// Ends by itself when the connection goes: the next write fails (SIGPIPE).
    private nonisolated static let shFollower = #"""
        d="${CODEX_HOME:-$HOME/.codex}/sessions"
        umask 077
        t=$(mktemp -d) || exit 1
        trap 'rm -rf "$t"' EXIT
        trap 'exit 0' HUP INT TERM PIPE
        printf '@C sh %s\n' "$(date +%s)" || exit 0
        first=1
        q=0
        e=3
        while :; do
          touch "$t/next"
          if [ $first = 1 ]; then set -- -mmin -5; else set -- -newer "$t/mark"; fi
          find "$d" -type f -name 'rollout-*.jsonl' "$@" 2>/dev/null | while IFS= read -r f; do
            k=${f##*/}
            s=$(wc -c < "$f" 2>/dev/null) || continue
            s=$((s))
            send() {
              tail -c "+$(($2 + 1))" "$f" 2>/dev/null | head -c "$(($3 - $2))" > "$t/buf"
              c=$(wc -c < "$t/buf"); c=$((c))
              printf '@F %s %s %s\n' "$k" "$1" "$c"
              cat "$t/buf"
            }
            if [ -f "$t/o-$k" ]; then
              o=$(cat "$t/o-$k")
              [ "$s" -gt "$o" ] || continue
              send data "$o" "$s"
            else
              m=$(head -n 1 "$f" | wc -c); m=$((m))
              send meta 0 "$m"
              o=$((s - 262144))
              if [ "$o" -gt "$m" ]; then send part "$o" "$s"; else send tail "$m" "$s"; fi
            fi
            echo "$s" > "$t/o-$k"
            : > "$t/hit"
          done
          mv -f "$t/next" "$t/mark"
          first=0
          q=$((q + 1))
          if [ -f "$t/hit" ]; then rm -f "$t/hit"; q=0; fi
          if [ "$e" -ge 3 ]; then
            e=0
            if pgrep -f codex >/dev/null 2>&1; then a=1; else a=0; fi
            printf '@H %s\n' "$a" || exit 0
          fi
          if [ "$q" -lt 60 ]; then w=1; else w=3; fi
          e=$((e + w))
          sleep "$w"
        done </dev/null

        """#

    /// Runs ssh (its arguments) and ends it when stdin closes, which it does however this app
    /// exits, even SIGKILL. Windows needs this: with the app gone nobody reads ssh's output, but
    /// the follower's writes still succeed there and neither a closed stdin nor bytes written to
    /// it reach a Windows command, so ssh and the follower stayed up for good (2026-11-12).
    /// The script's status is ssh's own.
    private nonisolated static let sshWatch =
        #"exec 3<&0; /usr/bin/ssh "$@" </dev/null 3<&- & s=$!; (cat <&3; kill $s) >/dev/null 2>&1 & exec 3<&-; wait $s"#

    /// Windows' sshd leaves the command running when the connection goes, and its writes keep
    /// succeeding (measured 2026-11-12), so it ends when the sshd above it is gone. Kept short:
    /// encoded, it must fit cmd.exe's 8191-character command line.
    private nonisolated static let powerShellFollower = #"""
        $h=$env:CODEX_HOME;if(!$h){$h=Join-Path $env:USERPROFILE '.codex'}
        $d=Join-Path $h 'sessions'
        $o=[Console]::OpenStandardOutput()
        $z=$PID;for($y=0;$y -lt 4;$y++){$c=Get-CimInstance Win32_Process -Filter "ProcessId=$z";if(!$c){break};if($c.Name -eq 'sshd.exe'){break};$z=$c.ParentProcessId}
        if(!$c -or $y -ge 4){$z=0}
        function W($s){try{$b=[Text.Encoding]::ASCII.GetBytes($s+"`n");$o.Write($b,0,$b.Length);$o.Flush()}catch{exit}}
        function F($p){New-Object IO.FileStream($p,'Open','Read','ReadWrite,Delete')}
        function L($p){try{$f=F $p;$l=$f.Length;$f.Close();$l}catch{-1}}
        function S($k,$y,$p,$a,$e){$n=[int]($e-$a);$b=New-Object byte[] $n;$r=0
        try{$f=F $p;[void]$f.Seek($a,'Begin');while($r -lt $n){$c=$f.Read($b,$r,$n-$r);if($c -le 0){break};$r+=$c};$f.Close()}catch{}
        W "@F $k $y $r";try{$o.Write($b,0,$r);$o.Flush()}catch{exit}}
        W("@C ps "+[DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
        $t=@{};$g=@{};$m=(Get-Date).AddMinutes(-5);$n=0;$i=0;$e=3
        while($true){
        $w=Get-Date;$x=($n%20 -eq 19)
        Get-ChildItem $d -Recurse -Filter 'rollout-*.jsonl' -ErrorAction SilentlyContinue|ForEach-Object{$p=$_.FullName
        if(!$t.ContainsKey($p)){$u=($_.LastWriteTime -gt $m -or $_.CreationTime -gt $m)
        if(!$u -and $x -and $_.CreationTime -gt $w.AddDays(-30)){$u=([IO.File]::GetLastWriteTime($p) -gt $w.AddSeconds(-90))}
        if($u){$t[$p]=-1;$g[$p]=$w}}}
        foreach($p in @($t.Keys)){$a=$t[$p]
        if($a -ge 0 -and $g[$p] -lt $w.AddHours(-2) -and $n%10){continue}
        $s=L $p;if($s -lt 0){$t.Remove($p);continue}
        $k=Split-Path $p -Leaf
        if($a -lt 0){$c=0;$e=0;try{$f=F $p;while(($c=$f.ReadByte()) -ge 0){$e++;if($c -eq 10){break}};$f.Close()}catch{}
        S $k meta $p 0 $e;$a=$s-262144;if($a -gt $e){S $k part $p $a $s}else{S $k tail $p $e $s};$t[$p]=$s;$g[$p]=$w;$i=0}
        elseif($s -gt $a){S $k data $p $a $s;$t[$p]=$s;$g[$p]=$w;$i=0}}
        $m=$w.AddSeconds(-5);$n++;$i++
        if($e -ge 3){$e=0;$v=0;if(Get-Process -ErrorAction SilentlyContinue|Where-Object{$_.ProcessName -like '*codex*'}){$v=1};if($z -and !(Get-Process -Id $z -ErrorAction SilentlyContinue)){exit};W "@H $v"}
        $j=1;if($i -ge 60){$j=3};$e+=$j
        Start-Sleep $j}

        """#
}

/// Reads one follower's output and writes the session files it carries. Only whole lines reach
/// a file, so `CodexManager` never reads half a record. Runs on its own queue: a first `part`
/// is 256 KB and a tool's output can be megabytes.
final class RemoteCodexMirror: @unchecked Sendable {
    enum Event: Sendable {
        /// The follower started. `skew` is this Mac's clock minus the host's when they differ
        /// by 30 s or more (each line's timestamp is then shifted by it), else 0.
        case hello(skew: TimeInterval)
        case heartbeat(codexRunning: Bool)
        /// A session file has its recent lines: worth a scan now.
        case sessionFile
        /// Output that isn't the follower's; the connection is no use.
        case failed
    }

    private struct Frame {
        let name: String
        let kind: String
        var remaining: Int
        /// A file this connection already has (sent again), or the rest of one that was skipped.
        let discard: Bool
    }

    private let queue = DispatchQueue(label: "RemoteCodexMirror", qos: .utility)
    private let directory: URL
    private let onEvent: @Sendable (Event) -> Void
    private var buffer = Data()
    private var frame: Frame?
    private var files: [String: FileHandle] = [:]
    /// The unfinished last line of each file.
    private var carries: [String: Data] = [:]
    /// Files that have their first line and wait for the rest.
    private var fresh: Set<String> = []
    /// Files whose next bytes start mid-line: dropped up to the first line break.
    private var midLine: Set<String> = []
    private var skew: TimeInterval = 0
    private var codexRunning: Bool?
    private var stopped = false

    private static let maxFrame = 64 * 1024 * 1024
    private static let timestampPrefix = Data(#"{"timestamp":""#.utf8)
    private let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    init(directory: URL, onEvent: @escaping @Sendable (Event) -> Void) {
        self.directory = directory
        self.onEvent = onEvent
    }

    func receive(_ data: Data) {
        queue.async {
            guard !self.stopped else { return }
            self.buffer.append(data)
            self.drain()
        }
    }

    /// Closes the files; nothing is written after this returns.
    func stop() {
        queue.sync {
            stopped = true
            files.values.forEach { try? $0.close() }
            files = [:]
            buffer = Data()
        }
    }

    private func drain() {
        while !stopped {
            if var current = frame {
                guard !buffer.isEmpty else { return }
                let count = min(current.remaining, buffer.count)
                let range = buffer.startIndex..<buffer.index(buffer.startIndex, offsetBy: count)
                if !current.discard { append(buffer.subdata(in: range), to: current.name) }
                buffer.removeSubrange(range)
                current.remaining -= count
                frame = current.remaining == 0 ? nil : current
                if current.remaining == 0 { finished(current) }
                continue
            }
            guard let newline = buffer.firstIndex(of: 0x0A) else {
                // Not a line of ours and no end in sight.
                if buffer.count > 8192 { fail() }
                return
            }
            let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            buffer.removeSubrange(buffer.startIndex...newline)
            header(line)
        }
    }

    private func header(_ line: String) {
        let parts = line.split(separator: " ").map(String.init)
        switch parts.first {
        case "@C":
            guard parts.count == 3, let remote = TimeInterval(parts[2]) else { return fail() }
            let difference = Date().timeIntervalSince1970 - remote
            skew = abs(difference) >= 30 ? difference.rounded() : 0
            onEvent(.hello(skew: skew))
        case "@H":
            // Every 3 s; only a change is worth the main thread.
            let running = parts.count > 1 && parts[1] == "1"
            if running != codexRunning {
                codexRunning = running
                onEvent(.heartbeat(codexRunning: running))
            }
        case "@F":
            guard parts.count == 4, let length = Int(parts[3]), (0...Self.maxFrame).contains(length),
                  Self.isSessionFileName(parts[1]) else { return fail() }
            let name = parts[1], kind = parts[2]
            var discard = false
            switch kind {
            case "meta":
                discard = files[name] != nil
                if !discard { open(name) }
            case "tail", "part":
                discard = !fresh.contains(name)
                if kind == "part", !discard { midLine.insert(name) }
            case "data":
                discard = files[name] == nil || fresh.contains(name)
            default:
                return fail()
            }
            let next = Frame(name: name, kind: kind, remaining: length, discard: discard)
            if length == 0 { finished(next) } else { frame = next }
        default:
            // Anything else a shell prints before the script runs (a banner, a profile's echo).
            break
        }
    }

    private func finished(_ frame: Frame) {
        guard !frame.discard, frame.kind == "tail" || frame.kind == "part" else { return }
        fresh.remove(frame.name)
        onEvent(.sessionFile)
    }

    /// The name becomes a path under `directory`: nothing but a session file's own name passes.
    private static func isSessionFileName(_ name: String) -> Bool {
        name.count <= 160 && name.hasPrefix("rollout-") && name.hasSuffix(".jsonl") && !name.contains("..")
            && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
    }

    private func open(_ name: String) {
        let url = directory.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        files[name] = handle
        carries[name] = Data()
        fresh.insert(name)
    }

    private func append(_ data: Data, to name: String) {
        guard let handle = files[name] else { return }
        var carry = carries[name] ?? Data()
        carry.append(data)
        if midLine.contains(name) {
            guard let newline = carry.firstIndex(of: 0x0A) else {
                carries[name] = Data()
                return
            }
            carry.removeSubrange(carry.startIndex...newline)
            midLine.remove(name)
        }
        guard let last = carry.lastIndex(of: 0x0A) else {
            carries[name] = carry
            return
        }
        let lines = carry.subdata(in: carry.startIndex..<carry.index(after: last))
        carries[name] = carry.subdata(in: carry.index(after: last)..<carry.endIndex)
        try? handle.write(contentsOf: skew == 0 ? lines : shifted(lines))
    }

    /// Every record starts `{"timestamp":"…"`; moved onto this Mac's clock.
    private func shifted(_ lines: Data) -> Data {
        var result = Data(capacity: lines.count)
        var start = lines.startIndex
        while start < lines.endIndex {
            let end = lines[start...].firstIndex(of: 0x0A).map { lines.index(after: $0) } ?? lines.endIndex
            let line = lines[start..<end]
            let prefix = Self.timestampPrefix
            if line.starts(with: prefix),
               let quote = line.dropFirst(prefix.count).prefix(40).firstIndex(of: UInt8(ascii: "\"")),
               let date = formatter.date(from: String(decoding: line[line.index(line.startIndex, offsetBy: prefix.count)..<quote], as: UTF8.self)) {
                result.append(prefix)
                result.append(Data(formatter.string(from: date.addingTimeInterval(skew)).utf8))
                result.append(line[quote...])
            } else {
                result.append(line)
            }
            start = end
        }
        return result
    }

    private func fail() {
        stopped = true
        buffer = Data()
        onEvent(.failed)
    }
}
