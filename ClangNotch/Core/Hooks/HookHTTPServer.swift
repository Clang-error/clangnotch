import Foundation
import Network

/// Plain HTTP on 127.0.0.1 for the hook curls: one request per connection, `Content-Length` bodies.
final class HookHTTPServer {
    enum Route {
        case claudeHook
        case permissionHook
        case other
    }

    struct Request {
        let route: Route
        let body: Data
        /// Set only for `.permissionHook`: the hook's curl waits on it for a decision.
        var reply: HookReply? = nil
    }

    var onRequest: ((Request) -> Void)?
    var onError: ((String) -> Void)?

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.clangerror.ClangNotch.hook.server", qos: .userInitiated)
    private var activeHandlers: [ObjectIdentifier: HTTPConnectionHandler] = [:]

    func start(port: UInt16) throws {
        let params = NWParameters.tcp
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return }
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: endpointPort)
        let listener = try NWListener(using: params)
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
        if !headerParsed {
            guard let headerRange = buffer.range(of: Data("\r\n\r\n".utf8)) else { return }
            let headerData = buffer.subdata(in: 0..<headerRange.lowerBound)
            parseHeaders(headerData)
            buffer.removeSubrange(0..<headerRange.upperBound)
            headerParsed = true
        }

        guard headerParsed else { return }
        guard buffer.count >= contentLength else { return }

        let body = Data(buffer.prefix(contentLength))
        buffer.removeSubrange(0..<contentLength)
        if route == .permissionHook {
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

    private func parseHeaders(_ data: Data) {
        let headerString = String(decoding: data, as: UTF8.self)
        let lines = headerString.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first else { return }

        let parts = requestLine.split(separator: " ")
        if parts.count >= 2 {
            route = Self.route(for: String(parts[1]))
        }

        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("content-length:") {
                let value = trimmed.split(separator: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
                contentLength = Int(value) ?? 0
            }
        }
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

    private static func route(for path: String) -> HookHTTPServer.Route {
        if path.hasSuffix("/claude-hook") {
            return .claudeHook
        }
        if path.hasSuffix("/permission-hook") {
            return .permissionHook
        }
        return .other
    }
}

/// One held `/permission-hook` request. Exactly one of `send` (a decision body, or nil for
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
