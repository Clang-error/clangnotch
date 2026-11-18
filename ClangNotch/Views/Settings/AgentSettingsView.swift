import AppKit
import Combine
import SwiftUI

/// Height of the window's unified toolbar, which the sidebar and the page title sit under
/// so the traffic lights, the back/forward control and the title share one line.
private let settingsTitleBarHeight: CGFloat = 52
private let settingsSidebarWidth: CGFloat = 220
/// Where the first toolbar item starts (past the traffic lights) and how wide the
/// back/forward control is, both measured on macOS 26.
private let toolbarItemsStart: CGFloat = 96
private let navControlWidth: CGFloat = 73

enum SettingsPage: String, CaseIterable, Identifiable {
    case about, general, notch, features, network, agents, security, experimental

    var id: String { rawValue }

    /// Sidebar groups, top to bottom; 정보 is the card above them.
    static let groups: [[SettingsPage]] = [[.general, .notch], [.features, .network], [.agents, .security], [.experimental]]

    var title: String {
        switch self {
        case .about:    return L("정보", "About")
        case .general:  return L("일반", "General")
        case .notch:    return L("노치", "Notch")
        case .features: return L("기능", "Features")
        case .network:  return L("네트워크", "Network")
        case .agents:   return L("에이전트", "Agents")
        case .security: return L("보안", "Security")
        case .experimental: return L("실험 기능", "Experimental")
        }
    }

    var symbol: String {
        switch self {
        case .about:    return "info"
        case .general:  return "gearshape.fill"
        case .notch:    return "macbook"
        case .features: return "square.grid.2x2.fill"
        case .network:  return "wifi"
        case .agents:   return "sparkles"
        case .security: return "lock.shield.fill"
        case .experimental: return "flask.fill"
        }
    }

    var tint: Color {
        switch self {
        case .about:    return .gray
        case .general:  return .gray
        case .notch:    return Color(white: 0.22)
        case .features: return .blue
        case .network:  return .teal
        case .agents:   return .orange
        case .security: return .red
        case .experimental: return .purple
        }
    }

    /// Words the search field matches besides the title, in both languages.
    var keywords: [String] {
        switch self {
        case .about:    return ["버전", "업데이트", "version", "updates"]
        case .general:  return ["언어", "로그인", "메뉴 막대", "배터리 절약", "language", "login", "menu bar", "battery saver"]
        case .notch:    return ["노치 색", "라이트", "다크", "배경", "탭", "순서", "열기", "햅틱", "전체 화면", "표시", "메뉴바",
                                "notch color", "light", "dark", "wallpaper", "tabs", "order", "opening", "haptic", "full screen", "visibility",
                                "디스플레이", "모니터", "화면", "display", "monitor"]
        case .features: return ["클립보드", "볼륨", "믹서", "sidecar", "배터리", "속도", "키보드", "밝기",
                                "노치 탭", "조절창", "에어팟", "드롭다운", "헤드셋", "맥 배터리",
                                "clipboard", "volume", "mixer", "battery", "speed", "keyboard", "brightness",
                                "notch tabs", "hud", "airpods", "headset",
                                "미디어", "음악", "재생", "영상", "media", "music", "now playing"]
        case .network:  return ["wi-fi", "위치", "skt", "t world", "테더링", "핫스팟", "location", "tethering", "hotspot"]
        case .agents:   return ["claude", "codex", "효과음", "알림", "사용량", "컨텍스트", "ssh", "원격",
                                "sounds", "remind", "usage", "context", "remote"]
        case .security: return ["보안", "권한", "허용", "위험", "승인", "security", "permission", "allow", "danger", "approve"]
        case .experimental: return ["실험", "codex", "claude", "질문", "답하기", "다음 단계", "모자", "효과음", "입력", "소리", "크기", "헤드폰", "이어폰", "블루투스", "단축키",
                                     "experimental", "question", "answer", "next step", "hat", "typing", "sound", "volume",
                                     "headphones", "bluetooth", "shortcut"]
        }
    }

    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return true }
        return ([title] + keywords).contains { $0.lowercased().contains(q) }
    }
}

/// Which page is shown and the back/forward history, shared by the SwiftUI view and the
/// window's toolbar. Lives outside the language `.id`, so switching language keeps the page.
@MainActor
final class SettingsNavigator: ObservableObject {
    @Published private(set) var history: [SettingsPage] = [.general]
    @Published private(set) var index = 0

    var page: SettingsPage { history[index] }
    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index < history.count - 1 }

    func open(_ target: SettingsPage) {
        guard target != page else { return }
        history = Array(history[...index]) + [target]
        index = history.count - 1
    }

    func back() { if canGoBack { index -= 1 } }
    func forward() { if canGoForward { index += 1 } }
}

/// The settings window's toolbar: an invisible spacer that pushes the back/forward control
/// to where the page column starts. A real toolbar item, because SwiftUI buttons drawn
/// under the title bar never get the click: WindowServer takes it as a window drag.
@MainActor
final class SettingsToolbarController: NSObject, NSToolbarDelegate {
    let toolbar = NSToolbar(identifier: "SettingsToolbar")
    private let navigator: SettingsNavigator
    private let navControl: NSSegmentedControl
    private var cancellable: AnyCancellable?

    private static let spacerID = NSToolbarItem.Identifier("settings.spacer")
    private static let navID = NSToolbarItem.Identifier("settings.nav")

    init(navigator: SettingsNavigator) {
        self.navigator = navigator
        navControl = NSSegmentedControl(
            images: [NSImage(systemSymbolName: "chevron.left", accessibilityDescription: L("뒤로", "Back"))!,
                     NSImage(systemSymbolName: "chevron.right", accessibilityDescription: L("앞으로", "Forward"))!],
            trackingMode: .momentary, target: nil, action: nil)
        super.init()
        navControl.target = self
        navControl.action = #selector(navigate(_:))
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        cancellable = navigator.objectWillChange.sink { [weak self] _ in
            // Fires before the change lands.
            DispatchQueue.main.async { self?.refresh() }
        }
        refresh()
    }

    @objc private func navigate(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 0 { navigator.back() } else { navigator.forward() }
    }

    private func refresh() {
        navControl.setEnabled(navigator.canGoBack, forSegment: 0)
        navControl.setEnabled(navigator.canGoForward, forSegment: 1)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.spacerID, Self.navID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.spacerID, Self.navID]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        if itemIdentifier == Self.spacerID {
            let spacer = NSView()
            spacer.translatesAutoresizingMaskIntoConstraints = false
            spacer.widthAnchor.constraint(equalToConstant: settingsSidebarWidth + 12 - toolbarItemsStart).isActive = true
            spacer.heightAnchor.constraint(equalToConstant: 1).isActive = true
            item.view = spacer
            // Bordered, it got an empty glass capsule next to the traffic lights (macOS 26+).
            item.isBordered = false
        } else {
            item.view = navControl
            item.label = L("뒤로/앞으로", "Back/Forward")
        }
        return item
    }
}

public struct AgentSettingsView: View {
    @StateObject private var settings = AppSettings.shared
    @ObservedObject var navigator: SettingsNavigator
    @State private var query = ""

    init(navigator: SettingsNavigator) {
        self.navigator = navigator
    }

    private var page: SettingsPage { navigator.page }

    public var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selection: page, query: $query, open: navigator.open)
            Divider()
            VStack(spacing: 0) {
                // The back/forward control is a toolbar item to the left of this.
                Text(page.title)
                    .font(.system(size: 15, weight: .bold))
                    .padding(.leading, 12 + navControlWidth + 12)
                    .frame(maxWidth: .infinity, minHeight: settingsTitleBarHeight,
                           maxHeight: settingsTitleBarHeight, alignment: .leading)
                pageContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Rebuilds every page when the language changes; the picker lives on 일반.
        .id(settings.settingsLanguage)
        .background {
            Group {
                Button("", action: navigator.back).keyboardShortcut("[", modifiers: .command)
                Button("", action: navigator.forward).keyboardShortcut("]", modifiers: .command)
            }
            .opacity(0)
        }
        // The window's height (600, set where it is made), not a fixed one: a fixed 600 asked for
        // 600 below the toolbar, so the window grew 52pt and that strip stayed empty (2026-11-11).
        .frame(width: 780)
        .frame(maxHeight: .infinity)
        .ignoresSafeArea(.container, edges: .top)
    }

    @ViewBuilder
    private var pageContent: some View {
        switch page {
        case .about:    AboutSettingsTab(settings: settings)
        case .general:  AppGeneralSettingsTab(settings: settings)
        case .notch:    NotchSettingsTab(settings: settings)
        case .features: FeaturesSettingsTab(settings: settings)
        case .network:  NetworkSettingsTab(settings: settings)
        case .agents:   AgentsSettingsTab(settings: settings)
        case .security: SecuritySettingsTab(settings: settings)
        case .experimental: ExperimentalSettingsTab(settings: settings)
        }
    }
}

// MARK: - Sidebar

private struct SettingsSidebar: View {
    let selection: SettingsPage
    @Binding var query: String
    let open: (SettingsPage) -> Void
    @ObservedObject private var updates = UpdateChecker.shared

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: settingsTitleBarHeight)
            searchField
                .padding(.bottom, 10)
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                aboutCard
                    .padding(.bottom, 12)
                ForEach(SettingsPage.groups.indices, id: \.self) { index in
                    VStack(spacing: 2) {
                        ForEach(SettingsPage.groups[index]) { row($0) }
                    }
                    .padding(.bottom, 12)
                }
            } else {
                let found = SettingsPage.allCases.filter { $0.matches(query) }
                VStack(spacing: 2) {
                    ForEach(found) { row($0) }
                }
                if found.isEmpty {
                    Text(L("결과 없음", "No results"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                }
            }
            Spacer(minLength: 0)
            if let version = updates.readyVersion {
                updateButton(version)
                    .padding(.bottom, 10)
            }
        }
        .padding(.horizontal, 10)
        .frame(width: settingsSidebarWidth)
        .background(Color.primary.opacity(0.025))
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField(L("설정 검색", "Search Settings"), text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
    }

    /// The 정보 page's entry: app icon, name and version, like a status card.
    private var aboutCard: some View {
        Button { open(.about) } label: {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 32, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text("ClangNotch")
                        .font(.system(size: 13, weight: .semibold))
                    Text(L("버전 \(version)", "Version \(version)"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 46)
            .background(selectionBackground(selection == .about))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 사이드바 업데이트 버튼: at the foot of the sidebar while a newer version is downloaded and
    /// waiting, on every page, for whoever doesn't find 설정 -> 정보 (user, 2026-11-16).
    private func updateButton(_ version: String) -> some View {
        Button { updates.install() } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 17))
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("재시작해서 업데이트", "Restart to Update"))
                        .font(.system(size: 12, weight: .semibold))
                    Text(L("새 버전 \(version) 준비됨", "Version \(version) is ready"))
                        .font(.system(size: 10))
                        .opacity(0.8)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.accentColor))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(updates.isInstalling)
    }

    private func row(_ page: SettingsPage) -> some View {
        Button { open(page) } label: {
            HStack(spacing: 10) {
                SettingsPageIcon(page: page)
                Text(page.title)
                    .font(.system(size: 13, weight: selection == page ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(selectionBackground(selection == page))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func selectionBackground(_ selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(selected ? Color.primary.opacity(0.08) : .clear)
    }
}

/// A white symbol on a coloured rounded square, like System Settings' sidebar.
private struct SettingsPageIcon: View {
    let page: SettingsPage

    var body: some View {
        if page == .about {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(page.tint.gradient)
                .frame(width: 22, height: 22)
                .overlay(
                    Image(systemName: page.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                )
        }
    }
}

#Preview {
    AgentSettingsView(navigator: SettingsNavigator())
}
