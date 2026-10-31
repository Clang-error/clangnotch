import Foundation

/// Resolve on discovery and click, rather than polling or trusting a resumed session's old metadata.
enum SessionAppResolver {
    static func codexOwner(of file: URL) -> SessionAppDestination? {
        let owners = output("/usr/sbin/lsof", ["-a", "-c", "codex", "-t", "--", file.path])
            .split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
        var terminalOwner = false
        for owner in owners {
            var pid = owner
            for _ in 0..<12 {
                guard pid > 1 else { break }
                let info = output("/bin/ps", ["-p", String(pid), "-o", "ppid=,comm="])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let fields = info.split(maxSplits: 1, whereSeparator: \.isWhitespace)
                guard fields.count == 2, let parent = Int32(fields[0]) else { break }
                let executable = String(fields[1])
                if let destination = application(containing: executable) { return destination }
                if pid == owner { terminalOwner = true }
                guard parent != pid else { break }
                pid = parent
            }
        }
        return terminalOwner ? .terminal : nil
    }

    /// Whether any codex process holds the file open. A live session keeps its rollout open
    /// (the Codex app for every loaded thread), so false means its writer has exited.
    static func isOpenByCodex(_ file: URL) -> Bool {
        !output("/usr/sbin/lsof", ["-a", "-c", "codex", "-t", "--", file.path])
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Terminals

    /// The terminal a process runs in, read from what the terminal set in its environment.
    /// nil when the environment names none. The parent chain can't tell: Rex's shells hang off
    /// its background server, and a CLI's own path is inside ChatGPT.app.
    static func terminal(pid: pid_t) -> TerminalLocation? {
        guard let environment = processArguments(pid: pid)?.environment else { return nil }
        func variable(_ name: String) -> String? {
            let prefix = name + "="
            return environment.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
        }

        // First: a Rex server started from another terminal passes that terminal's variables on.
        if variable("TERM_PROGRAM") == "rex" {
            var location = TerminalLocation(bundleIdentifier: "com.superlogical.rex")
            if let directory = variable("REX_BIN_DIR"), let session = variable("REX_SESSION"),
               let block = variable("REX_BLOCK") {
                location.tab = .rex(cli: directory + "/rex", server: variable("REX_SERVER"), session: session, block: block)
            }
            return location
        }

        // Warp sets `WARP_FOCUS_URL=warp://session/<uuid>` in every tab's shell.
        let warpURL = variable("WARP_FOCUS_URL").flatMap(URL.init(string:)).flatMap { $0.scheme == "warp" ? $0 : nil }
        // macOS sets this for whatever LaunchServices opened, so any terminal app has it.
        let identifier = variable("__CFBundleIdentifier").flatMap { $0.isEmpty ? nil : $0 }
        guard warpURL != nil || identifier != nil else { return nil }
        return TerminalLocation(bundleIdentifier: identifier, tab: warpURL.map { .warp($0) })
    }

    /// The terminal of a Codex session, or nil when no terminal opened it. When the rollout's
    /// writer runs in a terminal, that is exact. Current Codex CLIs instead attach to a shared
    /// `codex app-server` that writes every rollout, so: the client whose arguments name the
    /// session (`resume <id>`), else the client that opened the session's server connection
    /// (`codexConnectionDate`), else the only one in the session's folder.
    /// With several left, only their app is known, so a click doesn't jump to the wrong tab.
    static func codexTerminal(file: URL, sessionId: String, cwd: String) -> TerminalLocation? {
        let writers = output("/usr/sbin/lsof", ["-a", "-c", "codex", "-t", "--", file.path])
            .split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
        if let writer = writers.first(where: isInTerminal) { return terminal(pid: writer) ?? TerminalLocation() }

        let clients = processIDs(named: "codex").filter(isInTerminal)
        if let named = clients.first(where: { processArguments(pid: $0)?.arguments.contains(sessionId) == true }) {
            return terminal(pid: named) ?? TerminalLocation()
        }

        // The TUI creates this empty file with the thread; Desktop and phone threads have none.
        let marker = codexDirectory.appendingPathComponent("tui-thread-reference-capabilities/\(sessionId)")
        guard FileManager.default.fileExists(atPath: marker.path) else { return nil }

        let folder = URL(fileURLWithPath: cwd).standardizedFileURL.path
        let inFolder = clients.filter {
            processDirectory(pid: $0).map { URL(fileURLWithPath: $0).standardizedFileURL.path } == folder
        }
        if let connected = codexConnectionDate(sessionId: sessionId) {
            if let client = lastStarted(inFolder, before: connected) { return terminal(pid: client) ?? TerminalLocation() }
        } else if inFolder.count == 1 {
            return terminal(pid: inFolder[0]) ?? TerminalLocation()
        }
        let apps = Set(inFolder.map { terminal(pid: $0)?.bundleIdentifier })
        return TerminalLocation(bundleIdentifier: apps.count == 1 ? apps.first ?? nil : nil)
    }

    /// When the client holding the session connected to the shared server. Nothing links a
    /// thread to a client's pid, but the server's log names the connection each thread request
    /// came in on, and a client connects right after it starts (measured 2026-10-31). The
    /// thread's own time won't do: it comes after any dialog the TUI opens with. nil once the
    /// log has rotated the connection out, or if a Codex update changes these lines.
    private static func codexConnectionDate(sessionId: String) -> Date? {
        guard UUID(uuidString: sessionId) != nil,
              let names = try? FileManager.default.contentsOfDirectory(atPath: codexDirectory.path),
              let name = names.filter({ $0.hasPrefix("logs_") && $0.hasSuffix(".sqlite") }).max() else { return nil }
        func query(_ sql: String) -> String {
            output("/usr/bin/sqlite3", ["-readonly", codexDirectory.appendingPathComponent(name).path, sql])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let row = query("""
            select process_uuid || ' ' || feedback_log_body from logs
            where thread_id = '\(sessionId)' and feedback_log_body like '%app_server.connection_id=%'
            order by ts desc, ts_nanos desc limit 1
            """)
        guard let server = row.split(separator: " ").first,
              let label = row.range(of: #"app_server\.connection_id=\d+"#, options: .regularExpression),
              let connection = row[label].split(separator: "=").last else { return nil }
        let seconds = query("""
            select ts + ts_nanos / 1000000000.0 from logs
            where process_uuid = '\(server.replacingOccurrences(of: "'", with: "''"))'
              and feedback_log_body like 'app-server request: initialize connection_id=ConnectionId(\(connection))%'
            order by ts, ts_nanos limit 1
            """)
        return TimeInterval(seconds).map(Date.init(timeIntervalSince1970:))
    }

    /// The client that started last before `date`, within a few seconds. nil when two started
    /// too close together to tell which one it was.
    private static func lastStarted(_ clients: [pid_t], before date: Date) -> pid_t? {
        let started = clients.compactMap { pid in startDate(pid: pid).map { (pid: pid, date: $0) } }
            .filter { (0...10).contains(date.timeIntervalSince($0.date)) }
            .sorted { $0.date > $1.date }
        guard let last = started.first else { return nil }
        if started.count > 1, last.date.timeIntervalSince(started[1].date) < 1 { return nil }
        return last.pid
    }

    private static var codexDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    /// argv and environment of a process owned by this user (KERN_PROCARGS2).
    private static func processArguments(pid: pid_t) -> (arguments: [String], environment: [String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let argc = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })

        // Layout: argc, the executable path, NUL padding, then argv and envp as NUL-terminated
        // strings; an empty string ends envp.
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var strings: [String] = []
        while index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            if index == start { break }
            strings.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        let count = min(argc, strings.count)
        return (Array(strings[..<count]), Array(strings[count...]))
    }

    /// Whether the process has a controlling terminal; a server or an app's helper has none.
    private static func isInTerminal(_ pid: pid_t) -> Bool {
        processInfo(pid: pid).map { $0.e_tdev != UInt32.max } == true
    }

    private static func startDate(pid: pid_t) -> Date? {
        processInfo(pid: pid).map {
            Date(timeIntervalSince1970: TimeInterval($0.pbi_start_tvsec) + TimeInterval($0.pbi_start_tvusec) / 1_000_000)
        }
    }

    private static func processInfo(pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    private static func processDirectory(pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafeBytes(of: &info.pvi_cdir.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
    }

    private static func processIDs(named name: String) -> [pid_t] {
        var pids = [pid_t](repeating: 0, count: 4096)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        guard count > 0 else { return [] }
        return pids.prefix(min(count, pids.count)).filter { pid in
            var buffer = [CChar](repeating: 0, count: 64)
            return proc_name(pid, &buffer, UInt32(buffer.count)) > 0 && String(cString: buffer) == name
        }
    }

    static func application(containing executable: String) -> SessionAppDestination? {
        guard let range = executable.range(of: ".app/") else { return nil }
        let appPath = String(executable[..<range.lowerBound]) + ".app"
        guard let identifier = Bundle(path: appPath)?.bundleIdentifier else { return nil }
        for destination in [SessionAppDestination.codex, .claude, .vscode, .antigravity, .cursor, .windsurf, .zed, .terminal] {
            if destination.bundleIdentifiers.contains(identifier) { return destination }
        }
        return nil
    }

    private static func output(_ executable: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
