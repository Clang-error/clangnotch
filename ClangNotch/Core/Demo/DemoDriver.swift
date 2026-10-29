import Foundation

/// `open ClangNotch.app --args --demo [--demo-scene claude|codex|both]`: the notch runs on
/// made-up Claude Code and Codex sessions for screen recordings. Nothing real is read, so
/// no project name, path or prompt from this Mac can end up in a video.
enum DemoMode {
    static let isActive = CommandLine.arguments.contains("--demo")

    enum Scene: String { case claude, codex, both }

    static var scene: Scene {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--demo-scene"), index + 1 < args.count else { return .both }
        return Scene(rawValue: args[index + 1]) ?? .both
    }
}

/// Plays one fixed 56-second script on a loop, so a recording can be timed against it.
/// claude / codex: a first session starts at 2s, a second joins at 9s and asks a question
/// (질문 드롭다운, NEEDS YOU) from 17s to 25s; they finish (완료 드롭다운) at 30s and 40s.
/// both: one Claude session from 2s, one Codex session from 9s; the Claude question is up
/// from 17s, the Codex one from 24s; they finish at 31s and 36s. A Claude question can be
/// answered by picking an option in the notch. The last seconds are quiet, for a final look.
@MainActor
final class DemoDriver {
    static let shared = DemoDriver()

    static let loopLength: TimeInterval = 56

    private var task: Task<Void, Never>?
    /// Questions answered from the 질문 드롭다운 this loop.
    private var answered: Set<String> = []
    private init() {}

    /// A pick in the 질문 드롭다운 (`PermissionRequestCenter.answerQuestion`) ends the question.
    func answer(sessionId: String) {
        answered.insert(sessionId)
    }

    func start() {
        guard task == nil else { return }
        TelemetryCoordinator.shared.demoMarkRunning()
        let scripts = Self.scripts(for: DemoMode.scene)
        task = Task { [weak self] in
            var loop = 0
            while !Task.isCancelled {
                let began = Date()
                var completed: Set<String> = []
                self?.answered = []
                while Date().timeIntervalSince(began) < Self.loopLength, !Task.isCancelled {
                    self?.render(scripts, at: Date().timeIntervalSince(began), loop: loop, began: began, completed: &completed)
                    try? await Task.sleep(for: .milliseconds(250))
                }
                loop += 1
            }
        }
    }

    // MARK: - Script

    private enum Agent {
        case claude(ClaudeEntrypoint)
        case codex
    }

    private struct Step {
        /// Seconds after the session's start.
        let after: TimeInterval
        let tool: String
        let argument: String
        var change: ToolChange? = nil
    }

    private struct Question {
        let header: String
        let text: String
        let options: [(String, String)]
    }

    private struct Script {
        let name: String
        let agent: Agent
        let branch: String
        let prompt: String
        let answer: String
        var start: TimeInterval
        var end: TimeInterval
        var steps: [Step]
        var question: Question? = nil
        /// When the question is up, unless an option is picked in the notch first.
        var asks: ClosedRange<TimeInterval> = 17...25
        var id: String {
            if case .codex = agent { return "demo-\(name)" }
            return "Claude:/Users/demo/Projects/\(name)"
        }
        var path: String { "/Users/demo/Projects/\(name)" }
    }

    private static func scripts(for scene: DemoMode.Scene) -> [Script] {
        let orbit = Script(
            name: "orbit-api", agent: .claude(.desktop), branch: "feat/billing-tax",
            prompt: "Add regional tax to invoice totals",
            answer: "Invoice totals now include regional tax. All 48 billing tests pass.",
            start: 2, end: 30, steps: [
                Step(after: 1.5, tool: "Read", argument: "src/billing/invoice.ts"),
                Step(after: 3, tool: "Grep", argument: "applyTax"),
                Step(after: 4.5, tool: "Edit", argument: "src/billing/invoice.ts", change: ToolChange(file: "src/billing/invoice.ts", lines: [
                    .init(kind: .removed, text: "  return subtotal"),
                    .init(kind: .added, text: "  return subtotal + applyTax(subtotal, region)"),
                ])),
                Step(after: 8, tool: "Bash", argument: "pnpm test billing"),
                Step(after: 14, tool: "Edit", argument: "src/billing/tax.ts", change: ToolChange(file: "src/billing/tax.ts", lines: [
                    .init(kind: .added, text: "export const applyTax = (amount: number, region: Region) =>"),
                    .init(kind: .added, text: "  Math.round(amount * rates[region] * 100) / 100"),
                ])),
                Step(after: 20, tool: "Bash", argument: "pnpm test"),
            ])
        let lumen = Script(
            name: "lumen-web", agent: .claude(.terminal), branch: "main",
            prompt: "Add a dark mode toggle to settings",
            answer: "Dark mode toggle added to the settings page, next to the language picker.",
            start: 9, end: 40, steps: [
                Step(after: 1.5, tool: "Glob", argument: "app/**/page.tsx"),
                Step(after: 4, tool: "Read", argument: "app/settings/page.tsx"),
                Step(after: 17, tool: "Write", argument: "app/settings/theme.tsx"),
                Step(after: 23, tool: "Bash", argument: "pnpm lint"),
            ], question: Question(header: "Theme", text: "Where should the dark mode toggle go?", options: [
                ("Settings page", "Next to the language picker"),
                ("Header", "One click from every page"),
            ]))
        let atlas = Script(
            name: "atlas-cli", agent: .codex, branch: "fix/retry-backoff",
            prompt: "Retry failed uploads with backoff",
            answer: "Uploads now retry with exponential backoff, capped at 5 attempts.",
            start: 2, end: 35, steps: [
                Step(after: 2, tool: "exec", argument: "rg -n \"upload\" src"),
                Step(after: 6, tool: "apply_patch", argument: "src/retry.rs"),
                Step(after: 12, tool: "exec", argument: "cargo test retry"),
                Step(after: 20, tool: "exec", argument: "cargo test"),
            ])
        let prism = Script(
            name: "prism-app", agent: .codex, branch: "feat/onboarding",
            prompt: "Build the onboarding screens",
            answer: "Three onboarding screens added, with skip and progress dots.",
            start: 9, end: 40, steps: [
                Step(after: 2, tool: "exec", argument: "ls src/screens"),
                Step(after: 17, tool: "apply_patch", argument: "src/screens/Onboarding.tsx"),
                Step(after: 24, tool: "exec", argument: "npm test"),
            ], question: Question(header: "Onboarding", text: "How many intro screens should it have?", options: [
                ("Three", "Welcome, permissions, done"),
                ("One", "A single welcome screen"),
            ]))

        switch scene {
        case .claude: return [orbit, lumen]
        case .codex: return [atlas, prism]
        case .both:
            var claude = orbit
            claude.end = 31
            claude.question = lumen.question
            claude.asks = 17...23
            var codex = atlas
            codex.start = 9
            codex.end = 36
            codex.question = Question(header: "Retries", text: "Retry uploads on 4xx errors too?", options: [
                ("No", "Only network errors and 5xx"),
                ("Yes", "Every failed upload"),
            ])
            codex.asks = 24...30
            return [claude, codex]
        }
    }

    // MARK: - Rendering

    private func render(_ scripts: [Script], at t: TimeInterval, loop: Int, began: Date, completed: inout Set<String>) {
        let now = Date()
        func time(_ offset: TimeInterval) -> Date { began.addingTimeInterval(offset) }

        var claudeSessions: [ClaudeSession] = []
        var claudeStates: [String: ClaudeCodeState] = [:]
        var codexSessions: [CodexSession] = []
        var codexStates: [String: CodexState] = [:]
        var codexProgress: TimeInterval = 0

        for script in scripts {
            let progress = max(0, min(t, script.end) - script.start)
            let working = t >= script.start && t < script.end
            let asking = script.question != nil && script.asks.contains(t) && !answered.contains(script.id)
            // Steps, absolute times: each runs until the next starts, at most 2.5s.
            var active: (Int, Step, TimeInterval)?
            var finished: [(Int, Step, TimeInterval, TimeInterval)] = []
            for (index, step) in script.steps.enumerated() {
                let begin = script.start + step.after
                guard t >= begin else { continue }
                let next = index + 1 < script.steps.count ? script.start + script.steps[index + 1].after : script.end
                let stop = min(next, begin + 2.5)
                if t >= stop { finished.insert((index, step, begin, stop), at: 0) } else { active = (index, step, begin) }
            }

            switch script.agent {
            case .claude(let entrypoint):
                let session = ClaudeSession(pid: 0, workspaceFolders: [script.path], ideName: "Claude",
                                            transport: nil, runningInWindows: nil, cwd: script.path)
                var state = ClaudeCodeState()
                state.sessionId = session.id
                state.model = "claude-opus-5-5"
                state.cwd = script.path
                state.gitBranch = script.branch
                state.entrypoint = entrypoint
                state.isConnected = true
                state.lastUpdateTime = now
                state.tokenUsage = ClaudeTokenUsage(inputTokens: 2_400 + Int(progress * 180),
                                                    outputTokens: 900 + Int(progress * 140),
                                                    cacheReadInputTokens: 30_000 + Int(progress * 2_600),
                                                    cacheCreationInputTokens: 3_100 + Int(progress * 420))
                state.recentMessages = [ClaudeMessage(role: .user, text: script.prompt, time: time(script.start))]
                func tool(_ index: Int, _ step: Step, _ begin: TimeInterval) -> ClaudeToolExecution {
                    var tool = ClaudeToolExecution(id: "demo-\(loop)-\(script.name)-\(index)", toolName: step.tool,
                                                   argument: step.argument, startTime: time(begin))
                    tool.change = step.change
                    return tool
                }
                state.recentTools = finished.map { var done = tool($0.0, $0.1, $0.2); done.endTime = time($0.3); return done }
                if let (index, step, begin) = active { state.activeTools = [tool(index, step, begin)] }
                if working {
                    state.turnStartTime = time(script.start)
                    state.isThinking = state.activeTools.isEmpty && !asking
                } else if t >= script.end {
                    state.lastStopReason = "end_turn"
                }
                if asking, let question = script.question {
                    state.pendingInputRequests = [ClaudeInputRequest(id: "demo-\(loop)-\(script.name)-question", input: [
                        "questions": [[
                            "header": question.header,
                            "question": question.text,
                            "options": question.options.map { ["label": $0.0, "description": $0.1] },
                        ]],
                    ])]
                }
                claudeSessions.append(session)
                claudeStates[session.id] = state
                if t >= script.end, completed.insert(script.id).inserted {
                    ClaudeCodeManager.shared.demoComplete(CompletedTurn(sessionId: session.id, answer: script.answer,
                                                                        elapsed: script.end - script.start))
                }

            case .codex:
                let session = CodexSession(id: script.id, cwd: script.path, cliVersion: "1.0.0", modelProvider: "openai",
                                           gitBranch: script.branch, gitCommit: nil, timestamp: time(0),
                                           jsonlFile: URL(fileURLWithPath: "/dev/null"))
                var state = CodexState()
                state.sessionId = session.id
                state.model = "gpt-6"
                state.cwd = script.path
                state.gitBranch = script.branch
                state.isConnected = true
                state.lastUpdateTime = now
                state.lastUserPrompt = script.prompt
                let tokens = 24_000 + Int(progress * 1_760)
                state.tokenUsage = CodexTokenUsage(inputTokens: 14_000 + Int(progress * 900),
                                                   outputTokens: 1_200 + Int(progress * 160),
                                                   cachedInputTokens: 9_000 + Int(progress * 700),
                                                   totalTokens: tokens, contextTokens: tokens,
                                                   modelContextWindow: 272_000)
                func tool(_ index: Int, _ step: Step, _ begin: TimeInterval) -> CodexToolExecution {
                    CodexToolExecution(id: "demo-\(loop)-\(script.name)-\(index)", toolName: step.tool,
                                       argument: step.argument, startTime: time(begin))
                }
                state.recentTools = finished.map {
                    var done = tool($0.0, $0.1, $0.2)
                    done.endTime = time($0.3)
                    done.exitCode = 0
                    return done
                }
                if let (index, step, begin) = active { state.activeTools = [tool(index, step, begin)] }
                if working {
                    state.isTurnInProgress = true
                    state.isThinking = state.activeTools.isEmpty && !asking
                }
                if asking, let question = script.question {
                    state.pendingInputRequest = CodexInputRequest(id: "demo-\(loop)-\(script.name)-question", questions: [
                        AgentInputQuestion(header: question.header, question: question.text,
                                           options: question.options.map { AgentInputOption(label: $0.0, description: $0.1) }),
                    ])
                }
                codexSessions.append(session)
                codexStates[session.id] = state
                codexProgress = max(codexProgress, progress)
                if t >= script.end, completed.insert(script.id).inserted {
                    CodexManager.shared.demoComplete(CompletedTurn(sessionId: session.id, answer: script.answer,
                                                                   elapsed: script.end - script.start))
                }
            }
        }

        ClaudeCodeManager.shared.demoApply(sessions: claudeSessions, states: claudeStates)
        PermissionRequestCenter.shared.demoSetAnswerable(Set(claudeStates.filter { !$0.value.pendingInputRequests.isEmpty }.keys))
        // A scene without one agent shows no usage card for it either.
        let codexLimits = codexSessions.isEmpty ? CodexRateLimits() : CodexRateLimits(
            primary: CodexRateLimitWindow(usedPercent: 34 + codexProgress * 0.3, windowMinutes: 300,
                                          resetsAt: now.addingTimeInterval(3 * 3600 + 20 * 60)),
            secondary: CodexRateLimitWindow(usedPercent: 21, windowMinutes: 7 * 24 * 60,
                                            resetsAt: now.addingTimeInterval(4 * 86_400 + 6 * 3600)),
            planType: "pro")
        CodexManager.shared.demoApply(sessions: codexSessions, states: codexStates, rateLimits: codexLimits)
        ClaudeUsageManager.shared.demoApply(claudeSessions.isEmpty ? .empty : ClaudeUsageData(
            fiveHour: .init(percentage: 46 + max(0, min(t, 40) - 2) * 0.25, resetsAt: now.addingTimeInterval(2 * 3600 + 10 * 60)),
            sevenDay: .init(percentage: 31, resetsAt: now.addingTimeInterval(3 * 86_400 + 9 * 3600)),
            opus: nil, sonnet: nil, fable: nil, fetchedAt: now))
    }
}
