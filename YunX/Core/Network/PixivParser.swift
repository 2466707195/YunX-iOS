import Foundation

// MARK: - Pixiv

/// Pixiv 插画/漫画解析（图集）。
///
/// 匿名只能拿到一部分公开作品；带上浏览器里的 `PHPSESSID` 才能拿到全部（含 R18 与受限作品）。
/// 内置网页登录走不通（登录页有 reCAPTCHA Enterprise 风控），所以账号页只提供「粘贴 Cookie」。
struct PixivParser: VideoParser {

    let platform: VideoPlatform = .pixiv

    private static let referer = "https://www.pixiv.net/"

    private func headers(cookie: String) -> [String: String] {
        var headers: [String: String] = [
            "User-Agent": HTTPClient.uaDesktop,
            "Referer": Self.referer,
            "Accept": "application/json"
        ]
        if !cookie.isEmpty { headers["Cookie"] = cookie }
        return headers
    }

    func parse(link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        let illustId = link.id
        guard !illustId.isEmpty else {
            throw VideoParseError(.unsupported, "没有从链接里取到作品 id")
        }
        do {
            let detailURL = "https://www.pixiv.net/ajax/illust/\(illustId)"
            let json = try await HTTPClient.desktop.getJSON(detailURL, headers: headers(cookie: cookie), referer: Self.referer)
            if JSONSearch.bool(json, "error") {
                let message = JSONSearch.str(json, "message")
                throw VideoParseError(.notFound, message.isEmpty ? "作品不存在或不可见" : message)
            }
            let body = JSONSearch.dictionary(in: json, path: ["body"])
            guard !body.isEmpty else { throw VideoParseError(.unknown, "Pixiv 返回体缺少 body") }

            let title = JSONSearch.str(body, "title")
            let author = JSONSearch.str(body, "userName")
            let description = JSONSearch.str(body, "description")
            let cover = TextUtil.httpsURL(JSONSearch.str(JSONSearch.dictionary(in: body, path: ["urls"]), "regular"))
            let pageCount = max(1, Int(JSONSearch.num(body, "pageCount")))
            let illustType = Int(JSONSearch.num(body, "illustType"))
            let createDate = JSONSearch.str(body, "createDate")

            // 逐页的原图地址：单图作品 detail 里就有 urls.original，多图必须再问 pages 接口
            var pageURLs: [String] = []
            if pageCount > 1 {
                let pagesURL = "https://www.pixiv.net/ajax/illust/\(illustId)/pages"
                if let pagesJSON = try? await HTTPClient.desktop.getJSON(
                    pagesURL,
                    headers: headers(cookie: cookie),
                    referer: Self.referer
                ) {
                    for item in JSONSearch.array(in: pagesJSON, path: ["body"]) {
                        guard let dict = item as? [String: Any] else { continue }
                        let original = JSONSearch.str(JSONSearch.dictionary(in: dict, path: ["urls"]), "original")
                        if !original.isEmpty { pageURLs.append(original) }
                    }
                }
            }
            if pageURLs.isEmpty {
                let original = JSONSearch.str(JSONSearch.dictionary(in: body, path: ["urls"]), "original")
                if !original.isEmpty { pageURLs.append(original) }
            }

            var medias: [VideoMedia] = []
            for (index, raw) in pageURLs.enumerated() {
                let ext = Self.extensionFor(raw, illustType: illustType)
                let name = TextUtil.fileName(title, fallback: "pixiv_\(illustId)", ext: "")
                guard let media = ParserSupport.imageMedia(
                    url: raw,
                    fileName: "\(name)_p\(index).\(ext)",
                    quality: "原图",
                    headers: headers(cookie: cookie)
                ) else { continue }
                medias.append(media)
            }
            guard !medias.isEmpty else {
                throw VideoParseError(.unsupported, "没有解析到图片直链（该作品可能需要登录）")
            }

            var notice = ""
            if pageCount > medias.count {
                notice = "只拿到 \(medias.count)/\(pageCount) 页，其余可能受登录态限制"
            }
            if cookie.isEmpty {
                notice = notice.isEmpty
                    ? "未登录：只能解析公开作品，受限作品需要在「账号」页粘贴 Cookie"
                    : notice
            }

            return VideoParseResult(
                platform: platform,
                title: title,
                author: author,
                cover: cover,
                text: TextUtil.decodeHTMLEntities(description),
                timestampSeconds: Self.parseDate(createDate),
                url: "https://www.pixiv.net/artworks/\(illustId)",
                medias: medias,
                notice: notice
            )
        } catch {
            throw ParserSupport.translate(error)
        }
    }

    private static func extensionFor(_ url: String, illustType: Int) -> String {
        if illustType == 2 { return "zip" }   // 动图（ugoira）原图是 zip 帧包
        let lower = url.lowercased()
        if lower.contains(".png") { return "png" }
        if lower.contains(".gif") { return "gif" }
        if lower.contains(".webp") { return "webp" }
        return "jpg"
    }

    /// `2026-11-01T12:30:00+09:00` → 秒级时间戳
    private static func parseDate(_ text: String) -> Int64 {
        guard !text.isEmpty else { return 0 }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) {
            return Int64(date.timeIntervalSince1970)
        }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) {
            return Int64(date.timeIntervalSince1970)
        }
        return 0
    }
}
