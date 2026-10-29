import SwiftUI

struct BatteryView: View {
    @ObservedObject var manager: BatteryManager
    @ObservedObject private var settings = AppSettings.shared

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
                                   closedRank: closedIDs.firstIndex(of: device.id))
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
                    }
                }
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { manager.start() }
        .onDisappear { manager.stop() }
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
                    .foregroundColor(.white)
                    .lineLimit(1)
                if snoozed {
                    Text(L("20%를 넘으면 다시 켜집니다", "Turns back on above 20%"))
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.5))
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

    /// 아이폰 도구 줄: shown until libimobiledevice is installed.
    private var iosToolsRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "iphone")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.6))
            Text(L("아이폰·아이패드 배터리를 보려면 도구 설치가 필요합니다", "Install a tool to see iPhone and iPad batteries"))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.8))
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

    private func toggleHeader(_ id: String) {
        var ids = headerIDs
        if let index = ids.firstIndex(of: id) { ids.remove(at: index) } else { ids.append(id) }
        settings.headerBatteryDeviceIDs = ids.joined(separator: "\n")
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

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "battery.0")
                .font(.system(size: 30, weight: .light))
                .foregroundColor(.white.opacity(0.25))
            Text(L("기기를 찾지 못했습니다", "No devices found"))
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.5))
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

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: device.symbol)
                .font(.system(size: 15, weight: .regular))
                .foregroundColor(.white.opacity(0.75))
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(device.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    if device.charging {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 8))
                            .foregroundColor(good)
                            // Plugging in pops the bolt in (SuperIsland bounces its charging symbol).
                            .transition(.scale(scale: 0.2).combined(with: .opacity))
                    }
                    if pinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8))
                            .foregroundColor(.white.opacity(0.4))
                    }
                    if let closedRank {
                        Text(L("\(closedRank + 1)순위", "#\(closedRank + 1)"))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.white.opacity(0.5))
                    }
                    if !device.live {
                        Text(staleLabel)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white.opacity(0.5))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.white.opacity(0.08), in: Capsule())
                    }
                }
                gauge
                if let minutes = device.minutesLeft {
                    let time = minutes >= 60 ? L("\(minutes / 60)시간 \(minutes % 60)분", "\(minutes / 60)h \(minutes % 60)m")
                                             : L("\(minutes)분", "\(minutes)m")
                    Text(device.charging ? L("완충까지 \(time)", "\(time) to full") : L("약 \(time) 남음", "About \(time) left"))
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.5))
                }
                if !device.parts.isEmpty {
                    Text(device.parts.map { "\($0.displayLabel) \($0.percent)%" }.joined(separator: "  "))
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.5))
                }
            }

            Text("\(device.percent)%")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(tone)
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(device.percent)))
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.5), value: device.charging)
        .animation(.smooth, value: device.percent)
        .opacity(dim)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .notchCard(cornerRadius: 12)
        .padding(.horizontal, 6)
    }

    private var gauge: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.1))
                Capsule()
                    .fill(tone)
                    .frame(width: max(3, geo.size.width * CGFloat(device.percent) / 100))
            }
        }
        .frame(height: 4)
    }
}

/// Open-notch header strip: the pinned devices that are connected, icon and level only.
struct HeaderBatteryStrip: View {
    @ObservedObject private var manager = BatteryManager.shared
    @ObservedObject private var settings = AppSettings.shared

    /// 지정한 순서대로.
    private var shown: [BatteryDevice] {
        settings.headerBatteryDeviceIDs.split(separator: "\n").compactMap { id in
            manager.devices.first { $0.id == id && $0.isConnected }
        }
    }

    var body: some View {
        // 기기마다 한 줄: 가로로 이으면 기기가 늘수록 헤더 오른쪽 상태 글자까지 덮는다.
        VStack(alignment: .center, spacing: 2) {
            ForEach(shown) { device in
                HStack(spacing: 4) {
                    Image(systemName: device.compactSymbol)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.6))
                    // 에어팟처럼 좌우가 따로 잡히면 한쪽만 먼저 닳는 게 보이도록 L/R을 나눠 띄운다.
                    // 한쪽만 잡히면 아이콘이 이미 어느 쪽인지 말해 주므로 잔량만 둔다.
                    let earbuds = device.parts.filter { $0.label == "L" || $0.label == "R" }
                    if earbuds.count < 2 {
                        level(device.displayLevel)
                    } else {
                        ForEach(earbuds, id: \.label) { part in
                            HStack(spacing: 2) {
                                Text(part.label)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(.white.opacity(0.5))
                                level(part.percent)
                            }
                        }
                    }
                }
            }
        }
        .lineLimit(1)
    }

    private func level(_ percent: Int) -> some View {
        Text("\(percent)%")
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundColor(percent <= 20 ? Color(red: 0.95, green: 0.35, blue: 0.35) : .white.opacity(0.8))
            .monospacedDigit()
    }
}

/// Closed-notch right-wing badge for the low priority device: icon and level, in red.
struct ClosedLowBatteryBadge: View {
    let device: BatteryDevice

    static func width(for device: BatteryDevice) -> CGFloat {
        let text = ceil(("\(device.displayLevel)%" as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold)
        ]).width)
        return 14 + 3 + text
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: device.compactSymbol)
                .font(.system(size: 10))
                .frame(width: 14)
            Text("\(device.displayLevel)%")
                .font(.system(size: 10, weight: .semibold))
                .fixedSize()
        }
        .foregroundColor(Color(red: 0.95, green: 0.35, blue: 0.35))
    }
}
