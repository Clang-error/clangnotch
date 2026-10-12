import WebKit

/// Records the request headers T world's own page sends to the balance endpoint, so the
/// native client can repeat them. The header set is the site's to change; reading it off a
/// real request tracks those changes without another reverse-engineering round.
@MainActor
enum TWorldHeaderCapture {
    static let userScript = WKUserScript(source: """
        (function () {
          if (window.__cnHooked) return;
          window.__cnHooked = true;
          window.__cnBalanceRequest = null;
          var target = '/core-balance/v1/balances';
          var open = XMLHttpRequest.prototype.open, setH = XMLHttpRequest.prototype.setRequestHeader, send = XMLHttpRequest.prototype.send;
          XMLHttpRequest.prototype.open = function (m, u) { this.__cnUrl = String(u); this.__cnMethod = String(m || 'GET'); this.__cnHeaders = {}; return open.apply(this, arguments); };
          XMLHttpRequest.prototype.setRequestHeader = function (k, v) { if (this.__cnHeaders) this.__cnHeaders[k] = String(v); return setH.apply(this, arguments); };
          XMLHttpRequest.prototype.send = function () { if (this.__cnUrl && this.__cnUrl.indexOf(target) !== -1) window.__cnBalanceRequest = { url: this.__cnUrl, method: this.__cnMethod, headers: this.__cnHeaders }; return send.apply(this, arguments); };
          var f = window.fetch;
          if (f) window.fetch = function (input, init) {
            try {
              var u = typeof input === 'string' ? input : (input && input.url);
              if (u && u.indexOf(target) !== -1) {
                var h = {}, hh = (init && init.headers) || (input && input.headers);
                if (hh) { if (typeof hh.forEach === 'function') hh.forEach(function (v, k) { h[k] = String(v); }); else for (var k in hh) h[k] = String(hh[k]); }
                window.__cnBalanceRequest = { url: String(u), method: String((init && init.method) || (input && input.method) || 'GET'), headers: h };
              }
            } catch (e) {}
            return f.apply(this, arguments);
          };
        })();
        """, injectionTime: .atDocumentStart, forMainFrameOnly: false)

    struct Capture: Equatable {
        var endpoint: URL?
        var method: String = "GET"
        var headers: [String: String] = [:]
        var isEmpty: Bool { headers.isEmpty && endpoint == nil }
    }

    private struct Raw: Decodable {
        let url: String
        let method: String
        let headers: [String: String]
    }

    /// Polls for up to `timeout` seconds; the page fires its balance request shortly after load.
    static func read(from webView: WKWebView, timeout: TimeInterval = 8) async -> Capture {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let raw = try? await webView.evaluateJavaScript("JSON.stringify(window.__cnBalanceRequest)") as? String,
               raw != "null", let data = raw.data(using: .utf8),
               let request = try? JSONDecoder().decode(Raw.self, from: data) {
                let endpoint = URL(string: request.url, relativeTo: webView.url)?.absoluteURL
                let headers = request.headers.filter { !TWorldClient.reservedHeaders.contains($0.key.lowercased()) }
                return Capture(endpoint: endpoint, method: request.method.uppercased(), headers: headers)
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return Capture()
    }
}

/// Recovers an expired T world session without showing a window. T world hides T ID's
/// "로그인 정보 유지" option, so the only way back in is typing the saved T ID credentials into
/// T ID's own form; its page script handles password encryption and the reCAPTCHA token.
@MainActor
final class TWorldSilentLogin: NSObject, WKNavigationDelegate {
    private static let loginHost = "auth.skt-id.co.kr"
    private let webView: WKWebView
    private let credentials: TWorldCredentials?
    typealias Recovered = (cookies: [HTTPCookie], capture: TWorldHeaderCapture.Capture)
    private var continuation: CheckedContinuation<Recovered, Error>?
    private var submitted = false
    private var mainFrameStatus = 200
    private var forcedSignIn = false
    /// The hand-off page T world itself redirects to when a session lacks line context.
    private static let signInURL = URL(string: "https://www.tworld.co.kr/web/login/login-popup?isPopup=N&popup_request_yn=N&returnURL=/web/myt-data/balance")!

    private init(credentials: TWorldCredentials?) {
        self.credentials = credentials
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: TWorldLoginWindow.profileID)
        configuration.userContentController.addUserScript(TWorldHeaderCapture.userScript)
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1024, height: 768), configuration: configuration)
        super.init()
        webView.customUserAgent = TWorldClient.userAgent
        webView.navigationDelegate = self
    }

    /// T world cookies and the page's balance-request headers once a page outside the sign-in
    /// flow has loaded, or `loginRequired` when T ID still shows its form after 45 seconds.
    static func recover(credentials: TWorldCredentials?) async throws -> Recovered {
        try await TWorldSilentLogin(credentials: credentials).run()
    }

    private func run() async throws -> Recovered {
        let deadline = Task { [weak self] in
            try await Task.sleep(for: .seconds(45))
            self?.finish(.failure(TWorldError.loginRequired))
        }
        defer {
            deadline.cancel()
            webView.stopLoading()
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            webView.load(URLRequest(url: TWorldClient.pageURL))
        }
    }

    private func finish(_ result: Result<Recovered, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let url = webView.url else { return }
        if url.host == Self.loginHost {
            // One submission per recovery: a wrong password must not be retried into a lockout.
            guard let credentials, !submitted else { return }
            submitted = true
            webView.evaluateJavaScript(Self.fillScript(credentials))
            return
        }
        // An expired session first lands on /web/login/login-popup, which hands off to T ID.
        guard url.host == TWorldClient.pageURL.host, !url.path.hasPrefix("/web/login") else { return }
        // A signed-in session whose server-side line context lapsed renders the balance page
        // as a 500 error page (2026-09-23). Only the T ID hand-off rebuilds that context, and
        // T world doesn't redirect there on its own, so take that route once ourselves.
        if mainFrameStatus != 200 {
            guard !forcedSignIn else { finish(.failure(TWorldError.serviceUnavailable)); return }
            forcedSignIn = true
            webView.load(URLRequest(url: Self.signInURL))
            return
        }
        let store = webView.configuration.websiteDataStore.httpCookieStore
        Task { [weak self] in
            // The page's own balance request carries the headers the API currently demands.
            let capture = await TWorldHeaderCapture.read(from: webView)
            let cookies: [HTTPCookie] = await withCheckedContinuation { continuation in
                store.getAllCookies { continuation.resume(returning: $0) }
            }
            self?.finish(.success((cookies.filter(TWorldClient.isTWorldCookie), capture)))
        }
    }

    /// Waits for T ID's Vue form, sets both fields through the native setter so v-model sees the
    /// input events, then presses the login button.
    private static func fillScript(_ credentials: TWorldCredentials) -> String {
        let literal = { (value: String) -> String in
            let data = try! JSONSerialization.data(withJSONObject: [value])
            return String(decoding: data.dropFirst().dropLast(), as: UTF8.self)
        }
        return """
        (function () {
          var tries = 0;
          var timer = setInterval(function () {
            var id = document.querySelector('#inputId');
            var pw = document.querySelector('#inputPassword');
            var button = document.querySelector('button[data-click-id="login"]');
            if (!id || !pw || !button) { if (++tries > 150) clearInterval(timer); return; }
            clearInterval(timer);
            var set = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
            set.call(id, \(literal(credentials.id)));
            id.dispatchEvent(new Event('input', { bubbles: true }));
            set.call(pw, \(literal(credentials.password)));
            pw.dispatchEvent(new Event('input', { bubbles: true }));
            setTimeout(function () { button.click(); }, 1500);
          }, 100);
        })();
        """
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let scheme = navigationAction.request.url?.scheme
        decisionHandler(scheme == "https" || scheme == "about" ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.isForMainFrame, let http = navigationResponse.response as? HTTPURLResponse {
            mainFrameStatus = http.statusCode
        }
        decisionHandler(.allow)
    }
}
