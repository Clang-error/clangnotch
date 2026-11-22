import Foundation

/// Starts a program that isn't part of macOS as its own responsible process, not this app's.
///
/// macOS charges a child's privacy requests to the app that started it (its responsible
/// process): the Now Playing `perl` showed ClangNotch as responsible (2026-11-21). So a
/// `codex`, `tmux` or `idevice_id` that another program put in `~/.local/bin` or the Homebrew
/// folder (both writable by the user), or a terminal CLI named by another process's
/// environment, ran with this app's Accessibility, Input Monitoring, Location and audio grants.
///
/// The program goes through this executable: `--clangnotch-disclaim <path> <arguments…>`
/// replaces itself with the program (`POSIX_SPAWN_SETEXEC`), disclaiming the responsibility on
/// the way, before any of the app starts (`ClangNotchApp.init`). The pid, pipes and exit status
/// are the program's, so a `Process` reads them as before. Programs in the system's own folders
/// (protected by SIP) run as they are: `osascript` must stay charged to this app for Terminal's
/// Automation grant.
enum DisclaimedLaunch {
    static let flag = "--clangnotch-disclaim"

    static func configure(_ process: Process, executable: String, arguments: [String]) {
        let system = ["/usr/bin/", "/bin/", "/usr/sbin/", "/sbin/", "/usr/libexec/", "/System/"]
        if system.contains(where: executable.hasPrefix) || Bundle.main.executablePath == nil {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
        } else {
            process.executableURL = Bundle.main.executableURL
            process.arguments = [flag, executable] + arguments
        }
    }

    /// Never returns when asked to start a program; without the disclaim call (an SPI) it
    /// refuses rather than run the program as this app's.
    static func execIfRequested() {
        let arguments = CommandLine.arguments
        guard arguments.count >= 3, arguments[1] == flag else { return }
        typealias Disclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") else { exit(127) }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        guard unsafeBitCast(symbol, to: Disclaim.self)(&attributes, 1) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETEXEC)) == 0 else { exit(127) }
        let argv = arguments.dropFirst(2).map { strdup($0) } + [nil]
        posix_spawn(nil, arguments[2], nil, &attributes, argv, environ)
        exit(127)
    }
}
