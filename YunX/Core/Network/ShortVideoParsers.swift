import Foundation

// MARK: - 抖音

/// 抖音解析：读分享页 SSR 数据（`window._ROUTER_DATA`）。
///
/// 匿名即可解析：分享页把作品信息整段内联在 HTML 里，不需要签名参数
/// （App 端接口那套 `X-Bogus`/`a_bogus` 签名这里完全用不到）。
struct DouyinParser: VideoParser {

    let platform: VideoPlatform = .douyin

    private var headers: [String: String] {
        [
            "User-Agent": HTTPClient.uaMobile,
            "Referer": "https://www.douyin.com/",
            "Accept-Language": "zh-CN,zh;q=0.9"
        ]
    }

    func parse(link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        guard !link.id.isEmpty else {
            throw VideoParseError(.unsupported, "抖音短链没能展开出作品 id")
        }
        do {
            let shareURL = "https://www.iesdouyin.com/share/video/\(link.id)/"
            let response = try await HTTPClient.shared.get(shareURL, headers: headers)
            guard response.isOK else {
                throw VideoParseError(.blocked, "分享页返回 \(response.status)")
            }
            let html = response.text
            guard let payload = HTMLPayload.jsonObject(
                afterAny: ["window._ROUTER_DATA", "_ROUTER_DATA = ", "_ROUTER_DATA="],
                in: html
            ) else {
                throw VideoParseError(.unknown, "分享页里没有找到作品数据（平台可能改版）")
            }

            let item = JSONSearch.dictionaries(in: payload, containingKey: "aweme_id").first ?? [:]
            let video = JSONSearch.dictionary(in: item, path: ["video"])
            let author = JSONSearch.dictionary(in: item, path: ["author"])

            var medias: [VideoMedia] = []
            let title = JSONSearch.str(item, "desc")
            let base = TextUtil.fileName(title, fallback: "douyin_\(link.id)", ext: "")

            // 图集（图文笔记）：images[].url_list
            let images = JSONSearch.array(in: item, path: ["images"])
            if !images.isEmpty {
                for (index, raw) in images.enumerated() {
                    guard let dict = raw as? [String: Any] else { continue }
                    guard let url = JSONSearch.strings(in: dict, keys: ["url_list"]).first else { continue }
                    guard let media = ParserSupport.imageMedia(
                        url: url,
                        fileName: "\(base)_\(index + 1).jpg",
                        quality: "原图",
                        headers: headers
                    ) else { continue }
                    medias.append(media)
                }
            }

            // 视频：play_addr.url_list，把带水印的 playwm 换成 play
            let playAddr = JSONSearch.dictionary(in: video, path: ["play_addr"])
            if var url = JSONSearch.strings(in: playAddr, keys: ["url_list"]).first {
                url = url.replacingOccurrences(of: "playwm", with: "play")
                let ext = ParserSupport.extensionForVideo(url: url)
                medias.append(VideoMedia(
                    url: TextUtil.httpsURL(url),
                    kind: .video,
                    fileName: "\(base).\(ext)",
                    size: -1,
                    headers: headers,
                    quality: "无水印"
                ))
            }

            guard !medias.isEmpty else {
                throw VideoParseError(.notFound, "作品不存在、已删除或不可见")
            }

            let cover = JSONSearch.strings(in: JSONSearch.dictionary(in: video, path: ["cover"]), keys: ["url_list"]).first
                ?? JSONSearch.strings(in: JSONSearch.dictionary(in: video, path: ["origin_cover"]), keys: ["url_list"]).first
                ?? ""

            return VideoParseResult(
                platform: platform,
                title: title.isEmpty ? "抖音作品" : title,
                author: JSONSearch.str(author, "nickname"),
                avatar: TextUtil.httpsURL(JSONSearch.strings(in: JSONSearch.dictionary(in: author, path: ["avatar_thumb"]), keys: ["url_list"]).first ?? ""),
                cover: TextUtil.httpsURL(cover),
                text: title,
                url: "https://www.douyin.com/video/\(link.id)",
                medias: medias
            )
        } catch {
            throw ParserSupport.translate(error)
        }
    }
}

// MARK: - 快手

/// 快手解析：读 `window.__APOLLO_STATE__` 里的 `photoUrl`。
struct KuaishouParser: VideoParser {

    let platform: VideoPlatform = .kuaishou

    private var headers: [String: String] {
        [
            "User-Agent": HTTPClient.uaDesktop,
            "Referer": "https://www.kuaishou.com/",
            "Accept-Language": "zh-CN,zh;q=0.9"
        ]
    }

    func parse(link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        do {
            let pageURL = link.url.hasPrefix("http") ? link.url : "https://www.kuaishou.com/short-video/\(link.id)"
            let response = try await HTTPClient.shared.get(pageURL, headers: headers)
            guard response.isOK else {
                throw VideoParseError(.blocked, "作品页返回 \(response.status)")
            }
            let html = response.text
            guard let payload = HTMLPayload.jsonObject(
                afterAny: ["window.__APOLLO_STATE__", "__APOLLO_STATE__ = ", "__APOLLO_STATE__="],
                in: html
            ) else {
                throw VideoParseError(.unknown, "作品页里没有找到数据（可能需要登录或平台改版）")
            }

            let candidates = JSONSearch.strings(in: payload, keys: ["photoUrl", "playUrl", "srcNoMark"])
                .filter { $0.hasPrefix("http") && ($0.contains(".mp4") || $0.contains("video")) }
            guard let url = candidates.first else {
                throw VideoParseError(.notFound, "没有解析到视频直链")
            }

            let caption = JSONSearch.string(in: payload, keys: ["caption", "title", "photoCaption"]) ?? ""
            let base = TextUtil.fileName(caption, fallback: "kuaishou_\(link.id)", ext: "")
            let media = VideoMedia(
                url: TextUtil.httpsURL(url),
                kind: .video,
                fileName: "\(base).mp4",
                headers: headers,
                quality: "原画"
            )

            return VideoParseResult(
                platform: platform,
                title: caption.isEmpty ? "快手作品" : caption,
                author: JSONSearch.string(in: payload, keys: ["userName", "name"]) ?? "",
                cover: TextUtil.httpsURL(JSONSearch.strings(in: payload, keys: ["coverUrl", "coverUrls"]).first ?? ""),
                text: caption,
                url: pageURL,
                medias: [media]
            )
        } catch {
            throw ParserSupport.translate(error)
        }
    }
}

// MARK: - 微博

/// 微博解析：m 站 JSON 接口（`m.weibo.cn/statuses/show`）。
///
/// 视频在 `page_info.media_info.stream_url`（或 `page_info.urls` 里的 mp4），
/// 图片在 `pics[].large.url`；带 `videoSrc` 的图片其实是动图。
struct WeiboParser: VideoParser {

    let platform: VideoPlatform = .weibo

    private var headers: [String: String] {
        [
            "User-Agent": HTTPClient.uaMobile,
            "Referer": "https://m.weibo.cn/",
            "Accept": "application/json, text/plain, */*",
            "X-Requested-With": "XMLHttpRequest"
        ]
    }

    func parse(link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        do {
            if link.kind == "fid" || link.kind == "tv" {
                return try await parseVideoPage(link: link)
            }
            let api = "https://m.weibo.cn/statuses/show?id=\(link.id)"
            let json = try await HTTPClient.shared.getJSON(api, headers: headers, referer: "https://m.weibo.cn/")
            let data = JSONSearch.dictionary(in: json, path: ["data"])
            guard !data.isEmpty else {
                throw VideoParseError(.notFound, "微博不存在、已删除或不可见")
            }

            let text = HTMLPayload.plainText(fromHTML: JSONSearch.str(data, "text"))
            let user = JSONSearch.dictionary(in: data, path: ["user"])
            let author = JSONSearch.str(user, "screen_name")
            let base = TextUtil.fileName(text, fallback: "weibo_\(link.id)", ext: "")
            var medias: [VideoMedia] = []

            // ① 视频
            let pageInfo = JSONSearch.dictionary(in: data, path: ["page_info"])
            if !pageInfo.isEmpty {
                var stream = JSONSearch.str(JSONSearch.dictionary(in: pageInfo, path: ["media_info"]), "stream_url")
                if stream.isEmpty { stream = JSONSearch.str(pageInfo, "page_url") }
                if stream.isEmpty {
                    let urls = JSONSearch.dictionary(in: pageInfo, path: ["urls"])
                    stream = JSONSearch.strings(in: urls, keys: ["mp4_720p_mp4", "mp4_hd_url", "mp4_sd_url", "hevc_mp4_hd_url"]).first ?? ""
                }
                if !stream.isEmpty {
                    let ext = ParserSupport.extensionForVideo(url: stream)
                    medias.append(VideoMedia(
                        url: TextUtil.httpsURL(stream),
                        kind: .video,
                        fileName: "\(base).\(ext)",
                        headers: headers,
                        quality: "视频"
                    ))
                }
            }

            // ② 图片（含动图）
            let pics = JSONSearch.array(in: data, path: ["pics"])
            for (index, raw) in pics.enumerated() {
                guard let dict = raw as? [String: Any] else { continue }
                var url = JSONSearch.str(JSONSearch.dictionary(in: dict, path: ["large"]), "url")
                if url.isEmpty { url = JSONSearch.str(dict, "url") }
                guard let media = ParserSupport.imageMedia(
                    url: url,
                    fileName: "\(base)_\(index + 1).jpg",
                    quality: "原图",
                    headers: headers
                ) else { continue }
                var withMotion = media
                let motion = JSONSearch.str(dict, "videoSrc")
                if !motion.isEmpty { withMotion.motionUrl = TextUtil.httpsURL(motion) }
                medias.append(withMotion)
            }

            guard !medias.isEmpty else {
                throw VideoParseError(.unsupported, "这条微博里没有可下载的图片或视频")
            }

            return VideoParseResult(
                platform: platform,
                title: text.isEmpty ? "微博" : String(text.prefix(40)),
                author: author,
                avatar: TextUtil.httpsURL(JSONSearch.str(user, "profile_image_url")),
                cover: medias.first?.kind == .image ? medias[0].url : "",
                text: text,
                timestampSeconds: Self.timestamp(JSONSearch.str(data, "created_at")),
                url: "https://m.weibo.cn/detail/\(link.id)",
                medias: medias
            )
        } catch {
            throw ParserSupport.translate(error)
        }
    }

    /// `video.weibo.com/show?fid=` 这类只有播放页的链接：从页面里抠 stream_url
    private func parseVideoPage(link: DetectedVideoLink) async throws -> VideoParseResult {
        let pageURL = link.kind == "fid"
            ? "https://video.weibo.com/show?fid=\(link.id)"
            : link.url
        let response = try await HTTPClient.shared.get(pageURL, headers: headers)
        let html = response.text
        var candidates = RegexUtil.allGroups("\"(https?:[^\"]*\\.mp4[^\"]*)\"", in: html)
        if candidates.isEmpty {
            candidates = RegexUtil.allGroups("(https?:[^\"'\\s]*\\.m3u8[^\"'\\s]*)", in: html)
        }
        guard let url = candidates.first else {
            throw VideoParseError(.notFound, "播放页里没有可下载的直链")
        }
        let base = TextUtil.fileName(JSONSearch.str(HTMLPayload.jsonObject(after: "window.$render_data", in: html) as? [String: Any] ?? [:], "title"), fallback: "weibo_video", ext: "")
        let media = VideoMedia(
            url: TextUtil.httpsURL(url),
            kind: .video,
            fileName: "\(base).mp4",
            headers: headers,
            quality: "视频"
        )
        return VideoParseResult(
            platform: platform,
            title: base,
            url: pageURL,
            medias: [media]
        )
    }

    private static func timestamp(_ text: String) -> Int64 {
        guard !text.isEmpty else { return 0 }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM dd HH:mm:ss Z yyyy"
        if let date = formatter.date(from: text) {
            return Int64(date.timeIntervalSince1970)
        }
        return 0
    }
}

// MARK: - 小红书

/// 小红书解析：读笔记页 `window.__INITIAL_STATE__`。
///
/// ★ 必须登录：未登录访问笔记页会被 302 到登录/验证码页，页面里没有 `__INITIAL_STATE__`。
struct XhsParser: VideoParser {

    let platform: VideoPlatform = .xhs

    private func headers(cookie: String) -> [String: String] {
        var headers: [String: String] = [
            "User-Agent": HTTPClient.uaDesktop,
            "Referer": "https://www.xiaohongshu.com/",
            "Accept-Language": "zh-CN,zh;q=0.9"
        ]
        if !cookie.isEmpty { headers["Cookie"] = cookie }
        return headers
    }

    func parse(link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        if cookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw VideoParseError(.unsupported, "小红书要求登录后才能查看笔记，请先到「账号」页登录")
        }
        do {
            let pageURL = "https://www.xiaohongshu.com/explore/\(link.id)"
            let response = try await HTTPClient.desktop.get(pageURL, headers: headers(cookie: cookie))
            guard response.isOK else {
                throw VideoParseError(.blocked, "笔记页返回 \(response.status)")
            }
            let html = response.text
            guard let payload = HTMLPayload.jsonObject(afterAny: ["window.__INITIAL_STATE__", "__INITIAL_STATE__ = "], in: html) else {
                throw VideoParseError(.blocked, "笔记页没有返回数据：登录态可能已失效，请到「账号」页重新登录")
            }

            let note = JSONSearch.dictionaries(in: payload, containingKey: "imageList").first
                ?? JSONSearch.dictionaries(in: payload, containingKey: "noteCard").first
                ?? [:]
            let title = JSONSearch.str(note, "title")
            let desc = JSONSearch.str(note, "desc")
            let user = JSONSearch.dictionary(in: note, path: ["user"])
            let base = TextUtil.fileName(title.isEmpty ? desc : title, fallback: "xhs_\(link.id)", ext: "")
            var medias: [VideoMedia] = []

            let masterURL = JSONSearch.string(in: payload, keys: ["masterUrl", "master_url"]) ?? ""
            if !masterURL.isEmpty {
                medias.append(VideoMedia(
                    url: TextUtil.httpsURL(masterURL),
                    kind: .video,
                    fileName: "\(base).mp4",
                    headers: headers(cookie: cookie),
                    quality: "视频"
                ))
            }

            let imageList = JSONSearch.array(in: note, path: ["imageList"])
            for (index, raw) in imageList.enumerated() {
                guard let dict = raw as? [String: Any] else { continue }
                var url = JSONSearch.str(dict, "urlDefault")
                if url.isEmpty { url = JSONSearch.str(dict, "urlPre") }
                if url.isEmpty { url = JSONSearch.strings(in: dict, keys: ["url"]).first ?? "" }
                guard let media = ParserSupport.imageMedia(
                    url: url,
                    fileName: "\(base)_\(index + 1).jpg",
                    quality: "原图",
                    headers: headers(cookie: cookie)
                ) else { continue }
                medias.append(media)
            }

            guard !medias.isEmpty else {
                throw VideoParseError(.notFound, "笔记里没有可下载的媒体")
            }

            return VideoParseResult(
                platform: platform,
                title: title.isEmpty ? String(desc.prefix(30)) : title,
                author: JSONSearch.str(user, "nickname"),
                avatar: TextUtil.httpsURL(JSONSearch.str(user, "avatar")),
                cover: medias.first?.url ?? "",
                text: desc,
                url: pageURL,
                medias: medias
            )
        } catch {
            throw ParserSupport.translate(error)
        }
    }
}

// MARK: - AcFun

/// AcFun：`window.pageInfo` 里的 `ksPlayJson`（内容是 JSON 字符串），
/// 里面给的是 m3u8 —— 下载走 HLS 分片合并路径。
struct AcFunParser: VideoParser {

    let platform: VideoPlatform = .acfun

    private var headers: [String: String] {
        [
            "User-Agent": HTTPClient.uaDesktop,
            "Referer": "https://www.acfun.cn/",
            "Accept-Language": "zh-CN,zh;q=0.9"
        ]
    }

    func parse(link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        do {
            let pageURL = "https://www.acfun.cn/v/ac\(link.id)"
            let response = try await HTTPClient.shared.get(pageURL, headers: headers)
            guard response.isOK else {
                throw VideoParseError(.blocked, "作品页返回 \(response.status)")
            }
            let html = response.text
            guard let payload = HTMLPayload.jsonObject(afterAny: ["window.pageInfo", "pageInfo = "], in: html) else {
                throw VideoParseError(.unknown, "作品页里没有找到视频数据（平台可能改版）")
            }

            let title = JSONSearch.string(in: payload, keys: ["title"]) ?? "AcFun \(link.id)"
            let base = TextUtil.fileName(title, fallback: "acfun_\(link.id)", ext: "")

            // ksPlayJson 本身是字符串，里面还有一层 JSON
            var m3u8: String?
            if let raw = JSONSearch.string(in: payload, keys: ["ksPlayJson"]),
               let inner = HTMLPayload.unescapedJSONString(raw) {
                m3u8 = JSONSearch.strings(in: inner, keys: ["url"]).first { $0.contains(".m3u8") }
                    ?? JSONSearch.strings(in: inner, keys: ["url"]).first
            }
            if m3u8 == nil {
                m3u8 = RegexUtil.allGroups("(https?:[^\"'\\s]*\\.m3u8[^\"'\\s]*)", in: html).first
            }
            guard let finalURL = m3u8 else {
                throw VideoParseError(.notFound, "没有解析到 m3u8 地址")
            }

            let media = VideoMedia(
                url: TextUtil.httpsURL(finalURL),
                kind: .video,
                fileName: "\(base).ts",
                isHls: true,
                headers: headers,
                quality: "HLS 原画"
            )
            return VideoParseResult(
                platform: platform,
                title: title,
                author: JSONSearch.string(in: payload, keys: ["userName", "authorName"]) ?? "",
                cover: TextUtil.httpsURL(JSONSearch.string(in: payload, keys: ["coverImage", "image"]) ?? ""),
                text: JSONSearch.string(in: payload, keys: ["description"]) ?? "",
                url: pageURL,
                medias: [media],
                notice: "AcFun 是 HLS 流，下载会合并成单个 .ts 文件（可用 VLC 播放）"
            )
        } catch {
            throw ParserSupport.translate(error)
        }
    }
}
