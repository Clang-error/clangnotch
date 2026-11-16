import Foundation

/// Plain signs that a request is dangerous, for people who don't read shell. A request with one
/// can't be allowed from the 권한 드롭다운, only in the agent's own prompt. The list is short on
/// purpose: it catches the common tricks, not every one, and an everyday command must never trip it.
enum PermissionRisk: CaseIterable, Equatable {
    case runsDownload, runsEncoded, admin, secrets, wipes, loginConfig

    /// What the dropdown says, in words a non-programmer follows.
    var reason: String {
        switch self {
        case .runsDownload: L("인터넷에서 받은 스크립트를 바로 실행합니다", "Runs a script straight from the internet")
        case .runsEncoded: L("알아볼 수 없게 감춘 명령을 디코드하여 실행합니다", "Decodes a hidden command and runs it")
        case .admin: L("관리자 권한으로 실행합니다", "Runs with administrator rights")
        case .secrets: L("SSH 키나 비밀번호 같은 비밀 정보에 접근합니다", "Touches secrets such as SSH keys or passwords")
        case .wipes: L("홈 폴더나 디스크 전체를 지웁니다", "Deletes the home folder or the whole disk")
        case .loginConfig: L("로그인할 때마다 실행되는 설정을 바꿉니다", "Changes what runs every time you log in")
        }
    }

    private static let shell = #"(sudo\s+)?(ba|z|da|k|fi)?sh\b|python3?\b|perl\b|ruby\b|node\b"#
    private static let loginFiles = #"\.(zshrc|zshenv|zprofile|zlogin|bashrc|bash_profile|bash_login|profile)\b|Library/LaunchAgents|Library/LaunchDaemons"#

    private var patterns: [String] {
        switch self {
        case .runsDownload:
            [#"\b(curl|wget)\b[^|;&\n]*\|\s*"# + Self.shell,
             #"\$\(\s*(curl|wget)\b"#, #"<\(\s*(curl|wget)\b"#, #"`\s*(curl|wget)\b"#]
        case .runsEncoded:
            [#"base64\s+(-d|-D|--decode)\b[^;&\n]*\|\s*"# + Self.shell,
             #"\beval\b[^\n]*base64\s+(-d|-D|--decode)"#]
        case .admin:
            [#"(^|[\s;&|(`])sudo\s"#]
        case .secrets:
            [#"(^|[\s'"=/~])\.ssh(/|\b)"#, #"\bid_(rsa|ed25519|ecdsa|dsa)\b"#,
             #"\bsecurity\s+(find|dump|export)-"#,
             #"(^|[\s'"/])\.env(\.(local|production|development))?($|[\s'";|&)])"#,
             #"\.aws/credentials|\.gnupg\b|\.netrc\b"#]
        case .wipes:
            [#"\brm\s+(-[a-zA-Z]+\s+)*-[a-zA-Z]*[rR][a-zA-Z]*\s+(-[a-zA-Z]+\s+)*(["']?(~|\$HOME|\$\{HOME\})["']?/?\*?|/\*?)(\s|$|;|&)"#]
        case .loginConfig:
            [#"(>>?|\btee\b(\s+-a)?|\bcp\b[^\n]*|\bmv\b[^\n]*|\bsed\s+-i[^\n]*)\s*\S*("# + Self.loginFiles + ")"]
        }
    }

    /// The signs in what the dropdown shows: a command, a path, or an MCP tool's input.
    static func found(in text: String, toolName: String) -> [PermissionRisk] {
        guard text.utf8.count <= PermissionText.maxCharacters else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        func matches(_ pattern: String) -> Bool {
            (try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]))?
                .firstMatch(in: text, range: range) != nil
        }
        // Writing a file tool's path to a login file needs no redirect to count.
        let writesFile = ["Write", "Edit", "MultiEdit", "NotebookEdit", "apply_patch"].contains(toolName)
        return allCases.filter { risk in
            if risk == .loginConfig, writesFile, matches(loginFiles) { return true }
            return risk.patterns.contains(where: matches)
        }
    }
}
