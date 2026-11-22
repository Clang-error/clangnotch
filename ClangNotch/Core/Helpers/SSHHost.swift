import AppKit
import CryptoKit

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

    /// ssh's arguments up to and including the destination; `extra` are more options of the
    /// caller's (a forward). The remote command goes after.
    ///
    /// A host with a saved password or passphrase is reached without `~/.ssh/config`
    /// (`-F /dev/null`), with what that config says about it (`SSHRoute`) given as options and
    /// its host key checked against the keys kept with the secret (`SSHLogin.hostKeys`).
    /// The config can run commands (`ProxyCommand`, `Match exec`, `LocalCommand`,
    /// `KnownHostsCommand`), and whatever ssh starts looks to `SSHAskpass` exactly like ssh
    /// asking: any program running as the user could add one that runs this executable and
    /// takes the saved secret, or point the alias at its own server (found 2026-11-21). Without
    /// a saved secret there is nothing to take, and the config is used as before.
    ///
    /// Whether ssh may ask (a window) is in the arguments, not the environment: ssh's children
    /// inherit its environment, but not its arguments (`SSHAskpass.Caller`). Started by hand it
    /// is `StrictHostKeyChecking=ask`; in the background a connection through the config leaves
    /// the user's own setting alone.
    ///
    /// A host whose saved secret can't be used this way (behind a proxy, or `ssh -G` gave no
    /// answer in 3 s) goes through the config, where the secret is never handed over.
    static func arguments(_ host: String, interactive: Bool, extra: [String] = []) -> [String] {
        if SSHLogin.exists(host), let route = SSHRoute.resolve(host) {
            return ["-F", "/dev/null"] + options + ["-o", "StrictHostKeyChecking=" + (interactive ? "ask" : "yes")]
                + extra + route.options(for: host) + [route.hostName]
        }
        return options + (interactive ? ["-o", "StrictHostKeyChecking=ask"] : []) + extra + destination(host)
    }

    /// What ssh gets: the askpass variables and little else. The app's own environment can carry
    /// variables set for every app (`launchctl setenv`) that steer ssh or what it starts.
    static func environment(for host: String) -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        for name in ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "SSH_AUTH_SOCK"] {
            environment[name] = inherited[name]
        }
        environment["SSH_ASKPASS"] = Bundle.main.executablePath
        environment["SSH_ASKPASS_REQUIRE"] = "force"
        // Only tells this executable it was started as askpass; the host is read from ssh's arguments.
        environment[SSHAskpass.hostVariable] = host
        // The failure texts below are matched in English.
        environment["LC_ALL"] = "C"
        return environment
    }

    struct Failure {
        let message: String
        /// Retrying by itself is pointless: the user has to answer something or fix the host.
        let needsUser: Bool
    }

    /// ssh's own complaint (exit status 255), in the user's words. `arguments` are ssh's: a saved
    /// secret is forgotten for a refused login only if it was handed over, which happens only
    /// without the config.
    static func failure(_ stderr: String, host: String, arguments: [String]) -> Failure {
        let text = stderr.lowercased()
        if text.contains("host key verification failed") {
            if text.contains("identification has changed") {
                return Failure(message: L("호스트 키가 전과 다릅니다 — ~/.ssh/known_hosts에서 이 호스트 줄을 확인하세요",
                                          "The host's key has changed — check its line in ~/.ssh/known_hosts"), needsUser: true)
            }
            if arguments.contains("KnownHostsCommand=\(SSHAskpass.knownHostsCommand)") {
                // No key kept yet (saved before 1.5.0), or not the kept one: 다시 연결 tells which.
                return Failure(message: L("호스트 키 확인 필요 — 다시 연결을 눌러 확인", "Host key to confirm — press Reconnect"), needsUser: true)
            }
            return Failure(message: L("처음 연결하는 호스트 — 다시 연결을 눌러 확인", "New host — press Reconnect to confirm it"), needsUser: true)
        }
        if text.contains("permission denied") || text.contains("too many authentication failures") {
            // A saved password that no longer works would fail every time without ever asking.
            if arguments.contains("KnownHostsCommand=\(SSHAskpass.knownHostsCommand)") { SSHLogin.forget(host) }
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

/// What `~/.ssh/config` makes of a host (`ssh -G`), handed to an ssh that doesn't read it.
struct SSHRoute {
    let hostName: String
    let port: String
    let user: String
    let identityFiles: [String]
    let identitiesOnly: Bool
    let hostKeyAlias: String?
    let knownHostsFiles: [String]
    /// What else of the config is passed along, as `Key=value`: algorithms an older server
    /// needs, a certificate, an agent such as 1Password's. Nothing that runs a command, loads a
    /// library or routes the connection elsewhere.
    let passed: [String]

    /// `ssh -G` keys handed on, with the `-o` name each goes back as. Not `HostKeyAlgorithms`:
    /// `-G` prints the default list too, and set by hand it stops ssh putting the kept keys'
    /// types first (the `NONE NONE` call), so a host kept with only an RSA key would fail.
    static let passedKeys = [
        "kexalgorithms": "KexAlgorithms",
        "pubkeyacceptedalgorithms": "PubkeyAcceptedAlgorithms", "ciphers": "Ciphers", "macs": "MACs",
        "certificatefile": "CertificateFile", "identityagent": "IdentityAgent", "addkeystoagent": "AddKeysToAgent",
    ]

    /// nil when the host goes through a proxy (its command or jump host would have to come from
    /// the config), or ssh gave no answer. Anything `Match exec` starts here gets no secret
    /// either way (`SSHAskpass.Caller`).
    static func resolve(_ host: String) -> SSHRoute? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-G"] + SSHHost.destination(host)
        // Without the askpass variables (inside askpass they are set): nothing it starts gets an answer.
        var environment = SSHHost.environment(for: host)
        environment["SSH_ASKPASS"] = nil
        environment["SSH_ASKPASS_REQUIRE"] = nil
        environment[SSHAskpass.hostVariable] = nil
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        guard (try? process.run()) != nil else { return nil }
        // `Match exec` runs while ssh reads the config; one that hangs must not hold this up.
        if done.wait(timeout: .now() + 3) == .timedOut {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        return parse(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    static func parse(_ text: String) -> SSHRoute? {
        var values: [String: [String]] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let space = line.firstIndex(of: " ") else { continue }
            let value = String(line[line.index(after: space)...])
            // A value goes back to ssh as one `-o` line; nothing may start another.
            guard !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
            values[line[..<space].lowercased(), default: []].append(value)
        }
        for proxy in ["proxycommand", "proxyjump"] where values[proxy]?.contains(where: { $0 != "none" }) == true {
            return nil
        }
        guard let hostName = values["hostname"]?.first, !hostName.hasPrefix("-"), !hostName.contains(" "),
              let port = values["port"]?.first, UInt16(port) != nil,
              let user = values["user"]?.first, !user.contains(" ") else { return nil }
        return SSHRoute(
            hostName: hostName, port: port, user: user,
            identityFiles: values["identityfile"] ?? [],
            identitiesOnly: values["identitiesonly"]?.first == "yes",
            hostKeyAlias: values["hostkeyalias"]?.first,
            knownHostsFiles: values["userknownhostsfile"]?.first?.split(separator: " ").map(String.init) ?? [],
            passed: passedKeys.keys.sorted().flatMap { key in
                (values[key] ?? []).filter { $0 != "none" }.map { "\(passedKeys[key]!)=\(quoted($0))" }
            }
        )
    }

    /// A value with a space goes back in double quotes, as ssh's config takes it.
    private static func quoted(_ value: String) -> String {
        value.contains(" ") ? "\"\(value)\"" : value
    }

    /// Everything ssh needs with `-F /dev/null`. `SSHAskpass.Caller.allowedOptions` lists these.
    func options(for host: String) -> [String] {
        var options = ["-o", "HostName=\(hostName)", "-o", "Port=\(port)", "-o", "User=\(user)"]
        for file in identityFiles { options += ["-o", "IdentityFile=\(Self.quoted(file))"] }
        if identitiesOnly { options += ["-o", "IdentitiesOnly=yes"] }
        for option in passed { options += ["-o", option] }
        return options + [
            "-o", "HostKeyAlias=\(SSHAskpass.alias(for: host))",
            "-o", "UserKnownHostsFile=/dev/null", "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "KnownHostsCommand=\(SSHAskpass.knownHostsCommand)",
            "-o", "CheckHostIP=no", "-o", "UpdateHostKeys=no",
        ]
    }

    /// The keys `~/.ssh/known_hosts` holds for this host, as `type base64` lines: kept with a
    /// secret typed in a connection that just checked them (`SSHAskpass.save`).
    func knownKeys() -> [String] {
        let name = hostKeyAlias ?? (port == "22" ? hostName : "[\(hostName)]:\(port)")
        var keys: [String] = []
        for file in knownHostsFiles {
            let path = (file as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
            process.arguments = ["-F", name, "-f", path]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { continue }
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            for line in text.split(whereSeparator: \.isNewline) where !line.hasPrefix("#") && !line.hasPrefix("@") {
                let fields = line.split(separator: " ")
                guard fields.count >= 3 else { continue }
                let key = "\(fields[1]) \(fields[2])"
                if !keys.contains(key) { keys.append(key) }
            }
        }
        return keys
    }
}

/// A saved password or key passphrase, in the keychain with the host keys it may go to.
struct SSHLogin: Codable {
    enum Kind: String, Codable {
        case password, passphrase
        /// Saved before 2026-11-21, when the kind wasn't kept.
        case either
    }

    var secret: String
    var kind: Kind
    /// `type base64` keys from `~/.ssh/known_hosts` when the secret was saved, or `SHA256:`
    /// fingerprints the user trusted in the window. Kept in the secret's own item: another
    /// program can't change it without the keychain asking, as it could a file.
    var hostKeys: [String]

    private static func key(_ host: String) -> String { "ssh-password:" + host }

    static func load(_ host: String) -> SSHLogin? {
        guard let text = KeychainHelper.load(key: key(host)) else { return nil }
        if let login = try? JSONDecoder().decode(SSHLogin.self, from: Data(text.utf8)) { return login }
        // Saved before 2026-11-21: the bare secret, and no key yet (trusted again once).
        return SSHLogin(secret: text, kind: .either, hostKeys: [])
    }

    func save(_ host: String) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        KeychainHelper.save(key: Self.key(host), value: String(decoding: data, as: UTF8.self))
    }

    static func forget(_ host: String) {
        KeychainHelper.delete(key: key(host))
    }

    /// Without reading the secret: reading it can make the keychain ask for approval (a build
    /// with another signature saved it), which in the app would hold the main thread.
    static func exists(_ host: String) -> Bool {
        KeychainHelper.contains(key: key(host))
    }

    func trusts(key base64: String) -> Bool {
        guard let print = SSHAskpass.fingerprint(ofKey: base64) else { return false }
        return hostKeys.contains { entry in
            entry == print || entry.split(separator: " ").last.flatMap { SSHAskpass.fingerprint(ofKey: String($0)) } == print
        }
    }
}

/// ssh's askpass program: ssh runs `$SSH_ASKPASS "<question>"` and reads the answer from its
/// stdout. `SSHHost.environment` points that at this executable, which answers and exits before
/// anything of the app starts (`runIfRequested`). The same executable is the
/// `KnownHostsCommand` of a connection without the config (`printKnownHost`).
///
/// - "Are you sure you want to continue connecting (yes/no/[fingerprint])?" for a host seen for
///   the first time: a window with ssh's own text (the key's fingerprint is in it) and
///   신뢰하고 연결 / 취소.
/// - A password or key passphrase: the keychain's, else a window with a secure field and
///   "키체인에 저장". `SSHHost.failure` forgets a saved one that was refused.
/// - Anything else (a one-time code): always asked, never saved.
/// Windows only open when the connection was started by hand (`Caller.interactive`).
///
/// It answers nobody but an ssh that this app started, and gives a saved secret only to one
/// started without the config (`Caller`). The variables alone used to be enough: any program
/// could run this executable with them and a question naming "password" and be handed the
/// saved one on stdout, with none of the keychain's own asking (found 2026-11-12, before any
/// release carried it). Then anything the config made ssh start could (2026-11-21).
enum SSHAskpass {
    static let hostVariable = "CLANGNOTCH_SSH_HOST"
    static let knownHostFlag = "--clangnotch-known-host"

    static var knownHostsCommand: String {
        "\"\(Bundle.main.executablePath ?? "")\" \(knownHostFlag) %H %t %K"
    }

    /// The `HostKeyAlias` of a connection without the config: the host, in letters ssh and a
    /// known_hosts line take as they are.
    static func alias(for host: String) -> String {
        "clangnotch-" + host.utf8.map { String(format: "%02x", $0) }.joined()
    }

    static func host(fromAlias alias: String) -> String? {
        guard alias.hasPrefix("clangnotch-") else { return nil }
        let hex = Array(alias.dropFirst("clangnotch-".count))
        guard !hex.isEmpty, hex.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        for index in stride(from: 0, to: hex.count, by: 2) {
            guard let byte = UInt8(String(hex[index...index + 1]), radix: 16) else { return nil }
            bytes.append(byte)
        }
        return String(bytes: bytes, encoding: .utf8)
    }

    @MainActor static func runIfRequested() -> Bool {
        let arguments = CommandLine.arguments
        if arguments.count >= 2, arguments[1] == knownHostFlag {
            printKnownHost(Array(arguments.dropFirst(2)))
            exit(0)
        }
        guard ProcessInfo.processInfo.environment[hostVariable] != nil, arguments.count == 2 else { return false }
        // Not the app's own ssh asking: no answer, no window, nothing read.
        guard let caller = Caller.current(), let host = caller.host else { exit(1) }
        let question = arguments[1]

        if question.lowercased().contains("(yes/no") {
            guard caller.interactive else { exit(1) }
            guard caller.pinned, var login = SSHLogin.load(host) else {
                guard confirm(question, host: host) else { exit(1) }
                answer("yes")
            }
            // A key was kept with the secret and this one isn't it: nothing to trust from here.
            guard login.hostKeys.isEmpty else {
                refuseChangedKey(host: host)
                exit(1)
            }
            guard confirm(question, host: host), let print = fingerprint(in: question) else { exit(1) }
            login.hostKeys = [print]
            login.save(host)
            answer("yes")
        }
        let kind = promptKind(question)
        if caller.pinned, let kind, let login = SSHLogin.load(host), login.kind == kind || login.kind == .either {
            answer(login.secret)
        }
        guard caller.interactive else { exit(1) }
        // Through the config a secret is only saved for a host that has none (one that has, but
        // can't be reached without the config, keeps it) and that can be reached without it.
        let route = !caller.pinned && kind != nil && !SSHLogin.exists(host) ? SSHRoute.resolve(host) : nil
        guard let (secret, save) = ask(question, host: host, canSave: kind != nil && (caller.pinned || route != nil))
        else { exit(1) }
        if save, let kind {
            let kept = caller.pinned ? SSHLogin.load(host)?.hostKeys ?? [] : route?.knownKeys() ?? []
            SSHLogin(secret: secret, kind: kind, hostKeys: kept).save(host)
        }
        answer(secret)
    }

    /// ssh's own prompts for a password (its own and the keyboard-interactive one sshd sends)
    /// and for a key's passphrase. Nothing else gets a saved secret, or offers to save one.
    static func promptKind(_ question: String) -> SSHLogin.Kind? {
        let asked = question.trimmingCharacters(in: .whitespacesAndNewlines)
        if asked.range(of: #"^[^@\s]+@\S+'s password:$"#, options: .regularExpression) != nil
            || asked.range(of: #"^\([^@\s]+@[^\s)]+\) [Pp]assword:$"#, options: .regularExpression) != nil {
            return .password
        }
        if asked.hasPrefix("Enter passphrase for key '"), asked.hasSuffix(":"), !asked.contains("\n") { return .passphrase }
        return nil
    }

    /// `KnownHostsCommand <alias> <type> <key>`: the offered key back as a known_hosts line if it
    /// is one kept with the host's secret. Asked first with `NONE NONE`, for the order of key
    /// types (checked with OpenSSH 10.5, 2026-11-21): then every kept key with its type.
    private static func printKnownHost(_ arguments: [String]) {
        guard let alias = arguments.first, let host = host(fromAlias: alias), var login = SSHLogin.load(host) else { return }
        // Saved before 1.5.0, with no key: the ones known_hosts holds now, as a secret saved
        // today would get (`runIfRequested`), rather than a trust window for a host used for months.
        if login.kind == .either, login.hostKeys.isEmpty, let keys = SSHRoute.resolve(host)?.knownKeys(), !keys.isEmpty {
            login.hostKeys = keys
            login.save(host)
        }
        let offered = arguments.count == 3 && arguments[2] != "NONE" ? arguments[2] : ""
        let lines: [String]
        if offered.isEmpty {
            lines = login.hostKeys.filter { $0.contains(" ") }.map { "\(alias) \($0)" }
        } else {
            guard arguments[1].allSatisfy({ $0.isLetter || $0.isNumber || "-@.".contains($0) }),
                  Data(base64Encoded: offered) != nil, login.trusts(key: offered) else { return }
            lines = ["\(alias) \(arguments[1]) \(offered)"]
        }
        if !lines.isEmpty { FileHandle.standardOutput.write(Data((lines.joined(separator: "\n") + "\n").utf8)) }
    }

    /// ssh's `SHA256:` fingerprint of a base64 key.
    static func fingerprint(ofKey base64: String) -> String? {
        guard let data = Data(base64Encoded: base64) else { return nil }
        let digest = Data(SHA256.hash(data: data)).base64EncodedString()
        return "SHA256:" + digest.replacingOccurrences(of: "=", with: "")
    }

    private static func fingerprint(in question: String) -> String? {
        question.split(whereSeparator: \.isNewline).first { $0.contains("key fingerprint is") }
            .flatMap { $0.split(separator: " ").last { $0.hasPrefix("SHA256:") } }
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
    }

    /// The ssh that runs this, as it was started.
    struct Caller {
        /// The host it connects to: from `HostKeyAlias` without the config, else its destination
        /// (and `-p`). Not the variable, which a program ssh started can set to any host.
        let host: String?
        /// Started without the config, with nothing but the options `SSHHost.arguments` gives
        /// it: it may have the saved secret.
        let pinned: Bool
        /// Started by hand: windows may open.
        let interactive: Bool

        static let allowedOptions: Set<String> = Set([
            "controlmaster", "controlpath", "serveraliveinterval", "serveralivecountmax", "connecttimeout",
            "numberofpasswordprompts", "stricthostkeychecking", "exitonforwardfailure",
            "hostname", "port", "user", "identityfile", "identitiesonly",
            "hostkeyalias", "userknownhostsfile", "globalknownhostsfile", "knownhostscommand",
            "checkhostip", "updatehostkeys",
        ]).union(SSHRoute.passedKeys.keys)
        /// Options ssh takes more than once (each adds a file); any other given twice is refused,
        /// as ssh would use the first.
        static let repeatable: Set<String> = ["identityfile", "certificatefile"]

        /// The caller is `/usr/bin/ssh`, and that ssh was started by this same executable:
        /// directly, or through the `/bin/sh` that watches a Windows host's connection
        /// (`RemoteSessionFollower.sshWatch`). An ssh somebody else started has another parent,
        /// and one whose parent has exited belongs to launchd. Its arguments are read from the
        /// kernel: a program ssh started can set any variable, but not ssh's arguments. An ssh
        /// started by a child of this app (a program swapped in for `codex`) passes the parent
        /// check too, so the arguments are read the way ssh reads them.
        static func current() -> Caller? {
            guard let own = Bundle.main.executableURL?.resolvingSymlinksInPath().path else { return nil }
            let ssh = getppid()
            guard path(of: ssh) == "/usr/bin/ssh", var ancestor = parent(of: ssh) else { return nil }
            // `/bin/sh` runs as whichever shell `/private/var/select/sh` names (bash here).
            if let shell = path(of: ancestor), ["/bin/sh", "/bin/bash", "/bin/dash", "/bin/zsh"].contains(shell) {
                guard let above = parent(of: ancestor) else { return nil }
                ancestor = above
            }
            guard path(of: ancestor).map({ URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }) == own,
                  let arguments = arguments(of: ssh) else { return nil }
            return parse(arguments)
        }

        /// As ssh does: options before and after the destination (it reads on past it), up to
        /// the first word after it, where the remote command starts.
        static func parse(_ arguments: [String]) -> Caller {
            var options: [String] = []
            var configFile: String?
            var otherFlags = false
            var destination: String?
            var port: String?
            var command: [String] = []
            var index = 1
            while index < arguments.count {
                let argument = arguments[index]
                guard argument.hasPrefix("-") else {
                    if destination == nil {
                        destination = argument
                        index += 1
                        continue
                    }
                    command = Array(arguments[index...])
                    break
                }
                let value = index + 1 < arguments.count ? arguments[index + 1] : nil
                switch argument {
                case "-T":
                    index += 1
                case "-F":
                    configFile = value
                    index += 2
                case "-o":
                    if let value { options.append(value) }
                    index += 2
                case "-p":
                    port = value
                    index += 2
                case "-R":
                    index += 2
                default:
                    otherFlags = true
                    index += 1
                }
            }
            var values: [String: [String]] = [:]
            for option in options {
                let parts = option.split(separator: "=", maxSplits: 1).map(String.init)
                values[parts[0].lowercased(), default: []].append(parts.count == 2 ? parts[1] : "")
            }
            func only(_ key: String) -> String? {
                values[key].flatMap { $0.count == 1 ? $0[0] : nil }
            }
            let interactive = only("stricthostkeychecking") == "ask"
            let pinnedHost = only("hostkeyalias").flatMap(SSHAskpass.host(fromAlias:))
            let pinned = configFile == "/dev/null" && !otherFlags && command.count <= 1
                && values.keys.allSatisfy(allowedOptions.contains)
                && values.allSatisfy { $0.value.count == 1 || repeatable.contains($0.key) }
                && only("userknownhostsfile") == "/dev/null" && only("globalknownhostsfile") == "/dev/null"
                && only("knownhostscommand") == SSHAskpass.knownHostsCommand && pinnedHost != nil
            if pinned { return Caller(host: pinnedHost, pinned: true, interactive: interactive) }
            let host = destination.map { name in port.map { "\(name):\($0)" } ?? name }
            return Caller(host: host, pinned: false, interactive: interactive)
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

        /// `KERN_PROCARGS2`: argc, the executable's path, padding, then argc strings.
        private static func arguments(of pid: pid_t) -> [String]? {
            var name: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
            var size = 0
            guard sysctl(&name, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
            var buffer = [UInt8](repeating: 0, count: size)
            guard sysctl(&name, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return nil }
            let count = buffer.withUnsafeBytes { Int($0.load(as: Int32.self)) }
            var index = 4
            while index < size, buffer[index] != 0 { index += 1 }
            while index < size, buffer[index] == 0 { index += 1 }
            var arguments: [String] = []
            while arguments.count < count, index < size {
                let start = index
                while index < size, buffer[index] != 0 { index += 1 }
                arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
                index += 1
            }
            return arguments.count == count ? arguments : nil
        }
    }

    private static func answer(_ text: String) -> Never {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
        exit(0)
    }

    @MainActor private static func refuseChangedKey(host: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = L("호스트 키가 다릅니다: \(host)", "The host's key is different: \(host)")
        alert.informativeText = L(
            "비밀번호를 저장할 때 본 키와 다릅니다. 다른 컴퓨터가 이 호스트인 척하고 있을 수 있어서 연결하지 않았습니다. 그 컴퓨터의 키가 정말 바뀌었다면 설정에서 호스트를 지우고 다시 추가하세요.",
            "It isn't the key seen when the password was saved. Another computer may be posing as this host, so the connection was stopped. If that computer's key really changed, remove the host in Settings and add it again.")
        alert.addButton(withTitle: L("확인", "OK"))
        _ = show(alert)
    }

    @MainActor private static func confirm(_ question: String, host: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = L("처음 연결하는 호스트입니다: \(host)", "New host: \(host)")
        // ssh's own words carry the key's fingerprint; said plainly when it can be picked out.
        let lines = question.split(whereSeparator: \.isNewline).map(String.init)
        let shown = fingerprint(in: question)
        let known = lines.contains { $0.contains("known by the following other names") }
        if let shown {
            alert.informativeText = [
                L("이 Mac이 아직 본 적 없는 컴퓨터입니다. 맞는 컴퓨터인지는 아래 지문으로 확인할 수 있습니다.",
                  "This Mac hasn't seen that computer before. The fingerprint below is how to tell it is the right one."),
                L("지문: \(shown)", "Fingerprint: \(shown)"),
                known ? L("같은 지문의 컴퓨터를 다른 이름으로 이미 신뢰하고 있습니다.", "A computer with this fingerprint is already trusted under another name.") : nil,
                L("신뢰하면 기억되어 다시 묻지 않습니다.", "Trusting it is remembered and not asked again."),
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
