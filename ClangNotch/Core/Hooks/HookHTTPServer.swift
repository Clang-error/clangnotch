import Foundation
import Network

/// Plain HTTP on `HookSocket.path` for the hook curls: one request per connection, `Content-Length` bodies.
final class HookHTTPServer {
    enum Route {
        case claudeHook
        case permissionHook
        case nextStepHook
        case other
    }

    struct Request {
        let route: Route
        let body: Data
        /// Set for `.permissionHook` and `.nextStepHook`: the hook's curl waits on it for an answer.
        var reply: HookReply? = nil
    }

    /// What a request's header allows. A permission request carries the tool's whole input
    /// (a Write's file), so the body limit is generous; it only stops a runaway length.
    enum HeaderVerdict: Equatable {
        case accept(route: Route, contentLength: Int)
        case reject
    }
    static let maxHeaderBytes = 64 * 1024
    static let maxBodyBytes = 32 * 1024 * 1024

    /// The hook curls send no Origin and name the loopback in Host. A browser page always sends
    /// Origin, and a DNS-rebound page names its own host, so both are refused. Kept from when this
    /// listened on 127.0.0.1, where a page could reach it; a socket file a page can't.
    static func verdict(forHeader header: String) -> HeaderVerdict {
        let lines = header.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first else { return .reject }
        let parts = requestLine.split(separator: " ")
        // The curls only POST; a GET is what an <img> or a link on a page would send.
        guard parts.first == "POST" else { return .reject }
        let route = parts.count >= 2 ? route(for: String(parts[1])) : .other
        var contentLength = 0
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch name {
            case "content-length":
                guard let length = Int(value), (0...maxBodyBytes).contains(length) else { return .reject }
                contentLength = length
            case "origin":
                return .reject
            case "host":
                let hostName = value.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
                guard ["127.0.0.1", "localhost"].contains(hostName.lowercased()) else { return .reject }
            default:
                break
            }
        }
        return .accept(route: route, contentLength: contentLength)
    }

    private static func route(for path: String) -> Route {
        if path.hasSuffix("/claude-hook") {
            return .claudeHook
        }
        if path.hasSuffix("/permission-hook") {
            return .permissionHook
        }
        if path.hasSuffix("/next-step-hook") {
            return .nextStepHook
        }
        return .other
    }

    var onRequest: ((Request) -> Void)?
    var onError: ((String) -> Void)?

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.clangerror.ClangNotch.hook.server", qos: .userInitiated)
    private var activeHandlers: [ObjectIdentifier: HTTPConnectionHandler] = [:]

    struct InUse: Error {}

    /// Another copy of this app already answering at `path` keeps it (a Debug run beside the
    /// installed one); a socket left by one that has quit is replaced. The folder is the user's
    /// alone: connecting takes write access to it and to the socket.
    func start(socketPath path: String) throws {
        let folder = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // A folder that was already there keeps its mode otherwise.
        chmod(folder, 0o700)
        if Self.answers(at: path) { throw InUse() }
        unlink(path)
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .unix(path: path)
        let listener = try NWListener(using: params)
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state { self?.onError?("listener failed: \(error)") }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private static func answers(at path: String) -> Bool {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return false }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else { return false }
        defer { close(socket) }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        } == 0
    }

    private func handleConnection(_ connection: NWConnection) {
        let handler = HTTPConnectionHandler(connection: connection) { [weak self] request in
            debugLog("[Hooks] Received request: \(request.route), body size: \(request.body.count)")
            self?.onRequest?(request)
        } onError: { [weak self] message in
            self?.onError?(message)
        } onComplete: { [weak self] handler in
            self?.queue.async {
                self?.activeHandlers.removeValue(forKey: ObjectIdentifier(handler))
            }
        }

        activeHandlers[ObjectIdentifier(handler)] = handler
        handler.start()
    }
}

private final class HTTPConnectionHandler {
    private let connection: NWConnection
    private let onRequest: (HookHTTPServer.Request) -> Void
    private let onError: (String) -> Void
    private let onComplete: (HTTPConnectionHandler) -> Void

    private var buffer = Data()
    private var headerParsed = false
    private var contentLength: Int = 0
    private var route: HookHTTPServer.Route = .other
    private var didFinish = false
    /// A refusal is on its way out; later bytes on the connection are ignored.
    private var refused = false
    private var heldReply: HookReply?

    init(
        connection: NWConnection,
        onRequest: @escaping (HookHTTPServer.Request) -> Void,
        onError: @escaping (String) -> Void,
        onComplete: @escaping (HTTPConnectionHandler) -> Void
    ) {
        self.connection = connection
        self.onRequest = onRequest
        self.onError = onError
        self.onComplete = onComplete
    }

    func start() {
        connection.start(queue: .global())
        receiveNext()
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data {
                self.buffer.append(data)
                self.processBuffer()
            }

            if let error {
                self.onError("Hook HTTP receive error: \(error)")
                self.finish()
                return
            }

            if isComplete {
                self.finish()
                return
            }

            self.receiveNext()
        }
    }

    private func processBuffer() {
        guard !didFinish, !refused else { return }
        if !headerParsed {
            guard let headerRange = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if buffer.count > HookHTTPServer.maxHeaderBytes { refuse(status: 431) }
                return
            }
            let headerData = buffer.subdata(in: 0..<headerRange.lowerBound)
            guard case .accept(let route, let contentLength) =
                    HookHTTPServer.verdict(forHeader: String(decoding: headerData, as: UTF8.self)) else {
                // A refused permission request gets no decision, so the agent asks in its own prompt.
                refuse(status: 403)
                return
            }
            self.route = route
            self.contentLength = contentLength
            buffer.removeSubrange(0..<headerRange.upperBound)
            headerParsed = true
        }

        guard headerParsed else { return }
        guard buffer.count >= contentLength else { return }

        let body = Data(buffer.prefix(contentLength))
        buffer.removeSubrange(0..<contentLength)
        if route == .permissionHook || route == .nextStepHook {
            // Held open: the answer comes from the notch, or nothing after its time limit.
            let reply = HookReply { [weak self] body in self?.sendResponseAndFinish(status: 200, body: body) }
            heldReply = reply
            onRequest(.init(route: route, body: body, reply: reply))
            return
        }
        onRequest(.init(route: route, body: body))
        sendResponseAndFinish(status: 200)
    }

    private func finish() {
        guard !didFinish else { return }
        didFinish = true
        connection.cancel()
        // The hook gave up first (agent timeout, interrupted turn): drop the request.
        heldReply?.connectionClosed()
        onComplete(self)
    }

    private func refuse(status: Int) {
        refused = true
        buffer.removeAll()
        sendResponseAndFinish(status: status)
    }

    private func sendResponseAndFinish(status: Int, body: Data? = nil) {
        var response = Data("HTTP/1.1 \(status) OK\r\n".utf8)
        if let body {
            response += Data("Content-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
            response += body
        } else {
            response += Data("Content-Length: 0\r\nConnection: close\r\n\r\n".utf8)
        }
        connection.send(content: response, completion: .contentProcessed { [weak self] error in
            if let error {
                self?.onError("Hook HTTP send error: \(error)")
            }
            self?.finish()
        })
    }
}

/// One held `/permission-hook` or `/next-step-hook` request. Exactly one of `send` (a decision body, or nil for
/// "no decision") and the connection closing wins; the other becomes a no-op.
final class HookReply: @unchecked Sendable {
    private let lock = NSLock()
    private let deliver: (Data?) -> Void
    private var isDone = false
    private var closedEarly = false
    private var onClose: (() -> Void)?

    init(deliver: @escaping (Data?) -> Void) {
        self.deliver = deliver
    }

    func send(_ body: Data?) {
        lock.lock()
        guard !isDone else { lock.unlock(); return }
        isDone = true
        // The handler captures this reply; dropping it breaks the cycle once answered.
        onClose = nil
        lock.unlock()
        deliver(body)
    }

    /// Runs `handler` once if the hook disconnects before an answer, even if it already has.
    func setOnClose(_ handler: @escaping () -> Void) {
        lock.lock()
        if closedEarly {
            lock.unlock()
            handler()
            return
        }
        onClose = handler
        lock.unlock()
    }

    fileprivate func connectionClosed() {
        lock.lock()
        guard !isDone else { lock.unlock(); return }
        isDone = true
        closedEarly = true
        let handler = onClose
        onClose = nil
        lock.unlock()
        handler?()
    }
}
