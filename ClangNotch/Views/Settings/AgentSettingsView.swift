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
    case about, general, notch, features, network, agents

    var id: String { rawValue }

    /// Sidebar groups, top to bottom; 정보 is the card above them.
    static let groups: [[SettingsPage]] = [[.general, .notch], [.features, .network], [.agents]]

    var title: String {
        switch self {
        case .about:    return L("정보", "About")
        case .general:  return L("일반", "General")
        case .notch:    return L("노치", "Notch")
        case .features: return L("기능", "Features")
        case .network:  return L("네트워크", "Network")
        case .agents:   return L("에이전트", "Agents")
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
        }
    }

    /// Words the search field matches besides the title, in both languages.
    var keywords: [String] {
        switch self {
        case .about:    return ["버전", "업데이트", "version", "updates"]
        case .general:  return ["언어", "로그인", "메뉴 막대", "배터리 절약", "language", "login", "menu bar", "battery saver"]
        case .notch:    return ["노치 색", "라이트", "다크", "배경", "탭", "순서", "열기", "햅틱", "전체 화면", "표시",
                                "notch color", "light", "dark", "wallpaper", "tabs", "order", "opening", "haptic", "full screen", "visibility"]
        case .features: return ["클립보드", "볼륨", "믹서", "sidecar", "배터리", "속도", "키보드", "밝기",
                                "clipboard", "volume", "mixer", "battery", "speed", "keyboard", "brightness"]
        case .network:  return ["wi-fi", "위치", "skt", "t world", "테더링", "핫스팟", "location", "tethering", "hotspot"]
        case .agents:   return ["claude", "codex", "효과음", "알림", "사용량", "컨텍스트", "ssh", "원격",
                                "sounds", "remind", "usage", "context", "remote"]
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
        .frame(width: 780, height: 600)
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
        }
    }
}

// MARK: - Sidebar

private struct SettingsSidebar: View {
    let selection: SettingsPage
    @Binding var query: String
    let open: (SettingsPage) -> Void

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

/// 설정 › 노치 › 노치 색: four picture tiles, each a small notch over a desktop.
private struct NotchAppearancePicker: View {
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 14) {
            ForEach(NotchAppearanceMode.allCases, id: \.self) { mode in
                let selected = selection == mode.rawValue
                Button { selection = mode.rawValue } label: {
                    VStack(spacing: 6) {
                        NotchAppearanceTile(mode: mode)
                            .frame(width: 92, height: 60)
                            .padding(3)
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2.5))
                        Text(title(mode))
                            .font(.callout.weight(selected ? .semibold : .regular))
                            .foregroundStyle(selected ? .primary : .secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    private func title(_ mode: NotchAppearanceMode) -> String {
        switch mode {
        case .wallpaper: return L("배경 따라", "Wallpaper")
        case .auto:      return L("자동", "Auto")
        case .light:     return L("라이트", "Light")
        case .dark:      return L("다크", "Dark")
        }
    }
}

/// 배경 따라's colour: read from the wallpaper, or picked off the screen with the eyedropper.
private struct WallpaperColorSource: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var appearance = NotchAppearance.shared

    var body: some View {
        Picker(L("색 가져오기", "Colour from"), selection: $settings.notchWallpaperSource) {
            Text(L("바탕화면에서", "Wallpaper")).tag("wallpaper")
            Text(L("직접 지정", "Custom")).tag("custom")
        }
        .pickerStyle(.segmented)

        if settings.notchWallpaperSource == "custom" {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("스포이드", "Eyedropper"))
                    Text(L("화면 아무 곳이나 눌러 그 색을 노치에 칠함", "Click anywhere on screen to paint the notch that colour"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let color = NotchAppearance.color(hex: settings.notchCustomColor) {
                    Circle()
                        .fill(Color(nsColor: color))
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.2), lineWidth: 1))
                        .frame(width: 20, height: 20)
                        .help(settings.notchCustomColor)
                }
                Button {
                    NSColorSampler().show { picked in
                        guard let picked else { return }
                        Task { @MainActor in settings.notchCustomColor = NotchAppearance.hex(picked) }
                    }
                } label: {
                    Label(L("색 찍기", "Pick"), systemImage: "eyedropper")
                }
            }
        } else if appearance.wallpaperUnreadable {
            Text(L("폴더로 바뀌는 바탕화면은 지금 사진을 알 수 없어 다크로 표시 · 직접 지정 권장",
                   "A rotating wallpaper folder doesn't say which picture is showing, so the notch stays dark · use Custom"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct NotchAppearanceTile: View {
    let mode: NotchAppearanceMode

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        ZStack {
            switch mode {
            case .wallpaper:
                scene(desktop: [Color(red: 0.95, green: 0.55, blue: 0.35), Color(red: 0.45, green: 0.25, blue: 0.6)],
                      surface: Color(red: 0.93, green: 0.58, blue: 0.42), ink: .black)
            case .auto:
                scene(desktop: desktop, surface: Color(white: 0.96), ink: .black)
                scene(desktop: desktop, surface: .black, ink: .white)
                    .mask(DiagonalHalf())
            case .light:
                scene(desktop: desktop, surface: Color(white: 0.96), ink: .black)
            case .dark:
                scene(desktop: desktop, surface: .black, ink: .white)
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
    }

    private var desktop: [Color] {
        [Color(red: 0.2, green: 0.45, blue: 0.85), Color(red: 0.08, green: 0.2, blue: 0.5)]
    }

    /// A desktop with an open notch hanging from the top edge, two lines of text in it.
    private func scene(desktop: [Color], surface: Color, ink: Color) -> some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: desktop, startPoint: .topLeading, endPoint: .bottomTrailing)
            UnevenRoundedRectangle(bottomLeadingRadius: 8, bottomTrailingRadius: 8, style: .continuous)
                .fill(surface)
                .frame(width: 64, height: 36)
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 4) {
                        Capsule().fill(ink.opacity(0.85)).frame(width: 30, height: 4)
                        Capsule().fill(ink.opacity(0.4)).frame(width: 44, height: 4)
                        Capsule().fill(ink.opacity(0.4)).frame(width: 22, height: 4)
                    }
                    .padding(.top, 9)
                    .padding(.leading, 8)
                }
        }
    }
}

/// The lower-right triangle of the tile, for 자동's half-light, half-dark tile.
private struct DiagonalHalf: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.maxX * 0.62, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.maxX * 0.38, y: rect.maxY))
            p.closeSubpath()
        }
    }
}

/// A switch with what it does in one line under it, so no setting needs a paragraph.
private struct SettingToggle: View {
    let title: String
    let caption: String
    @Binding var isOn: Bool

    init(_ title: String, _ caption: String, isOn: Binding<Bool>) {
        self.title = title
        self.caption = caption
        self._isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - General

struct AppGeneralSettingsTab: View {
    @ObservedObject var settings: AppSettings
    @State private var launchAtLogin = LoginItem.isEnabled

    var body: some View {
        Form {
            Section {
                Picker(L("표시 언어", "Display language"), selection: $settings.settingsLanguage) {
                    Text("한국어").tag("ko")
                    Text("English").tag("en")
                }
            } header: {
                Text(L("언어", "Language"))
            }

            Section {
                Toggle(L("로그인 시 실행", "Launch at login"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        LoginItem.setEnabled(newValue)
                    }
                SettingToggle(L("메뉴 막대 아이콘 표시", "Show menu bar icon"),
                              L("세션 수·키보드 잠금·설정을 메뉴 막대에서 열기", "Sessions, keyboard lock and settings from the menu bar"),
                              isOn: $settings.showMenuBarItem)
            } header: {
                Text(L("시작", "Startup"))
            }

            Section {
                SettingToggle(L("배터리 절약 모드", "Battery saver mode"),
                              L("배터리 사용 시 글로우 애니메이션을 줄여 배터리 절약",
                                "Less glow animation on battery to save power"),
                              isOn: $settings.batterySaverEnabled)
            } header: {
                Text(L("성능", "Performance"))
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

// MARK: - About

struct AboutSettingsTab: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var updates = UpdateChecker.shared
    @State private var copied = false

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 6) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 96, height: 96)
                        // The icon file is a full square (macOS 26 masks it itself); give it
                        // the same continuous rounded corners here.
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    Text("ClangNotch")
                        .font(.title2.weight(.semibold))
                    // Click to copy, for bug reports.
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(version, forType: .string)
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.2))
                            copied = false
                        }
                    } label: {
                        Text(copied ? L("복사됨", "Copied") : L("버전 \(version)", "Version \(version)"))
                            .monospacedDigit()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(L("눌러서 복사", "Click to copy"))
                    Text(L("개발자 Clang_error", "Developer: Clang_error"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }

            Section {
                Toggle(L("업데이트 알림 받기", "Notify about updates"), isOn: $settings.checkForUpdates)
                    .onChange(of: settings.checkForUpdates) { _, _ in updates.syncWithSettings() }
                if let version = updates.availableVersion {
                    HStack {
                        Text(L("새 버전 \(version)", "Version \(version) available"))
                        Spacer()
                        Button(L("받기", "Download")) { NSWorkspace.shared.open(updates.releaseURL) }
                    }
                }
            } header: {
                Text(L("업데이트", "Updates"))
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

// MARK: - Notch

/// The notch itself: which tabs exist, in what order, and how it opens.
struct NotchSettingsTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                NotchAppearancePicker(selection: $settings.notchAppearance)
                if settings.notchAppearance == NotchAppearanceMode.wallpaper.rawValue {
                    WallpaperColorSource(settings: settings)
                }
            } header: {
                Text(L("노치 색", "Notch color"))
            }

            Section {
                NotchTabOrderView()
            } header: {
                Text(L("탭", "Tabs"))
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(L("열리기까지 기다리는 시간", "Delay before opening"))
                        Spacer()
                        Text(String(format: L("%.1f초", "%.1fs"), settings.notchOpenDelay))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $settings.notchOpenDelay, in: 0...1, step: 0.05)
                    Text(L("커서를 노치에 위 시간만큼 올려 둬야 열림",
                           "Opens after the cursor rests on the notch this long"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                SettingToggle(L("열릴 때 햅틱", "Haptic on open"),
                              L("노치가 펼쳐질 때 트랙패드 햅틱", "Trackpad haptic when the notch opens"),
                              isOn: $settings.notchHapticsEnabled)
                SettingToggle(L("끝날 때 햅틱", "Haptic when done"),
                              L("세션이 작업을 끝내면 트랙패드 햅틱", "Trackpad haptic when a session finishes"),
                              isOn: $settings.doneHapticsEnabled)
                if settings.notchHapticsEnabled || settings.doneHapticsEnabled {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(L("햅틱 세기", "Haptic strength"))
                            Spacer()
                            Text("\(settings.notchHapticStrength)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: Binding(get: { Double(settings.notchHapticStrength) },
                                              set: { settings.notchHapticStrength = Int($0.rounded()) }),
                               in: 1...8, step: 1)
                            .onChange(of: settings.notchHapticStrength) { _, strength in
                                TrackpadHaptics.tap(strength: strength)
                            }
                    }
                }
            } header: {
                Text(L("열기와 햅틱", "Opening and haptics"))
            }

            Section {
                SettingToggle(L("전체 화면에서도 표시", "Show in full screen"),
                              L("전체 화면 앱 위에도 노치 유지", "Keeps the notch over full-screen apps"),
                              isOn: $settings.keepNotchInFullScreen)
            } header: {
                Text(L("표시", "Visibility"))
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

// MARK: - Features

/// The utility features behind the notch's tabs.
struct FeaturesSettingsTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                SettingToggle(L("클립보드 기록", "Clipboard history"),
                              L("최근 복사한 글", "Recently copied text"),
                              isOn: $settings.enableClipboardHistory)
                    .onChange(of: settings.enableClipboardHistory) { _, _ in
                        ClipboardManager.shared.syncWithSettings()
                    }
                SettingToggle(L("앱별 볼륨 믹서", "Per-app volume mixer"),
                              L("앱마다 소리 크기 조절 · 오디오 캡처 권한 필요", "Volume per app · needs audio-capture permission"),
                              isOn: $settings.enableAudioMixer)
                    .onChange(of: settings.enableAudioMixer) { _, on in
                        if on { AudioMixerManager.shared.start() } else { AudioMixerManager.shared.stop() }
                    }
                SettingToggle(L("Sidecar 빠른 연결", "Sidecar quick-connect"),
                              L("iPad를 보조 화면으로 바로 연결", "Connect an iPad as a second display"),
                              isOn: $settings.enableSidecar)
                    .onChange(of: settings.enableSidecar) { _, on in
                        // The Sidecar tab starts it when shown.
                        if !on { SidecarManager.shared.stop() }
                    }
                SettingToggle(L("배터리 잔량", "Battery levels"),
                              L("Mac·블루투스 기기·iPhone의 배터리", "The Mac, Bluetooth accessories and iPhone"),
                              isOn: $settings.enableBattery)
                SettingToggle(L("에어팟 연결 알림", "AirPods connection card"),
                              L("에어팟이나 블루투스 헤드셋을 연결하면 노치 아래에 이름과 잔량 표시 · 배터리 잔량이 켜져 있어야 함",
                                "Name and battery under the notch when AirPods or a Bluetooth headset connect · needs Battery levels"),
                              isOn: $settings.enableAirPodsDropdown)
                    .disabled(!settings.enableBattery)
                SettingToggle(L("에어팟 연결 알림 자동으로 접기", "Fold the AirPods card by itself"),
                              L("6초 뒤 저절로 접음 · 끄면 X를 누르거나 노치 쪽으로 밀어 넣을 때까지 떠 있음",
                                "Folds after 6 seconds · off, it stays until you press X or push it up into the notch"),
                              isOn: $settings.airPodsDropdownAutoHide)
                    .disabled(!settings.enableBattery || !settings.enableAirPodsDropdown)
                SettingToggle(L("인터넷 속도 측정", "Internet speed test"),
                              L("측정할 때만 네트워크 사용", "Uses the network only while testing"),
                              isOn: $settings.enableSpeedTest)
                SettingToggle(L("키보드 잠금", "Keyboard lock"),
                              L("키보드 입력 잠금 · 손쉬운 사용 권한 필요", "Locks keyboard input · needs Accessibility"),
                              isOn: $settings.enableKeyboardLock)
                SettingToggle(L("볼륨·밝기 표시 바꾸기", "Replace volume and brightness HUD"),
                              L("macOS 볼륨·밝기 표시 대신 노치 중앙에 배치한 조절창 사용 · 손쉬운 사용 권한 필요",
                                "A HUD centered at the notch instead of macOS's volume and brightness display · needs Accessibility"),
                              isOn: $settings.centerSystemBanners)
                    .onChange(of: settings.centerSystemBanners) { _, _ in
                        SystemBannerCenterer.shared.syncWithSettings()
                    }
                SettingToggle(L("볼륨 조절 안 되는 모니터 소리 줄이기", "Volume for monitors without volume control"),
                              L("HDMI·DisplayPort 스피커로 가는 소리를 가로채 줄여서 다시 재생 · 볼륨·밝기 표시 바꾸기가 켜져 있어야 함",
                                "Intercepts sound headed to HDMI or DisplayPort speakers and replays it quieter · needs Replace volume and brightness HUD"),
                              isOn: $settings.enableSoftwareVolume)
                    .disabled(!settings.centerSystemBanners)
                    .onChange(of: settings.enableSoftwareVolume) { _, _ in
                        SoftwareVolume.shared.apply()
                    }
                if settings.enableSoftwareVolume && settings.centerSystemBanners {
                    SoftwareVolumeExcludedApps(settings: settings)
                }
            } header: {
                Text(L("기능", "Features"))
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

/// Apps "볼륨 조절 안 되는 모니터 소리 줄이기" leaves alone, so they keep their own sound path
/// (a screen-share that skips its own audio, say). Stored as bundle IDs.
private struct SoftwareVolumeExcludedApps: View {
    @ObservedObject var settings: AppSettings

    private var bundleIDs: [String] {
        settings.softwareVolumeExcludedApps.split(separator: "\n").map(String.init)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("제외할 앱", "Apps left out"))
            Text(L("가로채지 않아 볼륨 키로 안 줄어듦 · 화면 공유에 다른 사람 소리가 섞이는 앱(디스코드 등)",
                   "Not intercepted, so the volume keys don't turn them down · apps whose screen share picks up other people's voices (Discord, …)"))
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(bundleIDs, id: \.self) { id in
                HStack(spacing: 8) {
                    let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
                    if let url {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                            .resizable()
                            .frame(width: 18, height: 18)
                    }
                    Text(url.map { FileManager.default.displayName(atPath: $0.path) } ?? id)
                    Spacer()
                    Button {
                        set(bundleIDs.filter { $0 != id })
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
            Button(L("앱 추가…", "Add App…"), action: add)
        }
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let added = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
        set(bundleIDs + added.filter { !bundleIDs.contains($0) })
    }

    private func set(_ ids: [String]) {
        settings.softwareVolumeExcludedApps = ids.joined(separator: "\n")
        SoftwareVolume.shared.apply()
    }
}

// MARK: - Network

/// Wi-Fi name, the SKT shared-data balance and tethering places.
struct NetworkSettingsTab: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var network = NetworkInfoManager.shared

    var body: some View {
        Form {
            Section {
                SettingToggle(L("Wi-Fi 이름 표시", "Show Wi-Fi name"),
                              L("Speed 탭과 아래 기능에 사용 · macOS가 위치 권한 요구(위치는 다른 데 안 씀)",
                                "Used by the Speed tab and the features below · macOS requires Location access (used for nothing else)"),
                              isOn: $settings.enableNetworkName)
                    .onChange(of: settings.enableNetworkName) { _, on in
                        if on { network.requestAccess() } else { network.refresh() }
                    }
                if settings.enableNetworkName {
                    LabeledContent(L("위치 서비스", "Location Services")) {
                        HStack(spacing: 8) {
                            Text(networkPermissionStatus)
                                .foregroundColor(.secondary)
                            if !network.hasLocationAccess {
                                Button(network.authorization == .notDetermined ? L("허용…", "Allow…") : L("시스템 설정 열기", "Open System Settings")) {
                                    network.requestAccess()
                                }
                            }
                        }
                    }
                }
            } header: {
                Text(L("네트워크 이름", "Network name"))
            }

            TWorldSettingsView()

            TetherPlacesSettingsView()
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var networkPermissionStatus: String {
        switch network.authorization {
        case .authorizedAlways: return L("허용됨", "Allowed")
        case .denied:           return L("거부됨", "Denied")
        case .restricted:       return L("제한됨", "Restricted")
        case .notDetermined:    return L("아직 요청 안 함", "Not asked yet")
        @unknown default:       return L("사용 불가", "Unavailable")
        }
    }
}

// MARK: - Agents

/// Which coding agents are tracked, and how their activity reads in the notch.
/// The shared settings first, then one section per agent, so nothing about an agent is
/// split across the page.
struct AgentsSettingsTab: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var remote = RemoteClaudeManager.shared

    /// One switch per agent: showing it in the notch and reading its session logs go together.
    private var claudeEnabled: Binding<Bool> {
        Binding(get: { settings.showSourceClaudeCode && settings.enableClaudeCodeJSONL },
                set: { settings.showSourceClaudeCode = $0; settings.enableClaudeCodeJSONL = $0 })
    }

    private var codexEnabled: Binding<Bool> {
        Binding(get: { settings.showSourceCodex && settings.enableCodexJSONL },
                set: { settings.showSourceCodex = $0; settings.enableCodexJSONL = $0 })
    }

    var body: some View {
        Form {
            Section {
                Toggle(L("효과음", "Sounds"), isOn: $settings.notchSoundsEnabled)
                HStack(spacing: 8) {
                    Text(L("효과음 크기", "Sound volume"))
                    Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                    // Letting go plays the done sound at the new level.
                    Slider(value: $settings.notchSoundsVolume, in: 0...1) { editing in
                        if !editing { NotchSounds.playDone() }
                    }
                    Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                }
                .disabled(!settings.notchSoundsEnabled)
                Picker(L("답을 기다리면 다시 알림", "Remind while waiting"), selection: $settings.attentionReminderMinutes) {
                    Text(L("안 함", "Never")).tag(0)
                    Text(L("3분마다", "Every 3 min")).tag(3)
                    Text(L("5분마다", "Every 5 min")).tag(5)
                    Text(L("10분마다", "Every 10 min")).tag(10)
                }
                .disabled(!settings.notchSoundsEnabled)
                Toggle(L("화면이 잠겨 있으면 소리 끄기", "Mute while the screen is locked"), isOn: $settings.muteSoundsWhenLocked)
                    .disabled(!settings.notchSoundsEnabled)
                SettingToggle(L("사용량 추정", "Usage forecast"),
                              L("지금 속도로 쓰면 리셋 때 몇 %일지 예측",
                                "Predicts the % at reset at the current pace"),
                              isOn: $settings.usagePaceEnabled)
                SettingToggle(L("컨텍스트 막대 표시", "Show context bar"),
                              L("세션 화면 맨 위에 컨텍스트를 얼마나 썼는지 표시",
                                "How much context is used, atop the session view"),
                              isOn: $settings.showContextProgress)
                // Covers Codex approvals too, so it isn't under Claude Code.
                Toggle(L("권한 대기 표시 (날개의 Needs OK)", "Show permission indicator (Needs OK on the wing)"), isOn: $settings.showPermissionIndicator)
                    .disabled(!claudeEnabled.wrappedValue && !codexEnabled.wrappedValue)
            } header: {
                Text(L("공통 · Claude Code · Codex", "Shared · Claude Code · Codex"))
            }

            Section {
                Toggle(L("사용", "Enabled"), isOn: claudeEnabled)
                Toggle(L("할 일 목록 표시 (Current Tasks 카드)", "Show todo list (Current Tasks card)"), isOn: $settings.showTodoList)
                    .disabled(!claudeEnabled.wrappedValue)
                SettingToggle(L("사용량 한도 추적", "Enable usage quota tracking"),
                              L("Claude Code 로그인 정보로 5시간·주간 한도 확인 · 키체인 확인 창이 한 번 뜰 수 있음",
                                "Checks the 5-hour and weekly limits with Claude Code's sign-in · Keychain may ask once"),
                              isOn: $settings.enableClaudeUsage)
                ClaudeUsageSettingsView()
                    .disabled(!settings.enableClaudeUsage)
                HStack {
                    TextField(L("원격 SSH 호스트", "Remote SSH hosts"), text: $settings.remoteClaudeHosts, prompt: Text("myserver, other-host"))
                        .onSubmit { remote.apply() }
                    Button(L("연결", "Connect")) { remote.apply() }
                }
                ForEach(remote.statuses.keys.sorted(), id: \.self) { host in
                    LabeledContent(host, value: remote.statuses[host] ?? "")
                }
            } header: {
                Text("Claude Code")
            }

            Section {
                Toggle(L("사용", "Enabled"), isOn: codexEnabled)
            } header: {
                Text("Codex")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

#Preview {
    AgentSettingsView(navigator: SettingsNavigator())
}
