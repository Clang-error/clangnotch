import Foundation

/// The shared `codex app-server` daemon's control socket: terminal Codex clients attach to it,
/// and a second client that joins a thread gets its pending requests again and may answer them
/// (tried live on 2026-11-11, CLI 0.167 on daemon 0.163). JSON-RPC in WebSocket text frames
/// over the Unix socket, no auth. Codex marks this API experimental. The Codex app's own
/// threads are not here; those go through `CodexAppIPC`.
enum CodexDaemonIPC {
    /// Answers a terminal thread's pending `request_user_input`. `labels` are the picked option
    /// labels in question order. Blocks; call off the main thread.
    static func answerQuestion(threadId: String, callId: String, labels: [String],
                               socketPath: String = NSHomeDirectory() + "/.codex/app-server-control/app-server-control.sock") -> CodexAppIPC.Outcome {
        let fd = CodexAppIPC.connect(to: socketPath, timeout: 5)
        guard fd >= 0 else { return .refused }
        defer { close(fd) }
        var socket = Socket(fd: fd)
        guard socket.upgrade(),
              socket.call("initialize", ["clientInfo": ["name": "clangnotch", "title": "ClangNotch", "version": "1"],
                                         "capabilities": ["experimentalApi": true]]) != nil,
              socket.send(["method": "initialized"]) else { return .refused }

        // Joining a thread the daemon doesn't hold would load a second copy of it from disk.
        guard socket.holds(threadId),
              socket.call("thread/resume", ["threadId": threadId, "excludeTurns": true]) != nil,
              let request = socket.next(where: {
                  $0["method"] as? String == "item/tool/requestUserInput"
                      && ($0["params"] as? [String: Any])?["itemId"] as? String == callId
              }),
              let requestId = request["id"],
              let questions = (request["params"] as? [String: Any])?["questions"] as? [[String: Any]],
              questions.count == labels.count else { return .refused }

        var answers: [String: Any] = [:]
        for (question, label) in zip(questions, labels) {
            guard let id = question["id"] as? String else { return .refused }
            answers[id] = ["answers": [label]]
        }
        guard socket.send(["id": requestId, "result": ["answers": answers]]) else { return .refused }
        // The daemon tells every client of the thread once the question is settled.
        let settled = socket.next(where: {
            $0["method"] as? String == "serverRequest/resolved"
                && (($0["params"] as? [String: Any])?["requestId"]).map { "\($0)" } == "\(requestId)"
        })
        return settled == nil ? .unknown : .accepted
    }

    private struct Socket {
        let fd: Int32
        /// Messages read while waiting for something else.
        private var inbox: [[String: Any]] = []
        private var nextId = 0

        init(fd: Int32) { self.fd = fd }

        mutating func upgrade() -> Bool {
            let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
            let hello = "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                + "Sec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n"
            guard CodexAppIPC.write(Data(hello.utf8), to: fd) else { return false }
            // Byte by byte, so nothing of the first frame is taken with the header.
            var header = Data()
            while !header.suffix(4).elementsEqual(Data("\r\n\r\n".utf8)) {
                guard header.count < 4096, let byte = CodexAppIPC.read(1, from: fd) else { return false }
                header.append(byte)
            }
            return String(decoding: header, as: UTF8.self).hasPrefix("HTTP/1.1 101")
        }

        mutating func send(_ message: [String: Any]) -> Bool {
            guard let body = try? JSONSerialization.data(withJSONObject: message) else { return false }
            // A client's frames are masked: FIN + text, the length, four mask bytes, the masked body.
            var frame = Data([0x81])
            switch body.count {
            case ..<126: frame.append(0x80 | UInt8(body.count))
            case ..<65536: frame.append(0x80 | 126); frame.append(contentsOf: withUnsafeBytes(of: UInt16(body.count).bigEndian, Array.init))
            default: frame.append(0x80 | 127); frame.append(contentsOf: withUnsafeBytes(of: UInt64(body.count).bigEndian, Array.init))
            }
            let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
            frame.append(contentsOf: mask)
            frame.append(contentsOf: body.enumerated().map { $1 ^ mask[$0 % 4] })
            return CodexAppIPC.write(frame, to: fd)
        }

        /// Sends a request and returns its result; an error response or a dead socket is nil.
        mutating func call(_ method: String, _ params: [String: Any]) -> [String: Any]? {
            nextId += 1
            let id = nextId
            guard send(["id": id, "method": method, "params": params]) else { return nil }
            let response = next(where: { $0["method"] == nil && $0["id"] as? Int == id })
            return response?["result"] as? [String: Any]
        }

        mutating func holds(_ threadId: String) -> Bool {
            var cursor: String?
            for _ in 0..<8 {
                guard let page = call("thread/loaded/list", cursor.map { ["cursor": $0] } ?? [:]) else { return false }
                if (page["data"] as? [String] ?? []).contains(threadId) { return true }
                cursor = page["nextCursor"] as? String
                if cursor == nil { return false }
            }
            return false
        }

        /// The first message that matches, from the ones already read or the next to arrive.
        mutating func next(where matches: ([String: Any]) -> Bool) -> [String: Any]? {
            if let index = inbox.firstIndex(where: matches) { return inbox.remove(at: index) }
            // A thread in the middle of a turn streams deltas; bound the wait by count too.
            for _ in 0..<2000 {
                guard let message = receive() else { return nil }
                if matches(message) { return message }
                inbox.append(message)
            }
            return nil
        }

        private func receive() -> [String: Any]? {
            var text = Data()
            while true {
                guard let head = CodexAppIPC.read(2, from: fd) else { return nil }
                var length = Int(head[1] & 0x7f)
                if length == 126 {
                    guard let more = CodexAppIPC.read(2, from: fd) else { return nil }
                    length = more.reduce(0) { $0 << 8 | Int($1) }
                } else if length == 127 {
                    guard let more = CodexAppIPC.read(8, from: fd) else { return nil }
                    length = more.reduce(0) { $0 << 8 | Int($1) }
                }
                guard length <= 64 << 20 else { return nil }
                let mask = head[1] & 0x80 != 0 ? CodexAppIPC.read(4, from: fd) : nil
                guard var payload = CodexAppIPC.read(length, from: fd) else { return nil }
                if let mask = mask.map(Array.init) {
                    payload = Data(payload.enumerated().map { $1 ^ mask[$0 % 4] })
                }
                switch head[0] & 0x0f {
                case 0x8:
                    return nil
                case 0x9:
                    // Ping: answer with the same payload, masked with zeros.
                    guard payload.count < 126,
                          CodexAppIPC.write(Data([0x8a, 0x80 | UInt8(payload.count), 0, 0, 0, 0]) + payload, to: fd) else { return nil }
                case 0x0, 0x1, 0x2:
                    text.append(payload)
                    guard head[0] & 0x80 != 0 else { continue }
                    if let message = try? JSONSerialization.jsonObject(with: text) as? [String: Any] { return message }
                    text = Data()
                default:
                    break
                }
            }
        }
    }
}
