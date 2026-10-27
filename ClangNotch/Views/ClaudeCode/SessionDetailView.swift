import SwiftUI

/// The session a 세션 줄 opened in the 세션 화면.
struct SessionDetailTarget: Equatable {
    let agent: PermissionRequestItem.Agent
    let sessionId: String
}

/// One tool call as the 세션 화면 lists it, from either agent's history.
private struct SessionStep: Identifiable, Equatable {
    let id: String
    let name: String
    let argument: String?
    let isRunning: Bool
    let failed: Bool
    let change: ToolChange?
}

/// 세션 화면: a session's recent steps on the left, and on the right what the picked step
/// changed (removed/added lines) or ran. Built from what the JSONL watchers already keep.
struct SessionDetailView: View {
    let target: SessionDetailTarget
    @ObservedObject var manager: ClaudeCodeManager
    @ObservedObject var codexManager: CodexManager
    let onBack: () -> Void
    var openTitle = L("터미널 열기", "Open terminal")
    let onOpenTerminal: () -> Void
    @State private var pickedStepID: String?

    private var accent: Color {
        target.agent == .codex ? Color(red: 0.2, green: 0.5, blue: 1.0) : Color(red: 0.9, green: 0.4, blue: 0.1)
    }

    private var cwd: String {
        switch target.agent {
        case .claude: manager.sessionStates[target.sessionId]?.cwd ?? ""
        case .codex: codexManager.availableSessions.first { $0.id == target.sessionId }?.cwd ?? ""
        }
    }

    private var isActive: Bool {
        switch target.agent {
        case .claude: manager.sessionStates[target.sessionId]?.isActive == true
        case .codex: codexManager.sessionStates[target.sessionId]?.isActive == true
        }
    }

    /// Oldest first, the running ones last — the order they happened in.
    private var steps: [SessionStep] {
        switch target.agent {
        case .claude:
            guard let state = manager.sessionStates[target.sessionId] else { return [] }
            return (state.recentTools.reversed() + state.activeTools).map {
                SessionStep(id: $0.id, name: $0.toolName, argument: $0.argument,
                            isRunning: $0.isRunning, failed: false, change: $0.change)
            }
        case .codex:
            guard let state = codexManager.sessionStates[target.sessionId] else { return [] }
            return (state.recentTools.reversed() + state.activeTools).map {
                SessionStep(id: $0.id, name: $0.change != nil ? "apply_patch" : $0.toolName, argument: $0.argument,
                            isRunning: $0.isRunning, failed: ($0.exitCode ?? 0) != 0, change: $0.change)
            }
        }
    }

    /// The picked step, or the newest one that changed a file, or simply the newest.
    private var shownStep: SessionStep? {
        let all = steps
        if let pickedStepID, let step = all.first(where: { $0.id == pickedStepID }) { return step }
        return all.last(where: { $0.change != nil }) ?? all.last
    }

    private var lastAnswer: String? {
        guard target.agent == .claude else { return nil }
        return manager.sessionStates[target.sessionId]?.recentMessages.last { $0.role == .assistant }?.text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if AppSettings.shared.showContextProgress, let context {
                contextRow(used: context.used, limit: context.limit)
            }
            HStack(alignment: .top, spacing: 12) {
                stepList
                    .frame(width: 190)
                detailPane
            }
            if let lastAnswer {
                Text(lastAnswer.split(whereSeparator: \.isNewline).first.map(String.init) ?? lastAnswer)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.6))
                    .lineLimit(1)
            }
        }
        .padding(.top, 4)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.white.opacity(0.08)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(L("세션 목록으로", "Back to sessions"))

            Group {
                if target.agent == .claude {
                    Image("ClaudeIcon").resizable()
                } else {
                    Image("ChatGPTIcon").resizable().foregroundColor(.white)
                }
            }
            .frame(width: 14, height: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text(cwd.isEmpty ? L("알 수 없음", "Unknown") : URL(fileURLWithPath: cwd).lastPathComponent)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(target.agent == .claude ? "Claude Code" : "Codex")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.5))
            }
            if isActive {
                Text(L("작업 중", "Working"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(accent.opacity(0.15)))
            }
            Spacer(minLength: 0)
            Button(action: onOpenTerminal) {
                Label(openTitle, systemImage: "arrow.up.forward.app")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(accent))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .popIn()
    }

    /// How full the session's context window is. Claude's size comes from its status line;
    /// a session without one is taken as 200k until it passes that, which only 1M allows.
    private var context: (used: Int, limit: Int)? {
        switch target.agent {
        case .claude:
            guard let usage = manager.sessionStates[target.sessionId]?.tokenUsage else { return nil }
            // Same input-only sum Claude Code's own used_percentage uses.
            let used = usage.inputTokens + usage.cacheCreationInputTokens + usage.cacheReadInputTokens
            let limit = manager.contextWindowSizes[target.sessionId] ?? (used > 200_000 ? 1_000_000 : 200_000)
            return (used, limit)
        case .codex:
            guard let usage = codexManager.sessionStates[target.sessionId]?.tokenUsage,
                  usage.contextTokens > 0 else { return nil }
            return (usage.contextTokens, usage.modelContextWindow)
        }
    }

    /// One thin line under the header.
    private func contextRow(used: Int, limit: Int) -> some View {
        let progress = limit > 0 ? min(1, Double(used) / Double(limit)) : 0
        let color: Color = progress > 0.9 ? .red : progress > 0.7 ? .orange : progress > 0.5 ? .yellow : .green
        return HStack(spacing: 8) {
            Text("Context")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.5))
            Capsule()
                .fill(Color.white.opacity(0.1))
                .overlay(alignment: .leading) {
                    GeometryReader { geo in
                        Capsule().fill(color.opacity(0.8)).frame(width: geo.size.width * progress)
                    }
                }
                .frame(height: 3)
            Text("\(Self.tokens(used)) / \(Self.tokens(limit))")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.6))
        }
        .padding(.leading, 32)
    }

    private static func tokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            let millions = Double(count) / 1_000_000
            return millions == millions.rounded() ? "\(Int(millions))M" : String(format: "%.1fM", millions)
        }
        return count >= 1000 ? String(format: "%.1fk", Double(count) / 1000) : "\(count)"
    }

    private var stepList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 2) {
                    let all = steps
                    if all.isEmpty {
                        Text(L("아직 기록된 도구가 없습니다.", "No tool calls yet."))
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.5))
                            .padding(8)
                    }
                    ForEach(Array(all.enumerated()), id: \.element.id) { index, step in
                        stepRow(step, picked: step.id == shownStep?.id)
                            .id(step.id)
                            .popIn(.rise, delay: Double(min(index, 8)) * 0.035)
                    }
                    if !all.isEmpty, !isActive {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundColor(.white.opacity(0.35))
                            Text("Done")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.white.opacity(0.4))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .id("done")
                    }
                }
            }
            .scrollIndicators(.never)
            .onAppear { proxy.scrollTo(isActive ? steps.last?.id : "done", anchor: .bottom) }
        }
        .padding(6)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func stepRow(_ step: SessionStep, picked: Bool) -> some View {
        Button {
            pickedStepID = step.id
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Group {
                    if step.isRunning {
                        ProgressView().controlSize(.mini)
                    } else if step.failed {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.red.opacity(0.85))
                    } else {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(.green.opacity(0.85))
                    }
                }
                .font(.system(size: 13))
                .frame(width: 15, height: 15)
                VStack(alignment: .leading, spacing: 1) {
                    Text(step.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(step.isRunning ? 1 : 0.85))
                        .lineLimit(1)
                    if let argument = step.argument, !argument.isEmpty {
                        Text(argument)
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.45))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(picked ? accent.opacity(0.14) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var detailPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let step = shownStep, let change = step.change {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 10))
                        .foregroundColor(accent)
                    Text(URL(fileURLWithPath: change.file).lastPathComponent)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                    Spacer(minLength: 0)
                    Text(URL(fileURLWithPath: change.file).deletingLastPathComponent().lastPathComponent)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white.opacity(0.35))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(change.lines.enumerated()), id: \.offset) { _, line in
                            diffLine(line)
                        }
                    }
                }
                .scrollIndicators(.visible)
            } else if let step = shownStep {
                Text(step.name)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                Text("$ \(step.argument ?? "")")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.white.opacity(0.85))
                    .padding(.horizontal, 10)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.06)))
        .id(shownStep?.id)
        .popIn(delay: 0.07)
    }

    private func diffLine(_ line: ToolChange.Line) -> some View {
        let removed = line.kind == .removed
        return HStack(alignment: .top, spacing: 6) {
            Text(removed ? "−" : "+")
                .foregroundColor(removed ? .red.opacity(0.8) : .green.opacity(0.8))
                .frame(width: 10)
            Text(line.text.isEmpty ? " " : line.text)
                .foregroundColor(.white.opacity(removed ? 0.5 : 0.9))
                .strikethrough(removed, color: .red.opacity(0.5))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.horizontal, 8)
        .padding(.vertical, 1.5)
        .background(removed ? Color.red.opacity(0.13) : Color.green.opacity(0.11))
        .overlay(alignment: .leading) {
            Rectangle().fill(removed ? Color.red.opacity(0.7) : Color.green.opacity(0.7)).frame(width: 2)
        }
    }
}
