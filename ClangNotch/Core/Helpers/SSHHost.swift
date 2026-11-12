import AppKit

/// A remote host as typed into 설정 › 에이전트 › 원격 SSH 호스트, and how this app runs
/// `/usr/bin/ssh` to it (`RemoteClaudeManager`, `RemoteCodexManager`).
///
/// A host is `user@address`, `user@address:port`, a bare address, or an alias from
/// `~/.ssh/config`. Until 2026-11-12 only hosts that already worked from a terminal without a
/// question did: ssh ran in batch mode, so a host seen for the first time or one that logs in
/// with a password just failed. Now ssh asks through `SSHAskpass`, this same executable.
enum SSHHost {
    /// The settings value: comma-separated, in the order added.
    static func list(_ setting: String) -> [String] {
        var seen = Set<String>()
        return setting.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// The host is passed to ssh as an argument, baked into a shell script (Claude's hook) and
    /// names a folder that is later deleted (Codex's mirror).
    static func isValid(_ host: String) -> Bool {
        !host.isEmpty && !host.hasPrefix("-") && host != "." && host != ".."
            && host.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._@-:".contains($0)) }
            && host.filter { $0 == ":" }.count <= 1 && host.filter { $0 == "@" }.count <= 1
    }

    /// ssh's destination arguments: `-p <port>` when the host ends in `:port`.
    static func destination(_ host: String) -> [String] {
        let parts = host.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 2, let port = UInt16(parts[1]) { return ["-p", String(port), String(parts[0])] }
        return [host]
    }

    /// Never share (or tear down) the user's interactive ControlMaster connection; the alive
    /// probes notice a dead connection within ~45s. One password attempt: a wrong saved
    /// password must fail the connection, not be sent three times.
    static let options = [
        "-T", "-o", "ControlMaster=no", "-o", "ControlPath=none",
        "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3", "-o", "ConnectTimeout=10",
        "-o", "NumberOfPasswordPrompts=1",
    ]

    /// What ssh asks (trust this host? password?) goes to `SSHAskpass`. Without `interactive`
    /// it only answers from the keychain, so a reconnect in the background never opens a window.
    static func environment(for host: String, interactive: Bool) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["SSH_ASKPASS"] = Bundle.main.executablePath
        environment["SSH_ASKPASS_REQUIRE"] = "force"
        environment[SSHAskpass.hostVariable] = host
        environment[SSHAskpass.interactiveVariable] = interactive ? "1" : nil
        // The failure texts below are matched in English.
        environment["LC_ALL"] = "C"
        return environment
    }

    struct Failure {
        let message: String
        /// Retrying by itself is pointless: the user has to answer something or fix the host.
        let needsUser: Bool
    }

    /// ssh's own complaint (exit status 255), in the user's words.
    static func failure(_ stderr: String, host: String) -> Failure {
        let text = stderr.lowercased()
        if text.contains("host key verification failed") {
            if text.contains("identification has changed") {
                return Failure(message: L("호스트 키가 전과 다릅니다 — ~/.ssh/known_hosts에서 이 호스트 줄을 확인하세요",
                                          "The host's key has changed — check its line in ~/.ssh/known_hosts"), needsUser: true)
            }
            return Failure(message: L("처음 연결하는 호스트 — 다시 연결을 눌러 확인", "New host — press Reconnect to confirm it"), needsUser: true)
        }
        if text.contains("permission denied") || text.contains("too many authentication failures") {
            // A saved password that no longer works would fail every time without ever asking.
            SSHAskpass.forgetPassword(for: host)
            return Failure(message: L("로그인 실패 — 다시 연결을 눌러 비밀번호 입력", "Login failed — press Reconnect to enter the password"), needsUser: true)
        }
        if text.contains("could not resolve hostname") {
            return Failure(message: L("호스트 이름을 찾을 수 없습니다", "Can't find a host by that name"), needsUser: true)
        }
        if text.contains("connection refused") {
            return Failure(message: L("연결 거부됨 — 그 컴퓨터에서 SSH 서버가 켜져 있는지 확인", "Connection refused — is the SSH server on there?"), needsUser: false)
        }
        if text.contains("timed out") || text.contains("no route to host") || text.contains("network is unreachable") {
            return Failure(message: L("응답 없음 — 꺼져 있거나 네트워크가 닿지 않음", "No answer — it is off or out of reach"), needsUser: false)
        }
        let last = stderr.split(whereSeparator: \.isNewline).last.map { String($0).trimmingCharacters(in: .whitespaces) }
        return Failure(message: last ?? L("연결 끊김", "Disconnected"), needsUser: false)
    }

    /// `Host` names in `~/.ssh/config` (no patterns), for the 추가 menu.
    static var configAliases: [String] {
        guard let config = try? String(contentsOfFile: NSHomeDirectory() + "/.ssh/config", encoding: .utf8) else { return [] }
        var seen = Set<String>()
        return config.split(whereSeparator: \.isNewline).flatMap { line -> [String] in
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" }).map(String.init)
            guard words.first?.lowercased() == "host" else { return [] }
            return words.dropFirst().filter { !$0.contains("*") && !$0.contains("?") && !$0.hasPrefix("!") && isValid($0) }
        }.filter { seen.insert($0).inserted }
    }
}

/// ssh's askpass program: ssh runs `$SSH_ASKPASS "<question>"` and reads the answer from its
/// stdout. `SSHHost.environment` points that at this executable, which answers and exits before
/// anything of the app starts (`runIfRequested`).
///
/// - "Are you sure you want to continue connecting (yes/no/[fingerprint])?" for a host seen for
///   the first time: a window with ssh's own text (the key's fingerprint is in it) and
///   신뢰하고 연결 / 취소.
/// - A password or key passphrase: the keychain's, else a window with a secure field and
///   "키체인에 저장". `SSHHost.failure` forgets a saved one that was refused.
/// - Anything else (a one-time code): always asked, never saved.
/// Windows only open when the connection was started by hand (`interactiveVariable`).
///
/// It answers nobody but an ssh that this app started (`startedByThisApp`). The variables alone
/// used to be enough: any program could run this executable with them and a question naming
/// "password" and be handed the saved one on stdout, with none of the keychain's own asking
/// (found 2026-11-12, before any release carried it).
enum SSHAskpass {
    static let hostVariable = "CLANGNOTCH_SSH_HOST"
    static let interactiveVariable = "CLANGNOTCH_SSH_INTERACTIVE"

    private static func passwordKey(_ host: String) -> String { "ssh-password:" + host }

    static func forgetPassword(for host: String) {
        KeychainHelper.delete(key: passwordKey(host))
    }

    @MainActor static func runIfRequested() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment[hostVariable], CommandLine.arguments.count == 2 else { return false }
        // Not the app's own ssh asking: no answer, no window, nothing read.
        guard startedByThisApp else { exit(1) }
        let question = CommandLine.arguments[1]
        let interactive = environment[interactiveVariable] == "1"
        let lowered = question.lowercased()

        if lowered.contains("(yes/no") {
            guard interactive, confirm(question, host: host) else { exit(1) }
            answer("yes")
        }
        let isPassword = lowered.contains("password") || lowered.contains("passphrase")
        if isPassword, let saved = KeychainHelper.load(key: passwordKey(host)) { answer(saved) }
        guard interactive, let (secret, save) = ask(question, host: host, canSave: isPassword) else { exit(1) }
        if save { KeychainHelper.save(key: passwordKey(host), value: secret) }
        answer(secret)
    }

    /// The caller is `/usr/bin/ssh`, and that ssh was started by this same executable: directly,
    /// or through the `/bin/sh` that watches a Windows host's connection
    /// (`RemoteSessionFollower.sshWatch`). An ssh somebody else started has another parent, and
    /// one whose parent has exited belongs to launchd.
    private static var startedByThisApp: Bool {
        guard let own = Bundle.main.executableURL?.resolvingSymlinksInPath().path else { return false }
        let ssh = getppid()
        guard path(of: ssh) == "/usr/bin/ssh", var ancestor = parent(of: ssh) else { return false }
        // `/bin/sh` runs as whichever shell `/private/var/select/sh` names (bash here).
        if let shell = path(of: ancestor), ["/bin/sh", "/bin/bash", "/bin/dash", "/bin/zsh"].contains(shell) {
            guard let above = parent(of: ancestor) else { return false }
            ancestor = above
        }
        return path(of: ancestor).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == own
    }

    private static func path(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func parent(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, UInt32(name.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let parent = info.kp_eproc.e_ppid
        return parent > 1 ? parent : nil
    }

    private static func answer(_ text: String) -> Never {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
        exit(0)
    }

    @MainActor private static func confirm(_ question: String, host: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = L("처음 연결하는 호스트입니다: \(host)", "New host: \(host)")
        // ssh's own words carry the key's fingerprint; said plainly when it can be picked out.
        let lines = question.split(whereSeparator: \.isNewline).map(String.init)
        let fingerprint = lines.first { $0.contains("key fingerprint is") }
            .flatMap { $0.split(separator: " ").last { $0.hasPrefix("SHA256:") || $0.hasPrefix("MD5:") } }
        let known = lines.contains { $0.contains("known by the following other names") }
        if let fingerprint {
            alert.informativeText = [
                L("이 Mac이 아직 본 적 없는 컴퓨터입니다. 맞는 컴퓨터인지는 아래 지문으로 확인할 수 있습니다.",
                  "This Mac hasn't seen that computer before. The fingerprint below is how to tell it is the right one."),
                L("지문: \(fingerprint)", "Fingerprint: \(fingerprint)"),
                known ? L("같은 지문의 컴퓨터를 다른 이름으로 이미 신뢰하고 있습니다.", "A computer with this fingerprint is already trusted under another name.") : nil,
                L("신뢰하면 이 Mac의 ~/.ssh/known_hosts에 기억되어 다시 묻지 않습니다.",
                  "Trusting it is remembered in this Mac's ~/.ssh/known_hosts and not asked again."),
            ].compactMap { $0 }.joined(separator: "\n\n")
        } else {
            alert.informativeText = lines.filter { !$0.lowercased().contains("(yes/no") }.joined(separator: "\n")
        }
        let trust = alert.addButton(withTitle: L("신뢰하고 연결", "Trust and Connect"))
        let cancel = alert.addButton(withTitle: L("취소", "Cancel"))
        // The window takes the keyboard from whatever the user was typing in: Return must not
        // trust a host by accident (it did once in testing, 2026-11-12). Trusting takes a click.
        trust.keyEquivalent = ""
        cancel.keyEquivalent = "\r"
        return show(alert) == .alertFirstButtonReturn
    }

    @MainActor private static func ask(_ question: String, host: String, canSave: Bool) -> (String, Bool)? {
        let alert = NSAlert()
        alert.messageText = L("SSH 로그인: \(host)", "SSH login: \(host)")
        let asked = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = asked.lowercased()
        // ssh's "user@host's password:" and "Enter passphrase for key '…':" in plain words.
        if lowered.hasSuffix("'s password:") {
            alert.informativeText = L("이 컴퓨터는 키로 로그인되지 않습니다. \(asked.dropLast(12))의 비밀번호를 입력하세요.",
                                      "Key login didn't work there. Enter the password of \(asked.dropLast(12)).")
        } else if lowered.hasPrefix("enter passphrase for key") {
            alert.informativeText = L("SSH 키의 암호를 입력하세요.", "Enter the passphrase of the SSH key.") + "\n" + asked
        } else {
            alert.informativeText = asked
        }
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = field
        if canSave {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = L("키체인에 저장", "Save in Keychain")
            alert.suppressionButton?.state = .on
        }
        alert.addButton(withTitle: L("연결", "Connect"))
        alert.addButton(withTitle: L("취소", "Cancel"))
        alert.window.initialFirstResponder = field
        guard show(alert) == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return nil }
        return (field.stringValue, canSave && alert.suppressionButton?.state == .on)
    }

    @MainActor private static func show(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        alert.window.level = .floating
        return alert.runModal()
    }
}
