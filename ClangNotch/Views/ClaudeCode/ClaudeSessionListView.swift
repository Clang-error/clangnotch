import SwiftUI

private struct UnifiedWorkspaceGroup: Identifiable {
    let path: String
    var claude: [ClaudeSession] = []
    var codex: [CodexSession] = []

    var id: String { path }
}

struct ClaudeSessionListView: View {
    @ObservedObject var manager: ClaudeCodeManager
    @ObservedObject var codexManager: CodexManager
    let maxItems: Int?
    let onOpen: () -> Void

    init(manager: ClaudeCodeManager, codexManager: CodexManager, maxItems: Int? = nil, onOpen: @escaping () -> Void = {}) {
        self.manager = manager
        self.codexManager = codexManager
        self.maxItems = maxItems
        self.onOpen = onOpen
    }

    var body: some View {
        let groups = unifiedGroups
        let visibleGroups = maxItems.map { Array(groups.prefix($0)) } ?? groups

        Group {
            if visibleGroups.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "terminal")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(NotchPalette.accent)
                    Text(L("세션 없음", "Ready when you are"))
                        .font(.system(size: 14, weight: .semibold))
                    Text(L("작업 폴더에서 Claude Code나 Codex 세션을 시작하면 여기에 활동이 표시됩니다.", "Start a Claude Code or Codex session in your workspace. Its activity will appear here."))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 8) {
                    ForEach(visibleGroups) { group in
                        ForEach(group.claude) { session in
                            UnifiedWorkspaceSessionRow(
                                group: UnifiedWorkspaceGroup(path: group.path, claude: [session]),
                                onOpen: onOpen, manager: manager, codexManager: codexManager
                            )
                        }
                        ForEach(group.codex) { session in
                            UnifiedWorkspaceSessionRow(
                                group: UnifiedWorkspaceGroup(path: group.path, codex: [session]),
                                onOpen: onOpen, manager: manager, codexManager: codexManager
                            )
                        }
                    }
                }
            }
        }
    }

    private var unifiedGroups: [UnifiedWorkspaceGroup] {
        var grouped: [String: UnifiedWorkspaceGroup] = [:]

        for session in manager.availableSessions where AppSettings.shared.showSourceClaudeCode {
            let path = normalizedPath(session.workspacePath ?? "")
            grouped[path, default: UnifiedWorkspaceGroup(path: path)].claude.append(session)
        }

        if AppSettings.shared.showSourceCodex {
            for session in codexManager.availableSessions {
                let path = normalizedPath(session.cwd)
                grouped[path, default: UnifiedWorkspaceGroup(path: path)].codex.append(session)
            }
        }

        // Show the most recently active workspace first. A path tie-breaker keeps
        // the order deterministic when two sessions update at the same instant.
        return grouped.values.sorted { lhs, rhs in
            let lhsActivity = latestActivity(for: lhs)
            let rhsActivity = latestActivity(for: rhs)
            if lhsActivity != rhsActivity { return lhsActivity > rhsActivity }
            return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }
    }

    private func normalizedPath(_ path: String) -> String {
        guard !path.isEmpty else { return L("알 수 없음", "Unknown") }
        return URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func latestActivity(for group: UnifiedWorkspaceGroup) -> Date {
        var latest = Date.distantPast

        for session in group.claude {
            if let date = manager.sessionStates[session.id]?.lastUpdateTime {
                latest = max(latest, date)
            } else if let index = manager.availableSessions.firstIndex(of: session) {
                // Claude's discovery list is already newest-first, including
                // sessions whose state has not emitted an event in this launch.
                latest = max(latest, Date.distantPast.addingTimeInterval(
                    Double(manager.availableSessions.count - index)
                ))
            }
        }

        for session in group.codex {
            latest = max(latest, codexManager.sessionStates[session.id]?.lastUpdateTime ?? session.timestamp)
        }
        return latest
    }

}

private struct UnifiedWorkspaceSessionRow: View {
    let group: UnifiedWorkspaceGroup
    let onOpen: () -> Void
    @ObservedObject var manager: ClaudeCodeManager
    @ObservedObject var codexManager: CodexManager
    @State private var hovering = false

    private var claudeActive: Bool {
        group.claude.contains { manager.sessionStates[$0.id]?.isActive == true }
    }

    private var codexActive: Bool {
        group.codex.contains { codexManager.sessionStates[$0.id]?.isActive == true }
    }

    private var needsPermission: Bool {
        group.claude.contains { manager.sessionStates[$0.id]?.needsPermission == true }
    }

    private var awaitingAnswer: Bool {
        group.claude.contains { manager.sessionStates[$0.id]?.isAwaitingInput == true }
    }

    private var preview: String? {
        if awaitingAnswer { return L("Claude: 답변 대기", "Claude: Waiting for your answer") }
        if needsPermission { return L("Claude: 권한 승인 대기", "Claude: Waiting for permission") }
        if let tool = group.claude.compactMap({ manager.sessionStates[$0.id]?.currentToolName }).first {
            return "Claude: \(tool)"
        }
        if let tool = group.codex.compactMap({ codexManager.sessionStates[$0.id]?.currentToolName }).first {
            return "Codex: \(tool)"
        }
        if group.codex.contains(where: { codexManager.sessionStates[$0.id]?.isThinking == true }) {
            return L("Codex: 생각 중", "Codex: Thinking")
        }
        return nil
    }

    /// Tells rows of one folder apart when nothing is running: the session's last prompt,
    /// or its id when the replayed history holds no prompt.
    private var sessionHint: String? {
        if let session = group.claude.first {
            if let prompt = manager.sessionStates[session.id]?.recentMessages.last(where: { $0.role == .user })?.text {
                return prompt
            }
            return manager.conversationId(for: session).map { String($0.prefix(8)) }
        }
        if let session = group.codex.first {
            return codexManager.sessionStates[session.id]?.lastUserPrompt ?? String(session.id.prefix(8))
        }
        return nil
    }

    /// The session whose todos, context and tokens the open notch shows.
    private var isSelected: Bool {
        group.claude.contains { $0.id == manager.selectedSession?.id }
    }

    var body: some View {
        Button {
            onOpen()
            if let session = group.claude.first {
                manager.selectSession(session)
                manager.focusIDE(for: session)
            } else if let session = group.codex.first {
                codexManager.selectSession(session)
                codexManager.focusApp(for: session)
            }
        } label: {
            HStack(spacing: 8) {
                HStack(spacing: 2) {
                    if !group.claude.isEmpty { sourceIcon("ClaudeIcon", glow: .orange, active: claudeActive) }
                    if !group.codex.isEmpty { sourceIcon("ChatGPTIcon", glow: .blue, active: codexActive) }
                }
                .frame(width: 26, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(displayName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        if !group.claude.isEmpty {
                            SourceBadge(label: "Claude", count: group.claude.count, color: .orange, active: claudeActive)
                        }
                        if !group.codex.isEmpty {
                            SourceBadge(label: "Codex", count: group.codex.count, color: .blue, active: codexActive)
                        }
                        HStack(spacing: 3) {
                            Image(systemName: destination?.iconName ?? "macwindow")
                                .accessibilityHidden(true)
                            Text(destinationLabel)
                        }
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.teal)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.teal.opacity(0.15), in: Capsule())
                            .fixedSize()
                    }
                    if let subtitle = preview ?? sessionHint {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundColor(needsPermission || awaitingAnswer ? .orange : .secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
            .background(Color.white.opacity(isSelected ? (hovering ? 0.11 : 0.08) : (hovering ? 0.07 : 0.035)),
                        in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 9).stroke(Color.orange.opacity(0.35), lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(L("\(destinationLabel) 열기", "Open \(destinationLabel)"))
        .contextMenu {
            ForEach(group.claude) { session in
                if let id = manager.conversationId(for: session) {
                    Button(L("Claude 세션 ID 복사 (\(id.prefix(8)))", "Copy Claude Session ID (\(id.prefix(8)))")) { copyToPasteboard(id) }
                }
            }
            ForEach(group.codex) { session in
                Button(L("Codex 세션 ID 복사 (\(session.id.prefix(8)))", "Copy Codex Session ID (\(session.id.prefix(8)))")) { copyToPasteboard(session.id) }
            }
        }
    }

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    private var destination: SessionAppDestination? {
        if let session = group.codex.first {
            return codexManager.appDestination(for: session)
        }
        if let session = group.claude.first {
            return SessionAppDestination.claude(entrypoint: manager.sessionStates[session.id]?.entrypoint ?? .unknown, ideName: session.ideName)
        }
        return nil
    }

    private var destinationLabel: String {
        if let host = group.claude.first?.remoteHost { return "SSH · \(host)" }
        return destination?.label ?? group.claude.first?.ideName ?? "app"
    }

    private var displayName: String {
        let name = URL(fileURLWithPath: group.path).lastPathComponent
        return name.isEmpty ? group.path : name
    }

    private func sourceIcon(_ name: String, glow: Color, active: Bool) -> some View {
        Image(name)
            .resizable()
            .foregroundColor(.white)
            .frame(width: 12, height: 12)
            .opacity(active ? 1 : 0.55)
            .shadow(color: active ? glow.opacity(0.8) : .clear, radius: 4)
    }
}

private struct SourceBadge: View {
    let label: String
    let count: Int
    let color: Color
    let active: Bool

    var body: some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 4, height: 4)
            Text(count > 1 ? "\(label) \(count)" : label)
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundColor(color.opacity(active ? 1 : 0.75))
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(color.opacity(active ? 0.18 : 0.08), in: Capsule())
    }
}
