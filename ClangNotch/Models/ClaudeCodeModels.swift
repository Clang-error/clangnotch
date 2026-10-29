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
        guard let workspacePath else { return L("알 수 없음", "Unknown") }
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
    /// Edit/Write's removed and added lines, for the 세션 화면.
    var change: ToolChange?
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
/// One line of the Current Tasks 카드: a TodoWrite entry, or a task from TaskCreate that
/// TaskUpdate then moves along by `taskId`.
struct ClaudeTodoItem: Identifiable, Equatable {
    let id = UUID()
    var content: String
    var status: TodoStatus
    /// TaskCreate's tool_use id, until its result names the task.
    var createdBy: String? = nil
    var taskId: String? = nil

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
    /// The Claude desktop app's next-step box (`mcp__ccd_turn__wrap_up` with an `ask`). Its
    /// tool result comes back at once, so only the user's next message ends it.
    var isWrapUp = false
    /// The box's explanation above its question.
    var recap: String?

    /// A box asking the user something, or nil for a plain recap. Its buttons only send a
    /// prepared message in the app, so the notch shows them without answering.
    static func wrapUp(id: String, input: Any?) -> ClaudeInputRequest? {
        // Most boxes with a question carry no `blocked` at all; only `ask` marks one.
        guard let raw = input as? [String: Any], let ask = raw["ask"] as? String,
              !ask.isEmpty else { return nil }
        let options = (raw["actions"] as? [[String: Any]] ?? []).compactMap { action -> AgentInputOption? in
            guard let label = action["label"] as? String else { return nil }
            return AgentInputOption(label: label, description: action["message"] as? String ?? "")
        }
        var request = ClaudeInputRequest(id: id, questions: [
            AgentInputQuestion(header: "Next step", question: ask, options: options)
        ])
        request.isWrapUp = true
        request.recap = raw["recap"] as? String
        return request
    }

    private init(id: String, questions: [AgentInputQuestion]) {
        self.id = id
        self.questions = questions
    }

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

    // Convenience accessors
    var contextPercentage: Double { tokenUsage.contextPercentage }
    var hasActiveTools: Bool { !activeTools.isEmpty }
    var currentToolName: String? { activeTools.first?.toolName }

    /// True when the session is actively processing (thinking or running tools)
    var isActive: Bool { turnStartTime != nil || isThinking || hasActiveTools }
}
