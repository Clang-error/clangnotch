"""Exercise production parsers/history/read/idle methods with isolated fixture state.
Only UI, timers, conversation and quota side effects are stubbed. No real logs touched.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]

def method(source, name):
    prefix = '    private func ' if '    private func ' + name + '(' in source else '    func '
    start = source.index(prefix + name + '(')
    end = source.index('\n    }', start) + len('\n    }')
    return source[start:end].replace('private func', 'func', 1)

def formatter(source, name):
    start = source.index('    private static let ' + name + ':')
    end = source.index('\n    }()', start) + len('\n    }()')
    return source[start:end].replace('private static let', 'static let', 1)

claude = (root/'ClangNotch/Core/ClaudeCode/ClaudeCodeManager.swift').read_text()
codex = (root/'ClangNotch/Core/Codex/CodexManager.swift').read_text()
common = '''
    let objectWillChange = ObservableObjectPublisher()
    var selectedSession: Selection? = Selection(id: "s")
    var sessionReadPositions: [String: UInt64] = [:]
    var sessionFileHandles: [String: FileHandle] = [:]
    var sessionLineBuffers: [String: JSONLLineBuffer] = [:]
    var isLoadingHistoryBySession: [String: Bool] = [:]
    var nextCheck: TimeInterval?
    func resetIdleTimer(after delay: TimeInterval? = nil) { nextCheck = delay }
'''
swift = '''import Foundation
import Combine
func debugLog(_ value: @autoclosure () -> String) {}
func check(_ condition: @autoclosure () -> Bool, _ message: String = "Check failed") {
    guard condition() else {
        print("FAIL: \\(message)")
        exit(1)
    }
}
func L(_ korean: String, _ english: String) -> String { korean }
struct Selection { let id: String }
final class ClaudeFixture {
''' + common + '''
    var state = ClaudeCodeState()
    var sessionStates = ["s": ClaudeCodeState()]
    var sessionScanTimer: Bool? = true
    var remoteSessions: [String: ClaudeSession] = [:]
    var availableSessions: [ClaudeSession] = []
    var sessionJSONLPaths = ["s": "/test.jsonl"]
    var completedQuestionHookIDs: [String: Set<String>] = [:]
    var completedTurnMessageIDs: [String: String] = [:]
    var dismissedInputRequestIDs: Set<String> = []
    var lastTurnCompletedAt: Date?
    var lastCompletedTurn: CompletedTurn?
    let questionToolName = "AskUserQuestion"
    let wrapUpToolName = "mcp__ccd_turn__wrap_up"
    let questionWaitStaleAfter: TimeInterval = 300
    let staleLineAfter: TimeInterval = 120
    let turnSafetyTimeout: TimeInterval = 300
    func resetToolIdleTimer() {}
    func updateSessionsNeedingPermission() {}
    func captureConversation(from: [String: Any], into: inout ClaudeCodeState) {}
    func parseTodosFromArray(_ value: [[String: Any]]) -> [ClaudeTodoItem] { [] }
    func extractToolArgument(from: Any?) -> String? { nil }
    func scanForSessions() { availableSessions = Array(remoteSessions.values) }
    func displayableUserPrompt(_ raw: String) -> String? { raw }
    func appendConversationMessage(_ message: ClaudeMessage, into: inout ClaudeCodeState) {}
'''
swift += formatter(claude, 'lineTimestampFormatters') + '\n'
start = claude.index('    private static let attentionNotificationTypes:')
end = claude.index('\n    ]', start) + len('\n    ]')
swift += claude[start:end].replace('private static let', 'static let', 1) + '\n'
for name in ['parseMessageForSession','parseJSONLLineForSession','syncStateIfSelected','clearPermissionCheckForSession','handleLocalQuestionHook','handleNotificationHook','handleRemoteHook','loadRecentHistoryForSession','readNewSessionDataForSession','markAllSessionsIdle','dismissInputRequest','dismissPermission']:
    swift += method(claude, name) + '\n'
swift += '}\nfinal class CodexFixture {\n' + common + '''
    var state = CodexState()
    var sessionStates = ["s": CodexState()]
    var pendingFunctionCalls: [String: [String: Date]] = [:]
    var dismissedInputRequestIDs: Set<String> = []
    var externalImportSessions: Set<String> = []
    var sessionsDir = FileManager.default.temporaryDirectory
    var availableSessions: [CodexSession] = []
    var sessionWatchers: [String: Bool] = [:]
    var sessionActivityCache: [URL: (modifiedAt: Date, fileSize: UInt64, activity: Date?)] = [:]
    var rateLimits = CodexRateLimits()
    var lastTurnCompletedAt: Date?
    var lastCompletedTurn: CompletedTurn?
    func clearEndedSessions() {}
    func loadLatestRateLimits(from: URL) {}
    func selectSession(_ session: CodexSession) { selectedSession = Selection(id: session.id) }
    func startWatchingSession(_ session: CodexSession) {
        sessionWatchers[session.id] = true
        sessionStates[session.id] = CodexState()
        loadRecentHistoryForSession(from: session.jsonlFile, sessionId: session.id)
    }
    func stopWatchingSession(id: String) { sessionWatchers.removeValue(forKey: id); sessionStates.removeValue(forKey: id) }
    let staleLineAfter: TimeInterval = 120
    static let plainISO8601Formatter = ISO8601DateFormatter()
    func markUsageLimitExceeded(at: Date) {}
    func parseRateLimits(_ raw: [String: Any]) -> CodexRateLimits { CodexRateLimits() }
    func mergeRateLimits(_ limits: CodexRateLimits, at: Date) {}
'''
swift += formatter(codex, 'iso8601Formatter') + '\n'
for name in ['scanForSessions','parseSessionFromFile','readFirstJSONLRecord','parseResponseItem','parseInputRequest','parseEventMsg','parseJSONLLine','loadRecentHistoryForSession','readNewSessionData','markAllSessionsIdle']:
    swift += method(codex, name) + '\n'
if '    private func latestCodexActivityDate(' in codex:
    swift += method(codex, 'latestCodexActivityDate') + '\n'
swift += '''}
@main struct Checks {
    static func main() throws {
        // Every possible split, including the middle of a Korean UTF-8 character.
        let bytes = Data("{\\"text\\":\\"생각중\\"}\\n{\\"end\\":true}\\n".utf8)
        for split in 0...bytes.count {
            var buffer = JSONLLineBuffer()
            let lines = buffer.append(Data(bytes.prefix(split))) + buffer.append(Data(bytes.dropFirst(split)))
            precondition(lines.count == 2)
            precondition(lines.allSatisfy { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) != nil })
        }
        // Claude desktop next-step box: waits past its own tool result, ends on the user's message.
        let w = ClaudeFixture()
        let box: [String: Any] = ["ask": "받아도 될까요?",
                                  "actions": [["label": "받아도 돼", "message": "받아서 조사해"], ["label": "안 받고", "message": "웹으로만"]]]
        w.parseMessageForSession(["role":"assistant", "content":[["type":"tool_use", "id":"box", "name":"mcp__ccd_turn__wrap_up", "input": box]]], sessionId:"s")
        w.parseMessageForSession(["role":"user", "content":[["type":"tool_result", "tool_use_id":"box"]]], sessionId:"s")
        precondition(w.state.pendingInputRequests.first?.questions.first?.options.map(\.label) == ["받아도 돼", "안 받고"],
                     "A box with a question stays after its tool result, with or without blocked")
        w.parseMessageForSession(["role":"user", "content":"<system-reminder>x</system-reminder>"], sessionId:"s", isMeta: true)
        precondition(w.state.isAwaitingInput, "Meta lines are not the user's answer")
        w.parseMessageForSession(["role":"user", "content":"받아서 조사해"], sessionId:"s")
        precondition(!w.state.isAwaitingInput, "The user's message answers the box")
        let recap: [String: Any] = ["recap": "끝났습니다."]
        w.parseMessageForSession(["role":"assistant", "content":[["type":"tool_use", "id":"r", "name":"mcp__ccd_turn__wrap_up", "input": recap]]], sessionId:"s")
        precondition(!w.state.isAwaitingInput, "A recap without a question waits for nothing")
        let closed = ClaudeFixture()
        closed.parseMessageForSession(["role":"assistant", "content":[["type":"tool_use", "id":"box", "name":"mcp__ccd_turn__wrap_up", "input": box]]], sessionId:"s")
        closed.dismissInputRequest(id: "box")
        precondition(!closed.state.isAwaitingInput, "The X closes the box")
        closed.parseMessageForSession(["role":"assistant", "content":[["type":"tool_use", "id":"box", "name":"mcp__ccd_turn__wrap_up", "input": box]]], sessionId:"s")
        precondition(!closed.state.isAwaitingInput, "Reading the closed box's line again doesn't reopen it")
        let c = ClaudeFixture()
        c.parseMessageForSession(["role":"assistant", "content":[["type":"tool_use", "id":"t", "name":"Bash"]]], sessionId:"s")
        precondition(c.state.isActive && c.state.hasActiveTools)
        c.parseMessageForSession(["role":"user", "content":[["type":"tool_result", "tool_use_id":"t"]]], sessionId:"s")
        c.parseMessageForSession(["role":"assistant", "content":[["type":"thinking"]]], sessionId:"s")
        precondition(c.state.isThinking && c.state.isActive && !c.state.hasActiveTools)
        c.sessionStates["s"]?.turnStartTime = Date(timeIntervalSinceNow: -600)
        c.markAllSessionsIdle()
        precondition(c.state.isActive && c.nextCheck! > 290, "Recent work must extend an old turn")
        c.sessionStates["s"]?.lastUpdateTime = Date(timeIntervalSinceNow: -301)
        c.markAllSessionsIdle()
        precondition(!c.state.isActive, "Missing completion must expire")
        for terminal in ["end_turn", "stop_sequence", "max_tokens"] {
            c.parseMessageForSession(["role":"assistant", "stop_reason":terminal, "content":[["type":"text", "text":"done"]]], sessionId:"s")
            precondition(!c.state.isActive && c.state.lastStopReason == terminal)
        }
        c.lastTurnCompletedAt = nil
        c.parseMessageForSession(["id":"m1", "role":"assistant", "stop_reason":"end_turn", "content":[["type":"thinking"]]], sessionId:"s")
        precondition(c.lastTurnCompletedAt == nil, "A thinking line of the final message is not the end yet")
        c.parseMessageForSession(["id":"m1", "role":"assistant", "stop_reason":"end_turn", "content":[["type":"text", "text":"done"]]], sessionId:"s")
        precondition(c.lastTurnCompletedAt != nil, "The final answer text closes the turn")
        c.lastTurnCompletedAt = nil
        c.parseMessageForSession(["id":"m1", "role":"assistant", "stop_reason":"end_turn", "content":[["type":"text", "text":"more"]]], sessionId:"s")
        precondition(c.lastTurnCompletedAt == nil, "One message announces Done once")
        c.isLoadingHistoryBySession["s"] = true
        c.parseMessageForSession(["id":"m2", "role":"assistant", "stop_reason":"end_turn", "content":[["type":"text", "text":"old"]]], sessionId:"s")
        c.isLoadingHistoryBySession["s"] = nil
        precondition(c.lastTurnCompletedAt == nil, "Replayed history must not announce Done")
        c.parseMessageForSession(["id":"m3", "role":"assistant", "stop_reason":"max_tokens", "content":[["type":"text", "text":"cut"]]], sessionId:"s")
        precondition(c.lastTurnCompletedAt == nil, "Only end_turn counts as a normal finish")
        c.parseMessageForSession(["role":"assistant", "content":[["type":"tool_use", "id":"t2", "name":"Bash"]]], sessionId:"s")
        c.parseMessageForSession(["role":"user", "content":[["type":"tool_result", "tool_use_id":"t2"]]], sessionId:"s")
        c.parseJSONLLineForSession(#"{"type":"api-request-blob","message":{"role":"assistant","content":[{"type":"tool_use","id":"t2","name":"Bash"}]}}"#, sessionId:"s")
        precondition(!c.state.hasActiveTools, "A request blob replaying the prompt must not re-run a finished tool")
        c.parseMessageForSession(["id":"m4", "role":"assistant", "stop_reason":"end_turn", "content":[["type":"text", "text":"done"]]], sessionId:"s")
        precondition(!c.state.isActive, "The turn ends with no ghost tool left running")
        c.parseJSONLLineForSession("{\\"type\\":\\"system\\"}", sessionId:"s")
        precondition(!c.state.isActive, "Metadata must not restart a finished turn")
        c.parseMessageForSession(["role":"assistant", "content":[["type":"tool_use", "id":"q", "name":"AskUserQuestion"]]], sessionId:"s")
        precondition(!c.state.needsPermission, "Questions must not be classified as tool approvals")
        c.sessionStates["s"]?.lastUpdateTime = Date(timeIntervalSinceNow: -600)
        c.markAllSessionsIdle()
        precondition(c.state.isAwaitingInput && !c.state.needsPermission && c.state.isActive)
        c.parseMessageForSession(["role":"user", "content":[["type":"tool_result", "tool_use_id":"q"]]], sessionId:"s")
        precondition(!c.state.isAwaitingInput && !c.state.needsPermission && c.state.isThinking)

        let questionInput: [String: Any] = ["questions": [["header": "선택", "question": "어떤 방식을 사용할까요?", "multiSelect": true, "options": [["label": "첫 방식", "description": "긴 선택지 설명"], ["label": "둘째 방식", "description": "다른 설명"]]]]]
        c.parseMessageForSession(["role":"assistant", "content":[["type":"tool_use", "id":"details", "name":"AskUserQuestion", "input": questionInput]]], sessionId:"s")
        let question = c.state.pendingInputRequests.first!.questions.first!
        precondition(question.header == "선택" && question.question == "어떤 방식을 사용할까요?" && question.multiSelect)
        precondition(question.options.first?.description == "긴 선택지 설명")
        c.handleNotificationHook(transcriptPath: "/test.jsonl", notificationType: "permission_prompt")
        precondition(c.state.isAwaitingInput && !c.state.needsPermission, "A question notification must not become a tool approval")
        c.parseMessageForSession(["role":"assistant", "content":[["type":"tool_use", "id":"parallel", "name":"Bash"]]], sessionId:"s")
        c.parseMessageForSession(["role":"user", "content":[["type":"tool_result", "tool_use_id":"parallel"]]], sessionId:"s")
        precondition(c.state.isAwaitingInput, "An unrelated tool result must not dismiss a question")
        c.parseMessageForSession(["role":"user", "content":[["type":"tool_result", "tool_use_id":"details"]]], sessionId:"s")
        precondition(!c.state.isAwaitingInput && !c.state.needsPermission)
        c.parseMessageForSession(["role":"assistant", "content":[["type":"tool_use", "id":"approval", "name":"Bash"]]], sessionId:"s")
        c.handleNotificationHook(transcriptPath: "/test.jsonl", notificationType: "permission_prompt")
        precondition(c.state.needsPermission && !c.state.isAwaitingInput, "Real tool approvals must stay separate")
        c.parseMessageForSession(["role":"user", "content":[["type":"tool_result", "tool_use_id":"approval"]]], sessionId:"s")
        precondition(!c.state.needsPermission)
        c.handleNotificationHook(transcriptPath: "/test.jsonl", notificationType: "elicitation_dialog")
        precondition(c.state.isAwaitingInput && !c.state.needsPermission, "MCP input is a question rather than an approval")
        precondition(c.state.pendingInputRequests.first?.questions.isEmpty == true, "A notification without question text must not invent content")
        c.parseMessageForSession(["role":"user", "content":"답변"], sessionId:"s")
        precondition(!c.state.isAwaitingInput)

        // A hook must show the complete question even before any tool_use JSONL exists.
        let local = ClaudeFixture()
        let questionHook: [String: Any] = ["transcript_path":"/test.jsonl", "hook_event_name":"PreToolUse", "tool_name":"AskUserQuestion", "tool_use_id":"hook-q", "tool_input":questionInput]
        local.handleLocalQuestionHook(json: questionHook)
        precondition(local.state.pendingInputRequests.first?.questions.first == question)
        precondition(!local.state.needsPermission && local.state.isAwaitingInput)
        local.handleNotificationHook(transcriptPath: "/test.jsonl", notificationType: "permission_prompt")
        precondition(!local.state.needsPermission, "A native question notification must stay an answer wait")
        local.handleLocalQuestionHook(json: questionHook)
        local.parseMessageForSession(["role":"assistant", "content":[["type":"tool_use", "id":"hook-q", "name":"AskUserQuestion", "input":questionInput]]], sessionId:"s")
        precondition(local.state.pendingInputRequests.count == 1, "Hook and JSONL must identify the same question")
        local.handleLocalQuestionHook(json: ["transcript_path":"/test.jsonl", "hook_event_name":"PostToolUse", "tool_name":"Bash", "tool_use_id":"unrelated"])
        precondition(local.state.isAwaitingInput, "Other hooks must not close the question")
        local.handleLocalQuestionHook(json: ["transcript_path":"/test.jsonl", "hook_event_name":"PostToolUse", "tool_name":"AskUserQuestion", "tool_use_id":"hook-q"])
        precondition(!local.state.isAwaitingInput, "A real answer hook must close the question before JSONL is written")
        local.parseMessageForSession(["role":"assistant", "content":[["type":"tool_use", "id":"hook-q", "name":"AskUserQuestion", "input":questionInput]]], sessionId:"s")
        precondition(!local.state.isAwaitingInput && !local.state.hasActiveTools, "Late JSONL must not reopen an answered question")
        local.handleLocalQuestionHook(json: questionHook)
        precondition(!local.state.isAwaitingInput, "A duplicate start arriving after completion must be ignored")
        local.handleLocalQuestionHook(json: ["transcript_path":"/test.jsonl", "hook_event_name":"PreToolUse", "tool_name":"AskUserQuestion", "tool_use_id":"failed-q", "tool_input":questionInput])
        local.handleLocalQuestionHook(json: ["transcript_path":"/test.jsonl", "hook_event_name":"PostToolUseFailure", "tool_name":"AskUserQuestion", "tool_use_id":"failed-q"])
        precondition(!local.state.isAwaitingInput, "Failed questions must not remain pending")
        local.sessionScanTimer = nil
        local.handleLocalQuestionHook(json: ["transcript_path":"/test.jsonl", "hook_event_name":"PreToolUse", "tool_name":"AskUserQuestion", "tool_use_id":"tracking-off", "tool_input":questionInput])
        precondition(!local.state.isAwaitingInput, "Hooks must respect disabled tracking")

        let remote = ClaudeFixture()
        remote.handleRemoteHook(host: "fixture", json: ["session_id":"remote", "cwd":"/example", "hook_event_name":"PreToolUse", "tool_use_id":"remote-q", "tool_name":"AskUserQuestion", "tool_input":questionInput])
        let remoteId = remote.remoteSessions["remote"]!.id
        precondition(remote.sessionStates[remoteId]?.pendingInputRequests.first?.questions.first == question)
        remote.handleRemoteHook(host: "fixture", json: ["session_id":"remote", "hook_event_name":"Notification", "notification_type":"permission_prompt"])
        precondition(remote.sessionStates[remoteId]?.isAwaitingInput == true && remote.sessionStates[remoteId]?.needsPermission == false)
        remote.sessionStates[remoteId]?.lastUpdateTime = Date(timeIntervalSinceNow: -600)
        remote.markAllSessionsIdle()
        precondition(remote.sessionStates[remoteId]?.isAwaitingInput == true, "Known SSH questions must wait for the answer instead of expiring")
        remote.handleRemoteHook(host: "fixture", json: ["session_id":"remote", "hook_event_name":"PostToolUse", "tool_use_id":"remote-q", "tool_name":"AskUserQuestion"])
        precondition(remote.sessionStates[remoteId]?.isAwaitingInput == false)
        remote.handleRemoteHook(host: "fixture", json: ["session_id":"remote", "hook_event_name":"PreToolUse", "tool_use_id":"cancel-q", "tool_name":"AskUserQuestion", "tool_input":questionInput])
        remote.handleRemoteHook(host: "fixture", json: ["session_id":"remote", "hook_event_name":"Stop"])
        precondition(remote.sessionStates[remoteId]?.isAwaitingInput == false)

        let x = CodexFixture()
        var xs = CodexState()
        x.parseResponseItem(["type":"reasoning"], sessionState:&xs, sessionId:"s", eventTimestamp:Date())
        precondition(xs.isTurnInProgress && xs.isThinking, "No task_started required")
        x.sessionStates["s"] = xs
        x.markAllSessionsIdle()
        precondition(x.state.isActive && x.state.isThinking && x.nextCheck! > 290)
        x.parseResponseItem(["type":"message", "role":"assistant", "phase":"commentary", "content":[["type":"output_text", "text":"working"]]], sessionState:&xs, sessionId:"s", eventTimestamp:Date())
        precondition(xs.isActive)
        x.parseResponseItem(["type":"custom_tool_call", "call_id":"t", "name":"exec_command", "input":"{}"], sessionState:&xs, sessionId:"s", eventTimestamp:Date())
        precondition(xs.hasActiveTools && xs.isActive)
        x.parseResponseItem(["type":"custom_tool_call_output", "call_id":"t", "output":"ok"], sessionState:&xs, sessionId:"s", eventTimestamp:Date())
        precondition(xs.isThinking && !xs.hasActiveTools)
        x.parseResponseItem(["type":"message", "role":"assistant", "phase":"final_answer", "content":[["type":"output_text", "text":"done"]]], sessionState:&xs, sessionId:"s", eventTimestamp:Date())
        precondition(!xs.isActive)

        let asyncInput = #"{"questions":[{"title":"색상과 폭은 어떤가요?","options":["정상","아직 좁음"]},{"title":"추가 의견"}]}"#
        x.parseResponseItem(["type":"function_call", "call_id":"async-q", "name":"request_user_input_async", "arguments":asyncInput], sessionState:&xs, sessionId:"s", eventTimestamp:Date())
        precondition(xs.pendingInputRequest?.questions.first?.question == "색상과 폭은 어떤가요?", "Desktop async questions must be detected")
        precondition(xs.pendingInputRequest?.questions.first?.options.map(\\.label) == ["정상", "아직 좁음"])
        x.parseResponseItem(["type":"function_call_output", "call_id":"async-q", "output":#"{"accepted":true}"#], sessionState:&xs, sessionId:"s", eventTimestamp:Date())
        precondition(xs.pendingInputRequest != nil && xs.activeTools.isEmpty, "Acceptance is not an answer")
        x.parseResponseItem(["type":"message", "role":"assistant", "phase":"final_answer", "content":[["type":"output_text", "text":"waiting"]]], sessionState:&xs, sessionId:"s", eventTimestamp:Date())
        x.parseEventMsg(["type":"task_complete"], sessionState:&xs, sessionId:"s", rateLimitTimestamp:Date())
        precondition(xs.pendingInputRequest != nil && !xs.isActive, "Async questions outlive the sending turn")
        precondition(x.lastTurnCompletedAt != nil, "task_complete announces Done")
        x.lastTurnCompletedAt = nil
        var aborted = CodexState()
        x.parseEventMsg(["type":"turn_aborted"], sessionState:&aborted, sessionId:"s", rateLimitTimestamp:Date())
        x.parseEventMsg(["type":"task_complete", "error":["codex_error_info":"usage_limit_exceeded"]], sessionState:&aborted, sessionId:"s", rateLimitTimestamp:Date())
        precondition(x.lastTurnCompletedAt == nil, "Aborted or rejected turns are not Done")
        func reply(_ call: String, indices: [Int]) throws -> [String: Any] {
            let answers: [[String: Any]] = try indices.map { index in
                let key = String(data: try JSONSerialization.data(withJSONObject: ["request_user_input_async", call, index]), encoding: .utf8)!
                return ["questionItemId": key, "answer": "정상"]
            }
            let body = String(data: try JSONSerialization.data(withJSONObject: answers), encoding: .utf8)!
            return ["type":"message", "role":"user", "content":[["type":"input_text", "text":"<send_user_message_question_reply>\\n" + body + "\\n</send_user_message_question_reply>"]]]
        }
        x.parseResponseItem(try reply("other-q", indices: [0, 1]), sessionState:&xs, sessionId:"s", eventTimestamp:Date())
        precondition(xs.pendingInputRequest != nil, "Another request's answer must not dismiss this question")
        x.parseResponseItem(try reply("async-q", indices: [0]), sessionState:&xs, sessionId:"s", eventTimestamp:Date())
        precondition(xs.pendingInputRequest != nil, "Keep waiting for unanswered questions")
        x.parseResponseItem(try reply("async-q", indices: [1]), sessionState:&xs, sessionId:"s", eventTimestamp:Date())
        precondition(xs.pendingInputRequest == nil, "The matching answers must dismiss the dropdown")
        for prompt in ["켜놨어", "그냥 냅둬라 언제오는지만"] {
            x.parseResponseItem(["type":"function_call", "call_id":"text-reply-q", "name":"request_user_input_async", "arguments":asyncInput], sessionState:&xs, sessionId:"s", eventTimestamp:Date())
            x.parseResponseItem(["type":"function_call_output", "call_id":"text-reply-q", "output":#"{"accepted":true}"#], sessionState:&xs, sessionId:"s", eventTimestamp:Date())
            x.parseEventMsg(["type":"task_complete"], sessionState:&xs, sessionId:"s", rateLimitTimestamp:Date())
            x.parseResponseItem(["type":"message", "role":"user", "content":[["type":"input_text", "text":"<external_context>updated</external_context>"]]], sessionState:&xs, sessionId:"s", eventTimestamp:Date())
            precondition(xs.pendingInputRequest != nil, "Context updates must not dismiss an unanswered question")
            x.parseResponseItem(["type":"message", "role":"user", "content":[["type":"input_text", "text":prompt]]], sessionState:&xs, sessionId:"s", eventTimestamp:Date())
            precondition(xs.pendingInputRequest == nil && xs.lastUserPrompt == prompt, "A normal chat reply or new instruction must retire the previous async question")
        }
        x.parseResponseItem(["type":"function_call", "call_id":"rejected-q", "name":"request_user_input_async", "arguments":asyncInput], sessionState:&xs, sessionId:"s", eventTimestamp:Date())
        x.parseResponseItem(["type":"function_call_output", "call_id":"rejected-q", "output":#"{"accepted":false}"#], sessionState:&xs, sessionId:"s", eventTimestamp:Date())
        precondition(xs.pendingInputRequest == nil, "A rejected question must not remain pending")
        let syncInput = #"{"questions":[{"header":"Test","question":"질문","options":[{"label":"선택","description":"설명"}]}]}"#
        x.parseResponseItem(["type":"custom_tool_call", "call_id":"sync-q", "name":"request_user_input", "input":syncInput], sessionState:&xs, sessionId:"s", eventTimestamp:Date())
        precondition(xs.pendingInputRequest?.questions.first?.options.first?.description == "설명")
        x.parseResponseItem(["type":"custom_tool_call_output", "call_id":"sync-q", "output":"answer"], sessionState:&xs, sessionId:"s", eventTimestamp:Date())
        precondition(xs.pendingInputRequest == nil, "Existing blocking questions must still end on tool output")
        x.parseEventMsg(["type":"task_started"], sessionState:&xs, sessionId:"s", rateLimitTimestamp:Date())
        precondition(xs.isActive)
        x.parseEventMsg(["type":"turn_aborted"], sessionState:&xs, sessionId:"s", rateLimitTimestamp:Date())
        precondition(!xs.isActive)
        xs.isTurnInProgress = true; xs.lastUpdateTime = Date(timeIntervalSinceNow: -301)
        x.sessionStates["s"] = xs; x.markAllSessionsIdle()
        precondition(!x.state.isActive)

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let timestamp = ISO8601DateFormatter()
        timestamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let oldDate = Date(timeIntervalSinceNow: -3600)
        let oldTimestamp = timestamp.string(from: oldDate)
        let imported = folder.appendingPathComponent("imported.jsonl")
        let oldCodexLine = "{\\"timestamp\\":\\"\\(oldTimestamp)\\",\\"type\\":\\"response_item\\",\\"payload\\":{\\"type\\":\\"reasoning\\"}}\\n"
        try Data(oldCodexLine.utf8).write(to: imported)
        let importedCodex = CodexFixture()
        importedCodex.loadRecentHistoryForSession(from: imported, sessionId: "s")
        precondition(!importedCodex.state.isActive, "Fresh file mtime must not revive old imported reasoning")
        precondition(abs(importedCodex.state.lastUpdateTime!.timeIntervalSince(oldDate)) < 1)
        let appendedCodex = CodexFixture()
        appendedCodex.parseJSONLLine(oldCodexLine, sessionId: "s")
        precondition(!appendedCodex.state.isActive, "Re-appended old reasoning must not start a turn")
        let oldClaudeLine = "{\\"timestamp\\":\\"\\(oldTimestamp)\\",\\"message\\":{\\"role\\":\\"assistant\\",\\"content\\":[{\\"type\\":\\"thinking\\"}]}}\\n"
        try Data(oldClaudeLine.utf8).write(to: imported)
        let importedClaude = ClaudeFixture()
        importedClaude.loadRecentHistoryForSession(from: imported, sessionId: "s")
        precondition(!importedClaude.state.isActive)
        precondition(abs(importedClaude.state.lastUpdateTime!.timeIntervalSince(oldDate)) < 1, "Sync mtime must not replace Claude activity time")
        let importing = CodexFixture()
        let importTimestamp = timestamp.string(from: Date())
        let importStart = "{\\"timestamp\\":\\"\\(importTimestamp)\\",\\"type\\":\\"event_msg\\",\\"payload\\":{\\"type\\":\\"task_started\\",\\"turn_id\\":\\"external-import-turn-1\\"}}"
        importing.parseJSONLLine(importStart, sessionId: "s")
        precondition(!importing.state.isActive, "External import must not start live activity")
        let importMessage = "{\\"timestamp\\":\\"\\(importTimestamp)\\",\\"type\\":\\"response_item\\",\\"payload\\":{\\"type\\":\\"message\\",\\"role\\":\\"user\\",\\"content\\":[{\\"type\\":\\"input_text\\",\\"text\\":\\"Imported prompt\\"}]}}"
        importing.parseJSONLLine(importMessage, sessionId: "s")
        precondition(!importing.state.isActive && importing.state.lastUserPrompt == "Imported prompt")
        importing.parseJSONLLine(importStart.replacingOccurrences(of: "task_started", with: "task_complete"), sessionId: "s")
        importing.parseJSONLLine(importStart.replacingOccurrences(of: "external-import-turn-1", with: "live-turn"), sessionId: "s")
        precondition(importing.state.isActive, "A real turn after import must still start")
        let liveUpdate = importing.state.lastUpdateTime
        importing.parseJSONLLine(oldCodexLine, sessionId: "s")
        precondition(importing.state.isActive && importing.state.lastUpdateTime == liveUpdate)
        importing.parseJSONLLine(importStart, sessionId: "s")
        importing.parseJSONLLine(importMessage.replacingOccurrences(of: "user", with: "assistant"), sessionId: "s")
        importing.parseJSONLLine(importStart.replacingOccurrences(of: "task_started", with: "task_complete"), sessionId: "s")
        precondition(importing.state.isActive && importing.state.lastUpdateTime == liveUpdate, "Import must not end a running turn")
        let truncatedImport = CodexFixture()
        let importEnd = importStart.replacingOccurrences(of: "task_started", with: "task_complete")
        let discoveryFolder = folder.appendingPathComponent("discovery")
        try FileManager.default.createDirectory(at: discoveryFolder, withIntermediateDirectories: true)
        func sessionFile(_ id: String, _ body: String) throws -> URL {
            let file = discoveryFolder.appendingPathComponent("rollout-" + id + ".jsonl")
            let meta = "{\\"timestamp\\":\\"\\(importTimestamp)\\",\\"type\\":\\"session_meta\\",\\"payload\\":{\\"id\\":\\"\\(id)\\",\\"cwd\\":\\"/example\\",\\"originator\\":\\"Codex Desktop\\"}}\\n"
            try Data((meta + body + "\\n").utf8).write(to: file)
            return file
        }
        let importedOnly = try sessionFile("claude-only", importStart + "\\n" + importMessage + "\\n" + importEnd)
        let discovery = CodexFixture(); discovery.sessionsDir = discoveryFolder
        discovery.scanForSessions()
        precondition(discovery.availableSessions.isEmpty, "Claude-only imports must not appear as recent Codex sessions")
        let realStart = importStart.replacingOccurrences(of: "external-import-turn-1", with: "real-turn")
        _ = try sessionFile("real", realStart)
        _ = try sessionFile("opened-old", realStart.replacingOccurrences(of: importTimestamp, with: oldTimestamp))
        _ = try sessionFile("metadata-only", "{\\"timestamp\\":\\"\\(importTimestamp)\\",\\"type\\":\\"event_msg\\",\\"payload\\":{\\"type\\":\\"thread_settings_applied\\"}}")
        discovery.scanForSessions()
        precondition(Set(discovery.availableSessions.map(\\.id)) == ["real"], "Opening old conversations or settings must not count as Codex activity")
        let append = try FileHandle(forWritingTo: importedOnly)
        append.seekToEndOfFile(); append.write(Data((realStart + "\\n").utf8)); try append.close()
        discovery.scanForSessions()
        precondition(Set(discovery.availableSessions.map(\\.id)) == ["real", "claude-only"], "Imported conversation must appear after genuine Codex work starts")
        let largeMetadata = "{\\"type\\":\\"event_msg\\",\\"payload\\":{\\"type\\":\\"thread_settings_applied\\",\\"padding\\":\\"" + String(repeating: "동기화", count: 80_000) + "\\"}}"
        _ = try sessionFile("large-tail", realStart + "\\n" + largeMetadata)
        discovery.scanForSessions()
        precondition(discovery.availableSessions.contains { $0.id == "large-tail" }, "A large metadata record must not hide actual work")
        _ = try sessionFile("replayed-history", realStart + "\\n" + oldCodexLine)
        let restarted = CodexFixture(); restarted.sessionsDir = discoveryFolder; restarted.scanForSessions()
        precondition(restarted.availableSessions.contains { $0.id == "replayed-history" }, "Older replayed records must not hide recent real work after restart")
        let retained = discovery.availableSessions.first { $0.id == "real" }!
        var running = CodexState()
        running.activeTools = [CodexToolExecution(id: "tool", toolName: "Bash", argument: nil, startTime: oldDate)]
        discovery.sessionStates[retained.id] = running
        discovery.sessionWatchers[retained.id] = true
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: retained.jsonlFile.path)
        discovery.scanForSessions()
        precondition(discovery.availableSessions.contains { $0.id == retained.id }, "Quiet running tools must stay listed")
        try Data((importMessage + "\\n" + importEnd + "\\n").utf8).write(to: imported)
        truncatedImport.loadRecentHistoryForSession(from: imported, sessionId: "s")
        precondition(!truncatedImport.state.isActive, "History without the import start marker must finish idle")
        for agent in ["claude", "codex"] {
            let past = timestamp.string(from: Date(timeIntervalSinceNow: -180))
            let tool = agent == "claude" ? "{\\"timestamp\\":\\"\\(past)\\",\\"message\\":{\\"role\\":\\"assistant\\",\\"content\\":[{\\"type\\":\\"tool_use\\",\\"id\\":\\"q\\",\\"name\\":\\"AskUserQuestion\\"}]}}\\n" : "{\\"timestamp\\":\\"\\(past)\\",\\"type\\":\\"response_item\\",\\"payload\\":{\\"type\\":\\"custom_tool_call\\",\\"call_id\\":\\"q\\",\\"name\\":\\"exec_command\\",\\"input\\":\\"{}\\"}}\\n"
            try Data(tool.utf8).write(to: imported)
            if agent == "claude" {
                let f = ClaudeFixture(); f.loadRecentHistoryForSession(from: imported, sessionId: "s")
                precondition(f.state.isActive && f.state.isAwaitingInput && !f.state.needsPermission, "Recent unanswered question must survive restart")
                let last = f.state.lastUpdateTime
                f.parseJSONLLineForSession(oldClaudeLine, sessionId: "s")
                precondition(f.state.isActive && f.state.isAwaitingInput && !f.state.needsPermission && f.state.lastUpdateTime == last)
            } else {
                let f = CodexFixture(); f.loadRecentHistoryForSession(from: imported, sessionId: "s")
                precondition(f.state.isActive && f.state.hasActiveTools, "Recent running tool must survive restart")
            }
        }
        for agent in ["claude", "codex"] {
            let file = folder.appendingPathComponent(agent + ".jsonl")
            let nowTimestamp = timestamp.string(from: Date())
            let record = agent == "claude" ? "{\\"timestamp\\":\\"\\(nowTimestamp)\\",\\"message\\":{\\"role\\":\\"assistant\\",\\"content\\":[{\\"type\\":\\"thinking\\"}]}}\\n" : "{\\"timestamp\\":\\"\\(nowTimestamp)\\",\\"type\\":\\"response_item\\",\\"payload\\":{\\"type\\":\\"reasoning\\"}}\\n"
            let full = Data(record.utf8)
            let cut = full.count - 5
            try full.prefix(cut).write(to:file)
            if agent == "claude" {
                let f = ClaudeFixture()
                let h = try FileHandle(forReadingFrom:file)
                f.sessionReadPositions["s"] = h.seekToEndOfFile(); f.sessionFileHandles["s"] = h
                f.loadRecentHistoryForSession(from:file, sessionId:"s")
                precondition(!f.state.isActive)
                let w = try FileHandle(forWritingTo:file); w.seekToEndOfFile(); w.write(full.suffix(5)); try w.close()
                f.readNewSessionDataForSession(sessionId:"s")
                precondition(f.state.isActive, "History partial line must survive watcher startup")
                try h.close()
                let fresh = ClaudeFixture(); fresh.loadRecentHistoryForSession(from:file, sessionId:"s")
                precondition(fresh.state.isActive, "Restart must retain fresh thinking")
                try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSinceNow: -301)], ofItemAtPath:file.path)
                let stale = ClaudeFixture(); stale.loadRecentHistoryForSession(from:URL(fileURLWithPath:file.path), sessionId:"s")
                precondition(!stale.state.isActive)
            } else {
                let f = CodexFixture()
                let h = try FileHandle(forReadingFrom:file)
                f.sessionReadPositions["s"] = h.seekToEndOfFile(); f.sessionFileHandles["s"] = h
                f.loadRecentHistoryForSession(from:file, sessionId:"s")
                precondition(!f.state.isActive)
                let w = try FileHandle(forWritingTo:file); w.seekToEndOfFile(); w.write(full.suffix(5)); try w.close()
                f.readNewSessionData(sessionId:"s")
                precondition(f.state.isActive)
                try h.close()
                let fresh = CodexFixture(); fresh.loadRecentHistoryForSession(from:file, sessionId:"s")
                precondition(fresh.state.isActive)
                try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSinceNow: -301)], ofItemAtPath:file.path)
                let stale = CodexFixture(); stale.loadRecentHistoryForSession(from:URL(fileURLWithPath:file.path), sessionId:"s")
                precondition(!stale.state.isActive)
            }
        }
        for path in CommandLine.arguments.dropFirst() {
            let file = URL(fileURLWithPath: path)
            if file.lastPathComponent.hasPrefix("rollout-") {
                let f = CodexFixture(); f.loadRecentHistoryForSession(from: file, sessionId: "s")
                print("LIVE SNAPSHOT: \\(file.lastPathComponent) active=\\(f.state.isActive) tools=\\(f.state.activeTools.count)")
                // Copy only for the test: fresh mtime reproduces opening/importing without changing the user's log.
                let snapshotFolder = folder.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: snapshotFolder, withIntermediateDirectories: true)
                let snapshot = snapshotFolder.appendingPathComponent(file.lastPathComponent)
                try FileManager.default.copyItem(at: file, to: snapshot)
                try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: snapshot.path)
                let d = CodexFixture(); d.sessionsDir = snapshotFolder; d.scanForSessions()
                print("LIVE DISCOVERY WITH FRESH MTIME: \\(file.lastPathComponent) listed=\\(!d.availableSessions.isEmpty)")
            } else {
                let f = ClaudeFixture(); f.loadRecentHistoryForSession(from: file, sessionId: "s")
                print("LIVE SNAPSHOT: \\(file.lastPathComponent) active=\\(f.state.isActive) tools=\\(f.state.activeTools.count)")
            }
        }
        print("PASS: discovery excludes import/open/settings-only sessions; real Codex work, tools and questions preserved; restart and split JSONL/UTF-8")
    }
}
'''
swift = swift.replace('precondition(', 'check(')
with tempfile.TemporaryDirectory(prefix='clangnotch-activity-checks-') as folder:
    temp = Path(folder)
    (temp/'Checks.swift').write_text(swift)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library',
                    str(root/'ClangNotch/Models/AgentInputModels.swift'),
                    str(root/'ClangNotch/Models/ClaudeCodeModels.swift'),
                    str(root/'ClangNotch/Models/CodexModels.swift'),
                    str(root/'ClangNotch/Models/JSONLLineBuffer.swift'),
                    str(temp/'Checks.swift'), '-o', str(temp/'checks')], check=True)
    subprocess.run([str(temp/'checks'), *sys.argv[1:]], check=True)
