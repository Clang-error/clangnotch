//
//  ClaudeUsageModels.swift
//  ClangNotch
//
//  Models for Claude API usage quota tracking
//

import Foundation

// MARK: - API Response Models

/// Response from the OAuth usage endpoint (`api.anthropic.com/api/oauth/usage`).
///
/// Two representations of the same thing ship side by side: the legacy top-level windows
/// (`five_hour`, `seven_day_opus`, …) and a `limits` array. Per-model caps only have a
/// usable name in `limits` — at the top level they arrive under rotating codenames
/// (`nimbus_quill`, `tangelo`, `cedar_ember`, …) that say nothing about which model they
/// belong to, while `limits` carries the server's own `display_name`.
struct ClaudeUsageResponse: Codable {
    let fiveHour: LimitUsage?
    let sevenDay: LimitUsage?
    let sevenDayOpus: LimitUsage?
    let sevenDaySonnet: LimitUsage?
    let limits: [LimitEntry]?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        case limits
    }

    /// Fable's weekly cap, matched on the name the server itself displays.
    var fable: LimitEntry? {
        limits?.first { $0.scope?.model?.displayName == "Fable" }
    }

    struct LimitUsage: Codable {
        let utilization: Double  // 0-100 percentage
        let resetsAt: String?    // ISO 8601 format

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }
    }

    /// One entry of `limits`. `kind` is "session", "weekly_all" or "weekly_scoped"; a
    /// scoped entry names the model it caps.
    struct LimitEntry: Codable {
        let percent: Double
        let resetsAt: String?
        let scope: Scope?

        enum CodingKeys: String, CodingKey {
            case percent, scope
            case resetsAt = "resets_at"
        }

        struct Scope: Codable {
            let model: Model?

            struct Model: Codable {
                let displayName: String?

                enum CodingKeys: String, CodingKey {
                    case displayName = "display_name"
                }
            }
        }
    }
}

// MARK: - App Data Models

/// Parsed usage data for display
struct ClaudeUsageData: Equatable {
    let fiveHour: LimitData?
    let sevenDay: LimitData?
    let opus: LimitData?
    let sonnet: LimitData?
    let fable: LimitData?
    let fetchedAt: Date

    /// True when any window is spent. The endpoint carries no explicit "blocked"
    /// flag, and a low 5-hour reading says nothing about a spent weekly or
    /// per-model cap — which is the one actually turning requests away.
    var limitReached: Bool {
        [fiveHour, sevenDay, opus, sonnet, fable].contains { ($0?.percentage ?? 0) >= 100 }
    }

    static let empty = ClaudeUsageData(
        fiveHour: nil,
        sevenDay: nil,
        opus: nil,
        sonnet: nil,
        fable: nil,
        fetchedAt: Date()
    )

    struct LimitData: Equatable {
        let percentage: Double       // 0-100
        let resetsAt: Date?

        /// Time remaining until reset
        var resetsIn: TimeInterval? {
            guard let resetsAt = resetsAt else { return nil }
            return resetsAt.timeIntervalSinceNow
        }

        /// Formatted remaining time (e.g., "2h 30m", "3d 12h")
        var formattedRemaining: String {
            guard let seconds = resetsIn, seconds > 0 else { return "—" }

            let hours = Int(seconds) / 3600
            let minutes = (Int(seconds) % 3600) / 60

            if hours >= 24 {
                let days = hours / 24
                let remainingHours = hours % 24
                return L("\(days)일 \(remainingHours)시간", "\(days)d \(remainingHours)h")
            } else if hours > 0 {
                return L("\(hours)시간 \(minutes)분", "\(hours)h \(minutes)m")
            } else {
                return L("\(minutes)분", "\(minutes)m")
            }
        }

        /// Compact percentage string
        var formattedPercentage: String {
            return "\(Int(percentage.rounded()))%"
        }

        /// Color based on usage level
        var usageLevel: UsageLevel {
            switch percentage {
            case 0..<50: return .low
            case 50..<80: return .medium
            default: return .high
            }
        }
    }
}

// MARK: - Usage Level

enum UsageLevel {
    case low      // 0-50%: green
    case medium   // 50-80%: orange
    case high     // 80-100%: red
}

// MARK: - Refresh Mode

/// Smart refresh: every 5 minutes (the endpoint rate-limits anything faster), every 10 once
/// usage has stopped moving for a while.
enum UsageMonitoringMode: String {
    case active
    case idle

    var interval: TimeInterval {
        switch self {
        case .active: return 300
        case .idle: return 600
        }
    }
}

// MARK: - Errors

enum ClaudeUsageError: LocalizedError {
    case noData
    case noCredentials
    case networkError(Error)
    case unauthorized
    case rateLimited
    case httpError(statusCode: Int)
    /// Background read couldn't reach the token without a Keychain prompt; the user must
    /// tap refresh to authorize it interactively.
    case needsReauth
    /// The stored access token is past its expiry. Only Claude Code can renew it (it holds
    /// the refresh token), so the fix is to run the CLI — not to retry the request.
    case tokenExpired

    var errorDescription: String? {
        switch self {
        case .noData:
            return L("사용량 응답이 비어 있습니다", "No usage data received")
        case .noCredentials:
            return L("Claude Code 로그인을 찾지 못했습니다. 먼저 Claude Code에 로그인하세요.", "Claude Code login not found. Sign in with Claude Code first.")
        case .networkError(let error):
            return L("네트워크 오류: ", "Network error: ") + error.localizedDescription
        case .unauthorized:
            return L("Claude Code 로그인이 거부되었습니다. Claude Code에서 다시 로그인하세요.",
                     "Claude Code's login was refused. Sign in again in Claude Code.")
        case .rateLimited:
            return L("요청이 너무 많습니다. 잠시 후 다시 시도합니다.", "Too many requests. Trying again shortly.")
        case .httpError(let code):
            return L("HTTP 오류 \(code)", "HTTP error \(code)")
        case .needsReauth:
            return L("눌러서 사용량 읽기를 허용하세요", "Tap to authorize usage access")
        case .tokenExpired:
            return L("Claude Code 토큰이 만료되었습니다. Claude Code를 실행하면 갱신됩니다.", "Claude Code token expired. Run Claude Code to renew it.")
        }
    }
}
