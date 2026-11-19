import AppKit
import SwiftUI

/// The Agents tab's Sessions card as pages, one on show at a time (user, 2026-11-19):
/// - the sessions themselves, first, while there are any (`sessions`)
/// - 오늘: sessions that finished a turn today, the agents' working time and the folder used most
/// - 최근: the last sessions that finished a turn; an app's session opens in its app again, a
///   terminal's copies the command that resumes it
/// - 시작: the Claude app, a terminal, the Codex app
/// Only the page on show is drawn: laid side by side in a paging scroll view, a working row's
/// outline (a layer view, past SwiftUI's clipping) showed at the edge of the page next to it,
/// and opening the notch slid the strip over to the page last seen. Pages change with the
/// arrows and dots under them or a sideways two-finger swipe on the card, going round from the
/// last to the first; the card opens on the page last seen (without sessions, 오늘 in their place).
struct SessionCardPages<Sessions: View>: View {
    let hasSessions: Bool
    @ViewBuilder let sessions: () -> Sessions

    @ObservedObject private var log = AgentActivityLog.shared
    @ObservedObject private var settings = AppSettings.shared
    @AppStorage("idleSessionsPage") private var savedPage = Page.today.rawValue
    @State private var page: Page?
    /// Which way the last change went, for the side the new page comes in from.
    @State private var direction = 1
    /// The 최근 row whose resume command was just copied.
    @State private var copied: String?
    /// The cursor is on the card: the arrows show and a sideways swipe turns the page.
    @State private var hovering = false
    @State private var swipe = SidewaysSwipe()

    enum Page: String, CaseIterable, Identifiable {
        case sessions, today, recent, start
        var id: String { rawValue }
    }

    private var pages: [Page] { hasSessions ? Page.allCases : Page.allCases.filter { $0 != .sessions } }

    /// The page last seen, or 오늘 while that one isn't there (no sessions listed).
    private var lastSeen: Page {
        Page(rawValue: savedPage).flatMap { pages.contains($0) ? $0 : nil } ?? .today
    }

    private var current: Page { page.flatMap { pages.contains($0) ? $0 : nil } ?? lastSeen }

    var body: some View {
        VStack(spacing: 10) {
            content(current)
                .id(current)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .transition(.asymmetric(
                    insertion: .move(edge: direction > 0 ? .trailing : .leading).combined(with: .opacity),
                    removal: .move(edge: direction > 0 ? .leading : .trailing).combined(with: .opacity)))
            // A mouse has no sideways swipe: arrows at the ends of the dots' row, under the page
            // so they cover nothing.
            HStack(spacing: 0) {
                arrow(-1)
                Spacer(minLength: 0)
                dots
                Spacer(minLength: 0)
                arrow(1)
            }
        }
        .clipped()
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.15)) { hovering = inside }
            if inside { swipe.start { turn($0) } } else { swipe.stop() }
        }
        .onDisappear { swipe.stop() }
        // The sessions' page going away (the last session gone) leaves 오늘 on show; a session
        // showing up changes nothing on show (user, 2026-11-19: keep the page being looked at).
        .onChange(of: hasSessions) { _, has in
            if !has, page == .sessions { show(.today, direction: -1) }
        }
    }

    /// The page `step` away from the one on show, going round.
    private func turn(_ step: Int) {
        guard pages.count > 1, let index = pages.firstIndex(of: current) else { return }
        show(pages[(index + step + pages.count) % pages.count], direction: step)
    }

    private func show(_ target: Page, direction: Int) {
        guard target != current else { return }
        self.direction = direction
        withAnimation(.smooth(duration: 0.3)) { page = target }
        savedPage = target.rawValue
    }

    /// The page before (`-1`) or after (`1`). Its place is kept whether or not it shows, so the
    /// row doesn't shift; it shows while the cursor is on the card.
    private func arrow(_ step: Int) -> some View {
        let shown = hovering && pages.count > 1
        let target = pages.firstIndex(of: current).map { pages[($0 + step + pages.count) % pages.count] }
        return Button { turn(step) } label: {
            Image(systemName: step < 0 ? "chevron.left" : "chevron.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(NotchPalette.ink.opacity(0.8))
                .frame(width: 24, height: 20)
                .background(Capsule().fill(NotchPalette.ink.opacity(0.1)))
                .contentShape(Capsule())
        }
        .buttonStyle(NotchPressButtonStyle())
        .help(target.map(title) ?? "")
        .opacity(shown ? 1 : 0)
        .allowsHitTesting(shown)
    }

    private var dots: some View {
        HStack(spacing: 6) {
            ForEach(pages) { item in
                Button {
                    let from = pages.firstIndex(of: current) ?? 0, to = pages.firstIndex(of: item) ?? 0
                    show(item, direction: to >= from ? 1 : -1)
                } label: {
                    Circle()
                        .fill(NotchPalette.ink.opacity(current == item ? 0.75 : 0.22))
                        .frame(width: 6, height: 6)
                        .padding(3)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(title(item))
            }
        }
    }

    private func title(_ page: Page) -> String {
        switch page {
        case .sessions: return L("세션", "Sessions")
        case .today: return L("오늘", "Today")
        case .recent: return L("최근 세션", "Recent sessions")
        case .start: return L("시작", "Start")
        }
    }

    @ViewBuilder
    private func content(_ page: Page) -> some View {
        switch page {
        case .sessions: sessions()
        case .today: today
        case .recent: recent
        case .start: start
        }
    }

    // MARK: 오늘

    private var today: some View {
        let day = log.today
        return VStack(alignment: .leading, spacing: 14) {
            label(L("오늘", "Today"))
            HStack(alignment: .top, spacing: 0) {
                stat("\(day.sessions.count)", L("세션", "Sessions"))
                stat(Self.duration(day.seconds), L("일한 시간", "Agents at work"))
                stat(day.topFolder ?? "-", L("가장 많이 쓴 폴더", "Busiest folder"))
            }
            if !hasSessions {
                HStack(spacing: 6) {
                    Circle().fill(NotchPalette.ink.opacity(0.35)).frame(width: 6, height: 6)
                    Text(L("지금은 쉬는 중. 세션을 시작하면 여기에 나옵니다", "Quiet now. A session shows here once it starts"))
                        .font(.system(size: 11))
                        .foregroundStyle(NotchPalette.ink.opacity(0.45))
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func stat(_ value: String, _ name: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(name)
                .font(.system(size: 10))
                .foregroundStyle(NotchPalette.ink.opacity(0.5))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "2시간 14분", "14분", "0분".
    static func duration(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        let hours = minutes / 60
        return hours > 0 ? L("\(hours)시간 \(minutes % 60)분", "\(hours)h \(minutes % 60)m") : L("\(minutes)분", "\(minutes)m")
    }

    // MARK: 최근

    private var recent: some View {
        VStack(alignment: .leading, spacing: 6) {
            label(L("최근 세션", "Recent sessions"))
            let entries = Array(log.recent.prefix(3))
            if entries.isEmpty {
                Text(L("턴을 끝낸 세션이 여기에 남습니다", "Sessions that finish a turn stay here"))
                    .font(.system(size: 11))
                    .foregroundStyle(NotchPalette.ink.opacity(0.45))
                    .padding(.top, 6)
            }
            ForEach(entries) { entry in
                Button { resume(entry) } label: { recentRow(entry) }
                    .buttonStyle(NotchHoverButtonStyle())
                    .help(entry.inApp ? L("앱에서 이어 가기", "Continue in the app") : L("이어 가는 명령 복사", "Copy the command that resumes it"))
            }
        }
    }

    private func recentRow(_ entry: AgentActivityLog.Recent) -> some View {
        HStack(spacing: 8) {
            Image(entry.agent == .claude ? "ClaudeIcon" : "ChatGPTIcon")
                .resizable()
                .foregroundColor(NotchPalette.ink)
                .frame(width: 11, height: 11)
                .opacity(0.7)
            Text(entry.title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(NotchPalette.ink.opacity(0.8))
                .lineLimit(1)
            Text([entry.folder, entry.model.flatMap(ModelName.short)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.system(size: 10))
                .foregroundStyle(NotchPalette.ink.opacity(0.4))
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(copied == entry.id ? L("복사됨", "Copied") : entry.finished.formatted(.relative(presentation: .named)))
                .font(.system(size: 10))
                .foregroundStyle(copied == entry.id ? Color.green : NotchPalette.ink.opacity(0.4))
            Image(systemName: entry.inApp ? "arrow.up.forward.app" : "doc.on.doc")
                .font(.system(size: 9))
                .foregroundStyle(NotchPalette.ink.opacity(0.4))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    /// An app's session opens in that app again; a terminal's resume command is copied, since
    /// nothing says which terminal to run it in.
    private func resume(_ entry: AgentActivityLog.Recent) {
        switch entry.agent {
        case .claude:
            if entry.inApp,
               let link = entry.conversationId.flatMap({ SessionAppResolver.claudeDesktopSession(conversationId: $0) })
                .flatMap({ SessionAppLauncher.claudeLink(session: $0) }) {
                SessionAppLauncher.open(.claude, at: link)
                return
            }
            copy("claude --resume \(entry.conversationId ?? entry.sessionId)", for: entry)
        case .codex:
            if entry.inApp, let link = SessionAppLauncher.codexLink(thread: entry.sessionId) {
                SessionAppLauncher.open(.codex, at: link)
                return
            }
            copy("codex resume \(entry.sessionId)", for: entry)
        }
    }

    private func copy(_ command: String, for entry: AgentActivityLog.Recent) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        withAnimation(.easeOut(duration: 0.15)) { copied = entry.id }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            if copied == entry.id { withAnimation(.easeOut(duration: 0.2)) { copied = nil } }
        }
    }

    // MARK: 시작

    private var start: some View {
        VStack(alignment: .leading, spacing: 12) {
            label(L("시작", "Start"))
            HStack(spacing: 8) {
                if settings.showSourceClaudeCode, Self.installed("com.anthropic.claudefordesktop") {
                    launch(Image("ClaudeIcon").resizable(), L("Claude 앱", "Claude app"), "com.anthropic.claudefordesktop")
                }
                if let terminal = KnownTerminals.preferred {
                    launch(Image(systemName: "apple.terminal").resizable().foregroundColor(NotchPalette.accent),
                           L("터미널", "Terminal"), terminal)
                }
                if settings.showSourceCodex, Self.installed("com.openai.codex") {
                    launch(Image("ChatGPTIcon").resizable().foregroundColor(NotchPalette.ink), L("Codex 앱", "Codex app"), "com.openai.codex")
                }
            }
        }
        .padding(.vertical, 4)
    }

    private static func installed(_ bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    private func launch(_ icon: some View, _ title: String, _ bundleID: String) -> some View {
        Button {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        } label: {
            HStack(spacing: 6) {
                icon.scaledToFit().frame(width: 12, height: 12)
                Text(title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(NotchPalette.ink.opacity(0.85))
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(NotchPalette.ink.opacity(0.08)))
            .contentShape(Rectangle())
        }
        .buttonStyle(NotchPressButtonStyle())
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(NotchPalette.ink.opacity(0.4))
    }
}

/// A sideways two-finger swipe over the Sessions card, while the cursor is on it: one page per
/// swipe, the vertical scrolling left to the tab. Read from the app's own scroll events (a local
/// monitor), since SwiftUI has no swipe for the trackpad on macOS.
@MainActor
final class SidewaysSwipe {
    private var monitor: Any?
    private var travel: CGFloat = 0
    private var turned = false

    /// `onSwipe(1)` for the next page (fingers moving left), `-1` for the one before.
    func start(onSwipe: @escaping (Int) -> Void) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, event.hasPreciseScrollingDeltas else { return event }
            if event.phase == .began { travel = 0; turned = false }
            // The coasting after a swipe turns nothing more.
            guard event.momentumPhase.isEmpty else {
                return abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? nil : event
            }
            guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return event }
            travel += event.scrollingDeltaX
            if !turned, abs(travel) > 40 {
                turned = true
                onSwipe(travel < 0 ? 1 : -1)
            }
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
