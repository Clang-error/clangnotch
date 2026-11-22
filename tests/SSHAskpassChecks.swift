import Foundation

/// Who gets a saved SSH secret: only an ssh started without `~/.ssh/config` and with nothing
/// but the options `SSHHost.arguments` gives it (`SSHAskpass.Caller`). Nothing here touches the
/// keychain or runs ssh.
@main
struct SSHAskpassChecks {
    static func main() {
        let host = "me@box.example:2222"
        let alias = SSHAskpass.alias(for: host)
        precondition(SSHAskpass.host(fromAlias: alias) == host, "The alias names the host it was made from")
        precondition(alias.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }, "The alias is safe as a known_hosts name")
        precondition(SSHAskpass.host(fromAlias: "clangnotch-zz") == nil && SSHAskpass.host(fromAlias: "box") == nil)

        let config = """
        user me
        hostname box.example
        port 2222
        identityfile ~/.ssh/id_ed25519
        identityfile ~/Keys/my key
        identitiesonly yes
        userknownhostsfile ~/.ssh/known_hosts ~/.ssh/known_hosts2
        """
        guard let route = SSHRoute.parse(config) else { preconditionFailure("A plain host resolves") }
        precondition(route.hostName == "box.example" && route.port == "2222" && route.user == "me")
        precondition(route.identityFiles.count == 2 && route.identitiesOnly)
        precondition(route.knownHostsFiles == ["~/.ssh/known_hosts", "~/.ssh/known_hosts2"])
        let agent = SSHRoute.parse(config + "\nidentityagent ~/Library/Group Containers/x/agent.sock\nkexalgorithms a,b\npkcs11provider /tmp/evil.dylib\nlocalcommand x")
        precondition(agent?.passed == ["IdentityAgent=\"~/Library/Group Containers/x/agent.sock\"", "KexAlgorithms=a,b"], "Only safe keys pass, quoted")
        precondition(SSHRoute.parse(config + "\nproxyjump jump.example") == nil, "A jump host needs the config")
        precondition(SSHRoute.parse(config + "\nproxycommand nc %h %p") == nil, "A proxy command needs the config")
        precondition(SSHRoute.parse(config + "\nproxycommand none") != nil)
        precondition(SSHRoute.parse("user me\nhostname -oProxyCommand=x\nport 22") == nil, "A host name can't be an option")
        precondition(SSHRoute.parse("user me\nhostname box\u{1}x\nport 22") == nil, "No control characters")

        let pinned = ["/usr/bin/ssh", "-F", "/dev/null"] + SSHHost.options
            + ["-o", "StrictHostKeyChecking=yes", "-o", "ExitOnForwardFailure=yes", "-R", "/home/me/.claude/clangnotch.sock:/Users/me/Library/Application Support/ClangNotch/hook.sock"]
            + route.options(for: host) + [route.hostName, "sh"]
        let background = SSHAskpass.Caller.parse(pinned)
        precondition(background.pinned && background.host == host && !background.interactive, "The app's own config-free ssh gets the secret")
        let byHand = SSHAskpass.Caller.parse(pinned.map { $0 == "StrictHostKeyChecking=yes" ? "StrictHostKeyChecking=ask" : $0 })
        precondition(byHand.pinned && byHand.host == host && byHand.interactive)

        func refused(_ arguments: [String], _ why: String) {
            precondition(!SSHAskpass.Caller.parse(arguments).pinned, why)
        }
        // ssh reads options after the destination too, and uses the first of two (review, 2026-11-21).
        refused(Array(pinned.dropLast()) + ["-o", "ProxyCommand=sh -c x", "sh"], "No option after the destination")
        refused(Array(pinned.dropLast()) + ["sh", "extra"], "One remote command word only")
        refused(["/usr/bin/ssh", "-o", "UserKnownHostsFile=/tmp/evil"] + pinned.dropFirst(), "No second known_hosts file in front")
        refused(["/usr/bin/ssh", "-o", "HostName=evil.example"] + pinned.dropFirst(), "No second host name in front")
        refused(["/usr/bin/ssh", "-o", "knownhostscommand=/tmp/x"] + pinned.dropFirst(), "Keys are matched without case")
        refused(["/usr/bin/ssh", "-oProxyCommand=x"] + pinned.dropFirst(), "No joined option")
        refused(Array(pinned.dropLast(2)) + ["--", route.hostName, "sh"], "No end of options")
        refused(pinned.filter { $0 != "-F" && $0 != "/dev/null" }, "An ssh reading the config gets no saved secret")
        refused(["/usr/bin/ssh", "-F", "/tmp/evil"] + pinned.dropFirst(3), "Only /dev/null as the config")
        refused(Array(pinned.dropLast(2)) + ["-o", "ProxyCommand=sh -c x", route.hostName], "No option outside the list")
        refused(Array(pinned.dropLast(2)) + ["-o", "LocalCommand=x", route.hostName], "No local command")
        refused(Array(pinned.dropLast(2)) + ["-J", "jump", route.hostName], "No jump host")
        refused(pinned.map { $0.hasPrefix("KnownHostsCommand=") ? "KnownHostsCommand=/tmp/x %H %t %K" : $0 }, "Only this app as KnownHostsCommand")
        refused(pinned.map { $0 == "UserKnownHostsFile=/dev/null" ? "UserKnownHostsFile=~/.ssh/known_hosts" : $0 }, "Keys only from the keychain")
        refused(pinned.filter { !$0.hasPrefix("HostKeyAlias=") }, "No host without the alias")
        let plain = SSHAskpass.Caller.parse(["/usr/bin/ssh"] + SSHHost.options + ["-o", "StrictHostKeyChecking=ask"] + SSHHost.destination(host) + ["sh"])
        precondition(!plain.pinned && plain.interactive && plain.host == host, "Through the config the host is ssh's destination")
        let quiet = SSHAskpass.Caller.parse(["/usr/bin/ssh"] + SSHHost.options + SSHHost.destination("box") + ["sh"])
        precondition(!quiet.interactive && quiet.host == "box", "No window unless started by hand")

        precondition(SSHAskpass.promptKind("me@box.example's password: ") == .password)
        precondition(SSHAskpass.promptKind("(me@box.example) Password: ") == .password)
        precondition(SSHAskpass.promptKind("Enter passphrase for key '/Users/me/.ssh/id_ed25519': ") == .passphrase)
        precondition(SSHAskpass.promptKind("Verification code: ") == nil, "A one-time code is never saved")
        precondition(SSHAskpass.promptKind("Please type your password here: ") == nil, "A server's own wording gets nothing")
        precondition(SSHAskpass.promptKind("me@box's password:\nme@evil's password:") == nil)

        let key = "AAAAC3NzaC1lZDI1NTE5AAAAIOeM4px1zY4Ab6qpv69QCcOeGvIAkbYVUR9tqzxY8CkY"
        let expected = "SHA256:+LVnJ0LCyu+Ap4SH9BNlopPbdVQZwJIeoNR5WhnTK4I"  // ssh-keygen -l
        precondition(SSHAskpass.fingerprint(ofKey: key) == expected)
        precondition(SSHLogin(secret: "s", kind: .password, hostKeys: [expected]).trusts(key: key), "A trusted fingerprint")
        precondition(SSHLogin(secret: "s", kind: .password, hostKeys: ["ssh-ed25519 \(key)"]).trusts(key: key), "A key from known_hosts")
        precondition(!SSHLogin(secret: "s", kind: .password, hostKeys: []).trusts(key: key), "No key kept, none trusted")
        precondition(!SSHLogin(secret: "s", kind: .password, hostKeys: ["SHA256:other"]).trusts(key: key))
        print("SSHAskpassChecks passed")
    }
}
