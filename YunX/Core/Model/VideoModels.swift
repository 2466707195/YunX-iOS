import Foundation
import SwiftUI

// MARK: - 视频平台

/// 视频解析支持的平台（对应 Android 版 `VideoPlatform`）。
///
/// 与网盘的区别：视频平台**只要一个 Cookie**，不需要分享链接 + 目录树那一整套。
/// `loginUrl` 为空表示匿名可解析；非空表示能力依赖网页登录态。
/// `manualCookieOnly` 表示该平台不提供内置网页登录（只接受手动粘贴 Cookie）。
enum VideoPlatform: String, CaseIterable, Codable, Identifiable {

    case douyin
    case xhs
    case kuaishou
    case weibo
    case acfun
    case bilibili
    case pixiv

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .douyin: return "抖音"
        case .xhs: return "小红书"
        case .kuaishou: return "快手"
        case .weibo: return "微博"
        case .acfun: return "AcFun"
        case .bilibili: return "哔哩哔哩"
        case .pixiv: return "Pixiv"
        }
    }

    var tint: Color {
        switch self {
        case .douyin: return Color(hex: 0x161823)
        case .xhs: return Color(hex: 0xFF2442)
        case .kuaishou: return Color(hex: 0xFF5000)
        case .weibo: return Color(hex: 0xE6162D)
        case .acfun: return Color(hex: 0xFD4C5C)
        case .bilibili: return Color(hex: 0xFB7299)
        case .pixiv: return Color(hex: 0x0096FA)
        }
    }

    var systemIcon: String {
        switch self {
        case .pixiv: return "photo.on.rectangle.angled"
        case .bilibili: return "play.rectangle"
        default: return "play.circle"
        }
    }

    /// 登录页地址；空 = 无需登录
    var loginUrl: String {
        switch self {
        case .bilibili: return "https://passport.bilibili.com/login"
        case .xhs: return "https://www.xiaohongshu.com/login"
        default: return ""
        }
    }

    /// 读取 WebView 登录态用的 Cookie 域
    var cookieDomain: String {
        switch self {
        case .xhs: return "xiaohongshu.com"
        case .bilibili: return "bilibili.com"
        case .pixiv: return "pixiv.net"
        default: return ""
        }
    }

    /// 账号页展示的「登录后能得到什么」
    var loginBenefit: String {
        switch self {
        case .xhs: return "小红书网页端要求登录后才能查看笔记，未登录解析会失败"
        case .bilibili: return "登录后可解析更高清晰度；未登录只能拿到低清单文件"
        case .pixiv: return "未登录只能拿到一部分公开作品；粘贴浏览器 Cookie 后可解析全部作品"
        default: return "该平台匿名即可解析，无需登录"
        }
    }

    /// 只需要账号、但没有内置网页登录页（Pixiv 的 reCAPTCHA 风控在 App 内置 WebView 里走不完）
    var manualCookieOnly: Bool {
        self == .pixiv
    }

    /// 登录页依赖桌面版布局（小红书移动端根本没有登录入口）
    var loginViewportWidth: Int? {
        self == .xhs ? 1280 : nil
    }

    var needsLogin: Bool {
        !loginUrl.isEmpty || manualCookieOnly
    }

    /// 未登录是否也能解析（决定解析前是否拦一道）
    var requiresCookieForParse: Bool {
        self == .xhs
    }

    static func fromName(_ name: String) -> VideoPlatform? {
        VideoPlatform(rawValue: name)
    }
}

// MARK: - 媒体

/// 媒体类型：视频（mp4/flv/m3u8）、图片（图集/九宫格）、音频
enum VideoMediaKind: String, Codable {
    case video
    case image
    case audio
}

/// 一条可下载的媒体。
///
/// 每条媒体**自带请求头**：各平台直链往往要求特定 Referer/UA/Cookie 才不返回 403，
/// 而这个头是解析那一刻才知道的（例如抖音要拿分享页当 Referer），所以跟着媒体一起往上传。
struct VideoMedia: Identifiable, Equatable {

    let id = UUID()
    var url: String
    var kind: VideoMediaKind
    var fileName: String = ""
    var size: Int64 = -1
    /// m3u8 流：交给 HLS 下载路径
    var isHls: Bool = false
    var headers: [String: String] = [:]
    /// 清晰度/规格标签，仅用于界面展示（`720P`、`原图`）
    var quality: String = ""
    /// 需要合轨的音轨地址（B 站 DASH：高清是音视频分离的两路流）。
    /// 非空 = 下载器会先下两路再合成一个 mp4。
    var audioUrl: String = ""
    var audioHeaders: [String: String] = [:]
    /// 动图（Live Photo）的动图资源直链；非空表示这张「照片」其实是会动的
    var motionUrl: String = ""

    var isSplitTrack: Bool { !audioUrl.isEmpty }

    var sizeText: String {
        guard size > 0 else { return "未知大小" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

/// 一次解析的结果：**一个作品**（视频 / 图文 / 图集）。
struct VideoParseResult: Equatable {

    var platform: VideoPlatform
    var title: String
    var author: String = ""
    var avatar: String = ""
    var cover: String = ""
    /// 正文/文案：分享文案、笔记正文、微博正文、B站简介都落在这里
    var text: String = ""
    /// 发布时间戳（秒），0 = 未知
    var timestampSeconds: Int64 = 0
    /// 作品原始网页地址
    var url: String = ""
    var medias: [VideoMedia] = []
    /// 非致命提示：解析成功但部分内容降级了
    var notice: String = ""

    var videoCount: Int { medias.filter { $0.kind == .video }.count }
    var imageCount: Int { medias.filter { $0.kind == .image }.count }

    var timeText: String {
        guard timestampSeconds > 0 else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(timestampSeconds))
        return date.formatted("yyyy-MM-dd HH:mm")
    }
}

// MARK: - 识别结果

/// 一条链接属于哪个平台、是哪种资源。
///
/// `kind` 用平台自己的词（video / note / photo / status / ac / artwork / short），
/// 解析器按它决定走哪条路径。`isShortLink == true` 时 `id` 为空 —— 短链要先跟随重定向。
struct DetectedVideoLink: Equatable {

    var platform: VideoPlatform
    var kind: String
    var id: String
    var url: String
    var isShortLink: Bool = false
}

// MARK: - 错误

enum VideoParseErrorKind {

    /// 被平台风控拦截（403/418/验证码页）
    case blocked
    /// 内容不存在/已删除/私密
    case notFound
    /// 网络请求失败
    case network
    /// 链接形态不支持，或该平台必须登录但当前没有登录态
    case unsupported
    /// 其它（响应格式变了、平台改版）
    case unknown

    var userMessage: String {
        switch self {
        case .blocked: return "平台风控拦截了本次请求，请稍后重试"
        case .notFound: return "内容不存在、已删除或不可见"
        case .network: return "网络请求失败，请检查网络后重试"
        case .unsupported: return "暂不支持该链接"
        case .unknown: return "解析失败，请稍后重试"
        }
    }
}

/// 视频解析异常。各解析器**必须**用它抛失败，不要抛裸 Error：
/// 上层要靠 `kind` 决定提示文案（风控要提示稍后重试，而不是静默失败）。
struct VideoParseError: LocalizedError {

    var kind: VideoParseErrorKind
    var detail: String

    init(_ kind: VideoParseErrorKind, _ detail: String = "") {
        self.kind = kind
        self.detail = detail
    }

    var errorDescription: String? {
        // unsupported/unknown 的 detail 通常已经是可直接给用户看的一句话
        if kind == .unsupported || kind == .unknown {
            return detail.isEmpty ? kind.userMessage : detail
        }
        return kind.userMessage
    }
}
