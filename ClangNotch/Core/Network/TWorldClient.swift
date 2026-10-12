import Foundation
import Security
import LocalAuthentication
import os

struct TWorldBalance: Equatable {
    let name: String
    let totalKB: Double
    let usedKB: Double
    let remainingKB: Double
    let fetchedAt: Date

    var totalGB: Double { totalKB / 1_048_576 }
    var usedGB: Double { usedKB / 1_048_576 }
    var remainingGB: Double { remainingKB / 1_048_576 }
    var remainingFraction: Double { totalKB > 0 ? remainingKB / totalKB : 0 }

    static func decode(_ data: Data, status: Int, now: Date = Date()) throws -> Self {
        if status == 401 || status == 403 || (300..<400).contains(status) {
            throw TWorldError.loginRequired
        }
        if status == 429 { throw TWorldError.rateLimited }
        guard status == 200 else { throw TWorldError.serviceUnavailable }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw TWorldError.invalidResponse
        }
        guard response.code == "00", let result = response.result else {
            throw TWorldError.serviceUnavailable
        }
        let sharing = (result.spclData + result.gnrlData).filter { $0.skipNm.hasPrefix("통합공유 데이터") }
        guard sharing.count == 1, let item = sharing.first else { throw TWorldError.noSharingBalance }
        // T world's unit 140 is KiB; its UI calls 1024 MiB one GB.
        guard item.unit == "140", let total = Double(item.total), let used = Double(item.used),
              let remaining = Double(item.remained),
              total.isFinite, used.isFinite, remaining.isFinite,
              total >= 0, used >= 0, remaining >= 0, remaining <= total else {
            throw TWorldError.invalidResponse
        }
        return Self(name: item.skipNm, totalKB: total, usedKB: used, remainingKB: remaining, fetchedAt: now)
    }

    private struct Response: Decodable {
        let code: String
        let result: Result?
    }

    private struct Result: Decodable {
        let spclData: [Item]
        let gnrlData: [Item]
    }

    private struct Item: Decodable {
        let skipNm: String
        let total: String
        let used: String
        let remained: String
        let unit: String
    }
}

enum TWorldError: LocalizedError {
    case loginRequired, rateLimited, serviceUnavailable, invalidResponse, noSharingBalance, keychainUnavailable

    var errorDescription: String? {
        switch self {
        case .loginRequired: return "T world에 다시 로그인해 주세요."
        case .rateLimited: return "조회 제한입니다. 잠시 후 다시 확인합니다."
        case .serviceUnavailable: return "T world에 연결할 수 없습니다."
        case .invalidResponse: return "잔여량 응답을 확인할 수 없습니다."
        case .noSharingBalance: return "통합공유 데이터 항목을 확인해 주세요."
        case .keychainUnavailable: return "로그인 세션을 키체인에 저장할 수 없습니다."
        }
    }
}

/// Native HTTP only. No web view, JavaScript, Safari automation or password is needed here.
final class TWorldClient: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let balanceURL = URL(string: "https://www.tworld.co.kr/core-balance/v1/balances")!
    static let pageURL = URL(string: "https://www.tworld.co.kr/web/myt-data/balance")!
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ClangNotch", category: "TWorld")
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    private let configuration: URLSessionConfiguration

    init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration.copy() as! URLSessionConfiguration
        super.init()
    }

    /// `headers` are whatever the T world page itself sent to this endpoint the last time
    /// a WebView saw it (captured by `TWorldHeaderCapture`): since 2026-09-23 the API rejects
    /// requests without `T-SvcMgmtNum` and `T-DubScrbInfo`, values only the page knows.
    func fetch(cookies: [HTTPCookie], headers: [String: String] = [:], endpoint: URL? = nil) async throws -> (TWorldBalance, [HTTPCookie]) {
        // The page's own URL wins when it is on T world; otherwise the known endpoint.
        let url = endpoint.flatMap { $0.host.map(Self.isTWorldHost) == true ? $0 : nil } ?? Self.balanceURL
        let applicable = cookies.filter { Self.applies($0, to: url) }
        guard !applicable.isEmpty else { throw TWorldError.loginRequired }
        let config = configuration.copy() as! URLSessionConfiguration
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 25
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.allHTTPHeaderFields = HTTPCookie.requestHeaderFields(with: applicable)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.pageURL.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        for (name, value) in headers where !Self.reservedHeaders.contains(name.lowercased()) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TWorldError.invalidResponse }
        let balance: TWorldBalance
        do {
            balance = try TWorldBalance.decode(data, status: http.statusCode)
        } catch {
            // Status and the API's own code/msg only — never the body, cookies or account data.
            let envelope = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let summary = ["code", "msg", "message", "error", "clientDebug", "traceId"].compactMap { key -> String? in
                guard let value = envelope[key] else { return nil }
                return "\(key)=\(String(describing: value).prefix(key == "msg" ? 700 : 120))"
            }.joined(separator: " ")
            let sent = headers.keys.sorted().joined(separator: ",")
            let cookieNames = Self.describe(applicable)
            Self.logger.error("balance fetch failed: http \(http.statusCode, privacy: .public) path=\(url.path, privacy: .public) sentHeaders=[\(sent, privacy: .public)] cookies=[\(cookieNames, privacy: .public)] bytes=\(data.count, privacy: .public) \(summary, privacy: .public) -> \(String(describing: error), privacy: .public)")
            throw error
        }
        let responseHeaders = http.allHeaderFields.reduce(into: [String: String]()) { result, entry in
            if let key = entry.key as? String, let value = entry.value as? String { result[key] = value }
        }
        let updates = HTTPCookie.cookies(withResponseHeaderFields: responseHeaders, for: url)
            .filter(Self.isTWorldCookie)
        Self.logger.notice("balance fetch ok: path=\(url.path, privacy: .public) sentHeaders=[\(headers.keys.sorted().joined(separator: ","), privacy: .public)] cookies=[\(Self.describe(applicable), privacy: .public)] setCookies=[\(Self.describe(updates), privacy: .public)]")
        return (balance, Self.merge(cookies, updates: updates))
    }

    /// Cookie names with their remaining lifetime — no values.
    static func describe(_ cookies: [HTTPCookie]) -> String {
        cookies.map { cookie in
            guard let expires = cookie.expiresDate else { return "\(cookie.name)(session)" }
            return "\(cookie.name)(\(Int(expires.timeIntervalSinceNow / 60))m)"
        }.sorted().joined(separator: ",")
    }

    /// Never overridden by captured page headers.
    static let reservedHeaders: Set<String> = ["cookie", "host", "content-length", "user-agent", "referer", "origin", "accept"]

    static func isTWorldCookie(_ cookie: HTTPCookie) -> Bool {
        isTWorldHost(cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")))
    }

    static func isTWorldHost(_ host: String) -> Bool {
        let host = host.lowercased()
        return host == "tworld.co.kr" || host.hasSuffix(".tworld.co.kr")
    }

    static func applies(_ cookie: HTTPCookie, to url: URL, now: Date = Date()) -> Bool {
        guard isTWorldCookie(cookie), let host = url.host,
              cookie.expiresDate.map({ $0 > now }) ?? true,
              !cookie.isSecure || url.scheme == "https" else { return false }
        let domain = cookie.domain.lowercased()
        let matchesHost = domain.hasPrefix(".")
            ? (host == String(domain.dropFirst()) || host.hasSuffix(domain)) : host == domain
        let path = url.path.isEmpty ? "/" : url.path
        let matchesPath = path == cookie.path ||
            (path.hasPrefix(cookie.path) && (cookie.path.hasSuffix("/") || path.dropFirst(cookie.path.count).hasPrefix("/")))
        return matchesHost && matchesPath
    }

    static func merge(_ cookies: [HTTPCookie], updates: [HTTPCookie], now: Date = Date()) -> [HTTPCookie] {
        var result = cookies.filter(isTWorldCookie)
        for cookie in updates.filter(isTWorldCookie) {
            result.removeAll { $0.name == cookie.name && $0.domain == cookie.domain && $0.path == cookie.path }
            result.append(cookie)
        }
        return result.filter { $0.expiresDate.map { $0 > now } ?? true }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // A redirect to sign-in is an expired session, never a JSON balance.
        completionHandler(nil)
    }
}

struct TWorldCredentials: Codable, Equatable {
    let id: String
    let password: String
}

/// Actor isolation keeps potentially blocking Keychain operations off the UI thread.
actor TWorldCookieVault {
    private let service = "com.clangerror.ClangNotch.tworld"
    private let sessionAccount = "session-v1"
    private let credentialsAccount = "credentials-v1"

    private func query(_ account: String) -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                kSecAttrAccount as String: account, kSecUseAuthenticationContext as String: context]
    }

    struct StoredSession: Codable {
        var cookies: [CookieRecord]
        var headers: [String: String] = [:]
        var endpoint: String? = nil
    }

    func load() throws -> (cookies: [HTTPCookie], headers: [String: String], endpoint: URL?) {
        guard let data = try read(sessionAccount) else { return ([], [:], nil) }
        let decoder = JSONDecoder()
        let stored: StoredSession
        if let decoded = try? decoder.decode(StoredSession.self, from: data) {
            stored = decoded
        } else {
            // Older items hold a bare cookie array.
            stored = StoredSession(cookies: try decoder.decode([CookieRecord].self, from: data))
        }
        return (TWorldClient.merge(stored.cookies.compactMap(\.cookie), updates: []), stored.headers, stored.endpoint.flatMap(URL.init(string:)))
    }

    func save(_ cookies: [HTTPCookie], headers: [String: String], endpoint: URL?) throws {
        let stored = StoredSession(cookies: cookies.filter(TWorldClient.isTWorldCookie).map(CookieRecord.init),
                                   headers: headers, endpoint: endpoint?.absoluteString)
        try write(sessionAccount, try JSONEncoder().encode(stored))
    }

    func loadCredentials() throws -> TWorldCredentials? {
        guard let data = try read(credentialsAccount) else { return nil }
        return try JSONDecoder().decode(TWorldCredentials.self, from: data)
    }

    func saveCredentials(_ credentials: TWorldCredentials) throws {
        try write(credentialsAccount, try JSONEncoder().encode(credentials))
    }

    func clear() throws {
        try delete(sessionAccount)
        try delete(credentialsAccount)
    }

    private func read(_ account: String) throws -> Data? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else { throw TWorldError.keychainUnavailable }
        return data
    }

    private func write(_ account: String, _ data: Data) throws {
        let update = [kSecValueData as String: data]
        var status = SecItemUpdate(query(account) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(account)
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw TWorldError.keychainUnavailable }
    }

    private func delete(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw TWorldError.keychainUnavailable }
    }

    struct CookieRecord: Codable {
        let name: String
        let value: String
        let domain: String
        let path: String
        let secure: Bool
        let httpOnly: Bool
        let expires: Date?

        init(_ cookie: HTTPCookie) {
            name = cookie.name; value = cookie.value; domain = cookie.domain; path = cookie.path
            secure = cookie.isSecure; expires = cookie.expiresDate
            httpOnly = cookie.isHTTPOnly
        }

        var cookie: HTTPCookie? {
            var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: path]
            if secure { properties[.secure] = "TRUE" }
            if httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
            if let expires { properties[.expires] = expires }
            return HTTPCookie(properties: properties)
        }
    }
}
