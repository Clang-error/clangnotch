import SwiftUI

private struct UnifiedWorkspaceGroup: Identifiable {
    let path: String
    var claude: [ClaudeSession] = []
    var codex: [CodexSession] = []

    var id: String { path }
    /// One row per session (a folder can hold several).
    var rowID: String { (claude.first?.id ?? codex.first.map { "codex-\($0.id)" }) ?? path }
}

struct ClaudeSessionListView: View {
    @ObservedObject var manager: ClaudeCodeManager
    @ObservedObject var codexManager: CodexManager
    /// A row opens its 세션 화면.
    let onSelect: (SessionDetailTarget) -> Void
    /// When the rows came on show; nil while they aren't (the Sessions card on another page), so
    /// rows coming back with the page don't count as new sessions (user, 2026-11-19: every row
    /// flashed its white outline on turning to the sessions' page).
    @State private var listAppearedAt: Date?
    /// Row order captured while the cursor is over the list, so a row never moves under it.
    @State private var frozenOrder: [String]?

    var body: some View {
        let groups = unifiedGroups

        // The rows are the first of the card's pages; 오늘, 최근 세션 and 시작 follow, and stand
        // alone with nothing listed (2026-11-19; a line of text before).
        SessionCardPages(hasSessions: !groups.isEmpty, listed: listedKeys(groups), openSession: { open($0) }) {
            if !groups.isEmpty {
                let rows = frozen(groups.flatMap { group in
                    group.claude.map { UnifiedWorkspaceGroup(path: group.path, claude: [$0]) }
                        + group.codex.map { UnifiedWorkspaceGroup(path: group.path, codex: [$0]) }
                })
                VStack(spacing: 8) {
                    ForEach(Array(rows.enumerated()), id: \.element.rowID) { index, row in
                        VStack(spacing: 3) {
                            UnifiedWorkspaceSessionRow(
                                group: row,
                                onSelect: onSelect, manager: manager, codexManager: codexManager
                            )
                            SubagentRows(subagents: row.claude.first.flatMap { manager.sessionStates[$0.id]?.subagents } ?? [],
                                         shells: row.claude.first.flatMap { manager.sessionStates[$0.id]?.backgroundShells } ?? [],
                                         openShell: { shell in
                                             // Like the 세션 줄: its 세션 화면, on this shell.
                                             guard let session = row.claude.first else { return }
                                             manager.selectSession(session)
                                             onSelect(SessionDetailTarget(agent: .claude, sessionId: session.id, step: shell.id))
                                         })
                        }
                        // Rows rise in one after another as the list opens (the first eight;
                        // past that the wait would be noticeable). A session that shows up
                        // later, with the list already open, swells once to say it's new.
                        .popIn(.rise, delay: Double(min(index, 8)) * 0.035)
                        .newHighlight(cornerRadius: 9, active: listAppearedAt.map { Date().timeIntervalSince($0) > 0.6 } ?? false)
                    }
                }
                .onAppear { listAppearedAt = Date() }
                // Opening a 세션 화면 removes the list without a hover-exit.
                .onDisappear {
                    frozenOrder = nil
                    listAppearedAt = nil
                }
                .onHover { inside in
                    if inside {
                        frozenOrder = rows.map(\.rowID)
                    } else {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { frozenOrder = nil }
                    }
                }
            }
        }
    }

    /// The sessions on the list, as 완료 기록 names them (agent:id).
    private func listedKeys(_ groups: [UnifiedWorkspaceGroup]) -> Set<String> {
        Set(groups.flatMap { $0.claude.map { "claude:\($0.id)" } + $0.codex.map { "codex:\($0.id)" } })
    }

    /// 완료 기록's row for a session still listed: what clicking its row here does.
    private func open(_ target: SessionDetailTarget) {
        switch target.agent {
        case .claude:
            if let session = manager.availableSessions.first(where: { $0.id == target.sessionId }) { manager.selectSession(session) }
        case .codex:
            if let session = codexManager.availableSessions.first(where: { $0.id == target.sessionId }) { codexManager.selectSession(session) }
        }
        onSelect(target)
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

        // Working folders first, in name order: sorting them by last activity swapped two
        // busy rows every time either wrote a line. Idle ones keep most recent first, which
        // holds still because they write nothing. The path breaks ties.
        return grouped.values.sorted { lhs, rhs in
            // Folders with a session waiting on you come first, then working ones.
            let lhsWaiting = needsYou(lhs), rhsWaiting = needsYou(rhs)
            if lhsWaiting != rhsWaiting { return lhsWaiting }
            let lhsActive = isActive(lhs), rhsActive = isActive(rhs)
            if lhsActive != rhsActive { return lhsActive }
            if !lhsActive {
                let lhsActivity = latestActivity(for: lhs)
                let rhsActivity = latestActivity(for: rhs)
                if lhsActivity != rhsActivity { return lhsActivity > rhsActivity }
            }
            return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }
    }

    private func normalizedPath(_ path: String) -> String {
        guard !path.isEmpty else { return L("알 수 없음", "Unknown") }
        return URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Keeps the captured order while hovering; rows that appeared since go last.
    private func frozen(_ rows: [UnifiedWorkspaceGroup]) -> [UnifiedWorkspaceGroup] {
        guard let frozenOrder else { return rows }
        let rank = Dictionary(frozenOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return rows.enumerated()
            .sorted { (rank[$0.element.rowID] ?? Int.max, $0.offset) < (rank[$1.element.rowID] ?? Int.max, $1.offset) }
            .map(\.element)
    }

    /// A permission or a real question waiting (a lingering next-step box doesn't count).
    private func needsYou(_ group: UnifiedWorkspaceGroup) -> Bool {
        group.claude.contains { session in
            manager.sessionsNeedingPermission.contains { $0.id == session.id }
                || manager.sessionStates[session.id]?.pendingInputRequests.contains { !$0.isWrapUp } == true
        } || group.codex.contains { codexManager.sessionStates[$0.id]?.pendingInputRequest != nil }
    }

    private func isActive(_ group: UnifiedWorkspaceGroup) -> Bool {
        group.claude.contains { manager.sessionStates[$0.id]?.isActive == true }
            || group.codex.contains { codexManager.sessionStates[$0.id]?.isActive == true }
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
    let onSelect: (SessionDetailTarget) -> Void
    @ObservedObject var manager: ClaudeCodeManager
    @ObservedObject var codexManager: CodexManager
    @ObservedObject private var settings = AppSettings.shared
    @State private var hovering = false
    /// Bumped when the session reaches the hard hat (아이콘 모자), to redraw the row.
    @State private var hatClock = 0

    private var claudeActive: Bool {
        group.claude.contains { manager.sessionStates[$0.id]?.isActive == true }
    }

    /// 설정 › 실험 기능 › "Claude 아이콘에 모자 씌우기": the working session's hat, as on its
    /// icon in the closed wing.
    private var claudeHat: ClaudeIconHat? {
        guard settings.experimentalClaudeIconHats else { return nil }
        _ = hatClock
        let now = Date()
        return group.claude.compactMap { manager.sessionStates[$0.id] }
            .filter(\.isActive)
            .compactMap { ClaudeIconHat.wearing($0, now: now) }
            .first
    }

    private var claudeHardhatDue: Date? {
        guard settings.experimentalClaudeIconHats else { return nil }
        let now = Date()
        return group.claude.compactMap { manager.sessionStates[$0.id] }
            .filter(\.isActive)
            .compactMap { ClaudeIconHat.hardhatDue($0, now: now) }
            .min()
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

    /// Subagents the session is running now; each also has its own 서브에이전트 줄 below.
    private var subagentCount: Int {
        group.claude.reduce(0) { $0 + (manager.sessionStates[$1.id]?.subagents.count ?? 0) }
    }

    private var preview: String? {
        if awaitingAnswer { return L("Claude: 답변 대기", "Claude: Waiting for your answer") }
        if needsPermission { return L("Claude: 권한 승인 대기", "Claude: Waiting for permission") }
        if let tool = group.claude.compactMap({ manager.sessionStates[$0.id]?.currentToolName }).first {
            return "Claude: \(tool)"
        }
        // Nothing of its own running: the session is waiting on the subagents it started.
        if subagentCount > 0 {
            return L("Claude: 서브에이전트 \(subagentCount)개 실행 중",
                     subagentCount == 1 ? "Claude: running 1 subagent" : "Claude: running \(subagentCount) subagents")
        }
        // ...or its turn is over and waits on its background shells (each has a 셸 줄 below).
        if let shells = group.claude.compactMap({ manager.sessionStates[$0.id] })
            .first(where: { $0.shellWaitSince != nil && $0.turnStartTime == nil })?.backgroundShells.count, shells > 0 {
            return L("Claude: 셸 \(shells)개 기다리는 중",
                     shells == 1 ? "Claude: waiting on 1 shell" : "Claude: waiting on \(shells) shells")
        }
        if let tool = group.codex.compactMap({ codexManager.sessionStates[$0.id]?.currentToolName }).first {
            return "Codex: \(tool)"
        }
        if group.codex.contains(where: { codexManager.sessionStates[$0.id]?.isThinking == true }) {
            return L("Codex: 생각 중", "Codex: Thinking")
        }
        return nil
    }

    /// 곧 압축될 수 있음: one of the row's sessions is close to its automatic compaction. The
    /// 미리보기 줄 then ends with it, in orange (`ContextCompaction`).
    private var compactionNote: (agent: String, text: String)? {
        for session in group.claude {
            if let use = manager.contextUse(for: session.id),
               ContextCompaction.isNear(.claude, used: use.used, limit: use.limit) {
                return ("Claude", ContextCompaction.note(used: use.used, limit: use.limit))
            }
        }
        for session in group.codex {
            if let usage = codexManager.sessionStates[session.id]?.tokenUsage,
               ContextCompaction.isNear(.codex, used: usage.contextTokens, limit: usage.modelContextWindow) {
                return ("Codex", ContextCompaction.note(used: usage.contextTokens, limit: usage.modelContextWindow))
            }
        }
        return nil
    }

    /// The 미리보기 줄: what runs, or the hint; near a compaction, the note after it (or in
    /// place of the hint when nothing runs).
    private var subtitle: (text: String, warns: Bool)? {
        if let note = compactionNote {
            if let preview { return ("\(preview) · \(note.text)", true) }
            return ("\(note.agent): \(note.text)", true)
        }
        return (preview ?? sessionHint).map { ($0, needsPermission || awaitingAnswer) }
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

    /// A working session is outlined in its agent's notch glow color.
    private var activeOutline: Color? {
        if claudeActive { return Color(red: 0.9, green: 0.4, blue: 0.1) }
        if codexActive { return Color(red: 0.2, green: 0.5, blue: 1.0) }
        return nil
    }

    /// When the row's work began (its earliest working session's turn), where its outline's
    /// lap counts from, so working rows don't all go round in step.
    private var workStart: Date? {
        let claude = group.claude.compactMap { manager.sessionStates[$0.id] }.filter(\.isActive)
            .compactMap { $0.turnStartTime ?? $0.activeTools.first?.startTime }
        let codex = group.codex.compactMap { codexManager.sessionStates[$0.id] }.filter(\.isActive)
            .compactMap { $0.turnStartTime ?? $0.activeTools.first?.startTime }
        return (claude + codex).min()
    }

    private var isMuted: Bool {
        (group.claude.map(\.id) + group.codex.map(\.id)).contains(where: NotchSounds.isMuted)
    }

    /// 세션 고정: the row stays in the list whatever 쉬는 세션이 목록에 남는 시간 says
    /// (`SessionRetention`). A row can hold a Claude and a Codex session; both are pinned.
    private var sessionIDs: [String] { group.claude.map(\.id) + group.codex.map(\.id) }
    private var pinnedIDs: Set<String> { Set(settings.pinnedSessionIDs.split(separator: "\n").map(String.init)) }
    private var isPinned: Bool { sessionIDs.contains(where: pinnedIDs.contains) }

    private func togglePin() {
        var pinned = pinnedIDs
        if isPinned { pinned.subtract(sessionIDs) } else { pinned.formUnion(sessionIDs) }
        settings.pinnedSessionIDs = pinned.sorted().joined(separator: "\n")
        // An unpinned row that is past its time goes now, not at the next scan.
        manager.scanForSessions()
        codexManager.scanForSessions()
    }

    /// The session whose todos, context and tokens the open notch shows.
    private var isSelected: Bool {
        group.claude.contains { $0.id == manager.selectedSession?.id }
    }

    var body: some View {
        Button {
            if let session = group.claude.first {
                manager.selectSession(session)
                onSelect(SessionDetailTarget(agent: .claude, sessionId: session.id))
            } else if let session = group.codex.first {
                codexManager.selectSession(session)
                onSelect(SessionDetailTarget(agent: .codex, sessionId: session.id))
            }
        } label: {
            HStack(spacing: 8) {
                HStack(spacing: 2) {
                    if !group.claude.isEmpty {
                        sourceIcon("ClaudeIcon", glow: .orange, active: claudeActive)
                            .overlay {
                                if let claudeHat {
                                    ClaudeIconHatView(hat: claudeHat)
                                        .transition(.scale(scale: 0.3).combined(with: .opacity))
                                }
                            }
                            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: claudeHat)
                            // A turn that only thinks changes nothing for minutes: sleep
                            // once until it reaches the hard hat.
                            .task(id: claudeHardhatDue) {
                                guard let due = claudeHardhatDue else { return }
                                try? await Task.sleep(for: .seconds(due.timeIntervalSinceNow + 0.2))
                                if !Task.isCancelled { hatClock &+= 1 }
                            }
                    }
                    if !group.codex.isEmpty { sourceIcon("ChatGPTIcon", glow: .blue, active: codexActive) }
                }
                .frame(width: 26, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(sessionTitle ?? displayName)
                            .font(.system(size: sessionTitle == nil ? 13 : 12, weight: .semibold))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        // The 출처 배지 names the model the session runs ("Opus 5.5"): the icon and
                        // the colour already say which agent (user, 2026-11-19). The agent's name
                        // until a reply has named the model.
                        if let session = group.claude.first {
                            SourceBadge(label: manager.sessionStates[session.id].flatMap { ModelName.short($0.model) } ?? "Claude",
                                        color: .orange, active: claudeActive)
                        }
                        if let session = group.codex.first {
                            SourceBadge(label: codexManager.sessionStates[session.id].flatMap { ModelName.short($0.model) } ?? "Codex",
                                        color: .blue, active: codexActive)
                        }
                        if subagentCount > 0 {
                            // 서브에이전트 배지: this session started subagents and they are at work.
                            HStack(spacing: 2) {
                                Image(systemName: "arrow.triangle.branch")
                                    .accessibilityHidden(true)
                                Text("\(subagentCount)")
                            }
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.orange)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.18), in: Capsule())
                            .fixedSize()
                            .help(L("서브에이전트 \(subagentCount)개 실행 중",
                                    subagentCount == 1 ? "Running 1 subagent" : "Running \(subagentCount) subagents"))
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
                    if sessionTitle != nil {
                        HStack(spacing: 4) {
                            FolderElbow()
                                .stroke(Color.secondary.opacity(0.7), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
                                .frame(width: 7, height: 6)
                                // The foot sits at the text's middle, not the row's.
                                .offset(y: -2.5)
                                .padding(.leading, 3)
                            Text(displayName)
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                    if let subtitle {
                        Text(subtitle.text)
                            .font(.system(size: 11))
                            .foregroundColor(subtitle.warns ? .orange : .secondary)
                            .lineLimit(1)
                            .padding(.top, sessionTitle == nil ? 0 : 3)
                    }
                }
                Spacer(minLength: 0)
                if isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .help(L("고정한 세션", "Pinned"))
                }
                if isMuted {
                    Image(systemName: "bell.slash.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .help(L("소리 꺼둔 세션", "Sounds muted"))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
            .background(NotchPalette.ink.opacity(isSelected ? (hovering ? 0.11 : 0.08) : (hovering ? 0.07 : 0.035)),
                        in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                if let activeOutline {
                    TracingGlowOutline(cornerRadius: 9, color: activeOutline, since: workStart)
                } else if isSelected {
                    RoundedRectangle(cornerRadius: 9).stroke(Color.orange.opacity(0.35), lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(L("세션 진행 보기", "Show session progress"))
        .contextMenu {
            Button(isPinned ? L("고정 해제", "Unpin") : L("세션 고정", "Pin Session")) { togglePin() }
            Divider()
            ForEach(group.claude) { session in
                if let id = manager.conversationId(for: session) {
                    Button(L("Claude 세션 ID 복사 (\(id.prefix(8)))", "Copy Claude Session ID (\(id.prefix(8)))")) { copyToPasteboard(id) }
                }
                muteButton(session.id)
            }
            ForEach(group.codex) { session in
                Button(L("Codex 세션 ID 복사 (\(session.id.prefix(8)))", "Copy Codex Session ID (\(session.id.prefix(8)))")) { copyToPasteboard(session.id) }
                muteButton(session.id)
            }
        }
    }

    private func muteButton(_ sessionId: String) -> some View {
        // `settings` is observed so the label flips right after a toggle.
        Button(NotchSounds.isMuted(sessionId) ? L("이 세션 소리 켜기", "Unmute This Session") : L("이 세션 소리 끄기", "Mute This Session")) {
            NotchSounds.toggleMute(sessionId)
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
        if let host = group.claude.first?.remoteHost ?? group.codex.first?.remoteHost { return "SSH · \(host)" }
        return destination?.label ?? group.claude.first?.ideName ?? "app"
    }

    /// The session's name; the folder then moves to a smaller line under it.
    private var sessionTitle: String? {
        if let session = group.claude.first { return manager.sessionStates[session.id]?.title }
        if let session = group.codex.first { return codexManager.threadNames[session.id] }
        return nil
    }

    private var displayName: String {
        let name = URL(fileURLWithPath: group.path).lastPathComponent
        return name.isEmpty ? group.path : name
    }

    private func sourceIcon(_ name: String, glow: Color, active: Bool) -> some View {
        Image(name)
            .resizable()
            .foregroundColor(NotchPalette.ink)
            .frame(width: 12, height: 12)
            .opacity(active ? 1 : 0.55)
            .shadow(color: active ? glow.opacity(0.8) : .clear, radius: 4)
    }
}

/// 서브에이전트 줄 and 셸 줄: the subagents and background shells a Claude session is
/// running, hung under its 세션 줄. They only show; going anywhere is the session's row.
private struct SubagentRows: View {
    let subagents: [ClaudeSubagent]
    var shells: [ClaudeBackgroundShell] = []
    /// A press on a 셸 줄: its session's 세션 화면 with the shell picked.
    var openShell: (ClaudeBackgroundShell) -> Void = { _ in }
    @ObservedObject private var settings = AppSettings.shared
    /// As many as the Current Tasks 카드 lists before "+N개 더", subagents first.
    private let limit = 4
    private static let shellBlue = Color(red: 0.35, green: 0.7, blue: 1.0)

    private var shownShells: [ClaudeBackgroundShell] {
        settings.showClaudeBackgroundShells ? Array(shells.prefix(max(0, limit - subagents.count))) : []
    }
    private var total: Int { subagents.count + (settings.showClaudeBackgroundShells ? shells.count : 0) }

    var body: some View {
        if total > 0 {
            VStack(spacing: 3) {
                ForEach(subagents.prefix(limit)) { subagent in
                    // A working 세션 줄 in small: the lit Claude icon, the name over what it is
                    // doing, and the tracing outline (a row only shows while its subagent works).
                    HStack(spacing: 6) {
                        FolderElbow()
                            .stroke(Color.secondary.opacity(0.7), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
                            .frame(width: 7, height: 6)
                            .offset(y: -2.5)
                        Image("ClaudeIcon")
                            .resizable()
                            .foregroundColor(NotchPalette.ink)
                            .frame(width: 10, height: 10)
                            .shadow(color: Color.orange.opacity(0.8), radius: 3)
                            // 아이콘 모자: a subagent wears the propeller, as its copy in the wing does.
                            .overlay {
                                if settings.experimentalClaudeIconHats {
                                    ClaudeIconHatView(hat: .propeller, iconSize: 10)
                                }
                            }
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                Text(subagent.description.isEmpty ? subagent.agentType : subagent.description)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                if !subagent.description.isEmpty, !subagent.agentType.isEmpty {
                                    Text(subagent.agentType)
                                        .font(.system(size: 9.5, weight: .medium))
                                        .foregroundColor(.orange)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1.5)
                                        .background(Color.orange.opacity(0.18), in: Capsule())
                                        .fixedSize()
                                }
                            }
                            Text(activity(of: subagent))
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, 10)
                    .padding(.trailing, 8)
                    .padding(.vertical, 6)
                    .background(NotchPalette.ink.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
                    .overlay { TracingGlowOutline(cornerRadius: 7, color: Color(red: 0.9, green: 0.4, blue: 0.1),
                                                  since: subagent.startTime) }
                    .help(subagent.agentType)
                }
                ForEach(shownShells) { shell in
                    Button { openShell(shell) } label: { shellRow(shell).contentShape(Rectangle()) }
                        .buttonStyle(.plain)
                        .help(shell.command ?? shell.title)
                }
                if total > limit {
                    Text(L("+\(total - limit)개 더", "+\(total - limit) more"))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // Under the names: row padding, elbow, icon and their spacing.
                        .padding(.leading, 39)
                }
            }
            // Indented under the session's own text.
            .padding(.leading, 18)
        }
    }

    /// A 셸 줄: a 서브에이전트 줄 with a terminal for the icon and blue for orange. Under the
    /// name, a Monitor's latest line, or since when it runs (fixed text: nothing here ticks).
    /// A press opens its session's 세션 화면 on it (`openShell`).
    private func shellRow(_ shell: ClaudeBackgroundShell) -> some View {
        HStack(spacing: 6) {
            FolderElbow()
                .stroke(Color.secondary.opacity(0.7), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
                .frame(width: 7, height: 6)
                .offset(y: -2.5)
            Image(systemName: "apple.terminal")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(NotchPalette.ink)
                .frame(width: 10, height: 10)
                .shadow(color: Self.shellBlue.opacity(0.9), radius: 3)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(shell.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    if shell.isMonitor {
                        Text("Monitor")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundColor(Self.shellBlue)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1.5)
                            .background(Self.shellBlue.opacity(0.18), in: Capsule())
                            .fixedSize()
                    }
                }
                Text(shell.lastEvent ?? L("\(shell.startTime.formatted(date: .omitted, time: .shortened))부터",
                                          "Since \(shell.startTime.formatted(date: .omitted, time: .shortened))"))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .background(NotchPalette.ink.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
        .overlay { TracingGlowOutline(cornerRadius: 7, color: Self.shellBlue, since: shell.startTime) }
    }

    /// The tool the subagent is running and what on, or that it is thinking.
    private func activity(of subagent: ClaudeSubagent) -> String {
        guard let tool = subagent.tool else { return L("생각 중", "Thinking") }
        return [tool.displayName, tool.description ?? tool.argument].compactMap { $0 }.joined(separator: " · ")
    }
}

/// The └ that hangs the folder line under the session name.
private struct FolderElbow: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        return path
    }
}

/// The model the session runs, in its agent's colour. No dot before the name (user, 2026-11-26).
private struct SourceBadge: View {
    let label: String
    let color: Color
    let active: Bool

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(color.opacity(active ? 1 : 0.75))
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(color.opacity(active ? 0.18 : 0.08), in: Capsule())
    }
}
