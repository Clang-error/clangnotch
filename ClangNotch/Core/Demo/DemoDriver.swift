import AppKit

/// `open ClangNotch.app --args --demo [--demo-scene claude|codex|both|ssh|tools|many|airpods|airpodslid|airpodslow|media|osd|lowbattery|tether|macbattery]`:
/// the notch runs on made-up Claude Code and Codex sessions (or, for `tools`, made-up clipboard,
/// volume, battery, Sidecar and display data) for screen recordings. Nothing real is read, so no
/// project name, path, device, copied text or account balance from this Mac can end up in a video.
enum DemoMode {
    static let isActive = CommandLine.arguments.contains("--demo")

    enum Scene: String { case claude, codex, both, ssh, tools, many, airpods, airpodslid, airpodslow, media, osd, lowbattery, tether, macbattery }

    /// Every scene's clock starts this long after launch, once the startup glow (3 s and a 0.3 s
    /// fade) is gone: started at launch, the first dropdown came down inside the glow and the two
    /// read as one effect (2026-11-11). Recordings start from here too.
    static let startDelay: TimeInterval = 4

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
/// many: Claude sessions join one every 3s from 2s (up to 5), then Codex ones from 17s
/// (up to 3), so the wing's 아이콘 지그재그 grows; all finish around 40–45s.
@MainActor
final class DemoDriver {
    static let shared = DemoDriver()

    static let loopLength: TimeInterval = 56

    private var task: Task<Void, Never>?
    /// Questions answered from the 질문 드롭다운 this loop.
    private var answered: Set<String> = []
    /// Next-step boxes answered from the 다음 단계 드롭다운 this loop.
    private var answeredNextSteps: Set<String> = []
    private init() {}

    /// A pick in the 질문 드롭다운 (`PermissionRequestCenter.answerQuestion`) ends the question.
    func answer(sessionId: String) {
        answered.insert(sessionId)
    }

    /// A button in the 다음 단계 드롭다운 (`PermissionRequestCenter.answerNextStep`) ends the box.
    func answerNextStep(sessionId: String) {
        answeredNextSteps.insert(sessionId)
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(DemoMode.startDelay))
            guard !Task.isCancelled else { return }
            await self?.play()
        }
    }

    private func play() async {
        if DemoMode.scene == .tools {
            applyTools()
            // A copy in another app at 0.6 s, before the recording's cursor opens the notch: the
            // 복사 방울 drops, and the Clipboard tab then has the copy at the top (under the pin).
            // ClipboardManager doesn't run in a demo, so the item and the drop are sent here.
            try? await Task.sleep(for: .milliseconds(600))
            ClipboardManager.shared.demoAdd(ClipboardItem(text: "git push origin feat/billing-tax", copiedAt: Date()))
            ClipboardManager.shared.copied.send()
            return
        }
        // lowbattery: an idle notch; the iPhone, ranked for the closed notch, is down to 12%, so
        // its battery shows in the wing (배터리 부족 날개).
        if DemoMode.scene == .lowbattery {
            applyTools(iPhonePercent: 12)
            BatteryManager.shared.demoPriorityIDs = ["demo-iphone"]
            return
        }
        // tether: tethering to the iPhone at a saved place: the red glow, the wing's place and
        // time, the 테더링 드롭다운, and in the Speed tab the SKT shared data balance.
        if DemoMode.scene == .tether {
            applyTools()
            let now = Date()
            TWorldSession.shared.demoApply(TWorldBalance(totalKB: 40 * 1_048_576,
                                                         usedKB: 13.62 * 1_048_576, remainingKB: 26.38 * 1_048_576,
                                                         fetchedAt: now.addingTimeInterval(-4 * 60)))
            TetherPlaceMonitor.shared.demoTether(place: L("집", "Home"))
            return
        }
        // macbattery: an idle notch; this Mac's card drops every 12 s, at 20% then 10%.
        if DemoMode.scene == .macbattery {
            var level = 20
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                AirPodsDropdown.shared.demoShowMacLow(level: level)
                level = level == 20 ? 10 : 20
                try? await Task.sleep(for: .seconds(10))
            }
            return
        }
        // airpodslow: an idle notch; low battery cards every 12 s, AirPods Pro with the left bud
        // low (split) then AirPods Max at 18%.
        if DemoMode.scene == .airpodslow {
            var max = false
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                AirPodsDropdown.shared.demoShowLow(max: max)
                max.toggle()
                try? await Task.sleep(for: .seconds(10))
            }
            return
        }
        // airpods: an idle notch; the 에어팟 드롭다운 drops every 12 s, AirPods Pro then Max.
        if DemoMode.scene == .airpods {
            var max = false
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                AirPodsDropdown.shared.demoShow(max: max)
                max.toggle()
                try? await Task.sleep(for: .seconds(10))
            }
            return
        }
        // airpodslid: an idle notch, 26 s a round. The case opens and AirPods Pro drop (2 s), the
        // left bud comes out and the card splits (5 s), the lid shuts on it and the card folds
        // (8.5 s); AirPods Max drop at 12 s and fold at 17 s. Every fold is scripted here, so
        // this Mac's fold times don't change the recording.
        if DemoMode.scene == .airpodslid {
            let card = AirPodsDropdown.shared
            card.demoKeeps = true
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                card.demoShow(max: false)
                try? await Task.sleep(for: .seconds(3))
                card.demoTakeBudOut()
                try? await Task.sleep(for: .milliseconds(3500))
                card.demoFold()
                try? await Task.sleep(for: .milliseconds(3500))
                card.demoShow(max: true)
                try? await Task.sleep(for: .seconds(5))
                card.demoFold()
                try? await Task.sleep(for: .seconds(9))
            }
            return
        }
        // media: an idle notch, 36 s a round. A track starts (2 s): the 미디어 드롭다운 drops and
        // folds at 7 s, leaving the 앨범 그림 and 음파 막대 in the wings. The next track starts
        // at 13 s and its card stays down until 26 s, long enough to pin it and drag it about
        // (the recording's cursor does that); then the wings again until the round ends.
        if DemoMode.scene == .media {
            let card = AirPodsDropdown.media, monitor = NowPlayingMonitor.shared
            card.demoKeeps = true
            func track(_ title: String, _ artist: String, hue: CGFloat, length: TimeInterval, at elapsed: TimeInterval) -> NowPlaying {
                let art = Self.demoArtwork(hue: hue)
                var playing = NowPlaying(title: title, artist: artist, bundleID: "com.apple.Music", appName: "Music",
                                         isPlaying: true, artwork: art)
                playing.accent = NowPlaying.accent(of: art)
                playing.duration = length
                playing.elapsed = elapsed
                playing.elapsedAt = Date()
                playing.rate = 1
                return playing
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                let first = track("Low Tide", "Marlow Keys", hue: 0.57, length: 214, at: 41)
                monitor.demoApply(first)
                card.demoShowMedia(first)
                try? await Task.sleep(for: .seconds(5))
                card.demoFold()
                try? await Task.sleep(for: .seconds(6))
                let second = track("Paper Lanterns", "June Okada", hue: 0.07, length: 187, at: 0)
                monitor.demoApply(second)
                card.demoShowMedia(second)
                try? await Task.sleep(for: .seconds(13))
                card.demoFold()
                try? await Task.sleep(for: .seconds(8))
                monitor.demoApply(nil)
                try? await Task.sleep(for: .seconds(2))
            }
            return
        }
        // osd: an idle notch; every 15 s the 조절창 turns the volume up to the top, down again,
        // then dims the brightness and brings it back.
        if DemoMode.scene == .osd {
            // (volume or brightness, level in 16ths, ms until the next one)
            let up = (8...16).map { (true, $0, 160) }, down = (6...15).reversed().map { (true, $0, 140) }
            let dim = (4...12).reversed().map { (false, $0, 160) }, brighten = (5...12).map { (false, $0, 160) }
            var plan = up + [(true, 16, 920)] + down  // 16 twice: the icon bounces at the top
            plan[plan.count - 1].2 = 2200
            plan += dim
            plan[plan.count - 1].2 = 500
            plan += brighten
            plan[plan.count - 1].2 = 3500
            let osd = SystemControlOSD.shared
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                for (volume, level, pause) in plan {
                    if volume { osd.demoVolume(Double(level) / 16) } else { osd.demoBrightness(Double(level) / 16) }
                    try? await Task.sleep(for: .milliseconds(pause))
                }
            }
            return
        }
        let scripts = Self.scripts(for: DemoMode.scene)
        var loop = 0
        while !Task.isCancelled {
            let began = Date()
            var completed: Set<String> = []
            answered = []
            answeredNextSteps = []
            while Date().timeIntervalSince(began) < Self.loopLength, !Task.isCancelled {
                render(scripts, at: Date().timeIntervalSince(began), loop: loop, began: began, completed: &completed)
                try? await Task.sleep(for: .milliseconds(250))
            }
            loop += 1
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

    private struct NextStep {
        let recap: String
        let ask: String
        /// (button, the message it sends)
        let actions: [(String, String)]
    }

    private struct Script {
        let name: String
        var agent: Agent
        let prompt: String
        let answer: String
        var start: TimeInterval
        var end: TimeInterval
        var steps: [Step]
        var question: Question? = nil
        /// When the question is up, unless an option is picked in the notch first.
        var asks: ClosedRange<TimeInterval> = 17...25
        /// The SSH host it runs on (an SSH 원격 세션), nil for a session on this Mac.
        var host: String? = nil
        /// Claude only: the cached context it starts the turn with, so a session can sit close to
        /// its automatic compaction ("곧 압축될 수 있음"). It then grows slowly, staying in the
        /// 87–89% of a 1M window where the note shows and the bar is still orange.
        var nearCompaction = false
        /// The Claude app's next-step box after the turn, answerable from the notch (실험 기능).
        var nextStep: NextStep? = nil
        /// When the box is up, unless a button is picked in the notch first.
        var offers: ClosedRange<TimeInterval> = 30.5...46
        var id: String {
            if case .codex = agent { return "demo-\(name)" }
            return "Claude:/Users/demo/Projects/\(name)"
        }
        var path: String { "/Users/demo/Projects/\(name)" }
    }

    private static func scripts(for scene: DemoMode.Scene) -> [Script] {
        let orbit = Script(
            name: "orbit-api", agent: .claude(.desktop),
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
            name: "lumen-web", agent: .claude(.terminal),
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
            name: "atlas-cli", agent: .codex,
            prompt: "Retry failed uploads with backoff",
            answer: "Uploads now retry with exponential backoff, capped at 5 attempts.",
            start: 2, end: 35, steps: [
                Step(after: 2, tool: "exec", argument: "rg -n \"upload\" src"),
                Step(after: 6, tool: "apply_patch", argument: "src/retry.rs"),
                Step(after: 12, tool: "exec", argument: "cargo test retry"),
                Step(after: 20, tool: "exec", argument: "cargo test"),
            ])
        let prism = Script(
            name: "prism-app", agent: .codex,
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
        case .claude:
            // The desktop session ends on the app's next-step box, picked from the notch.
            var desktop = orbit
            desktop.nearCompaction = true
            desktop.nextStep = NextStep(
                recap: "Invoice totals now include regional tax. All 48 billing tests pass.",
                ask: "Open a pull request for the tax change?",
                actions: [("Open PR", "Open a pull request for the regional tax change"),
                          ("Not yet", "Leave it on the branch for now")])
            return [desktop, lumen]
        case .codex: return [atlas, prism]
        case .tools, .airpods, .airpodslid, .airpodslow, .media, .osd, .lowbattery, .tether, .macbattery: return []

        case .ssh:
            // One session on this Mac and one on an SSH host: the remote one shows "SSH · host"
            // in its row, asks from 17 s (answerable in the notch), and both end on a Done card
            // (the remote one's button is 확인).
            var local = orbit
            local.end = 37
            var remote = lumen
            remote.agent = .claude(.ssh)
            remote.host = "build-box"
            remote.start = 6
            remote.end = 30
            return [local, remote]
        case .many:
            let claudeNames = ["orbit-api", "lumen-web", "nova-docs", "pulse-ios", "relay-bot"]
            let codexNames = ["atlas-cli", "prism-app", "quill-sdk"]
            let claude = claudeNames.enumerated().map { index, name in
                var script = index.isMultiple(of: 2) ? orbit : lumen
                script = Script(name: name, agent: script.agent, prompt: script.prompt,
                                answer: script.answer, start: 2 + Double(index) * 3, end: 40 + Double(index),
                                steps: script.steps)
                return script
            }
            let codex = codexNames.enumerated().map { index, name in
                let base = index.isMultiple(of: 2) ? atlas : prism
                return Script(name: name, agent: .codex, prompt: base.prompt,
                              answer: base.answer, start: 17 + Double(index) * 3, end: 42 + Double(index),
                              steps: base.steps)
            }
            return claude + codex
        case .both:
            var claude = orbit
            claude.nearCompaction = true
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
                                            cwd: script.path, remoteHost: script.host)
                var state = ClaudeCodeState()
                state.model = "claude-opus-5-5"
                state.cwd = script.path
                state.entrypoint = entrypoint
                state.lastUpdateTime = now
                state.tokenUsage = ClaudeTokenUsage(inputTokens: 2_400 + Int(progress * 180),
                                                    cacheReadInputTokens: script.nearCompaction
                                                        ? 868_000 + Int(progress * 150) : 30_000 + Int(progress * 2_600),
                                                    cacheCreationInputTokens: 3_100 + Int(progress * 420))
                state.recentMessages = [ClaudeMessage(role: .user, text: script.prompt)]
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
                if let next = script.nextStep, script.offers.contains(t), !answeredNextSteps.contains(script.id),
                   let box = ClaudeInputRequest.wrapUp(id: "demo-\(loop)-\(script.name)-next", input: [
                       "recap": next.recap, "ask": next.ask,
                       "actions": next.actions.map { ["label": $0.0, "message": $0.1] },
                   ]) {
                    state.pendingInputRequests.append(box)
                }
                claudeSessions.append(session)
                claudeStates[session.id] = state
                if t >= script.end, completed.insert(script.id).inserted {
                    ClaudeCodeManager.shared.demoComplete(CompletedTurn(sessionId: session.id, answer: script.answer,
                                                                        elapsed: script.end - script.start))
                }

            case .codex:
                let session = CodexSession(id: script.id, cwd: script.path,
                                           timestamp: time(0),
                                           jsonlFile: URL(fileURLWithPath: "/dev/null"))
                var state = CodexState()
                state.model = "gpt-6"
                state.lastUpdateTime = now
                state.lastUserPrompt = script.prompt
                let tokens = 24_000 + Int(progress * 1_760)
                state.tokenUsage = CodexTokenUsage(contextTokens: tokens, modelContextWindow: 272_000)
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
                    state.turnStartTime = time(script.start)
                    state.isThinking = state.activeTools.isEmpty && !asking
                }
                if asking, let question = script.question {
                    // An app question (async), the kind the notch can answer with 실험 기능 on.
                    state.pendingInputRequest = CodexInputRequest(id: "demo-\(loop)-\(script.name)-question", questions: [
                        AgentInputQuestion(header: question.header, question: question.text,
                                           options: question.options.map { AgentInputOption(label: $0.0, description: $0.1) }),
                    ], isAsync: true)
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
        // Questions and next-step boxes alike can be answered in the notch, as with 실험 기능 on.
        PermissionRequestCenter.shared.demoSetAnswerable(
            Set(claudeStates.filter { $0.value.pendingInputRequests.contains { !$0.isWrapUp } }.keys),
            nextSteps: Set(claudeStates.filter { $0.value.pendingInputRequests.contains { $0.isWrapUp } }.keys))
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
            opus: nil, sonnet: nil, fable: nil))
    }

    // MARK: - Artwork

    /// A made-up album cover (a soft two-tone square with a sun and a horizon), so no real
    /// artwork is in a recording. `hue` 0…1 sets its colour.
    static func demoArtwork(hue: CGFloat) -> NSImage {
        let side: CGFloat = 240
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let top = NSColor(hue: hue, saturation: 0.75, brightness: 0.95, alpha: 1)
            let bottom = NSColor(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.85, brightness: 0.45, alpha: 1)
            NSGradient(starting: bottom, ending: top)?.draw(in: rect, angle: 90)
            NSColor(hue: (hue + 0.52).truncatingRemainder(dividingBy: 1), saturation: 0.35, brightness: 1, alpha: 0.9).setFill()
            NSBezierPath(ovalIn: NSRect(x: side * 0.3, y: side * 0.36, width: side * 0.4, height: side * 0.4)).fill()
            NSColor(hue: hue, saturation: 0.9, brightness: 0.3, alpha: 0.85).setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: side, height: side * 0.42)).fill()
            return true
        }
    }

    // MARK: - Tools

    private func applyTools(iPhonePercent: Int = 64) {
        let now = Date()
        // The notch may open on the agents tab first; its usage cards shouldn't read "sign in".
        CodexManager.shared.demoApply(sessions: [], states: [:], rateLimits: CodexRateLimits(
            primary: CodexRateLimitWindow(usedPercent: 34, windowMinutes: 300, resetsAt: now.addingTimeInterval(3 * 3600 + 20 * 60)),
            secondary: CodexRateLimitWindow(usedPercent: 21, windowMinutes: 7 * 24 * 60, resetsAt: now.addingTimeInterval(4 * 86_400)),
            planType: "pro"))
        ClaudeUsageManager.shared.demoApply(ClaudeUsageData(
            fiveHour: .init(percentage: 46, resetsAt: now.addingTimeInterval(2 * 3600 + 10 * 60)),
            sevenDay: .init(percentage: 31, resetsAt: now.addingTimeInterval(3 * 86_400 + 9 * 3600)),
            opus: nil, sonnet: nil, fable: nil))
        ClipboardManager.shared.demoApply([
            ClipboardItem(text: "npm run build && npm run preview", copiedAt: now.addingTimeInterval(-3 * 3600), isPinned: true),
            ClipboardItem(text: "git checkout -b feat/billing-tax", copiedAt: now.addingTimeInterval(-40)),
            // An image and a file, under the two rows the recordings click (their place is fixed).
            ClipboardItem(text: L("이미지 1200×800", "Image 1200×800"), copiedAt: now.addingTimeInterval(-3 * 60),
                          kind: .image(file: URL(fileURLWithPath: "/dev/null"), type: .png, thumbnail: Self.demoArtwork(hue: 0.57))),
            ClipboardItem(text: "invoice-2026-11.pdf", copiedAt: now.addingTimeInterval(-5 * 60),
                          kind: .files([URL(fileURLWithPath: "/Users/demo/Documents/invoice-2026-11.pdf")])),
            ClipboardItem(text: "Invoice totals now include regional tax.", copiedAt: now.addingTimeInterval(-6 * 60)),
            ClipboardItem(text: "https://github.com/Clang-error/clangnotch", copiedAt: now.addingTimeInterval(-18 * 60)),
            ClipboardItem(text: "#FF9F0A", copiedAt: now.addingTimeInterval(-52 * 60)),
            ClipboardItem(text: "pnpm test billing --watch", copiedAt: now.addingTimeInterval(-2 * 3600)),
        ])

        func app(_ pid: pid_t, _ bundleID: String, _ name: String, _ path: String, _ gain: Float) -> AudioApp {
            AudioApp(pid: pid, processObjectID: 0, bundleID: bundleID, name: name,
                     icon: NSWorkspace.shared.icon(forFile: path), gain: gain)
        }
        AudioMixerManager.shared.demoApply([
            app(90_001, "com.apple.Music", "Music", "/System/Applications/Music.app", 0.8),
            app(90_002, "com.apple.Safari", "Safari", "/Applications/Safari.app", 1.0),
            app(90_003, "com.apple.podcasts", "Podcasts", "/System/Applications/Podcasts.app", 0.45),
            app(90_004, "com.apple.FaceTime", "FaceTime", "/System/Applications/FaceTime.app", 1.0),
        ])

        func device(_ id: String, _ name: String, _ symbol: String, _ percent: Int, charging: Bool = false,
                    parts: [BatteryPart] = [], minutesLeft: Int? = nil) -> BatteryDevice {
            BatteryDevice(id: id, name: name, symbol: symbol, percent: percent, charging: charging, live: true,
                          seenAt: now, parts: parts, minutesLeft: minutesLeft)
        }
        BatteryManager.shared.demoApply([
            device("mac", "MacBook Pro", "macbook", 82, minutesLeft: 344),
            device("demo-iphone", "iPhone", "iphone", iPhonePercent),
            device("demo-ipad", "iPad Pro", "ipad", 91, charging: true),
            device("demo-airpodspro", "AirPods Pro", "airpodspro", 74,
                   parts: [BatteryPart(label: "L", percent: 78), BatteryPart(label: "R", percent: 74),
                           BatteryPart(label: "케이스", percent: 55)]),
            device("demo-airpodsmax", "AirPods Max", "airpodsmax", 46),
        ])
    }
}
