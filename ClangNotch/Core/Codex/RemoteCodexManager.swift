//
//  RemoteCodexManager.swift
//  ClangNotch
//
//  Mirrors Codex sessions running on SSH hosts into the notch.
//

import Foundation

/// For each host in `AppSettings.remoteCodexHosts` (while `remoteCodexEnabled` is on) a
/// `RemoteSessionFollower` sends what the host's Codex appends to its session files
/// (`~/.codex/sessions/**/rollout-*.jsonl`) and writes that into a file of the same name under
/// `CodexSession.remoteMirrorRoot/<host>/`. `CodexManager` scans that folder next to this Mac's
/// own sessions, so a remote session works like a local one: wings, questions, Done, the 세션 화면.
///
/// Nothing is installed or changed on the host. Codex writes everything the notch shows into
/// its session files, which hooks would only repeat, and Codex hooks need trusting on each host.
/// What the files don't carry stays local-only: approval requests (a hook) and answering
/// questions from the notch (Codex's own sockets).
@MainActor
final class RemoteCodexManager: ObservableObject {
    static let shared = RemoteCodexManager()

    /// Human-readable connection state per host, for Settings.
    @Published private(set) var statuses: [String: String] = [:]

    private var hosts: [String] = []
    private var followers: [String: RemoteSessionFollower] = [:]
    private var hostsWithCodex: Set<String> = []

    private init() {}

    /// Whether some Codex process runs on the host, by its follower's last word. A session left
    /// working by a Codex that is gone is cleared on this (`CodexManager.clearEndedSessions`).
    func codexRunning(on host: String) -> Bool { hostsWithCodex.contains(host) }

    /// Launch, or the agent switched on or off: every host from scratch, without asking anything.
    func apply() {
        stopAll()
        try? FileManager.default.removeItem(at: CodexSession.remoteMirrorRoot)
        sync()
    }

    /// Follows the switch and the host list in settings: hosts that left are dropped, new ones
    /// connected. `asking` is the host the user just added: its questions (trust it? password?)
    /// may open a window.
    func sync(asking: String? = nil) {
        let settings = AppSettings.shared
        let wanted = settings.enableCodexJSONL && settings.remoteCodexEnabled && !DemoMode.isActive
            ? SSHHost.list(settings.remoteCodexHosts) : []
        for host in hosts where !wanted.contains(host) { stop(host) }
        for host in wanted where !hosts.contains(host) {
            guard SSHHost.isValid(host) else {
                statuses[host] = L("잘못된 주소", "Invalid address")
                continue
            }
            connect(host, interactive: host == asking)
        }
        hosts = wanted
        statuses = statuses.filter { wanted.contains($0.key) }
    }

    /// 다시 연결: this host again, and this time it may ask.
    func reconnect(_ host: String) {
        guard hosts.contains(host), SSHHost.isValid(host) else { return }
        stop(host)
        connect(host, interactive: true)
    }

    func stopAll() {
        hosts.forEach(stop)
        hosts = []
    }

    private func stop(_ host: String) {
        followers.removeValue(forKey: host)?.stop()
        emptyMirror(host, keepFolder: false)
    }

    private func connect(_ host: String, interactive: Bool) {
        let directory = CodexSession.remoteMirrorRoot.appendingPathComponent(host, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let follower = RemoteSessionFollower(host: host, source: .codex, sink: .files(directory)) { [weak self] event in
            self?.handle(event, host: host)
        }
        followers[host] = follower
        follower.start(interactive: interactive)
    }

    private func handle(_ event: RemoteSessionFollower.Event, host: String) {
        switch event {
        case .status(let text):
            statuses[host] = text
        case .connected(let skew):
            // A clock that far off would hide every session: the notch only shows recent work.
            statuses[host] = skew == 0 ? L("연결됨", "Connected")
                : L("연결됨 · 호스트 시계 \(Int(abs(skew)))초 차이 보정", "Connected · host clock \(Int(abs(skew)))s off, corrected")
        case .agentRunning(let running):
            if running { hostsWithCodex.insert(host) } else { hostsWithCodex.remove(host) }
        case .sessionFile:
            // Don't wait out the 10 s scan for a session that just started.
            CodexManager.shared.scanForSessions()
        case .dropped:
            // No more lines can arrive; don't leave rows reading as working. The folder stays
            // for the next attempt.
            emptyMirror(host, keepFolder: true)
        }
    }

    /// The host's sessions go first: left to the next scan, a watcher would hold a deleted file.
    private func emptyMirror(_ host: String, keepFolder: Bool) {
        hostsWithCodex.remove(host)
        CodexManager.shared.removeRemoteSessions(host: host)
        let directory = CodexSession.remoteMirrorRoot.appendingPathComponent(host, isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        if keepFolder { try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    }
}
