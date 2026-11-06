import Foundation

// MARK: - 视频解析服务

/// 视频解析的统一入口：识别 → 展开短链 → 分发到平台解析器。
enum VideoResolveService {

    static func parser(for platform: VideoPlatform) -> VideoParser {
        switch platform {
        case .douyin: return DouyinParser()
        case .xhs: return XhsParser()
        case .kuaishou: return KuaishouParser()
        case .weibo: return WeiboParser()
        case .acfun: return AcFunParser()
        case .bilibili: return BilibiliParser()
        case .pixiv: return PixivParser()
        }
    }

    /// - Parameter cookieProvider: 取该平台登录态（未登录返回空串）
    static func parse(text: String, cookieProvider: (VideoPlatform) -> String) async throws -> VideoParseResult {
        guard var link = VideoLinkParser.parse(text) else {
            throw VideoParseError(.unsupported, "没有识别到视频链接，请检查是否粘贴完整")
        }

        // 短链要先跟随重定向拿到最终地址，再重新识别一次
        if link.isShortLink {
            do {
                let expanded = try await HTTPClient.shared.expandShortLink(link.url)
                link = VideoLinkParser.reparse(expandedURL: expanded, fallback: link)
            } catch let error as HTTPError {
                throw VideoParseError(.network, "短链展开失败：\(error.localizedDescription)")
            }
        }

        let cookie = cookieProvider(link.platform)
        try ParserSupport.requireCookie(link.platform, cookie: cookie)
        return try await parser(for: link.platform).parse(link: link, cookie: cookie)
    }

    /// 保存账号前的登录态校验：返回昵称（可能为空串），无效返回 nil
    static func validateCookie(_ cookie: String, for platform: VideoPlatform) async -> String? {
        await parser(for: platform).validateCookie(cookie)
    }

    /// 账号页展示用：这件事为什么需要登录
    static func loginHint(for platform: VideoPlatform) -> String {
        platform.loginBenefit
    }
}
