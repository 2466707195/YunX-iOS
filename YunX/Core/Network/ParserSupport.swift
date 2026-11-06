import Foundation

// MARK: - 页面内嵌 JSON 提取

/// 各平台的分享页都是「HTML 里塞一段 JS 对象」的形态：
/// `window.__INITIAL_STATE__=...`、`window.pageInfo=...`、`window._ROUTER_DATA=...`。
///
/// 用平衡括号扫描而不是正则：这些对象里嵌套深、还带字符串里的花括号，
/// 正则一定截断；扫描才拿得到完整 JSON。
enum HTMLPayload {

    /// 找到 `marker` 之后第一个 `{` 开始的对象并解析成 JSON。
    static func jsonObject(after marker: String, in html: String) -> Any? {
        guard let markerRange = html.range(of: marker) else { return nil }
        guard let start = html[markerRange.upperBound...].firstIndex(of: "{") else { return nil }
        guard let slice = balancedObject(from: start, in: html) else { return nil }
        return parseLoose(slice)
    }

    /// 同上，允许先跳过一段赋值表达式（`a.b=window.__X__=` 这种链式赋值）
    static func jsonObject(afterAny markers: [String], in html: String) -> Any? {
        for marker in markers {
            if let value = jsonObject(after: marker, in: html) { return value }
        }
        return nil
    }

    private static func balancedObject(from start: String.Index, in text: String) -> String? {
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else {
                if character == "\"" {
                    inString = true
                } else if character == "{" {
                    depth += 1
                } else if character == "}" {
                    depth -= 1
                    if depth == 0 { return String(text[start...index]) }
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// 页面里的对象常带 `undefined`，JSONSerialization 不认，统一换成 null
    static func parseLoose(_ json: String) -> Any? {
        var cleaned = json
            .replacingOccurrences(of: ":undefined", with: ":null")
            .replacingOccurrences(of: ": void 0", with: ":null")
            .replacingOccurrences(of: ":void 0", with: ":null")
        cleaned = cleaned.replacingOccurrences(of: "\\/", with: "/")
        guard let data = cleaned.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    /// 直接把 `JSON.parse('...')` 里那层字符串解开
    static func unescapedJSONString(_ raw: String) -> Any? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8) {
            return try? JSONSerialization.jsonObject(with: data)
        }
        return nil
    }

    /// 从 HTML 里清理出纯文本（微博正文是 HTML 片段）
    static func plainText(fromHTML html: String) -> String {
        var text = html
        text = text.replacingOccurrences(of: "<br />", with: "\n")
        text = text.replacingOccurrences(of: "<br/>", with: "\n")
        text = text.replacingOccurrences(of: "<br>", with: "\n")
        text = stripTags(text)
        return TextUtil.decodeHTMLEntities(text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripTags(_ html: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "<[^>]+>", options: []) else { return html }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        return regex.stringByReplacingMatches(in: html, options: [], range: range, withTemplate: "")
    }
}

// MARK: - 解析器共用

enum ParserSupport {

    static func requireCookie(_ platform: VideoPlatform, cookie: String) throws {
        if platform.requiresCookieForParse && cookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw VideoParseError(.unsupported, "\(platform.displayName)需要登录后才能解析，请先到「账号」页登录")
        }
    }

    /// `HTTPError` → `VideoParseError`：决定给用户看什么话，而不是把 403 甩出去
    static func translate(_ error: Error) -> Error {
        if error is VideoParseError { return error }
        if error is PanError { return error }
        guard let http = error as? HTTPError else { return error }
        switch http {
        case .status(let code, let body):
            if code == 403 || code == 418 || code == 412 {
                let hint = body.contains("captcha") || body.contains("验证") ? "（触发了验证码）" : ""
                return VideoParseError(.blocked, "平台返回 \(code)\(hint)")
            }
            if code == 404 { return VideoParseError(.notFound, "内容不存在或已删除") }
            if code == 401 { return VideoParseError(.unsupported, "登录态已失效，请重新登录") }
            return VideoParseError(.unknown, http.localizedDescription)
        case .network:
            return VideoParseError(.network, http.localizedDescription)
        case .decode(let detail):
            return VideoParseError(.unknown, "平台响应格式变了：\(detail)")
        case .invalidURL:
            return VideoParseError(.unsupported, "链接格式不正确")
        }
    }

    /// 图片媒体的统一构造：图片也要带 Referer，否则 CDN 直链 403
    static func imageMedia(
        url: String,
        fileName: String,
        quality: String,
        headers: [String: String]
    ) -> VideoMedia? {
        let clean = TextUtil.httpsURL(url)
        guard !clean.isEmpty else { return nil }
        return VideoMedia(
            url: clean,
            kind: .image,
            fileName: fileName,
            size: -1,
            headers: headers,
            quality: quality
        )
    }

    /// 微博/抖音的 `.m3u8`、`.mov` 之类后缀推断
    static func extensionForVideo(url: String) -> String {
        let lower = url.lowercased()
        if lower.contains(".m3u8") { return "m3u8" }
        if lower.contains(".mov") { return "mov" }
        if lower.contains(".flv") { return "flv" }
        if lower.contains(".webm") { return "webm" }
        return "mp4"
    }
}

// MARK: - 解析器协议

/// 单个视频平台的解析器。
protocol VideoParser {

    var platform: VideoPlatform { get }

    /// 解析一条已识别的链接（短链已在服务层展开）
    func parse(link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult

    /// 保存登录态前的校验：返回昵称（拿不到昵称返回空串），Cookie 无效返回 nil。
    /// 不做这一步就会存下一份「永远解析失败」的账号，用户看不懂错在哪。
    func validateCookie(_ cookie: String) async -> String?
}

extension VideoParser {

    func validateCookie(_ cookie: String) async -> String? {
        let trimmed = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : ""
    }
}
