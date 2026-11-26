import AppKit
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
    /// The command, file or URL being asked about, as the 권한 드롭다운 shows it.
    let text: PermissionText
    /// Signs of danger; any of them keeps 허용 off in the notch.
    let risks: [PermissionRisk]
    let receivedAt: Date
    /// A Claude app session asking whether to start a new session for this (`SessionOffer`): the
    /// 새 세션 드롭다운 instead of the 권한 드롭다운. 허용 is 새 세션, 거부 is 여기서 하기 and
    /// 터미널에서 is 앱에서 고르기, which allows the tool so the app draws its card.
    var offerTitle: String? = nil
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
    /// Held offers' transcripts, and the calls an answered offer leads to (`SessionOffer.FollowUp`).
    private var offerTranscripts: [UUID: String] = [:]
    private var offerFollowUps: [SessionOffer.FollowUp] = []

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

    /// Claude sessions whose next-step box the 다음 단계 드롭다운 can answer right now.
    @Published private(set) var answerableNextStepSessions: Set<String> = []
    private struct HeldNextStep {
        let reply: HookReply
        let timeout: Task<Void, Never>
    }
    private var heldNextSteps: [String: HeldNextStep] = [:]
    /// Under the next-step hook's 600s curl limit.
    private static let nextStepWaitLimit: TimeInterval = 590

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
        // The app asks again for the call an answer in the 새 세션 드롭다운 just led to.
        if agent == .claude, toolName == SessionOffer.toolName {
            let input = json["tool_input"] as? [String: Any] ?? [:]
            offerFollowUps.removeAll { Date().timeIntervalSince($0.at) > SessionOffer.followUpWindow }
            if let index = offerFollowUps.firstIndex(where: { $0.transcript == transcript && $0.matches(input) }) {
                offerFollowUps.remove(at: index)
                reply.send(Self.allowBody)
                return
            }
        }
        let sessionId: String? = switch agent {
        case .claude: ClaudeCodeManager.shared.sessionId(forTranscript: transcript)
        case .codex: CodexManager.shared.availableSessions.first { $0.jsonlFile.path == transcript }?.id
        }
        let cwd = json["cwd"] as? String ?? ""
        let detail = Self.detail(of: json["tool_input"] as? [String: Any] ?? [:], toolName: toolName)
        let item = PermissionRequestItem(
            agent: agent,
            sessionId: sessionId,
            projectName: cwd.isEmpty ? "" : URL(fileURLWithPath: cwd).lastPathComponent,
            toolName: toolName,
            text: PermissionText(detail),
            risks: PermissionRisk.found(in: detail, toolName: toolName),
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

    /// A question on an SSH host, held by the hook script there (`RemoteClaudeManager`) and
    /// checked by `HookReceiver`: questions only, never an approval. Its session is made by the
    /// PreToolUse event, which is posted in the background and can land a moment later.
    func receiveRemoteQuestion(_ json: [String: Any], reply: HookReply) {
        guard json["tool_name"] as? String == Self.questionTool,
              let conversation = json["session_id"] as? String,
              UICoordinator.shared.isVisible else {
            reply.send(nil)
            return
        }
        let input = json["tool_input"] as? [String: Any] ?? [:]
        Task { [weak self] in
            for _ in 0..<8 {
                if let sessionId = ClaudeCodeManager.shared.remoteSessionId(conversation: conversation) {
                    self?.holdQuestion(sessionId: sessionId, input: input, reply: reply)
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            reply.send(nil)
        }
    }

    private static let allowBody = Data(#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#.utf8)

    func decide(_ id: UUID, _ decision: Decision) {
        if let title = queue.first(where: { $0.id == id })?.offerTitle {
            if decision != .deny, let transcript = offerTranscripts[id] {
                offerFollowUps.append(SessionOffer.FollowUp(transcript: transcript, title: title, newSession: decision == .allow))
            }
            replies[id]?.send(decision == .terminal ? nil : SessionOffer.deny(newSession: decision == .allow, title: title))
            remove(id)
            return
        }
        let body: Data? = switch decision {
        case .allow: Self.allowBody
        case .deny: Data(#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied from ClangNotch"}}}"#.utf8)
        case .terminal: nil
        }
        replies[id]?.send(body)
        remove(id)
    }

    private func remove(_ id: UUID) {
        timeouts.removeValue(forKey: id)?.cancel()
        replies.removeValue(forKey: id)
        offerTranscripts.removeValue(forKey: id)
        queue.removeAll { $0.id == id }
        stopWatchingIfIdle()
    }

    // MARK: Session offers

    /// The `PreToolUse` hook of a Claude app session's `start_session` (`SessionOffer`). An offer
    /// waits for the 새 세션 드롭다운, whichever app is in front; anything else goes on as it would
    /// without the hook.
    func receiveSessionOffer(_ body: Data, reply: HookReply) {
        let settings = AppSettings.shared
        guard settings.experimentalClaudeSessionOffers, settings.showSourceClaudeCode,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              json["tool_name"] as? String == SessionOffer.toolName,
              let input = json["tool_input"] as? [String: Any] else {
            reply.send(nil)
            return
        }
        let transcript = json["transcript_path"] as? String ?? ""
        guard let title = SessionOffer.offerTitle(input), UICoordinator.shared.isVisible, queue.count < Self.maxQueued else {
            reply.send(nil)
            return
        }
        let cwd = json["cwd"] as? String ?? ""
        let item = PermissionRequestItem(
            agent: .claude,
            sessionId: ClaudeCodeManager.shared.sessionId(forTranscript: transcript),
            projectName: cwd.isEmpty ? "" : URL(fileURLWithPath: cwd).lastPathComponent,
            toolName: SessionOffer.toolName,
            text: PermissionText(""),
            risks: [],
            receivedAt: Date(),
            offerTitle: title
        )
        queue.append(item)
        replies[item.id] = reply
        offerTranscripts[item.id] = transcript
        reply.setOnClose { [weak self] in
            Task { @MainActor in self?.remove(item.id) }
        }
        // Past this the card shows in the app, as if 앱에서 고르기 was pressed.
        timeouts[item.id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.waitLimit))
            guard !Task.isCancelled else { return }
            self?.decide(item.id, .terminal)
        }
        watchClaudeApp()
    }

    private static let claudeAppBundleID = "com.anthropic.claudefordesktop"
    private var claudeAppWatch: NSObjectProtocol?

    /// The Claude app coming forward lets its cards show: the user went there to answer.
    private func watchClaudeApp() {
        guard claudeAppWatch == nil else { return }
        claudeAppWatch = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == Self.claudeAppBundleID else { return }
            Task { @MainActor in
                guard let self else { return }
                for item in self.queue where item.offerTitle != nil { self.decide(item.id, .terminal) }
            }
        }
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

    // MARK: Next steps

    /// A `Stop` hook that stays behind after the turn (`NextStepHooks`). It is held only
    /// while the session shows a next-step box with buttons; the answer goes back as the
    /// hook's output, which wakes the session.
    func receiveNextStep(_ body: Data, reply: HookReply) {
        guard AppSettings.shared.experimentalClaudeNextStepAnswers,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let transcript = json["transcript_path"] as? String,
              let sessionId = ClaudeCodeManager.shared.sessionId(forTranscript: transcript) else {
            reply.send(nil)
            return
        }
        Task { [weak self] in
            // The box is written before the turn's last message, but the transcript watcher
            // can be a beat behind the hook. The box was waiting for this hook to show.
            for _ in 0..<10 {
                ClaudeCodeManager.shared.showStagedWrapUp(for: sessionId)
                if Self.nextStepBox(in: sessionId) != nil {
                    self?.holdNextStep(sessionId: sessionId, reply: reply)
                    return
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
            reply.send(nil)
        }
    }

    private static func nextStepBox(in sessionId: String) -> ClaudeInputRequest? {
        ClaudeCodeManager.shared.sessionStates[sessionId]?.pendingInputRequests.first {
            $0.isWrapUp && $0.questions.first?.options.isEmpty == false
        }
    }

    private func holdNextStep(sessionId: String, reply: HookReply) {
        releaseNextStep(sessionId)
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.nextStepWaitLimit))
            guard !Task.isCancelled else { return }
            self?.releaseNextStep(sessionId)
        }
        heldNextSteps[sessionId] = HeldNextStep(reply: reply, timeout: timeout)
        answerableNextStepSessions.insert(sessionId)
        reply.setOnClose { [weak self] in
            Task { @MainActor in self?.dropNextStep(sessionId, ifReply: reply) }
        }
        watchTranscripts()
    }

    /// The pick goes to Claude as the hook's output. Claude Code hands it over as a Stop hook
    /// "blocking error", so the text says what it really is.
    func answerNextStep(sessionId: String, requestId: String, label: String, message: String) {
        // `--demo`: no hook is held; the script takes the pick and drops its box.
        if DemoMode.isActive {
            answerableNextStepSessions.remove(sessionId)
            DemoDriver.shared.answerNextStep(sessionId: sessionId)
            return
        }
        guard let held = heldNextSteps[sessionId] else { return }
        // Without a new box the app keeps drawing the answered one, buttons and all (seen
        // 2026-11-11 with a "no" that led to no work), so Claude is asked to close with one.
        let text = "This is not an error. The user answered your next-step question from ClangNotch, "
            + "the notch app they use to reply without opening this window. "
            + "They picked \"\(label)\"\(message.isEmpty || message == label ? "." : ": \(message)") "
            + "The box they answered is still on screen in the app, so close this turn with "
            + "mcp__ccd_turn__wrap_up as you normally do (the recap alone when nothing is pending) to replace it."
        held.reply.send(Data(text.utf8))
        dropNextStep(sessionId, ifReply: held.reply)
        // The wake-up is not a user message in the transcript, so the box is cleared here.
        ClaudeCodeManager.shared.dismissInputRequest(id: requestId)
    }

    /// Lets the hook end without waking the session.
    private func releaseNextStep(_ sessionId: String) {
        guard let held = heldNextSteps[sessionId] else { return }
        held.reply.send(nil)
        dropNextStep(sessionId, ifReply: held.reply)
    }

    private func dropNextStep(_ sessionId: String, ifReply reply: HookReply) {
        guard let held = heldNextSteps[sessionId], held.reply === reply else { return }
        held.timeout.cancel()
        heldNextSteps.removeValue(forKey: sessionId)
        answerableNextStepSessions.remove(sessionId)
        stopWatchingIfIdle()
    }

    private func stopWatchingIfIdle() {
        if !queue.contains(where: { $0.agent == .claude }) && heldQuestions.isEmpty && heldNextSteps.isEmpty {
            transcriptWatch = nil
        }
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
        // A box answered in the app, or cleared, is gone from the session.
        for sessionId in heldNextSteps.keys where Self.nextStepBox(in: sessionId) == nil {
            releaseNextStep(sessionId)
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

    private static func detail(of input: [String: Any], toolName: String) -> String {
        // An MCP tool's fields mean whatever its server says: show them all (below).
        let builtIn = !toolName.hasPrefix("mcp__")
        if builtIn, let command = input["command"] as? String {
            // Codex sends apply_patch as the patch itself; its file lines say what changes.
            // Only for apply_patch: a Bash command carrying those lines in a heredoc would
            // otherwise show as a file name and hide what actually runs. Whole paths, and a
            // move's destination, so `config` can't stand for `~/.ssh/config`.
            var files: [String] = []
            if toolName == "apply_patch" {
                for line in command.split(separator: "\n") {
                    if line.hasPrefix("*** Move to: "), let last = files.popLast() {
                        files.append("\(last) -> \(line.dropFirst("*** Move to: ".count))")
                    }
                    for prefix in ["*** Add File: ", "*** Update File: ", "*** Delete File: "] where line.hasPrefix(prefix) {
                        files.append(String(line.dropFirst(prefix.count)))
                    }
                }
            }
            if !files.isEmpty { return files.joined(separator: "\n") }
            return command
        }
        if builtIn {
            for key in ["file_path", "notebook_path", "path", "url", "query", "pattern"] {
                if let value = input[key] as? String { return value }
            }
        }
        // Any other tool: its one string, or the whole input, so no field goes unseen.
        if input.count == 1, let only = input.values.first as? String { return only }
        guard !input.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Demo

extension PermissionRequestCenter {
    /// `--demo`: the demo's Claude questions and next-step boxes can be answered from the notch,
    /// as if their hooks were held (the next-step one as with 실험 기능 on).
    func demoSetAnswerable(_ sessionIds: Set<String>, nextSteps: Set<String> = []) {
        if answerableQuestionSessions != sessionIds { answerableQuestionSessions = sessionIds }
        if answerableNextStepSessions != nextSteps { answerableNextStepSessions = nextSteps }
    }
}
