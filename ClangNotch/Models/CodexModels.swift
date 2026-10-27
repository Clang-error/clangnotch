//
//  CodexModels.swift
//  ClangNotch
//
//  Created for OpenAI Codex CLI JSONL integration
//

import Foundation

// MARK: - Session Discovery

/// Represents an active Codex CLI session from ~/.codex/sessions/
struct CodexSession: Identifiable, Equatable {
    let id: String  // session_id from session_meta
    let cwd: String
    let cliVersion: String
    let modelProvider: String
    let gitBranch: String?
    let gitCommit: String?
    let timestamp: Date
    let jsonlFile: URL
    var originator: String = ""
    var source: String = ""

    /// Display name for UI (last folder component of cwd)
    var displayName: String {
        URL(fileURLWithPath: cwd).lastPathComponent
    }
}

// MARK: - Token Usage

/// Token usage data from Codex token_count event
struct CodexTokenUsage: Equatable {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cachedInputTokens: Int = 0
    var reasoningOutputTokens: Int = 0
    var totalTokens: Int = 0
    /// What the last turn sent and got back (`last_token_usage`) — the part sitting in the
    /// context window. `totalTokens` adds up every turn, so it outgrows the window.
    var contextTokens: Int = 0
    var modelContextWindow: Int = 200_000

    var contextPercentage: Double {
        guard modelContextWindow > 0 else { return 0 }
        return min(100, Double(totalTokens) / Double(modelContextWindow) * 100)
    }

    // OpenAI pricing (GPT-4 Turbo estimates)
    struct ModelPricing {
        let inputPerMillion: Double
        let outputPerMillion: Double
        let cachedPerMillion: Double
    }

    static let gpt4Pricing = ModelPricing(
        inputPerMillion: 10.0,
        outputPerMillion: 30.0,
        cachedPerMillion: 2.5
    )

    func estimatedCost(model: String) -> Double {
        let pricing = Self.gpt4Pricing

        let inputCost = Double(inputTokens) / 1_000_000 * pricing.inputPerMillion
        let outputCost = Double(outputTokens) / 1_000_000 * pricing.outputPerMillion
        let cachedCost = Double(cachedInputTokens) / 1_000_000 * pricing.cachedPerMillion

        return inputCost + outputCost + cachedCost
    }
}

// MARK: - Tool Execution

/// Represents a Codex function call in progress or completed
struct CodexToolExecution: Identifiable, Equatable {
    let id: String  // call_id from function_call
    let toolName: String
    let argument: String?
    let startTime: Date
    var endTime: Date?
    var isRunning: Bool { endTime == nil }

    // Additional info
    var workdir: String?
    /// apply_patch's removed and added lines, for the 세션 화면.
    var change: ToolChange?
    var output: String?
    var exitCode: Int?

    var durationMs: Int? {
        guard let end = endTime else { return nil }
        return Int(end.timeIntervalSince(startTime) * 1000)
    }

    var formattedDuration: String {
        guard let ms = durationMs else {
            let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
            return formatMs(elapsed)
        }
        return formatMs(ms)
    }

    private func formatMs(_ ms: Int) -> String {
        if ms < 1000 {
            return "\(ms)ms"
        } else if ms < 60000 {
            return String(format: "%.1fs", Double(ms) / 1000.0)
        } else {
            let seconds = ms / 1000
            let minutes = seconds / 60
            let remainingSeconds = seconds % 60
            return "\(minutes)m \(remainingSeconds)s"
        }
    }
}

// MARK: - Interactive Input

struct CodexInputRequest: Identifiable, Equatable {
    let id: String  // call_id from the input request
    let questions: [AgentInputQuestion]
    var isAsync = false
    var answeredQuestionIndices: Set<Int> = []
}

// MARK: - Usage Limits

struct CodexRateLimitWindow: Equatable {
    let usedPercent: Double
    let windowMinutes: Int
    let resetsAt: Date?
}

struct CodexRateLimits: Equatable {
    var primary: CodexRateLimitWindow?
    var secondary: CodexRateLimitWindow?
    var planType: String?
    /// Whether the account is out of ordinary quota right now. The window
    /// percentages alone don't say this: the 5h window can read well under
    /// 100% while the spent weekly window is what's actually blocking.
    var limitReached = false

    var hasData: Bool { primary != nil || secondary != nil }
}

// MARK: - Complete State

/// Complete Codex session state for display
struct CodexState: Equatable {
    var sessionId: String = ""
    var model: String = ""
    var cwd: String = ""
    var gitBranch: String = ""

    var tokenUsage: CodexTokenUsage = CodexTokenUsage()

    var activeTools: [CodexToolExecution] = []
    var recentTools: [CodexToolExecution] = []

    var isConnected: Bool = false
    var lastUpdateTime: Date?

    /// True when Codex is actively thinking/reasoning
    var isThinking: Bool = false

    /// A started turn remains active across gaps in JSONL output.
    var isTurnInProgress: Bool = false

    /// Last reasoning text
    var lastReasoningText: String?

    /// Interactive question waiting for an answer in Codex
    var pendingInputRequest: CodexInputRequest?

    /// Last prompt the user typed, to tell idle sessions of one folder apart in the list
    var lastUserPrompt: String?

    // Convenience accessors
    var contextPercentage: Double { tokenUsage.contextPercentage }
    var hasActiveTools: Bool { !activeTools.isEmpty }
    var currentToolName: String? { activeTools.first?.toolName }

    /// True when actively processing
    var isActive: Bool { isTurnInProgress || isThinking || hasActiveTools }
}
