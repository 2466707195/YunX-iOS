import Foundation
import UIKit
import WebKit

// MARK: - 隐藏 WebView

/// 「隐藏 WebView」解析通道：让页面的 JS 真正跑一遍，再把结果取回来。
///
/// 为什么需要它（2026-10 实测）：抖音的 `iesdouyin.com/share/...` 会 302 到
/// `www.douyin.com/{video|note}/<id>`，纯 HTTP 拿到的是一张 `byted_acrawler` 的 JS 挑战页
/// （用 `__ac_nonce` 算出 `__ac_signature` 写回 Cookie 再 `location.reload()`），页面里
/// **没有作品数据**；真正作品页的数据还要靠页面自己发 `aweme/v1/web/aweme/detail` 才拿得到。
/// 这两步都只有「真的把页面跑起来」才能过 —— 在本文件里改字段名是没用的。
///
/// 做法：把 `WKWebView` 挂到 key window 上（1×1、几乎全透明，肉眼不可见），
/// 轮询 `readyCheckJS` 直到它返回 `"true"` 或超时，再执行 `extractJS` 取值，最后销毁。
/// **必须挂窗口**：不挂的话 `requestAnimationFrame` / `document.visibilityState` 不对，
/// 挑战脚本容易就此卡住。
///
/// 取回值约定：
/// - `readyCheckJS` 返回字符串 `"true"` / `"false"`（不要返回布尔值，桥接后的类型不好判断）；
/// - `extractJS` 返回一个 **JSON 字符串**（自己 `JSON.stringify`），方便直接交给 `JSONSerialization`。
@MainActor
final class HeadlessWebView: NSObject {

    static let shared = HeadlessWebView()

    /// 正在跑：同时只允许一个（解析是一次一个的，撞车说明上层逻辑有问题，直接放弃更安全）
    private var busy = false
    private var webView: WKWebView?
    private var host: UIWindow?
    private var failure: String?

    /// 打开 `url`，等 `readyCheckJS` 为真后执行 `extractJS` 取回 JSON 文本；超时/失败返回 nil。
    ///
    /// - Parameters:
    ///   - documentStartScripts: 必须在页面自身脚本之前跑的脚本（XHR 钩子、navigator 伪装）。
    func loadAndExtract(
        url: String,
        userAgent: String,
        readyCheckJS: String,
        extractJS: String,
        timeout: TimeInterval = 40,
        settle: TimeInterval = 0.25,
        documentStartScripts: [String] = []
    ) async -> String? {
        guard !busy, let target = URL(string: url) else { return nil }
        busy = true
        defer {
            cleanup()
            busy = false
        }

        guard let window = Self.keyWindow() else { return nil }
        host = window
        failure = nil

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        for script in documentStartScripts {
            configuration.userContentController.addUserScript(
                WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            )
        }

        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
        web.customUserAgent = userAgent
        web.navigationDelegate = self
        // alpha 不能是 0：那样 WebKit 会认为视图不可见，页面渲染/定时器会被降频
        web.alpha = 0.01
        web.isUserInteractionEnabled = false
        web.allowsBackForwardNavigationGestures = false
        web.scrollView.isScrollEnabled = false
        window.addSubview(web)
        webView = web

        var request = URLRequest(url: target)
        request.timeoutInterval = timeout
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        web.load(request)

        let deadline = Date().addingTimeInterval(timeout)
        var ready = false
        while Date() < deadline {
            if failure != nil { return nil }
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let value = await evaluate(readyCheckJS) else { continue }
            if value == "true" || value == "1" {
                ready = true
                break
            }
            // 页面自己都说「作品不存在」了，没必要再等到超时
            if value == "abort" { break }
        }
        guard ready, failure == nil else { return nil }

        // 就绪后再给页面一点时间把详情写完（DOM/接口都可能在就绪判据之后才落定）
        try? await Task.sleep(nanoseconds: UInt64(max(0, settle) * 1_000_000_000))
        guard let json = await evaluate(extractJS), !json.isEmpty, json != "null" else { return nil }
        return json
    }

    // MARK: 内部

    private func evaluate(_ script: String) async -> String? {
        guard let web = webView else { return nil }
        let value = try? await web.evaluateJavaScript(script)
        if let text = value as? String { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private func cleanup() {
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
        host = nil
    }

    /// 当前 key window（必须挂上去，页面才会被当作可见）
    private static func keyWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let active = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard let windows = active?.windows else { return nil }
        return windows.first { $0.isKeyWindow } ?? windows.first
    }
}

// MARK: - 导航回调

extension HeadlessWebView: WKNavigationDelegate {

    nonisolated func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        let message = error.localizedDescription
        Task { @MainActor [weak self] in
            guard let self, self.failure == nil else { return }
            self.failure = message
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        let message = error.localizedDescription
        Task { @MainActor [weak self] in
            guard let self, self.failure == nil else { return }
            self.failure = message
        }
    }

    /// 只放行 http(s)：抖音会试图跳 `snssdk1128://`（拉起 App），在 WebView 里一跳就走丢了
    nonisolated func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        let scheme = navigationAction.request.url?.scheme?.lowercased() ?? "https"
        let allowed: Set<String> = ["http", "https", "about", "data", "blob", "file"]
        decisionHandler(allowed.contains(scheme) ? .allow : .cancel)
    }
}

// MARK: - 通用脚本片段

/// 让 `navigator.platform` 与自定义 UA 自洽的脚本。
///
/// WKWebView 不管 `customUserAgent` 写的是什么，`navigator.platform` 都还是 `iPhone`。
/// 我们对外声称是 Mac Chrome，页面自己会把这个不一致序列化进请求参数，风控据此判定
/// 「环境被伪装」→ 服务端不给直出详情（表现：一直停在上拉加载）。文档开始前覆盖 getter 即可。
enum WebViewDisguise {

    static func platformScript(platform: String) -> String {
        """
        (function(){try{Object.defineProperty(navigator,'platform',{get:function(){return '\(platform)';},configurable:true});}catch(e){}})()
        """
    }

    /// 与 UA 对应的 platform 值
    static func platform(for userAgent: String) -> String {
        if userAgent.contains("Windows") { return "Win32" }
        if userAgent.contains("Macintosh") { return "MacIntel" }
        return "iPhone"
    }

    /// 一站式：按 UA 生成伪装脚本（拿不到对应关系时返回空数组）
    static func scripts(for userAgent: String) -> [String] {
        let value = platform(for: userAgent)
        guard value != "iPhone" else { return [] }
        return [platformScript(platform: value)]
    }
}
