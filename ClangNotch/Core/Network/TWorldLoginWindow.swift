import AppKit
import WebKit

/// Only sign-in uses WebKit. Its private persistent profile never accesses Safari's cookies.
@MainActor
final class TWorldLoginWindow: NSObject, NSWindowDelegate, WKUIDelegate, WKNavigationDelegate {
    static let profileID = UUID(uuidString: "CF39EEA1-589E-47C6-944B-74DAD045D923")!
    private let window: NSWindow
    private let webView: WKWebView
    private let status = NSTextField(wrappingLabelWithString: "T world 로그인 후 아래 ‘연결 확인’을 눌러 주세요. 설정에 T ID 아이디와 비밀번호를 저장하면 세션 만료 시 자동으로 다시 로그인합니다.")
    private let confirm = NSButton(title: "로그인 후 연결 확인", target: nil, action: nil)
    private var popups: [NSWindow] = []
    private let onCookies: ([HTTPCookie], TWorldHeaderCapture.Capture) async throws -> Void
    private let onConnected: () -> Void
    private let onClosed: () -> Void

    init(cookies: [HTTPCookie], onCookies: @escaping ([HTTPCookie], TWorldHeaderCapture.Capture) async throws -> Void,
         onConnected: @escaping () -> Void, onClosed: @escaping () -> Void) {
        self.onCookies = onCookies
        self.onConnected = onConnected
        self.onClosed = onClosed
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: Self.profileID)
        configuration.userContentController.addUserScript(TWorldHeaderCapture.userScript)
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 760),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "ClangNotch · T world 로그인"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        webView.customUserAgent = TWorldClient.userAgent
        webView.uiDelegate = self
        webView.navigationDelegate = self
        confirm.target = self
        confirm.action = #selector(connect)
        let header = NSStackView(views: [status, confirm])
        header.orientation = .horizontal
        header.spacing = 12
        header.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        let content = NSView()
        window.contentView = content
        for view in [header, webView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            header.topAnchor.constraint(equalTo: content.topAnchor),
            webView.topAnchor.constraint(equalTo: header.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        Task {
            let store = webView.configuration.websiteDataStore.httpCookieStore
            for cookie in cookies.filter(TWorldClient.isTWorldCookie) { await store.setCookie(cookie) }
            webView.load(URLRequest(url: TWorldClient.pageURL))
        }
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() { window.close() }

    @objc private func connect() {
        confirm.isEnabled = false
        status.stringValue = "브라우저 밖에서 잔여량 조회 및 세션 저장을 확인하고 있습니다…"
        Task {
            do {
                let capture = await TWorldHeaderCapture.read(from: webView)
                let cookies: [HTTPCookie] = await withCheckedContinuation { continuation in
                    webView.configuration.websiteDataStore.httpCookieStore.getAllCookies {
                        continuation.resume(returning: $0)
                    }
                }
                try await onCookies(cookies.filter(TWorldClient.isTWorldCookie), capture)
                close()
                onConnected()
            } catch {
                status.stringValue = error.localizedDescription
                confirm.isEnabled = true
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        webView.stopLoading()
        for popup in popups { popup.close() }
        onClosed()
    }

    static func clearWebsiteData() async {
        await WKWebsiteDataStore(forIdentifier: profileID).removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let popup = WKWebView(frame: .zero, configuration: configuration)
        popup.customUserAgent = TWorldClient.userAgent
        popup.uiDelegate = self
        popup.navigationDelegate = self
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 720),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = "T world · 인증"
        panel.isReleasedWhenClosed = false
        panel.contentView = popup
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        popups.append(panel)
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) { webView.window?.close() }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let scheme = navigationAction.request.url?.scheme
        decisionHandler(scheme == "https" || scheme == "about" ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.beginSheetModal(for: webView.window ?? window) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "확인")
        alert.addButton(withTitle: "취소")
        alert.beginSheetModal(for: webView.window ?? window) { completionHandler($0 == .alertFirstButtonReturn) }
    }
}
