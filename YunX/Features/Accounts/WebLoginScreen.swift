import SwiftUI
import WebKit

// MARK: - Cookie 抓取

/// 从 `WKWebsiteDataStore` 里读出某个域下的 Cookie，拼成请求头用的字符串。
///
/// iOS 没有公开的「监听登录成功」接口，所以只能三路并用：
/// 导航完成时试一次、用户点「完成」时试一次、登录态 Cookie 出现时自动收工。
enum WebCookieGrabber {

    /// 各平台表示「已登录」的关键 Cookie 名。
    ///
    /// ★ 夸克/UC 不在这里：它们的 `__pus` 在**未登录**的匿名会话里也会下发，
    ///   用它判断会把「页面刚打开」误判成「已登录」。所以网盘一律让用户点「完成」。
    static func loginCookieNames(for domain: String) -> [String] {
        if domain.contains("bilibili") { return ["SESSDATA"] }
        if domain.contains("xiaohongshu") { return ["web_session"] }
        if domain.contains("pixiv") { return ["PHPSESSID"] }
        return []
    }

    static func allCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }

    static func cookie(for domainHint: String) async -> [HTTPCookie] {
        let cookies = await allCookies()
        guard !domainHint.isEmpty else { return cookies }
        return cookies.filter { cookie in
            let domain = cookie.domain.lowercased()
            let hint = domainHint.lowercased()
            return domain.contains(hint) || hint.contains(domain.replacingOccurrences(of: ".", with: ""))
        }
    }

    /// `a=1; b=2` 形态的 Cookie 头
    static func header(for domainHint: String) async -> String {
        let cookies = await cookie(for: domainHint)
        return cookies
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }

    /// 登录态是否已经拿到（用关键 Cookie 判断）
    static func hasLoginCookie(domain: String) async -> Bool {
        let names = loginCookieNames(for: domain)
        guard !names.isEmpty else { return false }
        let cookies = await cookie(for: domain)
        return cookies.contains { names.contains($0.name) && !$0.value.isEmpty }
    }
}

// MARK: - 网页登录

/// 内置网页登录：加载平台登录页，用户登完点「完成」，我们抓 Cookie 存进账号。
///
/// 两个细节：
/// - 小红书必须用**桌面 UA + 1280 宽**（移动端没有登录入口，且窄屏会把确认按钮裁掉）；
/// - 抓到关键 Cookie 后自动关闭并回调，不用用户再点一次。
struct WebLoginScreen: View {

    let title: String
    let urlString: String
    let cookieDomain: String
    var userAgent: String = HTTPClient.uaDesktop
    var viewportWidth: Int? = nil
    var onCaptured: (String, String) -> Void   // (cookie, 昵称占位)

    @Environment(\.dismiss) private var dismiss

    @State private var progress: Double = 0
    @State private var currentURL: String = ""
    @State private var captured = false
    @State private var noCookieHint = false

    var body: some View {
        NavigationStack {
            ZStack {
                AuroraBackdrop()
                VStack(spacing: 0) {
                    if progress < 1 {
                        ProgressView(value: progress)
                            .tint(Aurora.brand)
                            .padding(.horizontal, 16)
                            .padding(.top, 6)
                    }
                    WebViewContainer(
                        urlString: urlString,
                        userAgent: userAgent,
                        viewportWidth: viewportWidth,
                        progress: $progress,
                        currentURL: $currentURL
                    )
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        Task { await capture(manual: true) }
                    }
                    .fontWeight(.semibold)
                }
            }
            .task {
                // 登录页里 Cookie 是逐步写入的，轮询几次直到拿到关键 Cookie
                for _ in 0..<60 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if captured { return }
                    if await WebCookieGrabber.hasLoginCookie(domain: cookieDomain) {
                        await capture(manual: false)
                        return
                    }
                }
            }
            .alert("没有读到登录 Cookie", isPresented: $noCookieHint) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text("可能还没登录完成，或者该平台把登录态存在了 localStorage。可以退回「手动粘贴 Cookie」的方式。")
            }
        }
    }

    private func capture(manual: Bool) async {
        guard !captured else { return }
        let header = await WebCookieGrabber.header(for: cookieDomain)
        guard !header.isEmpty else {
            if manual { noCookieHint = true }
            return
        }
        captured = true
        onCaptured(header, "")
        dismiss()
    }
}

// MARK: - WKWebView 包装

struct WebViewContainer: UIViewRepresentable {

    let urlString: String
    let userAgent: String
    var viewportWidth: Int?
    @Binding var progress: Double
    @Binding var currentURL: String

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.customUserAgent = userAgent

        if let width = viewportWidth {
            // 用 viewport 覆盖把桌面页面塞进手机宽度：小红书登录表单是固定 440px 宽的容器，
            // 窄屏会把「登录」按钮裁到屏幕外，覆盖 viewport 后 WebView 会整体缩放
            let js = """
            (function() {
              var meta = document.querySelector('meta[name=viewport]');
              if (!meta) { meta = document.createElement('meta'); meta.name = 'viewport'; document.head.appendChild(meta); }
              meta.setAttribute('content', 'width=\(width), initial-scale=0.28, maximum-scale=3.0, user-scalable=yes');
            })();
            """
            let script = WKUserScript(source: js, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
            webView.configuration.userContentController.addUserScript(script)
        }

        if let url = URL(string: urlString) {
            webView.load(URLRequest(url: url))
        }
        context.coordinator.observe(webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.stopObserving()
    }

    final class Coordinator: NSObject, WKNavigationDelegate {

        private let parent: WebViewContainer
        private var progressObservation: NSKeyValueObservation?

        init(_ parent: WebViewContainer) {
            self.parent = parent
        }

        func observe(_ webView: WKWebView) {
            progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
                DispatchQueue.main.async {
                    self?.parent.progress = webView.estimatedProgress
                }
            }
        }

        func stopObserving() {
            progressObservation?.invalidate()
            progressObservation = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.currentURL = webView.url?.absoluteString ?? ""
        }
    }
}
