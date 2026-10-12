//
//  ClaudeUsageIndicator.swift
//  ClangNotch
//
//  Displays Claude API usage quota in the notch
//

import SwiftUI

// MARK: - Compact Usage Indicator (for closed notch)

/// Small usage bar shown alongside Claude Code status in closed notch
struct ClaudeUsageCompactIndicator: View {
    @ObservedObject var usageManager = ClaudeUsageManager.shared
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        if settings.showClaudeUsageInClosedNotch, usageManager.isConfigured, let fiveHour = usageManager.usageData.fiveHour {
            HStack(spacing: 4) {
                // Percentage text
                Text(fiveHour.formattedPercentage)
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundColor(colorForLevel(fiveHour.usageLevel))

                // Mini progress bar
                UsageMiniBar(percentage: fiveHour.percentage)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.black.opacity(0.4))
            .clipShape(Capsule())
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

/// Tiny progress bar for closed notch
struct UsageMiniBar: View {
    let percentage: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Background
                Capsule()
                    .fill(Color.white.opacity(0.2))

                // Fill
                Capsule()
                    .fill(fillColor)
                    .frame(width: geometry.size.width * CGFloat(min(percentage, 100) / 100))
            }
        }
        .frame(width: 30, height: 4)
    }

    private var fillColor: Color {
        switch percentage {
        case 0..<50: return .green
        case 50..<80: return .orange
        default: return .red
        }
    }
}

// MARK: - Expanded Usage View (for open notch / stats view)

/// Full usage display for the expanded notch view
struct ClaudeUsageExpandedView: View {
    @ObservedObject var usageManager = ClaudeUsageManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Image(systemName: "chart.bar.fill")
                    .foregroundColor(.secondary)
                Text("API Usage")
                    .font(.headline)

                Spacer()

                // Refresh button
                Button(action: {
                    Task {
                        await usageManager.manualRefresh()
                    }
                }) {
                    Image(systemName: usageManager.isLoading ? "arrow.trianglehead.2.clockwise" : "arrow.clockwise")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(usageManager.isLoading ? 360 : 0))
                        .animation(usageManager.isLoading ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: usageManager.isLoading)
                }
                .buttonStyle(.plain)
                .disabled(usageManager.isLoading)
            }

            if !usageManager.isConfigured {
                // Not configured state
                VStack(spacing: 8) {
                    Image(systemName: "key.fill")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text("Session key required")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("Configure in Settings")
                        .font(.caption2)
                        .foregroundColor(.secondary.opacity(0.7))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else if let error = usageManager.lastError {
                // Error state
                VStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(error.localizedDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            } else {
                // Usage bars
                VStack(spacing: 10) {
                    // 5-hour limit (always shown)
                    if let fiveHour = usageManager.usageData.fiveHour {
                        UsageBarRow(
                            label: "5 Hour",
                            data: fiveHour,
                            icon: "clock"
                        )
                    }

                    // 7-day limit
                    if let sevenDay = usageManager.usageData.sevenDay {
                        UsageBarRow(
                            label: "7 Day",
                            data: sevenDay,
                            icon: "calendar"
                        )
                    }

                    // Opus limit
                    if let opus = usageManager.usageData.opus {
                        UsageBarRow(
                            label: "Opus",
                            data: opus,
                            icon: "sparkles"
                        )
                    }

                    // Sonnet limit
                    if let sonnet = usageManager.usageData.sonnet {
                        UsageBarRow(
                            label: "Sonnet",
                            data: sonnet,
                            icon: "wand.and.stars"
                        )
                    }

                    // Extra usage (paid)
                    if let extra = usageManager.usageData.extraUsage, extra.enabled {
                        ExtraUsageRow(data: extra)
                    }
                }

                // Last updated
                Text("Updated \(usageManager.usageData.fetchedAt, style: .relative) ago")
                    .font(.caption2)
                    .foregroundColor(.secondary.opacity(0.6))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding()
        .background(Color.black.opacity(0.3))
        .cornerRadius(12)
    }
}

/// Single usage bar row
struct UsageBarRow: View {
    let label: String
    let data: ClaudeUsageData.LimitData
    let icon: String

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

                if let resetsAt = data.resetsAt {
                    Text("• \(data.formattedRemaining) · \(resetsAt, format: .dateTime.hour().minute())")
                        .font(.caption2)
                        .foregroundColor(.secondary.opacity(0.7))
                }
            }

            // Progress bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Background
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white.opacity(0.1))

                    // Fill
                    RoundedRectangle(cornerRadius: 2)
                        .fill(colorForLevel(data.usageLevel))
                        .frame(width: geometry.size.width * CGFloat(min(data.percentage, 100) / 100))
                }
            }
            .frame(height: 6)
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

/// Extra usage (paid) row
struct ExtraUsageRow: View {
    let data: ClaudeUsageData.ExtraUsageData

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "dollarsign.circle")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)

                Text("Extra Usage")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                Text("\(data.formattedUsed) / \(data.formattedLimit)")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.purple)
            }

            if let percentage = data.percentage {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.white.opacity(0.1))

                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.purple)
                            .frame(width: geometry.size.width * CGFloat(min(percentage, 100) / 100))
                    }
                }
                .frame(height: 6)
            }
        }
    }
}

// MARK: - Inline API Usage Badges (for Context bar integration)

/// Ultra-compact ring indicator for inline display
struct MiniUsageRing: View {
    let label: String
    let percentage: Double
    var color: Color? = nil

    private var ringColor: Color {
        if let color = color { return color }
        switch percentage {
        case 0..<50: return .green
        case 50..<80: return .orange
        default: return .red
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            // Ring
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.15), lineWidth: 1.5)
                    .frame(width: 12, height: 12)
                Circle()
                    .trim(from: 0, to: CGFloat(min(percentage, 100) / 100))
                    .stroke(ringColor, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .frame(width: 12, height: 12)
                    .rotationEffect(.degrees(-90))
            }

            // Label + percentage
            Text("\(label) \(Int(percentage.rounded()))%")
                .font(.system(size: 8, weight: .medium).monospacedDigit())
                .foregroundColor(ringColor)
        }
    }
}

/// Inline API usage badges to display next to other elements
struct InlineApiUsageBadges: View {
    @ObservedObject var usageManager = ClaudeUsageManager.shared

    var body: some View {
        if usageManager.isConfigured {
            HStack(spacing: 6) {
                if let fiveHour = usageManager.usageData.fiveHour {
                    MiniUsageRing(
                        label: "5h",
                        percentage: fiveHour.percentage
                    )
                }
                if let sevenDay = usageManager.usageData.sevenDay {
                    MiniUsageRing(
                        label: "7d",
                        percentage: sevenDay.percentage,
                        color: .purple
                    )
                }
            }
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
                Text("Claude 사용량")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.55))
                if usageManager.usageData.limitReached {
                    // A window can sit well under 100% while a different one
                    // is what's actually blocking, so say so outright.
                    Text("한도 도달")
                        .font(.system(size: 9, weight: .bold))
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
                    Text("인증 필요 · 탭")
                }
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.orange)
            }
            .buttonStyle(.plain)
        } else if usageManager.isLoading {
            HStack(spacing: 3) {
                Image(systemName: "arrow.clockwise")
                Text("갱신 중")
            }
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(.white.opacity(0.45))
        } else if let next = usageManager.nextRefreshAt {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = max(0, next.timeIntervalSince(context.date))
                HStack(spacing: 3) {
                    Image(systemName: "timer")
                    Text(remaining >= 1 ? Self.formatCountdown(remaining) : "곧")
                }
                .font(.system(size: 9, weight: .medium).monospacedDigit())
                .foregroundColor(.white.opacity(0.45))
            }
        }
    }

    /// Shared with the Codex card, whose pause can also stretch to days.
    static func formatCountdown(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        // Polling pauses for days once the weekly window is spent; mm:ss reads as nonsense there.
        if total >= 86_400 { return "\(total / 86_400)일 \(total % 86_400 / 3600)시간" }
        if total >= 3_600 { return "\(total / 3_600)시간 \(total % 3_600 / 60)분" }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            if hasData {
                if let fiveHour = usageManager.usageData.fiveHour {
                    UsageBarRow(label: "5시간", data: fiveHour, icon: "clock")
                }
                if let sevenDay = usageManager.usageData.sevenDay {
                    UsageBarRow(label: "7일", data: sevenDay, icon: "calendar")
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
        if needsReauth { return "탭하여 인증하기 (사용량 새로고침)" }
        if !usageManager.isConfigured { return "Claude Code 로그인이 필요해요" }
        if let error = usageManager.lastError {
            switch error {
            case .tokenExpired: return "토큰 만료 — Claude Code 실행 후 탭"
            case .unauthorized: return "인증이 거부됐어요 — 탭하여 재시도"
            case .rateLimited: return "요청 한도 도달 — 잠시 후 재시도"
            default: return "사용량을 불러오지 못했어요"
            }
        }
        return "사용량 불러오는 중…"
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

// MARK: - Legacy Compact Stats (kept for backwards compatibility)

/// Simplified usage display with circular badges - compact inline design
struct ClaudeUsageCompactStats: View {
    @ObservedObject var usageManager = ClaudeUsageManager.shared

    var body: some View {
        HStack(spacing: 8) {
            InlineApiUsageBadges()

            Spacer()

            // Refresh button
            if usageManager.isConfigured {
                Button(action: {
                    Task { await usageManager.manualRefresh() }
                }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(usageManager.isLoading ? 360 : 0))
                        .animation(usageManager.isLoading ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: usageManager.isLoading)
                }
                .buttonStyle(.plain)
                .disabled(usageManager.isLoading)
            }
        }
    }
}

// MARK: - Usage Badge (compact inline display)

/// Compact usage badge for embedding in other views
struct UsageBadge: View {
    let label: String
    let percentage: Double

    private var badgeColor: Color {
        switch percentage {
        case 0..<50: return .green
        case 50..<80: return .orange
        default: return .red
        }
    }

    var body: some View {
        HStack(spacing: 2) {
            Text(label)
                .font(.system(size: 8, weight: .medium))
                .foregroundColor(.secondary)
            Text("\(Int(percentage.rounded()))%")
                .font(.system(size: 8, weight: .bold).monospacedDigit())
                .foregroundColor(badgeColor)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(badgeColor.opacity(0.15))
        .cornerRadius(3)
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

// MARK: - Previews

#Preview("Compact Indicator") {
    HStack {
        ClaudeUsageCompactIndicator()
    }
    .padding()
    .background(Color.black)
}

#Preview("Expanded View") {
    ClaudeUsageExpandedView()
        .frame(width: 300)
        .padding()
        .background(Color.gray.opacity(0.2))
}

#Preview("Compact Stats") {
    ClaudeUsageCompactStats()
        .frame(width: 250)
        .padding()
        .background(Color.black.opacity(0.8))
}
