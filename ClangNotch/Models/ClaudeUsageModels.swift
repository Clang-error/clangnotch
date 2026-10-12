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
    let extraUsage: ExtraUsageData?
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
        extraUsage: nil,
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
                return "\(days)d \(remainingHours)h"
            } else if hours > 0 {
                return "\(hours)h \(minutes)m"
            } else {
                return "\(minutes)m"
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

    struct ExtraUsageData: Equatable {
        let enabled: Bool
        let usedDollars: Double?
        let limitDollars: Double?
        let currency: String

        var percentage: Double? {
            guard let used = usedDollars, let limit = limitDollars, limit > 0 else {
                return nil
            }
            return (used / limit) * 100
        }

        var formattedUsed: String {
            guard let used = usedDollars else { return "—" }
            return String(format: "$%.2f", used)
        }

        var formattedLimit: String {
            guard let limit = limitDollars else { return "—" }
            return String(format: "$%.2f", limit)
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

enum UsageRefreshMode: String, CaseIterable, Identifiable {
    case smart = "Smart"
    case fixed = "Fixed"

    var id: String { rawValue }
}

enum UsageRefreshInterval: Int, CaseIterable, Identifiable {
    case oneMinute = 60
    case threeMinutes = 180
    case fiveMinutes = 300
    case tenMinutes = 600

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .oneMinute: return "1 minute"
        case .threeMinutes: return "3 minutes"
        case .fiveMinutes: return "5 minutes"
        case .tenMinutes: return "10 minutes"
        }
    }
}

/// Smart monitoring modes (adaptive based on activity)
enum UsageMonitoringMode: String {
    case active = "active"           // 1 minute
    case idleShort = "idle_short"    // 3 minutes
    case idleMedium = "idle_medium"  // 5 minutes
    case idleLong = "idle_long"      // 10 minutes

    var interval: TimeInterval {
        switch self {
        case .active: return 60
        case .idleShort: return 180
        case .idleMedium: return 300
        case .idleLong: return 600
        }
    }
}

// MARK: - Errors

enum ClaudeUsageError: LocalizedError {
    case invalidURL
    case noData
    case sessionExpired
    case cloudflareBlocked
    case noCredentials
    case networkError(Error)
    case decodingError(Error)
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
        case .invalidURL:
            return "Invalid API URL"
        case .noData:
            return "No data received"
        case .sessionExpired:
            return "Session expired. Please update your session key."
        case .cloudflareBlocked:
            return "Request blocked by Cloudflare"
        case .noCredentials:
            return "Claude Code login not found. Sign in with Claude Code first."
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .decodingError(let error):
            return "Failed to parse response: \(error.localizedDescription)"
        case .unauthorized:
            return "Invalid session key"
        case .rateLimited:
            return "Too many requests. Please wait."
        case .httpError(let code):
            return "HTTP error: \(code)"
        case .needsReauth:
            return "Tap to authorize usage access"
        case .tokenExpired:
            return "Claude Code token expired. Run Claude Code to renew it."
        }
    }
}
