//
//  RemoteSessionFollower.swift
//  ClangNotch
//
//  Follows an agent's session files on an SSH host.
//

import Foundation

/// One SSH connection to a host, on which a small follower script sends what an agent appends
/// to its session files there. `RemoteCodexManager` uses it for Codex on any host (the files are
/// written under a folder `CodexManager` scans), `RemoteClaudeManager` for Claude Code on hosts
/// that can't take its hooks, such as Windows (the lines become hook events).
///
/// Nothing is installed or changed on the host: the script travels with the command and only
/// reads. It is POSIX `sh` (Linux, macOS, WSL, Git Bash) or Windows PowerShell 5.1; sh is tried
/// first and whichever answers with the hello line is used. Everything runs through
/// `/usr/bin/ssh` with the user's own `~/.ssh/config` and keys; what ssh has to ask goes through
/// `SSHAskpass` (`SSHHost`).
@MainActor
final class RemoteSessionFollower {
    /// Where an agent keeps its session files on a host.
    struct Source: Sendable {
        /// The environment variable that moves the agent's folder, and the folder in the home
        /// directory otherwise.
        let environmentVariable: String
        let homeFolder: String
        let subfolder: String
        let fileFilter: String
        /// A folder of small `*.json` files the agent rewrites in place, sent whole whenever one
        /// changes (`Event.stateFile`); empty for none.
        let stateSubfolder: String
        /// A word in the command line of the agent's processes, for `Event.agentRunning`.
        let processWord: String
        let accepts: @Sendable (String) -> Bool

        /// `~/.codex/sessions/**/rollout-*.jsonl`
        static let codex = Source(environmentVariable: "CODEX_HOME", homeFolder: ".codex", subfolder: "sessions",
                                  fileFilter: "rollout-*.jsonl", stateSubfolder: "", processWord: "codex",
                                  accepts: { $0.hasPrefix("rollout-") })
        /// `~/.claude/projects/<project>/<conversation id>.jsonl`. Subagent transcripts
        /// (`subagents/`, `agent-*`) stay behind. `~/.claude/sessions/<pid>.json` is each
        /// running process's registry record, which says when it waits on the user.
        /// Only the registry records: for a host whose hooks already report the rest.
        static let claudeRegistry = Source(environmentVariable: "CLAUDE_CONFIG_DIR", homeFolder: ".claude", subfolder: "sessions",
                                           fileFilter: "", stateSubfolder: "sessions", processWord: "",
                                           accepts: { _ in false })
        static let claude = Source(environmentVariable: "CLAUDE_CONFIG_DIR", homeFolder: ".claude", subfolder: "projects",
                                   fileFilter: "*.jsonl", stateSubfolder: "sessions", processWord: "claude",
                                   accepts: { !$0.hasPrefix("agent-") })
    }

    /// The sh follower for `source`, to run as another connection's remote command
    /// (`RemoteClaudeManager`'s tunnel), fed to `sh` on its stdin and read with a
    /// `RemoteFollowerStream`.
    nonisolated static func shScript(for source: Source) -> String {
        fill(shTemplate, with: source)
    }

    enum Sink: Sendable {
        /// Each file is written, whole lines only, under this folder.
        case files(URL)
        /// Whole lines of a file as they come, and how far the host's clock is off (see
        /// `Event.connected`). `history`: what the file already held when the connection
        /// opened, not something that just happened.
        case lines(@Sendable (_ file: String, _ lines: Data, _ skew: TimeInterval, _ history: Bool) -> Void)
    }

    enum Event {
        /// A state worth showing in Settings: connecting, a failure, the wait before a retry.
        case status(String)
        /// The follower runs. `skew` is this Mac's clock minus the host's when they differ by
        /// 30 s or more, else 0.
        case connected(skew: TimeInterval)
        /// Whether a process of the agent runs on the host; sent when it changes.
        case agentRunning(Bool)
        /// A session file has its recent lines.
        case sessionFile
        /// A state file's whole content, as it is now; nil when the file is gone.
        case stateFile(name: String, content: Data?)
        /// The connection is gone (a retry may follow): nothing more comes from this host.
        case dropped
    }

    private enum Shell { case sh, powershell }

    let host: String
    private let source: Source
    private let sink: Sink
    private let onEvent: (Event) -> Void

    private var process: Process?
    private var stream: RemoteFollowerStream?
    /// Write end of the pipe a PowerShell follower's `sshWatch` reads, held open for its lifetime.
    private var input: Pipe?
    /// The shell that answered, tried first the next time.
    private var shell: Shell?
    /// The running follower got as far as its hello line.
    private var greeted = false
    private var retryTask: Task<Void, Never>?
    private var failures = 0

    init(host: String, source: Source, sink: Sink, onEvent: @escaping (Event) -> Void) {
        self.host = host
        self.source = source
        self.sink = sink
        self.onEvent = onEvent
    }

    /// Connects. `interactive`: ssh's questions (trust this host? password?) may open a window.
    func start(interactive: Bool = false) {
        launch(shell ?? .sh, interactive: interactive)
    }

    /// Ends the connection for good; no `dropped` follows.
    func stop() {
        retryTask?.cancel()
        retryTask = nil
        // Cleared before terminating so `closed` treats this exit as intentional.
        let running = process
        process = nil
        closeInput()
        running?.terminate()
        stream?.stop()
        stream = nil
        failures = 0
    }

    // MARK: - Connection

    private func launch(_ shell: Shell, interactive: Bool) {
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
            let encoded = script(Self.powerShellTemplate).data(using: .utf16LittleEndian)!.base64EncodedString()
            // cmd.exe, the usual default shell there, takes 8191 characters.
            assert(encoded.count < 8050, "the PowerShell follower no longer fits cmd.exe's command line")
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

        let stream = RemoteFollowerStream(sink: sink, accepts: source.accepts) { [weak self] event in
            Task { @MainActor in self?.handle(event, shell: shell, process: process) }
        }
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { stream.receive(data) }
        }
        process.terminationHandler = { [weak self] process in
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            Task { @MainActor in
                self?.closed(shell: shell, interactive: interactive, process: process, stderr: message)
            }
        }
        do {
            try process.run()
        } catch {
            retry(reason: error.localizedDescription)
            return
        }
        // A failed login closes ssh's stdin early; get an error instead of a fatal SIGPIPE.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        switch shell {
        case .sh:
            try? input.fileHandleForWriting.write(contentsOf: Data(script(Self.shTemplate).utf8))
            try? input.fileHandleForWriting.close()
        case .powershell:
            // Left open for `sshWatch`. An sh follower needs none: it dies on its next write.
            self.input = input
        }

        self.process = process
        self.stream = stream
        greeted = false
        onEvent(.status(L("연결 중…", "Connecting…")))
    }

    private func handle(_ event: RemoteFollowerStream.Event, shell: Shell, process: Process) {
        guard self.process === process else { return }
        switch event {
        case .hello(let skew):
            greeted = true
            self.shell = shell
            onEvent(.connected(skew: skew))
            // Back off from scratch only once the connection has proven stable.
            Task {
                try? await Task.sleep(for: .seconds(60))
                guard self.process === process else { return }
                failures = 0
            }
        case .heartbeat(let agentRunning):
            onEvent(.agentRunning(agentRunning))
        case .sessionFile:
            onEvent(.sessionFile)
        case .stateFile(let name, let content):
            onEvent(.stateFile(name: name, content: content))
        case .failed:
            process.terminate()
        }
    }

    private func closed(shell: Shell, interactive: Bool, process: Process, stderr: String) {
        guard self.process === process else { return }
        let hadGreeted = greeted
        self.process = nil
        closeInput()
        stream?.stop()
        stream = nil
        // No more lines can arrive; the owner must not leave rows reading as working.
        onEvent(.dropped)
        // ssh itself failing is 255. Anything else before the hello is the host not having this
        // shell (Windows has no sh): the other one gets its turn before giving up.
        if !hadGreeted, process.terminationStatus != 255, shell == .sh, self.shell == nil {
            launch(.powershell, interactive: interactive)
            return
        }
        if !hadGreeted, process.terminationStatus != 255 {
            self.shell = nil
            retry(reason: L("호스트에서 sh 또는 PowerShell을 실행하지 못했습니다", "Neither sh nor PowerShell ran on the host"))
            return
        }
        let failure = SSHHost.failure(stderr, host: host)
        // Waiting on the user (a host to confirm, a password): trying again alone can't help.
        if failure.needsUser, !hadGreeted {
            onEvent(.status(failure.message))
            return
        }
        retry(reason: failure.message)
    }

    /// Closed by hand: the `Process` keeps its pipe alive, and `sshWatch` waits on this end.
    private func closeInput() {
        try? input?.fileHandleForWriting.close()
        input = nil
    }

    private func retry(reason: String) {
        let attempt = failures
        failures += 1
        let delay = min(60, 5 << min(attempt, 4))
        onEvent(.status(L("\(reason) — \(delay)초 후 재시도", "\(reason) — retrying in \(delay)s")))
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.start()
        }
    }

    // MARK: - Followers

    // Both speak the same lines on stdout, read by `RemoteFollowerStream`:
    //   @C <shell> <unix time>          once, at the start
    //   @F <file name> <kind> <bytes>   followed by that many bytes of the file
    //   @H <0|1>                        every 3 s (15 s from PowerShell): whether a process of the agent runs on the host
    //   @S <file name> <bytes>          a state file's whole content, whenever it changes
    //   @X <file name>                  a state file is gone
    // The files are looked at every second, and every 3 s once nothing has changed for a minute:
    // at one second the Linux follower took 1.4% of a core and the Windows one 0.4 to 0.6%, at
    // 3 s the Windows one 0.17% (2026-11-12; see `powerShellTemplate` for how it was measured).
    // A file modified in the last 5 minutes, or later, is sent as `meta` (its first line), then
    // `tail` (the rest) or `part` (its last 256 KB, starting mid-line); what it grows by after
    // that as `data`. Files are followed by their size: a file its writer holds open keeps a
    // stale modification time in a Windows folder listing.

    /// A follower template with this source's folder, file filter and process word filled in.
    private func script(_ template: String) -> String {
        Self.fill(template, with: source)
    }

    private nonisolated static func fill(_ template: String, with source: Source) -> String {
        template
            .replacingOccurrences(of: "__ENV__", with: source.environmentVariable)
            .replacingOccurrences(of: "__HOME__", with: source.homeFolder)
            .replacingOccurrences(of: "__SUB__", with: source.subfolder)
            .replacingOccurrences(of: "__FILTER__", with: source.fileFilter)
            .replacingOccurrences(of: "__STATE__", with: source.stateSubfolder)
            .replacingOccurrences(of: "__WORD__", with: source.processWord)
    }

    /// Ends by itself when the connection goes: the next write fails (SIGPIPE).
    private nonisolated static let shTemplate = #"""
        d="${__ENV__:-$HOME/__HOME__}/__SUB__"
        sd="${__ENV__:-$HOME/__HOME__}/__STATE__"
        umask 077
        t=$(mktemp -d) || exit 1
        trap 'rm -rf "$t"' EXIT
        trap 'exit 0' HUP INT TERM PIPE
        printf '@C sh %s\n' "$(date +%s)" || exit 0
        first=1
        q=0
        e=3
        su=
        while :; do
          if [ -n "__FILTER__" ]; then
            touch "$t/next"
            if [ $first = 1 ]; then set -- -mmin -5; else set -- -newer "$t/mark"; fi
            find "$d" -type f -name '__FILTER__' ! -name 'agent-*' ! -path '*/subagents/*' "$@" 2>/dev/null | while IFS= read -r f; do
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
          fi
          if [ -n "__STATE__" ]; then
            u=$(cksum "$sd"/*.json 2>/dev/null)
            if [ "$u" != "$su" ]; then
              su=$u
              for f in "$sd"/*.json; do
                [ -f "$f" ] || continue
                k=${f##*/}
                c=$(cksum < "$f" 2>/dev/null) || { su=; continue; }
                [ "$c" = "$(cat "$t/s-$k" 2>/dev/null)" ] && continue
                cat "$f" > "$t/buf" 2>/dev/null || { su=; continue; }
                b=$(wc -c < "$t/buf"); b=$((b))
                printf '@S %s %s\n' "$k" "$b"
                cat "$t/buf"
                echo "$c" > "$t/s-$k"
                : > "$t/hit"
              done
              for g in "$t"/s-*; do
                [ -f "$g" ] || continue
                k=${g##*/s-}
                [ -f "$sd/$k" ] || { printf '@X %s\n' "$k"; rm -f "$g"; }
              done
            fi
          fi
          q=$((q + 1))
          if [ -f "$t/hit" ]; then rm -f "$t/hit"; q=0; fi
          if [ "$e" -ge 3 ]; then
            e=0
            if [ -z "__WORD__" ] || pgrep -f __WORD__ >/dev/null 2>&1; then a=1; else a=0; fi
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
    private static let sshWatch =
        #"exec 3<&0; /usr/bin/ssh "$@" </dev/null 3<&- & s=$!; (cat <&3; kill $s) >/dev/null 2>&1 & exec 3<&-; wait $s"#

    /// Windows' sshd leaves the command running when the connection goes, and its writes keep
    /// succeeding (measured 2026-11-12), so it ends when the sshd above it is gone. Kept short:
    /// encoded, it must fit cmd.exe's 8191-character command line.
    ///
    /// What it costs was measured on a 16-core Windows 11 laptop (2026-11-12), by CPU cycles:
    /// the clock-tick times `Get-Process` shows read about half. A pass a second apart costs
    /// ten times what the same code costs run back to back (a listing 6 ms against 0.5 ms,
    /// looking a process up 12 ms), so what counts is how much each pass touches:
    /// - Every pass: the files already followed, the state files, and with no state folder
    ///   today's dated folder, where Codex puts a new session.
    /// - Every 15 s, in one listing of the processes: whether the sshd above is still there
    ///   and whether the agent runs. `Get-Process` every 3 s took the process from 59 MB to
    ///   104 MB.
    /// - The walk of the whole tree only as often as its own time allows, about 1% of a core:
    ///   every 5 to 60 seconds, or a fifth of that after a state file changed, which is how a
    ///   new Claude Code session shows. With 3000 session files `Get-ChildItem -Recurse`
    ///   through a filter took 0.1 to 0.5 s, .NET's `GetFiles` a quarter of that; the latter
    ///   gives up on a folder it may not read, so the former is what it falls back to. It is
    ///   also the pass that asks each file created within 30 days for its real time: a session
    ///   resumed in a file its writer holds open keeps its old time in the folder listing
    ///   until the file itself is asked (seen again 2026-11-12).
    private static let powerShellTemplate = #"""
        $h=$env:__ENV__;if(!$h){$h=Join-Path $env:USERPROFILE '__HOME__'}
        $d=Join-Path $h '__SUB__'
        $o=[Console]::OpenStandardOutput()
        $z=$PID;for($y=0;$y -lt 4;$y++){$c=Get-CimInstance Win32_Process -Filter "ProcessId=$z";if(!$c){break};if($c.Name -eq 'sshd.exe'){break};$z=$c.ParentProcessId}
        if(!$c -or $y -ge 4){$z=0}
        function W($s){try{$b=[Text.Encoding]::ASCII.GetBytes($s+"`n");$o.Write($b,0,$b.Length);$o.Flush()}catch{exit}}
        function F($p){New-Object IO.FileStream($p,'Open','Read','ReadWrite,Delete')}
        function L($p){try{$f=F $p;$l=$f.Length;$f.Close();$l}catch{-1}}
        function S($k,$y,$p,$a,$e){$n=[int]($e-$a);$b=New-Object byte[] $n;$r=0
        try{$f=F $p;$f.Position=$a;while($r -lt $n){$c=$f.Read($b,$r,$n-$r);if($c -le 0){break};$r+=$c};$f.Close()}catch{}
        W "@F $k $y $r";try{$o.Write($b,0,$r);$o.Flush()}catch{exit}}
        function N($q){$p=$q.FullName;if($t.ContainsKey($p) -or $p -like '*\subagents\*' -or $q.Name -like 'agent-*'){return};$t[$p]=-1;$g[$p]=$w}
        W("@C ps "+[DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
        $t=@{};$g=@{};$m=(Get-Date).AddMinutes(-5);$n=0;$i=0;$e=15;$sd=Join-Path $h '__STATE__';$st=@{};$v=0;$nx=$m;$nf=$m
        for(;;){
        $w=Get-Date;$y=($w -ge $nx -or ($v -and $w -ge $nf))
        if(!'__STATE__'){foreach($q in @(Get-ChildItem (Join-Path $d $w.ToString('yyyy\\MM\\dd')) -Filter '__FILTER__' -EA 0|?{$_.LastWriteTime -gt $m -or $_.CreationTime -gt $m})){N $q}}
        if($y){$v=0;$x=$w.AddSeconds(-120);$c=$w.AddDays(-30)
        try{$fs=[IO.DirectoryInfo]::new($d).GetFiles('__FILTER__','AllDirectories')}catch{$fs=@(Get-ChildItem $d -Recurse -Filter '__FILTER__' -EA 0)}
        foreach($q in $fs){if($q.LastWriteTime -gt $m -or $q.CreationTime -gt $m -or ($q.CreationTime -gt $c -and [IO.File]::GetLastWriteTime($q.FullName) -gt $x)){N $q}}
        $j=[Math]::Min(60,[Math]::Max(5,[int](((Get-Date)-$w).TotalMilliseconds/10)));$nx=$w.AddSeconds($j);$nf=$w.AddSeconds($j/5);$m=$w.AddSeconds(-5)}
        foreach($p in @($t.Keys)){$a=$t[$p]
        if($a -ge 0 -and $g[$p] -lt $w.AddHours(-2) -and $n%10){continue}
        $s=L $p;if($s -lt 0){$t.Remove($p);continue}
        $k=Split-Path $p -Leaf
        if($a -lt 0){$c=0;$b=0;try{$f=F $p;while(($c=$f.ReadByte()) -ge 0){$b++;if($c -eq 10){break}};$f.Close()}catch{}
        S $k meta $p 0 $b;$a=$s-262144;if($a -gt $b){S $k part $p $a $s}else{S $k tail $p $b $s};$t[$p]=$s;$g[$p]=$w;$i=0}
        elseif($s -gt $a){S $k data $p $a $s;$t[$p]=$s;$g[$p]=$w;$i=0}}
        if('__STATE__'){$sn=@{};Get-ChildItem $sd -Filter '*.json' -EA 0|%{$k=$_.Name;if($_.Extension -ne '.json'){return};$sn[$k]=1
        try{$b=[IO.File]::ReadAllBytes($_.FullName)}catch{return};$q=[Convert]::ToBase64String($b)
        if($st[$k] -ne $q){$st[$k]=$q;W "@S $k $($b.Length)";try{$o.Write($b,0,$b.Length);$o.Flush()}catch{exit};$i=0;$v=1}}
        foreach($k in @($st.Keys)){if(!$sn[$k]){$st.Remove($k);W "@X $k"}}}
        $n++;$i++
        if($e -ge 15){$e=0;$u=0;$al=!$z;foreach($q in [Diagnostics.Process]::GetProcesses()){if($q.Id -eq $z){$al=1};if($q.ProcessName -like '*__WORD__*'){$u=1}};if(!$al){exit};W "@H $u"}
        $j=1;if($i -ge 60){$j=3};$e+=$j
        Start-Sleep $j}
        """#
}

/// Reads one follower's output and hands on the session files it carries: written under a folder
/// (Codex: `CodexManager` reads the files) or as lines (Claude: turned into hook events). Only
/// whole lines get through, so nobody reads half a record. Runs on its own queue: a first
/// `part` is 256 KB and a tool's output can be megabytes.
final class RemoteFollowerStream: @unchecked Sendable {
    enum Event: Sendable {
        /// The follower started. `skew` is this Mac's clock minus the host's when they differ
        /// by 30 s or more (each line's timestamp is then shifted by it), else 0.
        case hello(skew: TimeInterval)
        case heartbeat(agentRunning: Bool)
        /// A session file has its recent lines: worth a scan now.
        case sessionFile
        /// A state file's whole content; nil when it is gone.
        case stateFile(name: String, content: Data?)
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

    private let queue = DispatchQueue(label: "RemoteFollowerStream", qos: .utility)
    private let sink: RemoteSessionFollower.Sink
    private let accepts: @Sendable (String) -> Bool
    private let onEvent: @Sendable (Event) -> Void
    private var buffer = Data()
    /// The state file being received.
    private var stateBody = Data()
    private var frame: Frame?
    private var files: [String: FileHandle] = [:]
    /// Files this connection has had the first line of.
    private var known: Set<String> = []
    /// The unfinished last line of each file.
    private var carries: [String: Data] = [:]
    /// Files that have their first line and wait for the rest.
    private var fresh: Set<String> = []
    /// Files whose next bytes start mid-line: dropped up to the first line break.
    private var midLine: Set<String> = []
    private var skew: TimeInterval = 0
    private var agentRunning: Bool?
    private var stopped = false

    private static let maxFrame = 64 * 1024 * 1024
    private static let maxState = 256 * 1024
    private static let timestampPrefix = Data(#"{"timestamp":""#.utf8)
    private let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    init(sink: RemoteSessionFollower.Sink, accepts: @escaping @Sendable (String) -> Bool,
         onEvent: @escaping @Sendable (Event) -> Void) {
        self.sink = sink
        self.accepts = accepts
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
                if current.kind == "state" {
                    stateBody.append(buffer.subdata(in: range))
                } else if !current.discard {
                    append(buffer.subdata(in: range), to: current.name, history: current.kind != "data")
                }
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
            if running != agentRunning {
                agentRunning = running
                onEvent(.heartbeat(agentRunning: running))
            }
        case "@S":
            guard parts.count == 3, let length = Int(parts[2]), (0...Self.maxState).contains(length),
                  Self.isStateName(parts[1]) else { return fail() }
            stateBody = Data()
            let next = Frame(name: parts[1], kind: "state", remaining: length, discard: false)
            if length == 0 { finished(next) } else { frame = next }
        case "@X":
            guard parts.count == 2, Self.isStateName(parts[1]) else { return fail() }
            onEvent(.stateFile(name: parts[1], content: nil))
        case "@F":
            guard parts.count == 4, let length = Int(parts[3]), (0...Self.maxFrame).contains(length),
                  Self.isFileName(parts[1]) else { return fail() }
            let name = parts[1], kind = parts[2]
            let unwanted = !accepts(name)
            var discard = false
            switch kind {
            case "meta":
                discard = known.contains(name)
                if !discard, !unwanted { open(name) }
            case "tail", "part":
                discard = !fresh.contains(name)
                if kind == "part", !discard { midLine.insert(name) }
            case "data":
                discard = !known.contains(name) || fresh.contains(name)
            default:
                return fail()
            }
            let next = Frame(name: name, kind: kind, remaining: length, discard: discard || unwanted)
            if length == 0 { finished(next) } else { frame = next }
        default:
            // Anything else a shell prints before the script runs (a banner, a profile's echo).
            break
        }
    }

    private func finished(_ frame: Frame) {
        if frame.kind == "state" {
            onEvent(.stateFile(name: frame.name, content: stateBody))
            stateBody = Data()
            return
        }
        guard !frame.discard, frame.kind == "tail" || frame.kind == "part" else { return }
        fresh.remove(frame.name)
        onEvent(.sessionFile)
    }

    private static func isStateName(_ name: String) -> Bool {
        name.count <= 80 && name.hasSuffix(".json")
            && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
    }

    /// The name can become a path: nothing but a plain `.jsonl` file name passes.
    private static func isFileName(_ name: String) -> Bool {
        name.count <= 160 && name.hasSuffix(".jsonl") && !name.contains("..")
            && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
    }

    private func open(_ name: String) {
        if case .files(let directory) = sink {
            let url = directory.appendingPathComponent(name)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            files[name] = handle
        }
        known.insert(name)
        carries[name] = Data()
        fresh.insert(name)
    }

    private func append(_ data: Data, to name: String, history: Bool) {
        guard known.contains(name) else { return }
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
        switch sink {
        case .files:
            try? files[name]?.write(contentsOf: skew == 0 ? lines : shifted(lines))
        case .lines(let receive):
            receive(name, lines, skew, history)
        }
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
