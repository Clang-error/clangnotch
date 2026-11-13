import AppKit
import Foundation

/// 지금 재생 표시: what plays, for the closed notch's wings and the 미디어 드롭다운.
///
/// Since macOS 15.4 MediaRemote answers only Apple-signed processes, so ours reads it from inside
/// `/usr/bin/perl`: perl loads `libClangNotchNowPlaying.dylib` (built from `NowPlayingBridge/`)
/// and calls its `cn_stream`, which prints a JSON line whenever what plays changes. One process,
/// woken by MediaRemote's own notifications and, while something plays, by a 5 s timer that
/// reads again (a stop some apps never announce); it exits by itself when this app is gone.
/// Checked on macOS 27.2.1 (2026-11-12): a direct call from our own process returns nothing,
/// the same calls inside perl return the title, artist, app and artwork.
@MainActor
final class NowPlayingMonitor: ObservableObject {
    static let shared = NowPlayingMonitor()

    @Published private(set) var nowPlaying: NowPlaying? {
        didSet {
            NowPlayingLevels.shared.follow(nowPlaying)
            if oldValue?.isPlaying != nowPlaying?.isPlaying || nowPlaying == nil {
                updateLinger(from: oldValue, to: nowPlaying)
                updatePausedLong()
            }
            if nowPlaying == nil, oldValue != nil { AirPodsDropdown.media.mediaGone() }
        }
    }

    /// Paused for 3 minutes: the 노치 띠 lets it go too. An app such as Music keeps a paused
    /// track as "now playing" until it quits, and it stayed there all day (user, 2026-11-12).
    @Published private(set) var pausedLong = false
    private var pausedWork: DispatchWorkItem?
    private static let pausedLimit: TimeInterval = 3 * 60

    private func updatePausedLong() {
        pausedWork?.cancel()
        if pausedLong { pausedLong = false }
        guard let nowPlaying, !nowPlaying.isPlaying else { return }
        let work = DispatchWorkItem { NowPlayingMonitor.shared.pausedLong = true }
        pausedWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pausedLimit, execute: work)
    }

    /// The 미디어 드롭다운 is down. The wings step aside meanwhile, or the same artwork and bars
    /// would show twice, and spring back as it goes up (user, 2026-11-12).
    @Published private(set) var cardIsDown = false

    /// A track just changed and its card will drop once the change has held: the wings step
    /// aside already, or the new track showed in them for that moment first (user, 2026-11-12).
    @Published private(set) var cardIsComing = false

    /// Playback just stopped and the wings stay a moment (설정 › 기능 › 멈추면 숨기기 "잠시 뒤"),
    /// the bars resting. It also covers the instant some apps report "paused" between tracks.
    @Published private(set) var lingers = false
    private var lingerWork: DispatchWorkItem?
    private static let lingerTime: TimeInterval = 1.5

    /// Shown in the closed notch: something plays (or just stopped and lingers), the feature is
    /// on (it is stopped, and `nowPlaying` nil, when off), and its card is neither down nor
    /// about to drop.
    var isShowing: Bool {
        guard let nowPlaying else { return false }
        return (nowPlaying.isPlaying || lingers) && !cardIsDown && !cardIsComing
    }

    /// Playing to stopped: linger, or not. Anything else ends a linger.
    private func updateLinger(from old: NowPlaying?, to new: NowPlaying?) {
        lingerWork?.cancel()
        guard old?.isPlaying == true, let new, !new.isPlaying,
              AppSettings.shared.nowPlayingHideAfterStop == "later" else {
            if lingers { lingers = false }
            return
        }
        lingers = true
        let work = DispatchWorkItem { NowPlayingMonitor.shared.lingers = false }
        lingerWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.lingerTime, execute: work)
    }

    func setCardIsDown(_ down: Bool) {
        if cardIsDown != down { cardIsDown = down }
        NowPlayingLevels.shared.setCardDown(down)
    }

    private var process: Process?
    private var startedAt = Date.distantPast
    private var buffer = Data()
    /// Exits within a few seconds of starting; after three the feature stays off until relaunch,
    /// rather than starting perl over and over on a macOS that refuses it.
    private var quickExits = 0
    private var retryWork: DispatchWorkItem?
    private var policy = NowPlayingCardPolicy()
    private var dropWork: DispatchWorkItem?

    private var commands: FileHandle?

    /// A change has to hold this long before a card drops: switching apps passes through
    /// in-between states. 1.2 s felt slow from an app in the background (user, 2026-11-12).
    private static let settleDelay: TimeInterval = 0.35

    private static let perlScript = """
        use DynaLoader;
        my $lib = DynaLoader::dl_load_file($ARGV[0], 0) or die DynaLoader::dl_error();
        my $sym = DynaLoader::dl_find_symbol($lib, "cn_stream") or die DynaLoader::dl_error();
        DynaLoader::dl_install_xsub("main::cn_stream", $sym);
        cn_stream();
        """

    private init() {}

    /// `--demo --demo-scene media`: a made-up track for the wings; nothing real is read.
    func demoApply(_ playing: NowPlaying?) {
        nowPlaying = playing
    }

    /// 설정 › 기능 › 지금 재생 표시.
    func sync() {
        if AppSettings.shared.enableNowPlaying { start() } else { stop() }
    }

    private func start() {
        guard process == nil, quickExits < 3, !DemoMode.isActive else { return }
        let perl = URL(fileURLWithPath: "/usr/bin/perl")
        guard let library = Bundle.main.privateFrameworksURL?.appendingPathComponent("libClangNotchNowPlaying.dylib"),
              FileManager.default.fileExists(atPath: library.path),
              FileManager.default.isExecutableFile(atPath: perl.path) else {
            debugLog("[NowPlaying] perl or the bridge is missing; off")
            quickExits = 3
            return
        }
        let process = Process()
        process.executableURL = perl
        process.arguments = ["-e", Self.perlScript, library.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        // Commands go in here; the bridge exits when it closes, so it can't outlive this app.
        let input = Pipe()
        process.standardInput = input
        // In order on the main queue: an artwork line spans several reads, and separate Tasks
        // don't promise to run in the order they were made.
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { MainActor.assumeIsolated { NowPlayingMonitor.shared.receive(data, from: process) } }
        }
        process.terminationHandler = { ended in
            DispatchQueue.main.async { MainActor.assumeIsolated { NowPlayingMonitor.shared.exited(ended) } }
        }
        do {
            try process.run()
        } catch {
            debugLog("[NowPlaying] perl didn't start: \(error)")
            quickExits = 3
            return
        }
        self.process = process
        commands = input.fileHandleForWriting
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        startedAt = Date()
        buffer = Data()
        policy.restart()
    }

    private func stop() {
        retryWork?.cancel()
        dropWork?.cancel()
        cardIsComing = false
        let running = process
        process = nil
        try? commands?.close()
        commands = nil
        running?.terminate()
        nowPlaying = nil
    }

    private func exited(_ ended: Process) {
        guard ended === process else { return }
        process = nil
        try? commands?.close()
        commands = nil
        nowPlaying = nil
        dropWork?.cancel()
        cardIsComing = false
        let ranFor = Date().timeIntervalSince(startedAt)
        quickExits = ranFor < 10 ? quickExits + 1 : 0
        debugLog("[NowPlaying] bridge exited (\(ended.terminationStatus)) after \(Int(ranFor))s")
        guard AppSettings.shared.enableNowPlaying, quickExits < 3 else { return }
        let work = DispatchWorkItem { NowPlayingMonitor.shared.sync() }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    private func receive(_ data: Data, from source: Process) {
        guard source === process else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { handle(json) }
        }
    }

    private func handle(_ json: [String: Any]) {
        let playing = json["playing"] as? Bool ?? false
        guard let title = (json["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            // No title: nothing is playing any more, or an app switch is half done.
            if !playing { nowPlaying = nil }
            policy.readNothing()
            return
        }
        let old = nowPlaying
        var new = NowPlaying(title: title, artist: json["artist"] as? String,
                             bundleID: json["parent"] as? String ?? json["bundle"] as? String,
                             appName: json["app"] as? String, isPlaying: playing, artwork: nil)
        new.pid = (json["pid"] as? Int).map { pid_t($0) }
        new.duration = (json["duration"] as? Double).flatMap { $0 > 0 ? $0 : nil }
        new.elapsed = json["elapsedtime"] as? Double
        new.elapsedAt = (json["ts"] as? Double).map(Date.init(timeIntervalSince1970:)) ?? Date()
        new.rate = json["playbackrate"] as? Double ?? (playing ? 1 : 0)
        if let art = json["art"] as? String, let data = Data(base64Encoded: art), let image = NSImage(data: data) {
            new.artwork = image
            new.accent = NowPlaying.accent(of: image)
        }
        new = new.keepingArtwork(of: old)
        guard new != old else { return }
        let change = policy.change(from: old, to: new)
        if case .started(let key) = change, AppSettings.shared.enableNowPlayingDropdown,
           AirPodsDropdown.media.canDropMedia,
           policy.wouldAllowCard(for: new, key: key,
                                 frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier, now: Date()) {
            cardIsComing = true
        }
        nowPlaying = new
        switch change {
        case .started(let key):
            // A card that is up shows the new track at once (its 다음 button, a playlist).
            AirPodsDropdown.media.refreshMedia(new)
            scheduleCard(for: key)
        // Fresh artwork for a card that is up, or paused.
        case .sameTrack: AirPodsDropdown.media.refreshMedia(new)
        case .nothing: break
        }
    }

    private func scheduleCard(for key: String) {
        dropWork?.cancel()
        let work = DispatchWorkItem { NowPlayingMonitor.shared.dropCard(for: key) }
        dropWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: work)
    }

    /// Brings the app that plays to the front.
    static func openApp(of playing: NowPlaying) {
        guard let bundleID = playing.bundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    enum Command: String { case toggle, next, prev }

    /// The 미디어 드롭다운's buttons. MediaRemote takes commands only from Apple-signed processes
    /// too, so they go through the bridge.
    func send(_ command: Command) { write(command.rawValue) }

    func seek(to seconds: TimeInterval) { write("seek \(seconds)") }

    private func write(_ line: String) {
        try? commands?.write(contentsOf: Data((line + "\n").utf8))
    }

    /// 재생 시작 시 드롭다운, by `NowPlayingCardPolicy`.
    private func dropCard(for key: String) {
        // Shown or not, the wings go by the card from here: down, or back if it didn't come.
        defer { cardIsComing = false }
        guard AppSettings.shared.enableNowPlayingDropdown, let playing = nowPlaying else { return }
        let now = Date()
        guard policy.allowsCard(for: playing, key: key,
                                frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier, now: now),
              AirPodsDropdown.media.showMedia(playing) else { return }
        policy.cardShown(for: playing, at: now)
    }
}
