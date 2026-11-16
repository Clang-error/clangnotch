import Foundation

@main
struct HookHTTPServerChecks {
    static func main() {
        func head(_ lines: String...) -> String { lines.joined(separator: "\r\n") }
        func accepts(_ header: String) -> Bool {
            if case .accept = HookHTTPServer.verdict(forHeader: header) { return true }
            return false
        }
        func length(_ header: String) -> Int? {
            if case .accept(_, let length) = HookHTTPServer.verdict(forHeader: header) { return length }
            return nil
        }

        let local = head("POST /permission-hook HTTP/1.1", "Host: 127.0.0.1:4318", "Content-Length: 12")
        precondition(length(local) == 12, "The local hook curl is accepted with its length")
        if case .accept(let route, _) = HookHTTPServer.verdict(forHeader: local) {
            precondition(route == .permissionHook, "Routed to the permission hook")
        }
        precondition(accepts(head("POST /permission-hook HTTP/1.1", "Host: localhost", "Content-Length: 2")),
                     "The SSH tunnel's curl posts to http://localhost/ with no port")
        precondition(accepts(head("POST /claude-hook HTTP/1.1", "Host: LOCALHOST:4318", "Content-Length: 2")),
                     "Host names are case-insensitive")
        precondition(length(head("POST /claude-hook HTTP/1.1", "Host: 127.0.0.1:4318")) == 0,
                     "No Content-Length means an empty body")

        precondition(!accepts(head("POST /permission-hook HTTP/1.1", "Host: 127.0.0.1:4318", "Content-Length: -1")),
                     "A negative length is refused (it crashed Data.prefix)")
        precondition(!accepts(head("POST /claude-hook HTTP/1.1", "Host: 127.0.0.1:4318", "Content-Length: abc")),
                     "A length that isn't a number is refused")
        precondition(!accepts(head("POST /claude-hook HTTP/1.1", "Host: 127.0.0.1:4318",
                                   "Content-Length: \(HookHTTPServer.maxBodyBytes + 1)")),
                     "An oversized body is refused before it is buffered")
        precondition(!accepts(head("POST /claude-hook HTTP/1.1", "Host: 127.0.0.1:4318",
                                   "Content-Length: 99999999999999999999999")),
                     "A length past Int is refused")
        precondition(!accepts(head("POST /permission-hook HTTP/1.1", "Host: 127.0.0.1:4318",
                                   "Origin: https://evil.example", "Content-Length: 2")),
                     "A browser page's request (it carries Origin) is refused")
        precondition(!accepts(head("POST /permission-hook HTTP/1.1", "Host: 127.0.0.1:4318",
                                   "origin: null", "Content-Length: 2")),
                     "Origin in any case, even null")
        precondition(!accepts(head("POST /permission-hook HTTP/1.1", "Host: evil.example:4318", "Content-Length: 2")),
                     "A DNS-rebound name in Host is refused")
        precondition(!accepts(head("POST /permission-hook HTTP/1.1", "Host: 127.0.0.1.evil.example", "Content-Length: 2")),
                     "Only the exact loopback names")
        precondition(!accepts(head("GET /permission-hook HTTP/1.1", "Host: 127.0.0.1:4318")),
                     "Only POST, the hooks' method")
        print("HookHTTPServerChecks: all passed")
    }
}
