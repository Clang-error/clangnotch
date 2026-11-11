import Foundation

/// The Codex app's own IPC socket (`~/.codex/ipc/ipc.sock`): the channel its windows use to act
/// on a thread another window owns. Undocumented; read from the app's `app.asar` and tried live
/// on 2026-11-11. Frames are a 4-byte length (host order) and a JSON object. Each method carries
/// a version the app checks, so an app update that bumps it ends in `.refused`.
enum CodexAppIPC {
    enum Outcome {
        /// The app took the request.
        case accepted
        /// Nothing was started: the app isn't running, doesn't hold the thread, or said no.
        case refused
        /// The request went out and no answer came back. It may have started a turn.
        case unknown
    }

    /// The message the app itself sends for answered `request_user_input_async` questions.
    /// `questionItemId` is the app's `JSON.stringify(["request_user_input_async", callId, index])`.
    static func questionReply(callId: String, answers: [(index: Int, question: String, answer: String)]) -> String? {
        let items: [[String: String]] = answers.compactMap { answer in
            guard let id = json(["request_user_input_async", callId, answer.index] as [Any]) else { return nil }
            return ["questionItemId": id, "question": answer.question, "answer": answer.answer]
        }
        guard !items.isEmpty, items.count == answers.count, let body = json(items) else { return nil }
        return "<send_user_message_question_reply>\n\(body)\n</send_user_message_question_reply>"
    }

    /// Sends `text` as the user's next message in a thread the app holds. Blocks; call off the main thread.
    static func startTurn(threadId: String, text: String,
                          socketPath: String = NSHomeDirectory() + "/.codex/ipc/ipc.sock") -> Outcome {
        let fd = connect(to: socketPath)
        guard fd >= 0 else { return .refused }
        defer { close(fd) }

        let hello = UUID().uuidString
        guard send(["type": "request", "requestId": hello, "method": "initialize",
                    "params": ["clientType": "clangnotch"]], to: fd),
              let welcome = response(to: hello, from: fd),
              let clientId = (welcome["result"] as? [String: Any])?["clientId"] as? String else { return .refused }

        let request = UUID().uuidString
        let turnStart: [String: Any] = [
            "request": ["threadId": threadId,
                        "input": [["type": "text", "text": text, "text_elements": [Any]()]],
                        "clientUserMessageId": UUID().uuidString.lowercased()],
            "context": [String: Any](),
        ]
        guard send(["type": "request", "requestId": request, "sourceClientId": clientId, "version": 2,
                    "method": "thread-follower-start-turn",
                    "params": ["conversationId": threadId, "turnStart": turnStart]], to: fd) else { return .refused }
        guard let answer = response(to: request, from: fd) else { return .unknown }
        return answer["resultType"] as? String == "success" ? .accepted : .refused
    }

    private static func json(_ object: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// A connected Unix socket, or -1. `timeout` bounds each read and write, in seconds.
    static func connect(to path: String, timeout seconds: Int = 12) -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return -1 }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        // The default is for the app's socket: it answers for a thread it holds in well under a
        // second, but its router waits 10s before saying that no window holds the thread
        // ("no-client-found").
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { close(fd); return -1 }
        return fd
    }

    private static func send(_ message: [String: Any], to fd: Int32) -> Bool {
        guard let body = try? JSONSerialization.data(withJSONObject: message) else { return false }
        var frame = withUnsafeBytes(of: UInt32(body.count)) { Data($0) }
        frame.append(body)
        return write(frame, to: fd)
    }

    static func write(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { buffer in
            var sent = 0
            while sent < buffer.count {
                let n = Darwin.write(fd, buffer.baseAddress! + sent, buffer.count - sent)
                guard n > 0 else { return false }
                sent += n
            }
            return true
        }
    }

    /// Reads frames until the response to `requestId`. The app's router also asks every client
    /// whether it can handle other clients' requests; this one never can.
    private static func response(to requestId: String, from fd: Int32) -> [String: Any]? {
        // Broadcasts for other clients pass by here; a few are enough to tell a busy socket from a dead one.
        for _ in 0..<64 {
            guard let header = read(4, from: fd) else { return nil }
            let length = header.withUnsafeBytes { Int($0.loadUnaligned(as: UInt32.self)) }
            guard length <= 64 << 20, let body = read(length, from: fd) else { return nil }
            guard let message = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { continue }
            switch message["type"] as? String {
            case "response" where message["requestId"] as? String == requestId:
                return message
            case "client-discovery-request":
                if let id = message["requestId"] as? String {
                    _ = send(["type": "client-discovery-response", "requestId": id, "response": ["canHandle": false]], to: fd)
                }
            default:
                break
            }
        }
        return nil
    }

    static func read(_ count: Int, from fd: Int32) -> Data? {
        var data = Data(count: count)
        var filled = 0
        let complete = data.withUnsafeMutableBytes { buffer -> Bool in
            while filled < count {
                let n = Darwin.read(fd, buffer.baseAddress! + filled, count - filled)
                guard n > 0 else { return false }
                filled += n
            }
            return true
        }
        return complete ? data : nil
    }
}
