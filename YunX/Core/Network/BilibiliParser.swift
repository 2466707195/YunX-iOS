import Foundation

// MARK: - 哔哩哔哩

/// 哔哩哔哩解析。
///
/// 数据来源都是**公开 web 接口**：
/// 1. `x/web-interface/view` → bvid / cid / 标题 / UP 主 / 封面 / 时长；
/// 2. 已登录优先取 DASH 分轨（`fnval=4048`），未登录退回单文件 `durl`（`fnval=1`）。
///
/// ★ 为什么保留单文件路径：DASH 是音视频**分离**的两路流，必须合轨才能得到可播放的 mp4。
///   未登录时 DASH 往往也是最低清，不值得为它引入更长的合轨链路 —— 宁可低清可用。
/// ★ 已知限制：只解析第一个分P；番剧/课程（`bangumi/play`、`cheese/play`）不在识别范围内。
struct BilibiliParser: VideoParser {

    let platform: VideoPlatform = .bilibili

    private static let viewURL = "https://api.bilibili.com/x/web-interface/view"
    private static let playURL = "https://api.bilibili.com/x/player/playurl"
    private static let navURL = "https://api.bilibili.com/x/web-interface/nav"

    private var apiHeaders: [String: String] {
        ["User-Agent": HTTPClient.uaDesktop, "Referer": "https://www.bilibili.com/"]
    }

    /// 下载直链的请求头：**必须带 Referer**，B 站 CDN（upos-*.bilivideo.com）会校验来源，缺了直接 403
    private func mediaHeaders(cookie: String) -> [String: String] {
        var headers: [String: String] = [
            "User-Agent": HTTPClient.uaDesktop,
            "Referer": "https://www.bilibili.com/"
        ]
        if !cookie.isEmpty { headers["Cookie"] = cookie }
        return headers
    }

    private func headers(cookie: String) -> [String: String] {
        var headers = apiHeaders
        if !cookie.isEmpty { headers["Cookie"] = cookie }
        return headers
    }

    // MARK: 登录态

    /// `nav` 接口顺带返回用户名，可以直接当昵称存下来。
    /// ★ `isLogin` 是 JSON 布尔值，必须用布尔读法；按数字读会恒得 0。
    func validateCookie(_ cookie: String) async -> String? {
        let trimmed = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            let json = try await HTTPClient.desktop.getJSON(
                Self.navURL,
                headers: headers(cookie: trimmed),
                referer: "https://www.bilibili.com/"
            )
            let data = JSONSearch.dictionary(in: json, path: ["data"])
            guard JSONSearch.bool(data, "isLogin") else { return nil }
            let name = JSONSearch.str(data, "uname")
            return name
        } catch {
            return nil
        }
    }

    // MARK: 解析

    func parse(link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        do {
            let viewURL: String
            if link.id.uppercased().hasPrefix("BV") {
                viewURL = "\(Self.viewURL)?bvid=\(link.id)"
            } else {
                let aid = link.id.hasPrefix("av") ? String(link.id.dropFirst(2)) : link.id
                viewURL = "\(Self.viewURL)?aid=\(aid)"
            }

            let view = try await HTTPClient.desktop.getJSON(
                viewURL,
                headers: headers(cookie: cookie),
                referer: "https://www.bilibili.com/"
            )
            let code = JSONSearch.int(in: view, keys: ["code"]) ?? -1
            guard code == 0 else {
                let message = JSONSearch.string(in: view, keys: ["message"]) ?? ""
                throw VideoParseError(.notFound, "B站视频信息接口返回 code=\(code) \(message)")
            }
            let data = JSONSearch.dictionary(in: view, path: ["data"])
            let bvid = JSONSearch.str(data, "bvid")
            let pages = JSONSearch.array(in: data, path: ["pages"])
            var cid = JSONSearch.num(data, "cid")
            if let first = pages.first as? [String: Any], JSONSearch.num(first, "cid") > 0 {
                cid = JSONSearch.num(first, "cid")
            }
            guard !bvid.isEmpty, cid > 0 else {
                throw VideoParseError(.unknown, "B站视频信息缺少 bvid/cid")
            }

            let title = JSONSearch.str(data, "title")
            let fileBase = TextUtil.fileName(title, fallback: "bilibili_\(bvid)", ext: "")

            // ① 已登录才试 DASH 高清（音视频分离，下载时合轨）
            if !cookie.isEmpty, let dash = await dashStream(bvid: bvid, cid: cid, cookie: cookie) {
                let media = VideoMedia(
                    url: dash.videoURL,
                    kind: .video,
                    fileName: "\(fileBase).mp4",
                    headers: mediaHeaders(cookie: cookie),
                    quality: "\(qualityLabel(dash.quality))（分轨，下载后合轨）",
                    audioUrl: dash.audioURL,
                    audioHeaders: mediaHeaders(cookie: cookie)
                )
                return buildResult(data: data, bvid: bvid, media: media)
            }

            // ② 退回单文件 durl
            let playURL = "\(Self.playURL)?bvid=\(bvid)&cid=\(cid)&qn=80&fnval=1&fnver=0&fourk=1&platform=html5&high_quality=1"
            let play = try await HTTPClient.desktop.getJSON(
                playURL,
                headers: headers(cookie: cookie),
                referer: "https://www.bilibili.com/"
            )
            let playData = JSONSearch.dictionary(in: play, path: ["data"])
            let durl = JSONSearch.array(in: playData, path: ["durl"])
            guard let first = durl.first as? [String: Any] else {
                let code = JSONSearch.int(in: play, keys: ["code"]) ?? -1
                let message = JSONSearch.string(in: play, keys: ["message"]) ?? ""
                throw VideoParseError(
                    .unsupported,
                    "B站既未返回单文件直链、也未返回可合轨的分轨流（code=\(code) \(message)）：该视频可能是番剧/付费内容"
                )
            }
            let rawURL = JSONSearch.str(first, "url")
            guard !rawURL.isEmpty else {
                throw VideoParseError(.blocked, "B站直链为空（可能需要登录或已被风控）")
            }
            let size = JSONSearch.num(first, "size")
            let quality = JSONSearch.int(in: playData, keys: ["quality"]) ?? 0
            let media = VideoMedia(
                url: TextUtil.httpsURL(rawURL),
                kind: .video,
                fileName: "\(fileBase).mp4",
                size: size,
                headers: mediaHeaders(cookie: cookie),
                quality: qualityLabel(quality)
            )
            return buildResult(data: data, bvid: bvid, media: media)
        } catch {
            throw ParserSupport.translate(error)
        }
    }

    private func buildResult(data: [String: Any], bvid: String, media: VideoMedia) -> VideoParseResult {
        let owner = JSONSearch.dictionary(in: data, path: ["owner"])
        return VideoParseResult(
            platform: platform,
            title: JSONSearch.str(data, "title"),
            author: JSONSearch.str(owner, "name"),
            avatar: TextUtil.httpsURL(JSONSearch.str(owner, "face")),
            cover: TextUtil.httpsURL(JSONSearch.str(data, "pic")),
            text: JSONSearch.str(data, "desc"),
            timestampSeconds: JSONSearch.num(data, "pubdate"),
            url: "https://www.bilibili.com/video/\(bvid)",
            medias: [media]
        )
    }

    // MARK: DASH

    private struct DashStream {
        let videoURL: String
        let audioURL: String
        let quality: Int
    }

    /// `fnval=4048` = DASH + HDR + 4K + 杜比；`qn=120` = 能给多高给多高。
    /// 任何一步不对都返回 nil，由调用方退回单文件 —— 宁可低清可用，也不在这里抛错。
    private func dashStream(bvid: String, cid: Int64, cookie: String) async -> DashStream? {
        let url = "\(Self.playURL)?bvid=\(bvid)&cid=\(cid)&qn=120&fnval=4048&fnver=0&fourk=1"
        guard let json = try? await HTTPClient.desktop.getJSON(
            url,
            headers: headers(cookie: cookie),
            referer: "https://www.bilibili.com/"
        ) else { return nil }
        let dash = JSONSearch.dictionary(in: json, path: ["data", "dash"])
        let videos = JSONSearch.array(in: dash, path: ["video"])
        let audios = JSONSearch.array(in: dash, path: ["audio"])
        guard !videos.isEmpty, !audios.isEmpty else { return nil }

        let bestVideo = videos.compactMap { $0 as? [String: Any] }.max { left, right in
            JSONSearch.num(left, "id") < JSONSearch.num(right, "id")
        }
        let bestAudio = audios.compactMap { $0 as? [String: Any] }.max { left, right in
            JSONSearch.num(left, "id") < JSONSearch.num(right, "id")
        }
        guard let bestVideo = bestVideo, let bestAudio = bestAudio else { return nil }
        guard let videoURL = dashURL(bestVideo), let audioURL = dashURL(bestAudio) else { return nil }
        return DashStream(videoURL: videoURL, audioURL: audioURL, quality: Int(JSONSearch.num(bestVideo, "id")))
    }

    /// 直链字段名有两种（`baseUrl` / `base_url`），还可能被下发成字符串 "null"
    private func dashURL(_ dict: [String: Any]) -> String? {
        var raw = JSONSearch.str(dict, "baseUrl")
        if raw.isEmpty { raw = JSONSearch.str(dict, "base_url") }
        guard !raw.isEmpty, raw != "null" else { return nil }
        return TextUtil.httpsURL(raw)
    }

    /// B站清晰度编号 → 展示文案
    private func qualityLabel(_ qn: Int) -> String {
        switch qn {
        case 6, 7: return "240P"
        case 16: return "360P"
        case 32: return "480P"
        case 64: return "720P"
        case 74: return "720P60"
        case 80: return "1080P"
        case 112: return "1080P+"
        case 116: return "1080P60"
        case 120: return "4K"
        default: return qn > 0 ? "画质 \(qn)" : ""
        }
    }
}
