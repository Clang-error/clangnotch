import Foundation
import Combine

/// A tool approval waiting on the 권한 드롭다운.
struct PermissionRequestItem: Identifiable, Equatable {
    enum Agent { case claude, codex }

    let id = UUID()
    let agent: Agent
    /// The watched session's id in its manager, when the transcript is one we watch.
    let sessionId: String?
    let projectName: String
    let toolName: String
    /// The command, file or URL being asked about.
    let detail: String
    let receivedAt: Date
}

/// Holds `PermissionRequest` hooks from Claude Code and Codex until the notch answers.
///
/// Measured 2026-10-22 (Claude Code 2.1.308, Codex 0.163): Claude shows its own terminal
/// dialog while the hook waits and keeps the hook running after the user answers there,
/// so a Claude request also ends when its tool lands in the transcript. Codex shows
/// nothing until the hook returns, so every request answers "no decision" after
/// `waitLimit` and Codex falls back to its own dialog.
@MainActor
final class PermissionRequestCenter: ObservableObject {
    static let shared = PermissionRequestCenter()

    enum Decision { case allow, deny, terminal }

    static let waitLimit: TimeInterval = 30
    private static let maxQueued = 6
    private static let questionTool = "AskUserQuestion"
    /// Plan approval has its own choices; it stays in the agent's own prompt.
    private static let passThroughTools: Set<String> = ["ExitPlanMode"]
    /// Under the Claude hook's 600s curl limit.
    private static let questionWaitLimit: TimeInterval = 590

    @Published private(set) var queue: [PermissionRequestItem] = []
    private var replies: [UUID: HookReply] = [:]
    private var timeouts: [UUID: Task<Void, Never>] = [:]
    private var transcriptWatch: AnyCancellable?

    /// Claude sessions whose AskUserQuestion the 질문 드롭다운 can answer right now.
    @Published private(set) var answerableQuestionSessions: Set<String> = []
    private struct HeldQuestion {
        let input: [String: Any]
        let reply: HookReply
        let timeout: Task<Void, Never>
        /// Set once the question shows in the session; its disappearing then means answered.
        var seenPending = false
    }
    private var heldQuestions: [String: HeldQuestion] = [:]

    private init() {}

    func receive(_ body: Data, reply: HookReply) {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let toolName = json["tool_name"] as? String,
              !Self.passThroughTools.contains(toolName),
              // Hidden in full screen or Mission Control: nobody would see the dropdown.
              UICoordinator.shared.isVisible,
              queue.count < Self.maxQueued else {
            reply.send(nil)
            return
        }
        let transcript = json["transcript_path"] as? String ?? ""
        let agent: PermissionRequestItem.Agent = transcript.contains("/.codex/") ? .codex : .claude
        if toolName == Self.questionTool {
            // Claude asks its questions through here too; the answer goes back as the input.
            if agent == .claude, let sessionId = ClaudeCodeManager.shared.sessionId(forTranscript: transcript) {
                holdQuestion(sessionId: sessionId, input: json["tool_input"] as? [String: Any] ?? [:], reply: reply)
            } else {
                reply.send(nil)
            }
            return
        }
        guard agent == .claude ? AppSettings.shared.showSourceClaudeCode : AppSettings.shared.showSourceCodex else {
            reply.send(nil)
            return
        }
        let sessionId: String? = switch agent {
        case .claude: ClaudeCodeManager.shared.sessionId(forTranscript: transcript)
        case .codex: CodexManager.shared.availableSessions.first { $0.jsonlFile.path == transcript }?.id
        }
        let cwd = json["cwd"] as? String ?? ""
        let item = PermissionRequestItem(
            agent: agent,
            sessionId: sessionId,
            projectName: cwd.isEmpty ? "" : URL(fileURLWithPath: cwd).lastPathComponent,
            toolName: toolName,
            detail: Self.detail(of: json["tool_input"] as? [String: Any] ?? [:]),
            receivedAt: Date()
        )
        queue.append(item)
        replies[item.id] = reply
        reply.setOnClose { [weak self] in
            Task { @MainActor in self?.remove(item.id) }
        }
        timeouts[item.id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.waitLimit))
            guard !Task.isCancelled else { return }
            self?.decide(item.id, .terminal)
        }
        if agent == .claude { watchTranscripts() }
    }

    func decide(_ id: UUID, _ decision: Decision) {
        let body: String? = switch decision {
        case .allow: #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#
        case .deny: #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied from ClangNotch"}}}"#
        case .terminal: nil
        }
        replies[id]?.send(body.map { Data($0.utf8) })
        remove(id)
    }

    private func remove(_ id: UUID) {
        timeouts.removeValue(forKey: id)?.cancel()
        replies.removeValue(forKey: id)
        queue.removeAll { $0.id == id }
        stopWatchingIfIdle()
    }

    // MARK: Questions

    private func holdQuestion(sessionId: String, input: [String: Any], reply: HookReply) {
        releaseQuestion(sessionId)
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.questionWaitLimit))
            guard !Task.isCancelled else { return }
            self?.releaseQuestion(sessionId)
        }
        let pending = ClaudeCodeManager.shared.sessionStates[sessionId]?.pendingInputRequests.isEmpty == false
        heldQuestions[sessionId] = HeldQuestion(input: input, reply: reply, timeout: timeout, seenPending: pending)
        answerableQuestionSessions.insert(sessionId)
        reply.setOnClose { [weak self] in
            Task { @MainActor in self?.dropQuestion(sessionId, ifReply: reply) }
        }
        watchTranscripts()
    }

    /// `answers` maps each question's text to its option label, or to a list of labels
    /// for a multi-select question — Claude Code takes them as the tool's own input.
    func answerQuestion(sessionId: String, answers: [String: Any]) {
        if DemoMode.isActive {
            answerableQuestionSessions.remove(sessionId)
            DemoDriver.shared.answer(sessionId: sessionId)
            return
        }
        guard let held = heldQuestions[sessionId] else { return }
        var input = held.input
        input["answers"] = answers
        let body: [String: Any] = ["hookSpecificOutput": [
            "hookEventName": "PermissionRequest",
            "decision": ["behavior": "allow", "updatedInput": input],
        ]]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        held.reply.send(data)
        dropQuestion(sessionId, ifReply: held.reply)
    }

    /// Hands the question back to Claude's own picker without an answer.
    private func releaseQuestion(_ sessionId: String) {
        guard let held = heldQuestions[sessionId] else { return }
        held.reply.send(nil)
        dropQuestion(sessionId, ifReply: held.reply)
    }

    private func dropQuestion(_ sessionId: String, ifReply reply: HookReply) {
        guard let held = heldQuestions[sessionId], held.reply === reply else { return }
        held.timeout.cancel()
        heldQuestions.removeValue(forKey: sessionId)
        answerableQuestionSessions.remove(sessionId)
        stopWatchingIfIdle()
    }

    private func stopWatchingIfIdle() {
        if !queue.contains(where: { $0.agent == .claude }) && heldQuestions.isEmpty { transcriptWatch = nil }
    }

    /// Claude keeps a hook running after its own dialog was answered; the tool's result in
    /// the transcript is the sign that the terminal won.
    private func watchTranscripts() {
        guard transcriptWatch == nil else { return }
        transcriptWatch = ClaudeCodeManager.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.dropAnsweredInTerminal() }
            }
    }

    private func dropAnsweredInTerminal() {
        let states = ClaudeCodeManager.shared.sessionStates
        // A question answered in Claude's own picker leaves the session's pending list.
        for (sessionId, held) in heldQuestions {
            let pending = states[sessionId]?.pendingInputRequests.isEmpty == false
            if pending, !held.seenPending {
                heldQuestions[sessionId]?.seenPending = true
            } else if !pending, held.seenPending {
                releaseQuestion(sessionId)
            }
        }
        for item in queue where item.agent == .claude {
            guard let sessionId = item.sessionId,
                  let recent = states[sessionId]?.recentTools else { continue }
            let landed = recent.contains {
                $0.toolName == item.toolName && ($0.endTime ?? .distantPast) >= item.receivedAt
            }
            if landed { decide(item.id, .terminal) }
        }
    }

    private static func detail(of input: [String: Any]) -> String {
        if let command = input["command"] as? String {
            // Codex sends apply_patch as the patch itself; its file lines say what changes.
            let files = command.split(separator: "\n").compactMap { line -> String? in
                for prefix in ["*** Add File: ", "*** Update File: ", "*** Delete File: "] where line.hasPrefix(prefix) {
                    return URL(fileURLWithPath: String(line.dropFirst(prefix.count))).lastPathComponent
                }
                return nil
            }
            if !files.isEmpty { return files.joined(separator: ", ") }
            return command.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for key in ["file_path", "notebook_path", "path", "url", "query", "pattern"] {
            if let value = input[key] as? String { return value }
        }
        return input.values.compactMap { $0 as? String }.first ?? ""
    }
}

// MARK: - Demo

extension PermissionRequestCenter {
    /// `--demo`: the demo's Claude question can be answered from the notch, as if its hook were held.
    func demoSetAnswerable(_ sessionIds: Set<String>) {
        if answerableQuestionSessions != sessionIds { answerableQuestionSessions = sessionIds }
    }
}
