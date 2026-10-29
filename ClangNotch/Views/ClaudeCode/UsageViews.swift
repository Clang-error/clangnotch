// Usage bars and pace lines shared by the Claude and Codex 사용량 카드, the Claude 사용량 카드
// itself, and the Claude usage settings.

import SwiftUI

/// Where usage is heading at the current rate, as CodeIsland's usage cards show it:
/// either when the window runs out before its reset, or roughly where it ends up.
///
/// The rate blends the window's average with the last 45 minutes of readings: a burst early
/// in the window no longer reads as "fast" for hours, and one starting now shows up before
/// the average catches it. Until there are 10 minutes of readings it is the plain average.
/// A percentage that hasn't moved for 10 minutes means nothing is using the window now, so
/// it stays where it is: the average alone turned 4% in a window's first 26 minutes into
/// "about 49% at reset" with the agent idle. Readings are kept across launches.
@MainActor
enum UsagePace {
    private static let recentSpan: TimeInterval = 45 * 60
    private static let minimumSpan: TimeInterval = 10 * 60
    /// The recent rate's weight once a full span has been seen; the rest stays on the average.
    private static let recentWeight = 0.7
    private static let storageKey = "usagePaceHistory"

    private struct Reading: Codable {
        let at: Date
        let percent: Double
    }

    /// Readings per window (its length and reset), kept only when the percentage moved.
    private static var history: [String: [Reading]] = {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return [:] }
        return (try? JSONDecoder().decode([String: [Reading]].self, from: data)) ?? [:]
    }()

    /// Percent per second.
    private static func rate(percent: Double, resetsAt: Date, window: TimeInterval, elapsed: TimeInterval) -> Double {
        let average = percent / elapsed
        // Resets drift by a few seconds between readings; five minutes still tells windows apart.
        let key = "\(Int(window))-\(Int(resetsAt.timeIntervalSince1970 / 300))"
        let now = Date()
        var readings = history[key] ?? []
        if readings.last?.percent != percent {
            readings.append(Reading(at: now, percent: percent))
            readings.removeAll { now.timeIntervalSince($0.at) > window }
            history[key] = readings
            if history.count > 8, let stale = history.keys.first(where: { $0 != key }) { history[stale] = nil }
            if let data = try? JSONEncoder().encode(history) {
                UserDefaults.standard.set(data, forKey: storageKey)
            }
        }

        guard let first = readings.first, now.timeIntervalSince(first.at) >= minimumSpan else { return average }
        if let last = readings.last, now.timeIntervalSince(last.at) >= minimumSpan { return 0 }
        let span = min(recentSpan, now.timeIntervalSince(first.at))
        // The percentage as of `span` ago: the last reading at or before then.
        let then = readings.last { $0.at <= now.addingTimeInterval(-span) }?.percent ?? first.percent
        let recent = max(0, percent - then) / span
        let weight = recentWeight * span / recentSpan
        return weight * recent + (1 - weight) * average
    }

    /// 0–1 spot on the bar where usage lands at reset at the current rate (the end when it
    /// runs out first), for the tick. Only once there is a prediction: a fresh window or an
    /// unused cap shows a plain bar.
    static func projectedFraction(percent: Double, resetsAt: Date?, window: TimeInterval) -> Double? {
        guard let resetsAt, summary(percent: percent, resetsAt: resetsAt, window: window) != nil else { return nil }
        let remaining = resetsAt.timeIntervalSinceNow
        let rate = rate(percent: percent, resetsAt: resetsAt, window: window, elapsed: window - remaining)
        return min(percent + rate * remaining, 100) / 100
    }

    /// 여유 under 80% at reset, 약간 빠름 from 80%, 빠름 when it hits the limit before reset.
    enum Tier {
        case easy, brisk, fast

        var label: String {
            switch self {
            case .easy: return L("여유", "Easy")
            case .brisk: return L("약간 빠름", "A bit fast")
            case .fast: return L("빠름", "Fast")
            }
        }

        var color: Color {
            switch self {
            case .easy: return .green
            case .brisk: return .yellow
            case .fast: return .red
            }
        }
    }

    static func summary(percent: Double, resetsAt: Date?, window: TimeInterval) -> (tier: Tier, detail: String)? {
        guard let resetsAt, percent >= 1, percent < 100 else { return nil }
        let remaining = resetsAt.timeIntervalSinceNow
        let elapsed = window - remaining
        // Too early in the window, the rate is noise.
        guard remaining > 0, elapsed > window * 0.05 else { return nil }
        let rate = rate(percent: percent, resetsAt: resetsAt, window: window, elapsed: elapsed)
        if rate > 0, (100 - percent) / rate < remaining {
            let timeToFull = (100 - percent) / rate
            return (.fast, L("\(duration(timeToFull)) 뒤 한도 도달", "limit in \(duration(timeToFull))"))
        }
        let projected = Int((percent + rate * remaining).rounded())
        return (projected >= 80 ? .brisk : .easy, L("리셋 때 약 \(projected)%", "about \(projected)% at reset"))
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int(seconds / 60))
        if minutes < 60 { return L("\(minutes)분", "\(minutes)m") }
        if minutes < 1_440 { return L("\(minutes / 60)시간 \(minutes % 60)분", "\(minutes / 60)h \(minutes % 60)m") }
        return L("\(minutes / 1_440)일 \(minutes % 1_440 / 60)시간", "\(minutes / 1_440)d \(minutes % 1_440 / 60)h")
    }
}

/// The 10pt usage bar. A small grey tick marks where usage is predicted to land at reset.
struct UsageBar: View {
    let percent: Double
    let color: Color
    var projectedFraction: Double? = nil

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.white.opacity(0.1))
                RoundedRectangle(cornerRadius: 3)
                    .fill(color)
                    .frame(width: geometry.size.width * CGFloat(min(percent, 100) / 100))
            }
            // An overlay, so the taller tick never changes the bar's own height.
            .overlay(alignment: .leading) {
                if let projectedFraction {
                    Capsule()
                        .fill(Color(white: 0.62))
                        .frame(width: 2.5, height: 14)
                        .offset(x: min(max(0, geometry.size.width * projectedFraction - 1.25), geometry.size.width - 2.5))
                }
            }
            .animation(.smooth(duration: 0.5), value: percent)
        }
        .frame(height: 10)
    }
}

/// The pace line under a usage bar; orange when the window runs out before it resets.
struct UsagePaceLine: View {
    let percent: Double
    let resetsAt: Date?
    let window: TimeInterval

    var body: some View {
        if let pace = UsagePace.summary(percent: percent, resetsAt: resetsAt, window: window) {
            // The tier word takes its colour; the rest keeps orange (limit) or grey.
            (Text(pace.tier.label).foregroundColor(pace.tier.color)
                + Text(" · \(pace.detail)").foregroundColor(pace.tier == .fast ? .orange : .white.opacity(0.4)))
                .font(.system(size: 10, weight: pace.tier == .fast ? .semibold : .regular))
        }
    }
}

/// Single usage bar row
struct UsageBarRow: View {
    let label: String
    let data: ClaudeUsageData.LimitData
    let icon: String
    /// Length of this window: 5 hours, or 7 days for the weekly and per-model caps.
    var window: TimeInterval = 7 * 86_400
    @AppStorage("usagePaceEnabled") private var paceEnabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)

                Text(label)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                Text(data.formattedPercentage)
                    .font(.caption.monospacedDigit())
                    .foregroundColor(colorForLevel(data.usageLevel))
                    .contentTransition(.numericText(value: data.percentage))
                    .animation(.smooth, value: data.percentage)

                if let resetsAt = data.resetsAt {
                    Text("• \(data.formattedRemaining) · \(resetsAt, format: .dateTime.hour().minute())")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            UsageBar(percent: data.percentage, color: colorForLevel(data.usageLevel),
                     projectedFraction: paceEnabled
                        ? UsagePace.projectedFraction(percent: data.percentage, resetsAt: data.resetsAt, window: window) : nil)
            if paceEnabled {
                UsagePaceLine(percent: data.percentage, resetsAt: data.resetsAt, window: window)
            }
        }
    }

    private func colorForLevel(_ level: UsageLevel) -> Color {
        switch level {
        case .low: return .green
        case .medium: return .orange
        case .high: return .red
        }
    }
}

/// Always-visible usage panel for the open-notch AI tab. Shows 5-hour and 7-day
/// subscription usage as clear bars when data is available, and an explicit
/// loading / login-needed / retrying state otherwise — so the user always sees
/// *something*, even before the first successful fetch.
struct ClaudeUsageNotchSection: View {
    @ObservedObject var usageManager = ClaudeUsageManager.shared

    private var hasData: Bool {
        usageManager.usageData.fiveHour != nil || usageManager.usageData.sevenDay != nil
    }

    private var needsReauth: Bool {
        if case .needsReauth = usageManager.lastError { return true }
        return false
    }

    private func refreshNow() {
        Task { await usageManager.manualRefresh() }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header: title on the left, next-poll countdown on the right.
            HStack(spacing: 4) {
                Text(L("Claude 사용량", "Claude usage"))
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundColor(.white.opacity(0.4))
                if usageManager.usageData.limitReached {
                    // A window can sit well under 100% while a different one
                    // is what's actually blocking, so say so outright.
                    Text(L("한도 도달", "Limit reached"))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.red)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.red.opacity(0.18), in: Capsule())
                }
                Spacer(minLength: 0)
                nextPollCountdown
                Button(action: refreshNow) {
                    // Keep one symbol name. Swapping it as loading starts hands the symbol's
                    // replace transition the repeatForever below, and that never ends: the
                    // menu bar popover kept redrawing it at 120 Hz while closed.
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.55))
                        .rotationEffect(.degrees(usageManager.isLoading ? 360 : 0))
                        .animation(usageManager.isLoading ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: usageManager.isLoading)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(usageManager.isLoading)
            }

            content
        }
    }

    /// Live "time until next poll" shown at the header's right edge. The interval is
    /// variable in smart mode, so this counts down to the manager's scheduled instant.
    @ViewBuilder
    private var nextPollCountdown: some View {
        if needsReauth {
            Button(action: refreshNow) {
                HStack(spacing: 3) {
                    Image(systemName: "lock.fill")
                    Text(L("인증 필요 · 인증하기", "Sign-in needed · Sign in"))
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.orange)
            }
            .buttonStyle(.plain)
        } else if usageManager.isLoading {
            HStack(spacing: 3) {
                Image(systemName: "arrow.clockwise")
                Text(L("갱신 중", "Refreshing"))
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.white.opacity(0.5))
        } else if let next = usageManager.nextRefreshAt {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = max(0, next.timeIntervalSince(context.date))
                HStack(spacing: 3) {
                    Image(systemName: "timer")
                    Text(remaining >= 1 ? Self.formatCountdown(remaining) : L("곧", "soon"))
                }
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundColor(.white.opacity(0.5))
            }
        }
    }

    /// Shared with the Codex card, whose pause can also stretch to days.
    static func formatCountdown(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        // Polling pauses for days once the weekly window is spent; mm:ss reads as nonsense there.
        if total >= 86_400 { return L("\(total / 86_400)일 \(total % 86_400 / 3600)시간", "\(total / 86_400)d \(total % 86_400 / 3600)h") }
        if total >= 3_600 { return L("\(total / 3_600)시간 \(total % 3_600 / 60)분", "\(total / 3_600)h \(total % 3_600 / 60)m") }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            if hasData {
                if let fiveHour = usageManager.usageData.fiveHour {
                    UsageBarRow(label: L("5시간", "5h"), data: fiveHour, icon: "clock", window: 5 * 3_600)
                }
                if let sevenDay = usageManager.usageData.sevenDay {
                    UsageBarRow(label: L("7일", "7d"), data: sevenDay, icon: "calendar")
                }
                // Per-model weekly caps block on their own: Opus can be spent
                // while the overall 7-day window still reads low.
                if let opus = usageManager.usageData.opus {
                    UsageBarRow(label: "Opus", data: opus, icon: "sparkles")
                }
                if let sonnet = usageManager.usageData.sonnet {
                    UsageBarRow(label: "Sonnet", data: sonnet, icon: "wand.and.stars")
                }
                // Max-only row. The plan can't be read off the response: a Max 5x account
                // still gets `seven_day_opus`/`seven_day_sonnet` null, so the credential
                // blob's `subscriptionType` is the only signal there is.
                if usageManager.isMaxPlan, let fable = usageManager.usageData.fable {
                    UsageBarRow(label: "Fable", data: fable, icon: "book.pages")
                }
            } else {
                Button(action: refreshNow) {
                    HStack(spacing: 6) {
                        Image(systemName: statusIcon)
                            .font(.system(size: 10))
                            .foregroundColor(statusTint)
                            .rotationEffect(.degrees(usageManager.isLoading ? 360 : 0))
                            .animation(usageManager.isLoading ? .linear(duration: 1).repeatForever(autoreverses: false) : .default,
                                       value: usageManager.isLoading)
                        Text(statusText)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var statusText: String {
        if needsReauth { return L("눌러서 인증하기 (사용량 새로고침)", "Click to sign in (refreshes usage)") }
        if !usageManager.isConfigured { return L("Claude Code 로그인이 필요해요", "Sign in to Claude Code first") }
        if let error = usageManager.lastError {
            switch error {
            case .tokenExpired: return L("토큰 만료 — Claude Code 실행 후 누르기", "Token expired — run Claude Code, then click")
            case .unauthorized: return L("인증이 거부됐어요 — 눌러서 재시도", "Sign-in rejected — click to retry")
            case .rateLimited: return L("요청 한도 도달 — 잠시 후 재시도", "Rate limited — retrying shortly")
            default: return L("사용량을 불러오지 못했어요", "Couldn't load usage")
            }
        }
        return L("사용량 불러오는 중…", "Loading usage…")
    }

    private var statusIcon: String {
        if needsReauth { return "lock.fill" }
        if !usageManager.isConfigured { return "person.crop.circle.badge.questionmark" }
        if usageManager.lastError != nil { return "exclamationmark.triangle.fill" }
        return "arrow.clockwise"
    }

    private var statusTint: Color {
        usageManager.lastError != nil ? .orange : .secondary
    }
}

// MARK: - Settings View

/// Settings view for configuring Claude Usage
struct ClaudeUsageSettingsView: View {
    @ObservedObject var usageManager = ClaudeUsageManager.shared
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Claude Code account (auto-detected)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L("Claude Code 계정", "Claude Code Account"))
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Spacer()

                    // Status indicator
                    HStack(spacing: 4) {
                        Circle()
                            .fill(usageManager.isConfigured ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                        Text(usageManager.isConfigured ? L("감지됨", "Detected") : L("감지 안 됨", "Not detected"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Text(L("Claude Code가 이 Mac에 이미 저장한 토큰으로 사용량을 읽으므로 따로 로그인하거나 API 키를 넣을 필요가 없습니다. 감지되지 않으면 Claude Code에서 로그인하세요.", "Usage is read from the token Claude Code already stored on this Mac — no login or API key needed. Sign in with Claude Code if not detected."))
                    .font(.caption2)
                    .foregroundColor(.secondary.opacity(0.7))
            }

            Divider()

            // Refresh Settings
            VStack(alignment: .leading, spacing: 8) {
                Picker(L("새로고침 방식", "Refresh Mode"), selection: $settings.claudeUsageRefreshMode) {
                    Text(L("자동", "Smart")).tag("smart")
                    Text(L("고정", "Fixed")).tag("fixed")
                }
                .pickerStyle(.segmented)

                if settings.claudeUsageRefreshMode == "fixed" {
                    Picker(L("간격", "Interval"), selection: $settings.claudeUsageRefreshInterval) {
                        ForEach([5, 10, 15, 30], id: \.self) { minutes in
                            Text(L("\(minutes)분", "\(minutes) minutes")).tag(minutes * 60)
                        }
                    }
                } else {
                    HStack {
                        Text(L("현재 모드", "Current Mode"))
                            .font(.caption)
                        Spacer()
                        Text(monitoringModeText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            // Error display
            if let error = usageManager.lastError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(error.localizedDescription)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
        }
        .onChange(of: settings.enableClaudeUsage) { _, newValue in
            if newValue {
                usageManager.startRefreshing()
            } else {
                usageManager.stopRefreshing()
            }
        }
    }

    private var monitoringModeText: String {
        let minutes = Int(usageManager.currentMonitoringMode.interval / 60)
        return usageManager.currentMonitoringMode == .active
            ? L("활성 · \(minutes)분마다", "Active · every \(minutes) min")
            : L("대기 · \(minutes)분마다", "Idle · every \(minutes) min")
    }
}
