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

    // MARK: - Warp tabs

    /// The URL that brings the process's own Warp tab to the front. Warp sets
    /// `WARP_FOCUS_URL=warp://session/<uuid>` in every tab's shell, so any process started in
    /// a tab inherits it. nil for a process started anywhere else.
    static func warpFocusURL(pid: pid_t) -> URL? {
        let prefix = "WARP_FOCUS_URL="
        guard let value = processArguments(pid: pid)?.environment.first(where: { $0.hasPrefix(prefix) }),
              let url = URL(string: String(value.dropFirst(prefix.count))),
              url.scheme == "warp" else { return nil }
        return url
    }

    /// The Warp tab of a Codex session. When the rollout's writer runs in a tab, that is exact.
    /// Current Codex CLIs instead attach to a shared `codex app-server` that writes every
    /// rollout, and nothing links a thread to its client — so fall back to the Warp codex
    /// client in the session's folder: the one whose arguments name the session (`resume <id>`),
    /// else the only one there. nil when unsure, so a click never jumps to the wrong tab.
    static func codexWarpFocusURL(file: URL, sessionId: String, cwd: String) -> URL? {
        let writers = output("/usr/sbin/lsof", ["-a", "-c", "codex", "-t", "--", file.path])
            .split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
        if let url = writers.lazy.compactMap({ warpFocusURL(pid: $0) }).first { return url }

        let folder = URL(fileURLWithPath: cwd).standardizedFileURL.path
        let clients = processIDs(named: "codex").filter {
            processDirectory(pid: $0).map { URL(fileURLWithPath: $0).standardizedFileURL.path } == folder
        }.compactMap { pid in warpFocusURL(pid: pid).map { (pid: pid, url: $0) } }
        if let named = clients.first(where: { processArguments(pid: $0.pid)?.arguments.contains(sessionId) == true }) {
            return named.url
        }
        return clients.count == 1 ? clients[0].url : nil
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
