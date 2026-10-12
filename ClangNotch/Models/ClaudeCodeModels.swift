//
//  ClaudeCodeModels.swift
//  ClangNotch
//
//  Created for Claude Code JSONL integration
//

import Foundation

// MARK: - Session Discovery

/// Represents an active Claude Code IDE session from ~/.claude/ide/*.lock
struct ClaudeSession: Identifiable, Codable, Equatable {
    var id: String { "\(ideName):\(workspaceFolders.first ?? "\(pid)")" }

    let pid: Int
    let workspaceFolders: [String]
    let ideName: String
    let transport: String?
    let runningInWindows: Bool?

    /// Real working directory of a terminal session. The project-dir name is a lossy
    /// encoding (both "/" and "_" become "-"), so `workspaceFolders` is kept in its
    /// lossy-decoded form for project-key lookup while the real path (from the JSONL
    /// `cwd` field) is stored here for display. Optional → absent in IDE lock files.
    var cwd: String? = nil

    /// SSH host alias for a session running on a remote server (fed by hook events over
    /// the reverse tunnel, not by a local JSONL). nil for every local session.
    var remoteHost: String? = nil

    /// Derived from workspace path for project JSONL lookup
    /// Claude Code uses path with "/" replaced by "-" as the project directory name
    var projectKey: String? {
        guard let workspace = workspaceFolders.first else { return nil }
        // Strip session fragment if present (e.g., /path#sessionId -> /path)
        let cleanPath = workspace.components(separatedBy: "#").first ?? workspace
        // Claude Code escapes the path by replacing every character that isn't an ASCII
        // letter/digit or "-" with "-". So "/", "_", ".", spaces, "~" all become "-".
        // e.g. /Users/foo/my_app -> -Users-foo-my-app
        return String(cleanPath.map { ch in
            (ch.isASCII && (ch.isLetter || ch.isNumber)) || ch == "-" ? ch : "-"
        })
    }

    /// Folder path for display and grouping: the real `cwd` when known, otherwise the
    /// workspace path with any session fragment stripped (e.g., /path#sessionId -> /path).
    var workspacePath: String? {
        if let cwd, !cwd.isEmpty { return cwd }
        guard let workspace = workspaceFolders.first else { return nil }
        return workspace.components(separatedBy: "#").first ?? workspace
    }

    /// Display name for UI (last folder component)
    var displayName: String {
        guard let workspacePath else { return "Unknown" }
        return URL(fileURLWithPath: workspacePath).lastPathComponent
    }

    /// Terminal session ID extracted from workspace fragment (nil for IDE sessions)
    var terminalSessionId: String? {
        guard let workspace = workspaceFolders.first else { return nil }
        let parts = workspace.components(separatedBy: "#")
        return parts.count > 1 ? parts[1] : nil
    }
}

// MARK: - Token Usage

/// Token usage data from JSONL message.usage field
struct ClaudeTokenUsage: Equatable {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheReadInputTokens: Int = 0
    var cacheCreationInputTokens: Int = 0

    var totalTokens: Int {
        inputTokens + outputTokens + cacheReadInputTokens + cacheCreationInputTokens
    }

    static let contextWindow = 200_000

    var contextPercentage: Double {
        guard Self.contextWindow > 0 else { return 0 }
        return min(100, Double(totalTokens) / Double(Self.contextWindow) * 100)
    }

    struct ModelPricing {
        let inputPerMillion: Double
        let outputPerMillion: Double
        let cacheReadPerMillion: Double
        let cacheWritePerMillion: Double
    }

    static let opusPricing = ModelPricing(
        inputPerMillion: 15.0,
        outputPerMillion: 75.0,
        cacheReadPerMillion: 1.50,
        cacheWritePerMillion: 18.75
    )

    static let sonnetPricing = ModelPricing(
        inputPerMillion: 3.0,
        outputPerMillion: 15.0,
        cacheReadPerMillion: 0.30,
        cacheWritePerMillion: 3.75
    )

    func estimatedCost(model: String) -> Double {
        let pricing = model.contains("opus") ? Self.opusPricing : Self.sonnetPricing

        let inputCost = Double(inputTokens) / 1_000_000 * pricing.inputPerMillion
        let outputCost = Double(outputTokens) / 1_000_000 * pricing.outputPerMillion
        let cacheReadCost = Double(cacheReadInputTokens) / 1_000_000 * pricing.cacheReadPerMillion
        let cacheWriteCost = Double(cacheCreationInputTokens) / 1_000_000 * pricing.cacheWritePerMillion

        return inputCost + outputCost + cacheReadCost + cacheWriteCost
    }
}

// MARK: - Tool Execution

/// Represents a tool call in progress or completed
struct ClaudeToolExecution: Identifiable, Equatable {
    let id: String
    let toolName: String
    let argument: String?
    let startTime: Date
    var endTime: Date?
    var isRunning: Bool { endTime == nil }

    // New fields from JSONL
    var description: String?
    var timeout: Int?
    var inputTokens: Int?
    var outputTokens: Int?
    var cacheReadTokens: Int?
    var cacheWriteTokens: Int?

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

// MARK: - Todo Item

/// Claude Code todo item from TodoWrite tool
struct ClaudeTodoItem: Identifiable, Equatable {
    let id = UUID()
    let content: String
    let status: TodoStatus

    enum TodoStatus: String {
        case pending
        case inProgress = "in_progress"
        case completed
    }
}

// MARK: - Entrypoint (input environment)

/// Where the Claude Code input originated, from the JSONL top-level `entrypoint` field.
enum ClaudeEntrypoint: Equatable {
    case terminal   // "cli"
    case desktop    // "claude-desktop"
    case vscode     // "claude-vscode"
    case sdk        // "sdk-ts", "sdk-cli"
    case ssh        // remote server session (never read from JSONL)
    case unknown

    init(raw: String) {
        switch raw {
        case "cli": self = .terminal
        case "claude-desktop": self = .desktop
        case "claude-vscode": self = .vscode
        case "sdk-ts", "sdk-cli", "sdk": self = .sdk
        default: self = .unknown
        }
    }

    /// Short label for the footer badge
    var label: String {
        switch self {
        case .terminal: return "Terminal"
        case .desktop: return "Desktop"
        case .vscode: return "VS Code"
        case .sdk: return "SDK"
        case .ssh: return "SSH"
        case .unknown: return ""
        }
    }

    /// SF Symbol for the badge
    var iconName: String {
        switch self {
        case .terminal: return "terminal"
        case .desktop: return "macwindow"
        case .vscode: return "chevron.left.forwardslash.chevron.right"
        case .sdk: return "curlybraces"
        case .ssh: return "network"
        case .unknown: return "questionmark"
        }
    }

    /// Whether the badge should be shown (hidden until a known entrypoint is seen)
    var isVisible: Bool { self != .unknown }
}

// MARK: - Conversation Message

/// A single conversation message parsed from JSONL (user prompt or assistant text)
struct ClaudeMessage: Identifiable, Equatable {
    enum Role: String { case user, assistant }

    let id: UUID
    let role: Role
    let text: String
    let time: Date

    init(role: Role, text: String, time: Date = Date()) {
        self.id = UUID()
        self.role = role
        self.text = text
        self.time = time
    }
}

// MARK: - Interactive Input

struct ClaudeInputRequest: Identifiable, Equatable {
    let id: String
    let questions: [AgentInputQuestion]

    init(id: String, input: Any?) {
        self.id = id
        let raw = input as? [String: Any]
        questions = (raw?["questions"] as? [[String: Any]] ?? []).compactMap { question in
            guard let text = question["question"] as? String else { return nil }
            let options = (question["options"] as? [[String: Any]] ?? []).compactMap { option -> AgentInputOption? in
                guard let label = option["label"] as? String else { return nil }
                return AgentInputOption(label: label, description: option["description"] as? String ?? "")
            }
            return AgentInputQuestion(header: question["header"] as? String ?? "Question",
                                      question: text, options: options,
                                      multiSelect: question["multiSelect"] as? Bool ?? false)
        }
    }
}

// MARK: - Complete State

/// Complete Claude Code state for display
struct ClaudeCodeState: Equatable {
    var sessionId: String = ""
    var model: String = ""
    var cwd: String = ""
    var gitBranch: String = ""
    var entrypoint: ClaudeEntrypoint = .unknown

    var tokenUsage: ClaudeTokenUsage = ClaudeTokenUsage()

    var activeTools: [ClaudeToolExecution] = []
    var recentTools: [ClaudeToolExecution] = []

    /// Recent conversation messages (user prompts + assistant text), oldest first
    var recentMessages: [ClaudeMessage] = []

    var todos: [ClaudeTodoItem] = []

    var isConnected: Bool = false
    var lastUpdateTime: Date?

    /// Questions waiting for answers, separate from tool execution approval.
    var pendingInputRequests: [ClaudeInputRequest] = []
    var isAwaitingInput: Bool { !pendingInputRequests.isEmpty }

    /// True when Claude is waiting for user permission to execute a tool
    var needsPermission: Bool = false
    /// True when `needsPermission` was set by Claude Code's own Notification hook
    /// (deterministic) rather than guessed from JSONL tool_use/tool_result timing
    /// (a tool just running long looks identical to one genuinely awaiting the user).
    /// Only hook-confirmed sessions should trigger an interruptive peek notification.
    var needsPermissionConfirmed: Bool = false
    /// The tool waiting for permission (if any)
    var pendingPermissionTool: String?

    /// True when Claude is actively generating a response (thinking)
    var isThinking: Bool = false

    /// When the current turn started (set on user/assistant activity, cleared on end_turn).
    /// nil = no turn in progress. Keeps the active indicator alive across silent
    /// thinking gaps where no JSONL is written.
    var turnStartTime: Date?

    /// Last stop_reason from Claude (e.g., "end_turn", "tool_use")
    var lastStopReason: String?

    /// True when the session completed its last response (stop_reason = end_turn and not active)
    var isSessionComplete: Bool {
        lastStopReason == "end_turn" && !isThinking && activeTools.isEmpty
    }

    // Convenience accessors
    var contextPercentage: Double { tokenUsage.contextPercentage }
    var hasActiveTools: Bool { !activeTools.isEmpty }
    var currentToolName: String? { activeTools.first?.toolName }

    /// True when the session is actively processing (thinking or running tools)
    var isActive: Bool { turnStartTime != nil || isThinking || hasActiveTools }
}
