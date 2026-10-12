import Foundation

private let fixture = Data("""
{"code":"00","result":{
 "gnrlData":[{"skipNm":"데이터통화 무제한","total":"-1","used":"36149","remained":"-1","unit":"140"}],
 "spclData":[{"skipNm":"통합공유 데이터 120GB","total":"41943040","used":"440137","remained":"41502903","unit":"140"}]
}}
""".utf8)

private final class MockProtocol: URLProtocol {
    static var status = 200
    static var calls = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.calls += 1
        precondition(request.url == TWorldClient.balanceURL)
        precondition(request.value(forHTTPHeaderField: "Cookie") == "session=fake-value")
        precondition(request.value(forHTTPHeaderField: "Referer") == TWorldClient.pageURL.absoluteString)
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Set-Cookie": "session=rotated; Path=/; Secure; HttpOnly"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: fixture)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
struct TWorldChecks {
    static func cookie(domain: String = ".tworld.co.kr", path: String = "/", expires: Date? = nil) -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: "session", .value: "fake-value", .domain: domain, .path: path,
            .secure: "TRUE", HTTPCookiePropertyKey("HttpOnly"): "TRUE"
        ]
        if let expires { properties[.expires] = expires }
        return HTTPCookie(properties: properties)!
    }

    static func expectError(_ expected: TWorldError, _ block: () throws -> Void) {
        do { try block(); preconditionFailure("Expected error") }
        catch { precondition((error as? TWorldError)?.localizedDescription == expected.localizedDescription) }
    }

    static func main() async throws {
        let now = Date()
        let balance = try TWorldBalance.decode(fixture, status: 200, now: now)
        precondition(balance.totalGB == 40, "Use prorated total, never parse 120GB from the plan name")
        precondition(abs(balance.remainingGB - 39.5802526473999) < 0.00001)
        precondition(abs(balance.usedGB + balance.remainingGB - 40) < 0.00001)
        precondition(balance.fetchedAt == now)
        for status in [301, 302, 401, 403] {
            expectError(.loginRequired) { _ = try TWorldBalance.decode(fixture, status: status) }
        }
        expectError(.rateLimited) { _ = try TWorldBalance.decode(fixture, status: 429) }
        expectError(.invalidResponse) { _ = try TWorldBalance.decode(Data("<html>login</html>".utf8), status: 200) }
        let text = String(decoding: fixture, as: UTF8.self)
        for replacement in ["-1", "NaN", "Infinity", "999999999"] {
            expectError(.invalidResponse) {
                _ = try TWorldBalance.decode(Data(text.replacingOccurrences(of: "41502903", with: replacement).utf8), status: 200)
            }
        }
        expectError(.noSharingBalance) {
            _ = try TWorldBalance.decode(Data(text.replacingOccurrences(of: "통합공유 데이터", with: "다른 데이터").utf8), status: 200)
        }
        expectError(.invalidResponse) {
            _ = try TWorldBalance.decode(Data(text.replacingOccurrences(of: "140", with: "999").utf8), status: 200)
        }
        print("PASS: prorated quota, unit conversion, error/expired/rate-limit states")

        let valid = cookie()
        precondition(valid.isHTTPOnly)
        let record = TWorldCookieVault.CookieRecord(valid)
        let restored = try JSONDecoder().decode(TWorldCookieVault.CookieRecord.self, from: JSONEncoder().encode(record)).cookie!
        precondition(restored.isHTTPOnly && restored.isSecure && restored.value == valid.value)
        precondition(restored.expiresDate == nil, "Retain session cookies across restarts without inventing an expiry")
        precondition(TWorldClient.applies(valid, to: TWorldClient.balanceURL))
        precondition(!TWorldClient.applies(valid, to: URL(string: "http://www.tworld.co.kr/")!))
        precondition(!TWorldClient.applies(valid, to: URL(string: "https://tworld.co.kr.attacker.test/")!))
        precondition(!TWorldClient.applies(cookie(domain: "evil.test"), to: TWorldClient.balanceURL))
        precondition(!TWorldClient.applies(cookie(domain: "tworld.co.kr"), to: TWorldClient.balanceURL))
        precondition(!TWorldClient.applies(cookie(path: "/core"), to: TWorldClient.balanceURL))
        precondition(TWorldClient.applies(cookie(path: "/core-balance"), to: TWorldClient.balanceURL))
        precondition(!TWorldClient.applies(cookie(expires: now.addingTimeInterval(-10)), to: TWorldClient.balanceURL))
        precondition(TWorldClient.merge([valid], updates: [cookie(expires: now.addingTimeInterval(-10))]).isEmpty)
        precondition(TWorldClient.merge([], updates: [cookie(domain: "evil.test")]).isEmpty)
        print("PASS: secure/HttpOnly session persistence, cookie host/path/expiry isolation")

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockProtocol.self]
        let client = TWorldClient(configuration: config)
        let (nativeBalance, cookies) = try await client.fetch(cookies: [valid, cookie(domain: "evil.test"), cookie(path: "/web")])
        precondition(nativeBalance.totalGB == 40)
        precondition(cookies.contains { $0.value == "rotated" && $0.isHTTPOnly })
        precondition(!cookies.contains { $0.domain == "evil.test" })
        for status in [401, 302, 429] {
            MockProtocol.status = status
            do { _ = try await client.fetch(cookies: [valid]); preconditionFailure("Expected HTTP error") }
            catch { precondition(error is TWorldError) }
        }
        precondition(MockProtocol.calls == 4)
        do { _ = try await client.fetch(cookies: []); preconditionFailure("Empty session must not send HTTP") }
        catch { precondition(MockProtocol.calls == 4) }
        print("PASS: browserless HTTP request, cookie rotation, rejected authentication, no empty-session traffic")
    }
}
