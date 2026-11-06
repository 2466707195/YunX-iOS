import Foundation
import UIKit
import WebKit

// MARK: - 结果

/// 隐藏 WebView 一次尝试的结果。
///
/// 失败时 `diagnostics` 是页面的真实状态（标题 / 地址 / 正文长度 / 图片数 / 钩子是否命中），
/// 会原样拼进解析报错里 —— 下次出问题不用再猜「到底是没跑起来，还是字段变了」。
struct WebViewOutcome {
    var json: String?
    var diagnostics: String

    var isEmpty: Bool { json == nil }
}

// MARK: - 隐藏 WebView

/// 「隐藏 WebView」解析通道：让页面的 JS 真正跑一遍，再把结果取回来。
///
/// 为什么需要它（实测）：抖音的 `iesdouyin.com/share/...` 会 302 到
/// `www.douyin.com/{video|note}/<id>`，纯 HTTP 拿到的只有页面元数据
/// （`_ROUTER_DATA` 里 `videoInfoRes: null`，图文的 `loaderData` 连媒体字段都没有）；
/// 作品详情接口 `aweme/v1/web/aweme/detail` 直接返回
/// `403 Blocked by ArgusSecurityPlugin Uifid Not Found` —— 需要页面自己算的
/// `uifid` + `a_bogus`（外加 `byted_acrawler` 的 JS 挑战）才能过。
/// 这两步只有「真的把页面跑起来」才能过 —— 在解析器里改字段名是没用的。
///
/// ★ 尺寸必须够大：`1×1` 的视口会让图文页的懒加载图永远不载、视频页播放器不初始化，
///   表现就是「页面看着打开了，但永远不就绪」。这里用整屏尺寸 + `alpha 0.01`（几乎全透明，
///   用户看不到），并且关掉交互，不影响上面的 UI。
/// ★ 预置 `ttwid` Cookie：页面自己的注册请求要走 CORS，WebView 里偶发失败后详情接口
///   会一路 403。改成原生请求先把 `ttwid` 写进 CookieStore，页面就不用再赌这一步。
@MainActor
final class HeadlessWebView: NSObject {

    static let shared = HeadlessWebView()

    /// 正在跑：同时只允许一个（解析是一次一个的，撞车说明上层逻辑有问题，直接放弃更安全）
    private var busy = false
    private var webView: WKWebView?
    private var failure: String?
    private var landedURL = ""
    private var loads = 0
    private static var seededTTWID = false

    /// 打开 `url`，等 `readyCheckJS` 为真后执行 `extractJS` 取回 JSON 文本。
    ///
    /// 超时不再直接判死：截止前还会再跑一次 `extractJS`（页面已经把数据画出来的情况能救回来），
    /// 并把页面状态写进 `diagnostics`。
    ///
    /// - Parameters:
    ///   - readyCheckJS: 返回字符串 `"true"` / `"false"` / `"abort"`（不要返回布尔值，桥接后类型不好判断）。
    ///   - extractJS: 返回 **JSON 字符串**（自己 `JSON.stringify`），方便交给 `JSONSerialization`。
    ///   - diagnoseJS: 返回一句人话状态，用来说明「为什么没就绪」。
    func loadAndExtract(
        url: String,
        userAgent: String,
        readyCheckJS: String,
        extractJS: String,
        diagnoseJS: String = "",
        timeout: TimeInterval = 22,
        settle: TimeInterval = 0.3,
        documentStartScripts: [String] = []
    ) async -> WebViewOutcome {
        var outcome = WebViewOutcome(json: nil, diagnostics: "未启动")
        guard !busy, let target = URL(string: url) else {
            outcome.diagnostics = busy ? "另一个解析正在进行" : "地址无效"
            return outcome
        }
        busy = true
        defer {
            cleanup()
            busy = false
        }

        guard let window = Self.keyWindow() else {
            outcome.diagnostics = "拿不到窗口（应用不在前台？）"
            return outcome
        }
        failure = nil
        landedURL = ""
        loads = 0

        await Self.seedTTWID()

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        for script in documentStartScripts {
            configuration.userContentController.addUserScript(
                WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            )
        }

        // ★ 整屏尺寸：1×1 会让懒加载 / 播放器初始化停摆（这是之前「三个通道全未就绪」的主因）
        let bounds = window.bounds
        let web = WKWebView(frame: bounds, configuration: configuration)
        web.customUserAgent = userAgent
        web.navigationDelegate = self
        // alpha 不能是 0：那样 WebKit 会认为视图不可见，页面渲染/定时器会被降频
        web.alpha = 0.01
        web.isOpaque = false
        web.backgroundColor = .clear
        web.isUserInteractionEnabled = false
        web.allowsBackForwardNavigationGestures = false
        web.scrollView.isScrollEnabled = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        window.addSubview(web)
        webView = web

        var request = URLRequest(url: target)
        request.timeoutInterval = max(8, timeout)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.douyin.com/", forHTTPHeaderField: "Referer")
        web.load(request)

        let deadline = Date().addingTimeInterval(timeout)
        var ready = false
        var aborted = false
        while Date() < deadline {
            if failure != nil { break }
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard let value = await evaluate(readyCheckJS) else { continue }
            if value == "true" || value == "1" {
                ready = true
                break
            }
            if value == "abort" {
                aborted = true
                break
            }
        }

        // 就绪后再给页面一点时间把详情写完（DOM/接口都可能在就绪判据之后才落定）
        if ready {
            try? await Task.sleep(nanoseconds: UInt64(max(0, settle) * 1_000_000_000))
        }

        // 即使没就绪也取一次：数据可能已经写在 DOM/钩子里，只是判据没命中
        if !aborted, let json = await evaluate(extractJS), Self.looksUseful(json) {
            outcome.json = json
        }

        if outcome.json == nil {
            var parts: [String] = []
            parts.append(ready ? "就绪但取数为空" : (aborted ? "页面显示作品不存在" : "未就绪"))
            if let error = failure { parts.append("load=\(error)") }
            if loads == 0 { parts.append("导航=0") }
            if !landedURL.isEmpty { parts.append("url=\(Self.shorten(landedURL))") }
            if !diagnoseJS.isEmpty, let note = await evaluate(diagnoseJS), !note.isEmpty {
                parts.append(note)
            }
            outcome.diagnostics = parts.joined(separator: "|")
        } else {
            outcome.diagnostics = "ok"
        }
        return outcome
    }

    // MARK: 内部

    /// `extractJS` 可能回 `{"error":…}` 或者空壳，这里只判断「有没有真的取到东西」
    private static func looksUseful(_ json: String) -> Bool {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "null", trimmed != "{}" else { return false }
        guard let data = trimmed.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return false
        }
        if let video = object["video"] as? String, !video.isEmpty { return true }
        if let images = object["images"] as? [Any], !images.isEmpty { return true }
        return false
    }

    private static func shorten(_ url: String) -> String {
        guard url.count > 90 else { return url }
        return String(url.prefix(90)) + "…"
    }

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
    }

    /// 当前 key window（必须挂上去，页面才会被当作可见）
    private static func keyWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let active = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard let windows = active?.windows else { return nil }
        return windows.first { $0.isKeyWindow } ?? windows.first
    }

    // MARK: ttwid

    /// 逐域写 `ttwid`。一次性，之后进程内不再重复请求。
    private static func seedTTWID() async {
        guard !seededTTWID else { return }
        seededTTWID = true
        guard let value = await registerTTWID() else { return }
        let store = WKWebsiteDataStore.default().httpCookieStore
        let expiry = Date().addingTimeInterval(60 * 60 * 24 * 300)
        for domain in [".douyin.com", ".iesdouyin.com"] {
            let props: [HTTPCookiePropertyKey: Any] = [
                .name: "ttwid",
                .value: value,
                .domain: domain,
                .path: "/",
                .secure: "TRUE",
                .expires: expiry
            ]
            guard let cookie = HTTPCookie(properties: props) else { continue }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                store.setCookie(cookie) { continuation.resume() }
            }
        }
    }

    /// 公开接口，不需要登录：拿一个 `ttwid`（全站通用的设备标识 Cookie）
    private static func registerTTWID() async -> String? {
        guard let url = URL(string: "https://ttwid.bytedance.com/ttwid/union/register/") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = #"{"region":"cn","aid":1768,"needFid":false,"service":"www.ixigua.com","migrate_info":{"ticket":"","source":"node"},"cbUrlProtocol":"https","union":true}"#
        request.httpBody = body.data(using: .utf8)
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200 else { return nil }
        let header = http.value(forHTTPHeaderField: "Set-Cookie") ?? ""
        guard let range = header.range(of: "ttwid=") else { return nil }
        let tail = header[range.upperBound...]
        let value = tail.prefix { $0 != ";" && $0 != "," }
        return value.isEmpty ? nil : String(value)
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

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let url = webView.url?.absoluteString ?? ""
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.loads += 1
            self.landedURL = url
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
