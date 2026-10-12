import SwiftUI

/// Expanded-notch tab: run a ping/download/upload test and read the numbers.
struct SpeedTestView: View {
    @ObservedObject var manager: SpeedTestManager
    @ObservedObject private var network = NetworkInfoManager.shared
    @ObservedObject private var settings = AppSettings.shared

    private let accent = Color(red: 0.3, green: 0.85, blue: 0.55)
    private let failed = Color(red: 0.95, green: 0.35, blue: 0.35)

    /// While a transfer runs the dial follows it live; afterwards it rests on the
    /// download result, which is the number people actually mean by "speed".
    private var dialValue: Double? {
        switch manager.phase {
        // 0 means "no trustworthy live figure yet" — an upload stays quiet while its
        // socket buffer fills. Show a dash rather than a number that isn't real.
        case .download, .upload: return manager.liveMbps > 0 ? manager.liveMbps : nil
        case .finished: return manager.downloadMbps
        case .ping: return nil
        case .idle, .failed: return nil
        }
    }

    private var statusText: String {
        switch manager.phase {
        case .idle:     return "측정을 눌러 시작"
        case .ping:     return "지연 시간 측정 중…"
        case .download: return "다운로드 중…"
        case .upload:   return "업로드 중…"
        case .finished: return "완료"
        case .failed:   return manager.errorMessage ?? "실패"
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            networkRow
            dial
            metrics
            if !manager.isRunning,
               let verdict = SpeedVerdict(download: manager.downloadMbps, upload: manager.uploadMbps, ping: manager.latencyMs) {
                verdictSection(verdict)
            }
            actionButton
            if settings.enableSpeedTest, !settings.tworldHotspotSSID.isEmpty,
               network.ssid == settings.tworldHotspotSSID {
                TWorldUsageView()
            }
            Spacer(minLength: 0)
            if let finishedAt = manager.finishedAt {
                measuredAtRow(finishedAt)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            // Also detects leaving the hotspot while the Speed tab stays open.
            while !Task.isCancelled {
                network.refresh()
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
            }
        }
    }

    private var networkRow: some View {
        HStack(spacing: 5) {
            Image(systemName: "wifi")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(0.4))
            Text(network.name)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.7))
                .lineLimit(1)
            if network.ssidBlocked {
                // macOS only reveals the SSID with Location Services. Tapping here
                // shows the prompt, or opens System Settings once it's been answered.
                Button { network.requestAccess() } label: {
                    Text("네트워크 이름을 보려면 위치 서비스 허용")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.5))
                        .lineLimit(1)
                        .underline()
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    private func verdictSection(_ verdict: SpeedVerdict) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(verdict.headline)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(verdict.tone)
                Text("— 가능한 용도")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.5))
                Spacer(minLength: 0)
            }

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), alignment: .leading),
                    GridItem(.flexible(), alignment: .leading),
                ],
                spacing: 5
            ) {
                ForEach(verdict.capabilities) { capability in
                    HStack(spacing: 5) {
                        Image(systemName: capability.ok ? "checkmark" : "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(capability.ok ? accent : .white.opacity(0.22))
                            .frame(width: 10)
                        Text(capability.name)
                            .font(.system(size: 11))
                            .foregroundColor(capability.ok ? .white.opacity(0.85) : .white.opacity(0.5))
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.horizontal, 2)
    }

    private var dial: some View {
        VStack(spacing: 2) {
            HStack(alignment: .lastTextBaseline, spacing: 5) {
                Text(dialValue.map(SpeedFormat.mbps) ?? "—")
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .monospacedDigit()
                Text("Mbps")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))
            }
            Text(statusText)
                .font(.system(size: 11))
                .foregroundColor(manager.phase == .failed ? failed : .white.opacity(0.5))
        }
        .padding(.top, 4)
    }

    private var metrics: some View {
        HStack(spacing: 8) {
            SpeedMetricCard(
                title: "핑",
                value: manager.latencyMs.map { String(format: "%.0f", $0) } ?? "—",
                unit: "ms",
                icon: "dot.radiowaves.left.and.right",
                active: manager.phase == .ping,
                accent: accent
            )
            SpeedMetricCard(
                title: "다운로드",
                value: manager.downloadMbps.map(SpeedFormat.mbps) ?? "—",
                unit: "Mbps",
                icon: "arrow.down",
                active: manager.phase == .download,
                accent: accent
            )
            SpeedMetricCard(
                title: "업로드",
                value: manager.uploadMbps.map(SpeedFormat.mbps) ?? "—",
                unit: "Mbps",
                icon: "arrow.up",
                active: manager.phase == .upload,
                accent: accent
            )
        }
    }

    /// The numbers stay on screen for a few minutes after a run, so say how old they are.
    /// Only here — the closed-notch dropdown is only ever shown right after a test.
    private func measuredAtRow(_ finishedAt: Date) -> some View {
        let seconds = Int(Date().timeIntervalSince(finishedAt))
        let ago: String = {
            switch seconds {
            case ..<60:    return "방금"
            case ..<3600:  return "\(seconds / 60)분 전"
            case ..<86400: return "\(seconds / 3600)시간 전"
            default:       return "\(seconds / 86400)일 전"
            }
        }()
        return HStack(spacing: 4) {
            Image(systemName: "clock")
                .font(.system(size: 8))
            Text("\(ago) 측정")
                .font(.system(size: 10))
            Spacer(minLength: 0)
        }
        .foregroundColor(.white.opacity(0.5))
    }

    private var actionButton: some View {
        let running = manager.isRunning
        return Button {
            if running { manager.cancel() } else { manager.start() }
        } label: {
            Text(running ? "취소" : "측정")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(running ? .white.opacity(0.8) : .black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(running ? Color.white.opacity(0.12) : accent, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct SpeedMetricCard: View {
    let title: String
    let value: String
    let unit: String
    let icon: String
    let active: Bool
    let accent: Color

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                Text(title)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(active ? accent : .white.opacity(0.5))

            Text(value)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Text(unit)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color.white.opacity(active ? 0.10 : 0.05), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(active ? accent.opacity(0.5) : .clear, lineWidth: 1)
        )
    }
}

// MARK: - Closed-notch dropdown

/// Left/right wings of the peek row. The middle sits behind the physical notch,
/// so nothing readable goes there.
struct SpeedPeekHeader: View {
    @ObservedObject var manager: SpeedTestManager
    @ObservedObject private var network = NetworkInfoManager.shared

    private let accent = Color(red: 0.3, green: 0.85, blue: 0.55)

    private var verdict: SpeedVerdict? {
        SpeedVerdict(download: manager.downloadMbps, upload: manager.uploadMbps, ping: manager.latencyMs)
    }

    /// The numbers are already in the row below, so the wings carry what isn't there:
    /// which step is running (or how the link rated) and which network it was.
    private var label: String {
        switch manager.phase {
        case .idle:     return "속도"
        case .ping:     return "핑"
        case .download: return "다운로드"
        case .upload:   return "업로드"
        case .finished: return verdict?.headline ?? "완료"
        case .failed:   return "실패"
        }
    }

    private var labelColor: Color {
        manager.phase == .finished ? (verdict?.tone ?? .white.opacity(0.8)) : .white.opacity(0.8)
    }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "speedometer")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(accent)
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(labelColor)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, 12)

            Spacer()

            HStack(spacing: 4) {
                Image(systemName: "wifi")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.white.opacity(0.35))
                Text(network.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: 90, alignment: .trailing)
            .padding(.trailing, 14)
        }
    }
}

/// The row that drops below the notch while a test runs: the three numbers as
/// they land, then the finished set for a few seconds.
struct SpeedPeekContent: View {
    @ObservedObject var manager: SpeedTestManager

    private let accent = Color(red: 0.3, green: 0.85, blue: 0.55)

    var body: some View {
        // A transfer in flight shows the live figure; ping has no live value, so it
        // just waits for its result.
        let live = manager.liveMbps > 0 ? SpeedFormat.mbps(manager.liveMbps) : nil
        HStack(spacing: 0) {
            peekMetric(
                "핑", "ms",
                value: manager.latencyMs.map { String(format: "%.0f", $0) } ?? (manager.phase == .ping ? "…" : nil),
                active: manager.phase == .ping
            )
            peekMetric(
                "다운로드", "Mbps",
                value: manager.phase == .download ? live : manager.downloadMbps.map(SpeedFormat.mbps),
                active: manager.phase == .download
            )
            peekMetric(
                "업로드", "Mbps",
                value: manager.phase == .upload ? live : manager.uploadMbps.map(SpeedFormat.mbps),
                active: manager.phase == .upload
            )
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private func peekMetric(_ title: String, _ unit: String, value: String?, active: Bool) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(active ? accent : .white.opacity(0.5))
            HStack(alignment: .lastTextBaseline, spacing: 3) {
                Text(value ?? "—")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .monospacedDigit()
                Text(unit)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.5))
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// What the measured link can actually be used for — the rating other speed tests
/// print after a run. Thresholds follow the published requirements of the services
/// themselves (Netflix HD 5 Mbps / 4K 25, Zoom HD calls ~3.8 down and 3 up, and the
/// sub-80 ms round trip competitive games need).
struct SpeedVerdict {
    struct Capability: Identifiable {
        let name: String
        let ok: Bool
        var id: String { name }
    }

    let headline: String
    let tone: Color
    let capabilities: [Capability]

    init?(download: Double?, upload: Double?, ping: Double?) {
        guard let download else { return nil }
        let up = upload ?? 0
        // A missing ping reading shouldn't pass the latency-sensitive checks.
        let latency = ping ?? .greatestFiniteMagnitude

        switch download {
        case 100...:
            headline = "매우 빠름"
            tone = Color(red: 0.3, green: 0.85, blue: 0.55)
        case 50..<100:
            headline = "빠름"
            tone = Color(red: 0.3, green: 0.85, blue: 0.55)
        case 25..<50:
            headline = "양호"
            tone = Color(red: 0.6, green: 0.85, blue: 0.4)
        case 10..<25:
            headline = "보통"
            tone = Color(red: 1.0, green: 0.78, blue: 0.3)
        default:
            headline = "느림"
            tone = Color(red: 0.95, green: 0.35, blue: 0.35)
        }

        capabilities = [
            Capability(name: "웹·이메일", ok: download >= 1),
            Capability(name: "음악 스트리밍", ok: download >= 2),
            Capability(name: "영상 통화", ok: download >= 4 && up >= 3 && latency <= 200),
            Capability(name: "HD 스트리밍", ok: download >= 8),
            Capability(name: "4K 스트리밍", ok: download >= 25),
            Capability(name: "온라인 게임", ok: download >= 5 && latency <= 80),
        ]
    }
}

enum SpeedFormat {
    /// Sub-10 readings need the extra digit; past 100 the decimal is just noise.
    static func mbps(_ value: Double) -> String {
        if value >= 100 { return String(format: "%.0f", value) }
        if value >= 10 { return String(format: "%.1f", value) }
        return String(format: "%.2f", value)
    }
}
