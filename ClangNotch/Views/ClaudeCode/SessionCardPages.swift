import AppKit
import SwiftUI

/// The Agents tab's Sessions card as pages, one on show at a time (user, 2026-11-19):
/// - the sessions themselves, first, while there are any (`sessions`)
/// - 오늘: sessions that finished work, the agents' working time and the folder used most, for
///   오늘, 7일 or 전체 picked in a pill bar at its top (2026-11-21); the pick stays
/// - 완료 기록: the latest finishes with their answer's first line (the 완료 드롭다운 goes by in a
///   few seconds, or doesn't come at all with the notch open). One still listed opens its 세션
///   화면; one gone opens in its app again, or a terminal's copies the command that resumes it
/// - 시작: the Claude app, a terminal, the Codex app
/// Only the page on show is drawn: laid side by side in a paging scroll view, a working row's
/// outline (a layer view, past SwiftUI's clipping) showed at the edge of the page next to it,
/// and opening the notch slid the strip over to the page last seen. Pages change with the
/// arrows and dots under them or a sideways two-finger swipe on the card, going round from the
/// last to the first; the card opens on the page last seen (without sessions, 오늘 in their place).
struct SessionCardPages<Sessions: View>: View {
    let hasSessions: Bool
    /// The sessions listed now (agent:id), and what opens one's 세션 화면.
    var listed: Set<String> = []
    var openSession: (SessionDetailTarget) -> Void = { _ in }
    @ViewBuilder let sessions: () -> Sessions

    @ObservedObject private var log = AgentActivityLog.shared
    @ObservedObject private var settings = AppSettings.shared
    /// The page last seen; empty until one has been turned to.
    @AppStorage("idleSessionsPage") private var savedPage = ""
    /// The 오늘 page's span, kept across closing the notch and relaunches.
    @AppStorage("sessionCardTodaySpan") private var savedSpan = AgentActivityLog.Span.today.rawValue
    @Namespace private var spanPill
    @State private var page: Page?
    /// Which way the last change went, for the side the new page comes in from.
    @State private var direction = 1
    /// The 완료 기록 row whose resume command was just copied.
    @State private var copied: UUID?
    /// The cursor is on the card: the arrows show and a sideways swipe turns the page.
    @State private var hovering = false
    @State private var swipe = SidewaysSwipe()

    typealias Page = SessionCardPage

    /// In the order set in Settings; the sessions' page only while there are sessions, 완료 기록
    /// only once something has finished.
    private var pages: [Page] {
        Page.order(from: settings.sessionCardPageOrder).filter {
            switch $0 {
            case .sessions: return hasSessions
            case .finished: return !log.finishes.isEmpty
            case .today, .start: return true
            }
        }
    }

    /// Nothing finished yet, ever: a first run.
    private var noHistory: Bool { log.isEmpty }

    /// The page last seen. Before any: 시작 on a first run (user, 2026-11-19: a row of zeros
    /// said nothing to someone new), else 오늘. 오늘 too while the one last seen isn't there
    /// (the sessions' page with none listed).
    private var lastSeen: Page {
        if let saved = Page(rawValue: savedPage), pages.contains(saved) { return saved }
        return savedPage.isEmpty && noHistory ? .start : .today
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

    private func title(_ page: Page) -> String { page.title }

    @ViewBuilder
    private func content(_ page: Page) -> some View {
        switch page {
        case .sessions: sessions()
        case .today: today
        case .finished: finished
        case .start: start
        }
    }

    // MARK: 오늘

    private var today: some View {
        let span = AgentActivityLog.Span(rawValue: savedSpan) ?? .today
        let totals = log.totals(span)
        return VStack(alignment: .leading, spacing: 12) {
            spanBar(span)
            HStack(alignment: .top, spacing: 0) {
                stat(Text("\(totals.sessions)"), L("세션", "Sessions"))
                stat(Text(Self.duration(totals.seconds)), L("일한 시간", "Agents at work"))
                stat(Text(totals.topFolder ?? "-"), L("가장 많이 쓴 폴더", "Busiest folder"))
            }
            HStack(alignment: .top, spacing: 0) {
                stat(Text(Self.count(totals.usage.tokens)), L("토큰", "Tokens"))
                stat(lines(totals.usage), L("고친 줄", "Lines changed"))
                stat(Text(totals.usage.topModel ?? "-"), L("가장 많이 쓴 모델", "Top model"))
            }
        }
        .padding(.vertical, 4)
    }

    /// 오늘, 7일, 전체 as one pill bar, the pick a pill of its own sliding inside it.
    private func spanBar(_ selected: AgentActivityLog.Span) -> some View {
        HStack(spacing: 0) {
            ForEach(AgentActivityLog.Span.allCases) { span in
                let on = span == selected
                Button {
                    withAnimation(.smooth(duration: 0.25)) { savedSpan = span.rawValue }
                } label: {
                    Text(span.title)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(NotchPalette.ink.opacity(on ? 0.9 : 0.45))
                        .padding(.horizontal, 10)
                        .frame(height: 20)
                        .background {
                            if on {
                                Capsule()
                                    .fill(NotchPalette.ink.opacity(0.16))
                                    .matchedGeometryEffect(id: "span", in: spanPill)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(NotchPalette.ink.opacity(0.07)))
    }

    private func stat(_ value: Text, _ name: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            value
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

    /// "+1,204 −380", the added part green and the removed part red as in the 세션 화면's diff.
    private func lines(_ usage: AgentActivityLog.Usage) -> Text {
        guard usage.added + usage.removed > 0 else { return Text("0") }
        return Text("+\(usage.added.formatted())").foregroundColor(.green.opacity(0.8))
            + Text(" −\(usage.removed.formatted())").foregroundColor(.red.opacity(0.8))
    }

    /// "8,421", "3.4만", "340만", "1.2억"; in English "8,421", "34K", "3.4M", "1.2B".
    static func count(_ value: Int) -> String {
        // Korean groups by 10,000.
        let korean = L("ko", "en") == "ko"
        let units: [(Double, String)] = korean ? [(1e8, "억"), (1e4, "만")] : [(1e9, "B"), (1e6, "M"), (1e3, "K")]
        guard let (size, unit) = units.first(where: { Double(value) >= $0.0 }) else { return value.formatted() }
        let scaled = Double(value) / size
        let number = scaled < 10 ? (scaled * 10).rounded(.down) / 10 : scaled.rounded(.down)
        return number.formatted(.number.precision(.fractionLength(0...1))) + unit
    }

    /// "2시간 14분", "14분", "0분".
    static func duration(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        let hours = minutes / 60
        return hours > 0 ? L("\(hours)시간 \(minutes % 60)분", "\(hours)h \(minutes % 60)m") : L("\(minutes)분", "\(minutes)m")
    }

    // MARK: 완료 기록

    private var finished: some View {
        VStack(alignment: .leading, spacing: 4) {
            label(L("완료 기록", "Finished"))
            let entries = Array(log.finishes.prefix(4))
            ForEach(entries) { entry in
                let isListed = listed.contains(entry.sessionKey)
                Button { open(entry, listed: isListed) } label: { finishRow(entry, listed: isListed) }
                    .buttonStyle(NotchHoverButtonStyle())
                    .help(isListed ? L("세션 화면 열기", "Open the session")
                          : entry.inApp ? L("앱에서 이어 가기", "Continue in the app") : L("이어 가는 명령 복사", "Copy the command that resumes it"))
            }
        }
    }

    private func finishRow(_ entry: AgentActivityLog.Finish, listed: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(entry.agent == .claude ? "ClaudeIcon" : "ChatGPTIcon")
                .resizable()
                .foregroundColor(NotchPalette.ink)
                .frame(width: 11, height: 11)
                .opacity(0.7)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(entry.title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(NotchPalette.ink.opacity(0.85))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(copied == entry.id ? L("복사됨", "Copied") : entry.finished.formatted(.relative(presentation: .named)))
                        .font(.system(size: 10))
                        .foregroundStyle(copied == entry.id ? Color.green : NotchPalette.ink.opacity(0.4))
                }
                Text(entry.headline ?? entry.folder)
                    .font(.system(size: 10.5))
                    .foregroundStyle(NotchPalette.ink.opacity(0.5))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    /// Still listed: its 세션 화면. Gone: an app's session opens in that app again; a terminal's
    /// resume command is copied, since nothing says which terminal to run it in. Only with a
    /// real session id: the id comes from transcripts and hooks (an SSH host's too), and one
    /// like `0; curl … | sh` was pasted into a shell as it was (found 2026-11-21). Checked here,
    /// where it is used, so an entry saved before the check can't get through either.
    private func open(_ entry: AgentActivityLog.Finish, listed: Bool) {
        if listed {
            openSession(SessionDetailTarget(agent: entry.agent == .claude ? .claude : .codex, sessionId: entry.sessionId))
            return
        }
        switch entry.agent {
        case .claude:
            if entry.inApp,
               let link = entry.conversationId.flatMap({ SessionAppResolver.claudeDesktopSession(conversationId: $0) })
                .flatMap({ SessionAppLauncher.claudeLink(session: $0) }) {
                SessionAppLauncher.open(.claude, at: link)
                return
            }
            let id = entry.conversationId ?? entry.sessionId
            guard UUID(uuidString: id) != nil else { return }
            copy("claude --resume \(id)", for: entry)
        case .codex:
            if entry.inApp, let link = SessionAppLauncher.codexLink(thread: entry.sessionId) {
                SessionAppLauncher.open(.codex, at: link)
                return
            }
            guard UUID(uuidString: entry.sessionId) != nil else { return }
            copy("codex resume \(entry.sessionId)", for: entry)
        }
    }

    private func copy(_ command: String, for entry: AgentActivityLog.Finish) {
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

/// The Sessions card's pages, in the order 설정 -> 에이전트 -> Sessions 카드 페이지 keeps.
enum SessionCardPage: String, CaseIterable, Identifiable {
    case sessions, today, finished, start

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sessions: return L("세션 목록", "Session list")
        case .today: return L("오늘", "Today")
        case .finished: return L("완료 기록", "Finished")
        case .start: return L("시작", "Start")
        }
    }

    /// The saved order, then any page it doesn't name yet in the order they first had.
    static func order(from stored: String) -> [SessionCardPage] {
        var saved: [SessionCardPage] = []
        for name in stored.split(separator: ",") {
            if let page = SessionCardPage(rawValue: String(name)), !saved.contains(page) { saved.append(page) }
        }
        return saved + allCases.filter { !saved.contains($0) }
    }

    static func stored(_ pages: [SessionCardPage]) -> String { pages.map(\.rawValue).joined(separator: ",") }
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
