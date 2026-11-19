import SwiftUI

struct BatteryView: View {
    @ObservedObject var manager: BatteryManager
    @ObservedObject private var settings = AppSettings.shared
    /// The Mac's row clicked open: the energy mode switch and the power coming in under it.
    @State private var macOpen = false

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 6) {
                ForEach(manager.lowPriorityDevices) { low in
                    lowBatteryBadgeRow(low)
                }
                if !BatteryManager.hasIOSTools && !DemoMode.isActive { iosToolsRow }
                if manager.devices.isEmpty {
                    emptyState
                } else {
                    ForEach(manager.devices) { device in
                        BatteryRow(device: device, pinned: headerIDs.contains(device.id),
                                   closedRank: closedIDs.firstIndex(of: device.id),
                                   energyMode: device.id == "mac" ? manager.macEnergyMode : nil,
                                   opened: device.id == "mac" ? macOpen : nil)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                guard device.id == "mac" else { return }
                                withAnimation(.smooth(duration: 0.25)) { macOpen.toggle() }
                                manager.watchMacPower(macOpen)
                            }
                            .contextMenu {
                                Button(headerIDs.contains(device.id) ? L("헤더에서 빼기", "Remove from header") : L("헤더에 표시", "Show in header")) {
                                    toggleHeader(device.id)
                                }
                                Divider()
                                if let rank = closedIDs.firstIndex(of: device.id) {
                                    if rank > 0 {
                                        Button(L("닫힌 노치 순위 올리기", "Move up in closed notch")) { moveClosed(device.id, by: -1) }
                                    }
                                    if rank < closedIDs.count - 1 {
                                        Button(L("닫힌 노치 순위 내리기", "Move down in closed notch")) { moveClosed(device.id, by: 1) }
                                    }
                                    Button(L("닫힌 노치에서 빼기", "Remove from closed notch")) { setClosedIDs(closedIDs.filter { $0 != device.id }) }
                                } else {
                                    Button(L("닫힌 노치 경고에 추가 (\(closedIDs.count + 1)순위)", "Add to closed-notch warning (#\(closedIDs.count + 1))")) {
                                        setClosedIDs(closedIDs + [device.id])
                                    }
                                }
                            }
                        if device.live, device.onlyOverUSB == true { usbOnlyHint(device) }
                        if device.id == "mac", macOpen {
                            MacEnergyPanel(manager: manager)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                }
                if !DemoMode.isActive { refreshRow }
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { manager.start() }
        .onDisappear { macOpen = false; manager.stop() }
    }

    /// 순위 기기가 부족할 때만 기기마다 나온다. 끄면 그 기기가 20%를 넘을 때까지 닫힌 노치에서 숨기고,
    /// 다음 순위 기기가 부족하면 그게 대신 뜬다.
    private func lowBatteryBadgeRow(_ device: BatteryDevice) -> some View {
        let snoozed = manager.snoozedIDs.contains(device.id)
        return HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundColor(Color(red: 0.95, green: 0.35, blue: 0.35))
            VStack(alignment: .leading, spacing: 1) {
                Text(L("닫힌 노치에 \(device.name) \(device.displayLevel)% 표시", "Showing \(device.name) \(device.displayLevel)% in the closed notch"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(NotchPalette.ink)
                    .lineLimit(1)
                if snoozed {
                    Text(L("20%를 넘으면 다시 켜집니다", "Turns back on above 20%"))
                        .font(.system(size: 10))
                        .foregroundColor(NotchPalette.ink.opacity(0.5))
                }
            }
            Spacer(minLength: 0)
            Toggle("", isOn: Binding(
                get: { !snoozed },
                set: { manager.setSnoozed(!$0, for: device.id) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(red: 0.95, green: 0.35, blue: 0.35).opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 6)
    }

    /// Under an iPhone or iPad that only shows over USB: what to turn on in Finder so it shows
    /// without the cable (a user read the feature as "only while plugged in", 2026-11-17).
    private func usbOnlyHint(_ device: BatteryDevice) -> some View {
        let model = device.symbol == "ipad" ? "iPad" : "iPhone"
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: "wifi")
                .font(.system(size: 11))
                .foregroundColor(NotchPalette.ink.opacity(0.6))
            VStack(alignment: .leading, spacing: 2) {
                Text(L("USB 연결 없이도 보려면", "To see it without a USB connection"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(NotchPalette.ink.opacity(0.85))
                Text(L("Finder에서 이 \(model)을 고르고 'Wi-Fi에 연결되어 있을 때 이 \(model) 보기'를 켜세요",
                       "Select this \(model) in Finder and turn on 'Show this \(model) when on Wi-Fi'"))
                    .font(.system(size: 11))
                    .foregroundColor(NotchPalette.ink.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 4)
    }

    /// 아이폰 도구 줄: shown until libimobiledevice is installed.
    private var iosToolsRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "iphone")
                .font(.system(size: 11))
                .foregroundColor(NotchPalette.ink.opacity(0.6))
            Text(L("아이폰·아이패드 배터리를 보려면 도구 설치가 필요합니다", "Install a tool to see iPhone and iPad batteries"))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(NotchPalette.ink.opacity(0.8))
                .lineLimit(1)
            Spacer(minLength: 0)
            Button(L("설치", "Install")) { BatteryManager.installIOSTools() }
                .controlSize(.small)
                .help(L("터미널에서 Homebrew와 libimobiledevice를 설치합니다", "Installs Homebrew and libimobiledevice in Terminal"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .notchCard(cornerRadius: 12)
        .padding(.horizontal, 6)
    }

    private var headerIDs: [String] {
        settings.headerBatteryDeviceIDs.split(separator: "\n").map(String.init)
    }

    /// One header device: showing another takes the place of the one there (2026-11-19).
    private func toggleHeader(_ id: String) {
        settings.headerBatteryDeviceIDs = headerIDs.contains(id) ? "" : id
    }

    /// 닫힌 노치 경고 순위, 앞이 1순위.
    private var closedIDs: [String] {
        settings.closedBatteryPriorityIDs.split(separator: "\n").map(String.init)
    }

    private func setClosedIDs(_ ids: [String]) {
        settings.closedBatteryPriorityIDs = ids.joined(separator: "\n")
    }

    /// 바로 위나 아래 순위와 자리를 바꾼다.
    private func moveClosed(_ id: String, by offset: Int) {
        var ids = closedIDs
        guard let index = ids.firstIndex(of: id), ids.indices.contains(index + offset) else { return }
        ids.swapAt(index, index + offset)
        setClosedIDs(ids)
    }

    /// 다시 찾기 (user, 2026-11-18): asks every device now instead of at the next pass (5 minutes,
    /// 1 while this tab shows), for one nearby that hasn't been asked yet. One pass at a time: it
    /// starts several helper processes.
    private var refreshRow: some View {
        HStack {
            Spacer()
            Button { manager.refresh() } label: {
                HStack(spacing: 4) {
                    if manager.isRefreshing {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    Text(manager.isRefreshing ? L("찾는 중", "Looking") : L("다시 찾기", "Look again"))
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(NotchPalette.ink.opacity(0.55))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(NotchPalette.ink.opacity(0.06)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(manager.isRefreshing)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "battery.0")
                .font(.system(size: 30, weight: .light))
                .foregroundColor(NotchPalette.ink.opacity(0.25))
            Text(L("기기를 찾지 못했습니다", "No devices found"))
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(NotchPalette.ink.opacity(0.5))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
    }
}

private struct BatteryRow: View {
    let device: BatteryDevice
    let pinned: Bool
    /// 닫힌 노치 경고 순위(0 = 1순위). 지정 안 했으면 nil.
    let closedRank: Int?
    /// The Mac's row only: 자동, 저전력 or 고성능 after its name.
    var energyMode: MacEnergyMode? = nil
    /// The Mac's row only: whether it is clicked open. The chevron at its end says it opens at all.
    var opened: Bool? = nil

    private let good = Color(red: 0.3, green: 0.85, blue: 0.55)
    private let warn = Color(red: 1.0, green: 0.78, blue: 0.3)
    private let critical = Color(red: 0.95, green: 0.35, blue: 0.35)

    private var tone: Color {
        if device.percent <= 20 { return critical }
        if device.percent <= 40 { return warn }
        return good
    }

    /// 캐시값은 실시간인 척하면 안 되므로 흐리게 깐다. 다만 너무 흐리면
    /// 기기가 목록에서 빠진 걸로 오해하므로 존재감은 남긴다.
    private var dim: Double { device.live ? 1.0 : 0.68 }

    /// 응답이 끊긴 기기는 언제 값인지 밝힌다. 절전에 들어간 폰은 몇 시간씩
    /// 조용할 수 있어 분 단위로만 보여주면 숫자가 의미 없이 커진다.
    private var staleLabel: String {
        let seconds = Int(Date().timeIntervalSince(device.seenAt))
        switch seconds {
        case ..<60:    return L("방금", "now")
        case ..<3600:  return L("\(seconds / 60)분 전", "\(seconds / 60)m ago")
        case ..<86400: return L("\(seconds / 3600)시간 전", "\(seconds / 3600)h ago")
        default:       return L("\(seconds / 86400)일 전", "\(seconds / 86400)d ago")
        }
    }

    /// 남은 시간과 L/R·케이스 잔량을 한 줄로.
    private var detail: String? {
        var items: [String] = []
        if let minutes = device.minutesLeft {
            let time = minutes >= 60 ? L("\(minutes / 60)시간 \(minutes % 60)분", "\(minutes / 60)h \(minutes % 60)m")
                                     : L("\(minutes)분", "\(minutes)m")
            items.append(device.charging ? L("완충까지 \(time)", "\(time) to full") : L("약 \(time) 남음", "About \(time) left"))
        }
        if !device.parts.isEmpty {
            items.append(device.parts.map { "\($0.displayLabel) \($0.percent)%" }.joined(separator: "  "))
        }
        return items.isEmpty ? nil : items.joined(separator: " · ")
    }

    // Volume 탭의 볼륨 알약과 같은 모양: 카드 왼쪽에 아이콘, 오른쪽에 이름과 %가 든 알약.
    // 알약은 잔량만큼 채워지고, 채워진 부분의 글자는 검정이다. 누르거나 끌 수는 없다.
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: device.symbol)
                .font(.system(size: 15))
                .foregroundColor(NotchPalette.ink.opacity(0.75))
                .frame(width: 22, height: 22)
            pill
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.5), value: device.charging)
        .animation(.smooth, value: device.percent)
        .opacity(dim)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .notchCard(cornerRadius: 8)
        .padding(.horizontal, 4)
    }

    private let height: CGFloat = 26

    private var pill: some View {
        GeometryReader { geometry in
            let fillWidth = max(height, geometry.size.width * CGFloat(device.percent) / 100)
            ZStack(alignment: .leading) {
                Capsule().fill(NotchPalette.ink.opacity(0.1))
                labels(color: NotchPalette.ink.opacity(0.85), dimColor: NotchPalette.ink.opacity(0.5))
                Capsule()
                    .fill(tone)
                    .frame(width: fillWidth)
                labels(color: .black.opacity(0.8), dimColor: .black.opacity(0.55))
                    .mask(alignment: .leading) { Rectangle().frame(width: fillWidth) }
            }
        }
        .frame(height: height)
    }

    private func labels(color: Color, dimColor: Color) -> some View {
        HStack(spacing: 5) {
            Text(device.name)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(color)
                .lineLimit(1)
            if device.charging {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 8))
                    .foregroundColor(color)
                    .transition(.scale(scale: 0.2).combined(with: .opacity))
            }
            if let energyMode {
                // The same in both passes (on the track and on the fill), so its own dark capsule
                // and colours, not the passes' ink.
                HStack(spacing: 3) {
                    Image(systemName: energyMode.symbol)
                        .font(.system(size: 7.5, weight: .semibold))
                    Text(energyMode.label)
                        .font(.system(size: 9, weight: .bold))
                }
                .foregroundColor(energyMode.tint)
                .padding(.horizontal, 6)
                .frame(height: 14)
                .background(Capsule().fill(Color.black.opacity(0.55)))
                .fixedSize()
            }
            if pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 8))
                    .foregroundColor(dimColor)
            }
            if let closedRank {
                Text(L("\(closedRank + 1)순위", "#\(closedRank + 1)"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(dimColor)
            }
            if !device.live {
                Text(staleLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(dimColor)
            }
            Spacer(minLength: 6)
            if let detail {
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundColor(dimColor)
                    .lineLimit(1)
            }
            Text("\(device.percent)%")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(color)
                .contentTransition(.numericText(value: Double(device.percent)))
            if let opened {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(dimColor)
                    .rotationEffect(.degrees(opened ? 180 : 0))
            }
        }
        .padding(.horizontal, 10)
    }
}

/// 저배터리 배지: the low priority device's level written inside a small battery, as in the
/// iPhone's status bar. Orange from 20%, red from 10%. A charging device is not low
/// (`lowPriorityDevices`), so there is no charging look.
/// Alone on the wings the device's icon sits on the left wing and this is the battery only;
/// beside an agent's wing content it is smaller and carries the icon itself.
struct ClosedLowBatteryBadge: View {
    let device: BatteryDevice
    var showsIcon = true

    static let wingIconWidth: CGFloat = 20
    private static let iconWidth: CGFloat = 13
    private static let nub: CGFloat = 2.5

    static func width(showsIcon: Bool) -> CGFloat {
        showsIcon ? iconWidth + 3 + 22 + nub : 27 + nub
    }

    static func tint(level: Int) -> Color {
        level <= 10 ? Color(red: 1.0, green: 0.27, blue: 0.23) : Color(red: 1.0, green: 0.62, blue: 0.04)
    }

    var body: some View {
        let size = showsIcon ? CGSize(width: 22, height: 11) : CGSize(width: 27, height: 13)
        let level = device.displayLevel
        HStack(spacing: 3) {
            if showsIcon {
                Image(systemName: device.compactSymbol)
                    .font(.system(size: 10))
                    .foregroundColor(NotchPalette.ink.opacity(0.85))
                    .frame(width: Self.iconWidth)
            }
            HStack(spacing: 1) {
                ZStack(alignment: .leading) {
                    NotchPalette.ink.opacity(0.22)
                    Self.tint(level: level)
                        .frame(width: max(3, size.width * CGFloat(min(level, 100)) / 100))
                    Text("\(level)")
                        .font(.system(size: size.height * 0.72, weight: .bold, design: .rounded))
                        .fixedSize()
                        .foregroundColor(NotchPalette.ink)
                        .frame(width: size.width)
                }
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: size.height * 0.32, style: .continuous))
                Capsule()
                    .fill(NotchPalette.ink.opacity(0.4))
                    .frame(width: Self.nub - 1, height: size.height * 0.38)
            }
        }
    }
}

extension MacEnergyMode {
    var tint: Color {
        switch self {
        case .automatic: return Color(white: 0.8)
        case .lowPower: return Color(red: 1.0, green: 0.8, blue: 0.2)
        case .highPower: return Color(red: 1.0, green: 0.55, blue: 0.2)
        }
    }
}

/// Under the Mac's row once it is clicked open: what the charger gives now (입력 전력) or, on
/// battery, what the Mac uses (소비 전력), then the
/// energy mode for both power sources, one row of two or three filling it (no high power mode on
/// this Mac, two). Without the helper the row is dimmed and a button under it installs it.
private struct MacEnergyPanel: View {
    @ObservedObject var manager: BatteryManager

    private var modes: [MacEnergyMode] {
        manager.macEnergyCapabilities?.highPower == false ? [.automatic, .lowPower] : [.automatic, .lowPower, .highPower]
    }

    var body: some View {
        VStack(spacing: 6) {
            // First and always there, "-" until a reading comes. On the charger what comes in, out
            // of what the adapter can give (as macOS's own power readout); on battery what the Mac uses.
            let onCharger = manager.macPower?.onCharger ?? (manager.macAdapterWatts != nil)
            HStack {
                Text(onCharger ? L("입력 전력", "Power in") : L("소비 전력", "Power use"))
                Spacer()
                Text(manager.macPower.map { String(format: "%.1fW", $0.watts) } ?? "-")
                    .monospacedDigit()
                    .contentTransition(.numericText())
                if onCharger, let adapter = manager.macAdapterWatts {
                    Text(L("의 \(adapter)W", "of \(adapter)W"))
                        .foregroundColor(NotchPalette.ink.opacity(0.4))
                }
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(NotchPalette.ink.opacity(0.6))
            .padding(.horizontal, 6)
            if manager.macEnergyCapabilities != nil {
                HStack(spacing: 4) {
                    ForEach(modes, id: \.label) { mode in
                        let selected = (manager.macEnergyChanging ?? manager.macEnergyMode) == mode
                        Button { manager.setMacEnergyMode(mode) } label: {
                            HStack(spacing: 4) {
                                Image(systemName: mode.symbol)
                                    .font(.system(size: 9, weight: .semibold))
                                Text(mode.label)
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .foregroundColor(selected ? .black.opacity(0.8) : NotchPalette.ink.opacity(0.75))
                            .frame(maxWidth: .infinity, minHeight: 26)
                            .background(Capsule().fill(selected ? mode.tint : NotchPalette.ink.opacity(0.08)))
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .opacity(manager.macEnergyChanging != nil && !selected ? 0.5 : 1)
                    }
                }
                .animation(.smooth(duration: 0.2), value: manager.macEnergyChanging ?? manager.macEnergyMode)
                .disabled(manager.energyHelper != .installed)
                .opacity(manager.energyHelper == .installed ? 1 : 0.45)
                if manager.energyHelper != .installed {
                    // Changing the mode needs root: the optional helper, installed from here.
                    Button { manager.installEnergyHelper() } label: {
                        Text(manager.energyHelper == .needsApproval
                             ? L("시스템 설정 -> 로그인 항목에서 ClangNotch 허용", "Allow ClangNotch in System Settings -> Login Items")
                             : L("에너지 모드를 바꾸려면 헬퍼 설치", "Install the helper to change the energy mode"))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(NotchPalette.ink.opacity(0.85))
                            .frame(maxWidth: .infinity, minHeight: 22)
                            .background(Capsule().strokeBorder(NotchPalette.ink.opacity(0.25)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .notchCard(cornerRadius: 8)
        .padding(.horizontal, 4)
    }
}
