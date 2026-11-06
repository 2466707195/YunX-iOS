import Foundation

// MARK: - 视频链接识别

/// 从用户粘贴的任意文本里识别视频平台链接。
///
/// 与 `ShareLinkParser` 同构（先抓 URL 再按平台规则顺序匹配），但两套识别是**分开**的：
/// 解析页先试 GitHub → 视频 → 网盘，任何一个命中就分流到对应结果页。
///
/// 规则顺序即优先级：**短链优先于长链**（短链命中后不会被长链规则抢走）。
/// 两条比上游更严的收紧：
/// 1. 不识别裸数字 ID（否则会把网盘提取码、迅雷口令里的数字吃进来）；
/// 2. 短链只认固定域名前缀，不做泛化。
enum VideoLinkParser {

    private struct Rule {
        let platform: VideoPlatform
        let kind: String
        let pattern: String
    }

    private static let rules: [Rule] = [
        // ---------- 抖音 ----------
        Rule(platform: .douyin, kind: "short", pattern: "v\\.douyin\\.com/[A-Za-z0-9_\\-]+"),
        Rule(platform: .douyin, kind: "short", pattern: "jx\\.douyin\\.com/[A-Za-z0-9_\\-]+"),
        Rule(platform: .douyin, kind: "video", pattern: "(?:www\\.)?douyin\\.com/(video|note)/(\\d{10,})"),
        // 从「用户页弹层」打开作品时，分享出来的链接是 /user/self?...&modal_id=<id>
        Rule(platform: .douyin, kind: "video", pattern: "douyin\\.com/[^\\s]*[?&]modal_id=(\\d{10,})"),
        Rule(platform: .douyin, kind: "video", pattern: "iesdouyin\\.com/share/(?:slides|video|note)/(\\d{10,})"),
        Rule(platform: .douyin, kind: "video", pattern: "m\\.douyin\\.com/share/(?:slides|video|note)/(\\d{10,})"),
        Rule(platform: .douyin, kind: "video", pattern: "jingxuan\\.douyin\\.com/m/(?:slides|video|note)/(\\d{10,})"),

        // ---------- 小红书 ----------
        Rule(platform: .xhs, kind: "short", pattern: "xhslink\\.(?:com|cn)/[A-Za-z0-9._?%&+=/#@\\-]+"),
        Rule(platform: .xhs, kind: "note", pattern: "xiaohongshu\\.com/(?:explore|discovery/item|discovery)/([0-9a-zA-Z]{10,})"),

        // ---------- 快手 ----------
        Rule(platform: .kuaishou, kind: "short", pattern: "v\\.kuaishou\\.com/[A-Za-z\\d._?%&+\\-=/#]+"),
        Rule(platform: .kuaishou, kind: "photo", pattern: "(?:www\\.)?kuaishou\\.com/(?:short-video|fw/photo|fw/long-video)/([A-Za-z\\d]+)"),
        Rule(platform: .kuaishou, kind: "photo", pattern: "(?:www\\.)?kuaishou\\.com/f/([A-Za-z\\d]+)"),
        Rule(platform: .kuaishou, kind: "photo", pattern: "(?:v\\.m\\.)?chenzhongtech\\.com/fw/(?:photo|long-video)/([A-Za-z\\d]+)"),

        // ---------- 微博 ----------
        Rule(platform: .weibo, kind: "tv", pattern: "weibo\\.com/tv/show/\\d{4}:\\d+\\?mid=(\\d+)"),
        Rule(platform: .weibo, kind: "fid", pattern: "video\\.weibo\\.com/show\\?fid=(\\d+:\\d+)"),
        Rule(platform: .weibo, kind: "status", pattern: "weibo\\.cn/(?:status|statuses|detail)/([0-9a-zA-Z]+)"),
        Rule(platform: .weibo, kind: "status", pattern: "weibo\\.com/\\d+/([0-9a-zA-Z]{6,})"),

        // ---------- AcFun ----------
        Rule(platform: .acfun, kind: "ac", pattern: "acfun\\.cn/.*(?:ac=|/ac)(\\d+)"),

        // ---------- 哔哩哔哩 ----------
        Rule(platform: .bilibili, kind: "short", pattern: "b23\\.tv/[A-Za-z\\d]+"),
        Rule(platform: .bilibili, kind: "short", pattern: "bili2233\\.cn/[A-Za-z\\d]+"),
        Rule(platform: .bilibili, kind: "video", pattern: "bilibili\\.com/video/(BV[0-9a-zA-Z]{10}|av\\d+)"),

        // ---------- Pixiv ----------
        Rule(platform: .pixiv, kind: "artwork", pattern: "pixiv\\.net/(?:[a-z]{2}/)?artworks/(\\d+)"),
        Rule(platform: .pixiv, kind: "artwork", pattern: "pixiv\\.net/member_illust\\.php\\?[^\\s]*illust_id=(\\d+)")
    ]

    /// 识别文本里的视频链接；识别不到返回 nil。
    ///
    /// ★ 只在**链接**上做匹配（不看链接外的文案）：抖音/快手的分享文案里常带一堆数字，
    ///   拿整段文本匹配必然误判。
    static func parse(_ text: String) -> DetectedVideoLink? {
        guard let url = TextUtil.firstURL(in: text) else { return nil }
        for rule in rules {
            guard let groups = RegexUtil.match(rule.pattern, in: url) else { continue }
            let captures = groups.dropFirst().filter { !$0.isEmpty }
            let id = captures.last ?? ""
            let isShort = rule.kind == "short"
            return DetectedVideoLink(
                platform: rule.platform,
                kind: isShort ? "short" : rule.kind,
                id: isShort ? "" : id,
                url: url.hasPrefix("http") ? url : "https://" + url,
                isShortLink: isShort
            )
        }
        return nil
    }

    static func looksLikeVideoLink(_ text: String) -> Bool {
        parse(text) != nil
    }

    /// 短链展开后重新识别 —— 展开后可能落到完全不同的平台规则上
    /// （例如 `b23.tv` 展开成 `www.bilibili.com/video/BV1xx`）
    static func reparse(expandedURL: String, fallback: DetectedVideoLink) -> DetectedVideoLink {
        if let detected = parse(expandedURL), !detected.isShortLink {
            return detected
        }
        var merged = fallback
        merged.url = expandedURL
        merged.isShortLink = false
        // 长链里没认出平台：保留原平台，用路径末段当 id 兜底
        if merged.id.isEmpty {
            let last = expandedURL.split(separator: "/").last.map(String.init) ?? ""
            merged.id = last.split(separator: "?").first.map(String.init) ?? last
        }
        return merged
    }
}
