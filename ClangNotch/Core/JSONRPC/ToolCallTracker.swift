import Foundation
import Combine

@MainActor
final class ToolCallTracker: ObservableObject {
    @Published private(set) var recentToolCalls: [ToolCall] = []

    private var pendingStderrCalls: [String: ToolCall] = [:]  // For stderr/telemetry events (string IDs)
    private let maxRecentCalls: Int

    init(maxRecentCalls: Int = 10) {
        self.maxRecentCalls = maxRecentCalls
    }

    // MARK: - Stderr event tracking (from Go server)

    func recordToolStart(id: String, toolCall: ToolCall) {
        pendingStderrCalls[id] = toolCall

        // Add to recent calls immediately (as active)
        recentToolCalls.insert(toolCall, at: 0)
        if recentToolCalls.count > maxRecentCalls {
            recentToolCalls.removeLast()
        }
    }

    func recordToolEnd(id: String, success: Bool, tokens: Int?, endTime: Date = Date()) {
        guard var toolCall = pendingStderrCalls.removeValue(forKey: id) else { return }

        toolCall.endTime = endTime
        toolCall.tokenCount = tokens
        if success {
            toolCall.result = .success(content: "")
        } else {
            toolCall.result = .failure(error: "Tool failed")
        }

        // Update the existing entry in recentToolCalls
        if let index = recentToolCalls.firstIndex(where: { $0.id == toolCall.id }) {
            recentToolCalls[index] = toolCall
        }
    }

    func recordCompletedToolCall(
        toolName: String,
        arguments: [String: AnyCodableValue] = [:],
        startTime: Date,
        endTime: Date,
        success: Bool,
        tokens: Int?,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        costUsd: Double? = nil,
        source: TelemetrySource = .unknown
    ) {
        var toolCall = ToolCall(
            toolName: toolName,
            arguments: arguments,
            startTime: startTime,
            tokenCount: tokens,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            costUsd: costUsd,
            source: source
        )
        toolCall.endTime = endTime
        toolCall.result = success ? .success(content: "") : .failure(error: "Tool failed")

        recentToolCalls.insert(toolCall, at: 0)
        if recentToolCalls.count > maxRecentCalls {
            recentToolCalls.removeLast()
        }
    }

    /// Force-complete all active tool calls (used when session ends)
    func forceCompleteAllActive() {
        let now = Date()
        pendingStderrCalls.removeAll()

        for i in recentToolCalls.indices {
            if recentToolCalls[i].isActive {
                recentToolCalls[i].endTime = now
                recentToolCalls[i].result = .success(content: "")
            }
        }
    }
}
