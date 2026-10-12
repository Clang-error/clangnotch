//
//  AntigravityManager.swift
//  ClangNotch
//
//  Watches Antigravity (Gemini) CLI transcripts and exposes activity for the notch.
//
//  Antigravity stores each conversation's transcript at:
//    ~/.gemini/antigravity-cli/brain/{conversationId}/.system_generated/logs/transcript.jsonl
//  Each line is one step: { step_index, source, type, status, created_at, content }.
//  The file is rewritten on every change, so we poll the most-recently-modified
//  transcript (small files) rather than tailing it. A step with status "RUNNING"
//  (or a very recent write, for the thinking gap between steps) means it's active.
//

import Foundation
import Combine

@MainActor
final class AntigravityManager: ObservableObject {
    static let shared = AntigravityManager()

    @Published private(set) var state = AntigravityState()

    /// Single hook the notch view reads to decide whether to glow.
    var hasAnySessionActivity: Bool { state.isActive }

    /// Antigravity stores transcripts under three roots depending on surface
    /// (IDE / standalone / CLI). All use the same brain/{id}/.../transcript.jsonl layout.
    private let brainDirs: [URL] = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            "antigravity-ide/brain",
            "antigravity/brain",
            "antigravity-cli/brain",
        ].map { home.appendingPathComponent(".gemini/\($0)") }
    }()

    private var pollTimer: Timer?
    /// Set while telemetry is stopped from the header — no tracking, like the setting being off.
    private var isPaused = false
    private let cpuQueue = DispatchQueue(label: "com.agentnotch.antigravity.cpu", qos: .utility)

    /// Antigravity's transcript only updates at step boundaries (and a long generation
    /// step can leave it untouched for minutes), so file mtime alone misses active work.
    /// CPU usage of the Antigravity processes, however, stays high (~50-97%) the whole
    /// time it generates. We combine both: high CPU OR a fresh transcript = active.
    private let cpuThreshold: Double = 40.0      // idle ~3%, active generation 47%+
    private let fileRecency: TimeInterval = 5.0  // transcript written within this = active
    private let smoothingGrace: TimeInterval = 5.0
    private var lastActiveTime: Date = .distantPast
    // Require sustained high CPU (not a momentary spike from editing/rendering) before
    // treating CPU as "agent working". Generation holds high CPU for many seconds;
    // UI activity only blips for one or two samples.
    private let cpuSustainSamples = 3
    private var highCpuStreak = 0
    /// Only sample CPU (spawn `ps`) while a session is recent/active; idle costs nothing.
    private let idleSessionWindow: TimeInterval = 300

    // Re-read the transcript only when its mtime changes (keeps polling cheap).
    private var cachedURL: URL?
    private var cachedMtime: Date?
    private var cachedParse: (running: Bool, action: String?, steps: [AntigravityStep]) = (false, nil, [])

    private init() {
        poll()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        poll()
    }

    private func poll() {
        guard AppSettings.shared.enableAntigravity, !isPaused else {
            if state.isActive { state = AntigravityState() }
            return
        }

        // File work (fast): pick latest transcript, re-parse only if it changed.
        let latest = mostRecentTranscript()
        let fileAge = latest.map { Date().timeIntervalSince($0.mtime) } ?? .greatestFiniteMagnitude

        // Antigravity not in use (no transcript touched recently AND not recently active)
        // → skip the per-second `ps` spawn entirely so idle costs ~nothing.
        let recentlyActive = Date().timeIntervalSince(lastActiveTime) < idleSessionWindow
        guard fileAge < idleSessionWindow || recentlyActive else {
            highCpuStreak = 0
            if state.isActive || !state.recentSteps.isEmpty { state = AntigravityState() }
            return
        }

        if let latest, latest.url != cachedURL || latest.mtime != cachedMtime {
            cachedURL = latest.url
            cachedMtime = latest.mtime
            cachedParse = parse(latest.url)
        }

        // CPU sample off the main thread (spawns `ps`), then combine signals on main.
        cpuQueue.async { [weak self] in
            let cpu = AntigravityManager.antigravityCPU()
            Task { @MainActor in self?.applySignals(cpu: cpu, fileAge: fileAge) }
        }
    }

    private func applySignals(cpu: Double, fileAge: TimeInterval) {
        // Debounce CPU: only count it once it has been high for several samples in a row.
        highCpuStreak = cpu > cpuThreshold ? highCpuStreak + 1 : 0
        let cpuActive = highCpuStreak >= cpuSustainSamples

        if cpuActive || fileAge < fileRecency {
            lastActiveTime = Date()
        }
        let active = Date().timeIntervalSince(lastActiveTime) < smoothingGrace
        let (_, action, steps) = cachedParse
        // Keep Recent Tools visible for 10 min after the last transcript write, even
        // when not live-active, so the user can glance at what Antigravity just did.
        let recentlyUsed = fileAge < 600
        let newState = AntigravityState(
            isActive: active,
            currentAction: active ? (action ?? "Working") : nil,
            recentSteps: steps,
            recentlyUsed: recentlyUsed
        )
        if newState != state { state = newState }
    }

    /// Total CPU% across the Antigravity app processes (case-sensitive match excludes
    /// the lowercase `.antigravity-ide/extensions` language servers).
    nonisolated private static func antigravityCPU() -> Double {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-Axo", "pcpu,comm"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return 0 }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let out = String(data: data, encoding: .utf8) else { return 0 }

        var sum = 0.0
        for line in out.split(separator: "\n") where line.contains("Antigravity") {
            let trimmed = line.drop(while: { $0 == " " })
            if let space = trimmed.firstIndex(of: " "),
               let value = Double(trimmed[..<space]) {
                sum += value
            }
        }
        return sum
    }

    /// Find the most recently modified transcript.jsonl across all conversations
    /// in every brain root (IDE / standalone / CLI).
    private func mostRecentTranscript() -> (url: URL, mtime: Date)? {
        let fm = FileManager.default
        var best: (url: URL, mtime: Date)?
        for brainDir in brainDirs {
            guard let convDirs = try? fm.contentsOfDirectory(
                at: brainDir, includingPropertiesForKeys: [.contentModificationDateKey]
            ) else { continue }

            for conv in convDirs {
                let transcript = conv.appendingPathComponent(".system_generated/logs/transcript.jsonl")
                guard let attrs = try? fm.attributesOfItem(atPath: transcript.path),
                      let mtime = attrs[.modificationDate] as? Date else { continue }
                if best == nil || mtime > best!.mtime {
                    best = (transcript, mtime)
                }
            }
        }
        return best
    }

    /// Returns whether any step is RUNNING, a label for the current step, and the
    /// most-recent-first list of labelled steps for the expanded view.
    private func parse(_ url: URL) -> (running: Bool, action: String?, steps: [AntigravityStep]) {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return (false, nil, []) }

        var running = false
        var runningAction: String?
        var lastAction: String?
        var steps: [AntigravityStep] = []

        for line in text.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            let type = json["type"] as? String
            let isRunning = (json["status"] as? String) == "RUNNING"
            guard let label = Self.actionLabel(for: type) else { continue }
            lastAction = label
            if isRunning { running = true; runningAction = label }
            let idx = json["step_index"] as? Int ?? steps.count
            steps.append(AntigravityStep(id: idx, label: label, isRunning: isRunning))
        }
        // Most recent first, capped.
        let recent = Array(steps.suffix(6).reversed())
        return (running, running ? runningAction : lastAction, recent)
    }

    private static func actionLabel(for type: String?) -> String? {
        switch type {
        case "PLANNER_RESPONSE": return "Thinking"
        case "RUN_COMMAND": return "Running command"
        case "VIEW_FILE": return "Reading file"
        case "CODE_ACTION": return "Editing"
        case "USER_INPUT", "CONVERSATION_HISTORY", "SYSTEM_MESSAGE": return nil
        default: return "Working"
        }
    }
}
