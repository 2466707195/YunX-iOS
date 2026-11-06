import Foundation
import SwiftUI

// MARK: - 网盘平台

/// 网盘平台（对应 Android 版 `SharePlatform`）。
///
/// `displayName` 是给界面用的人类可读名：解析页的识别提示、账号页、关于页的平台列表
/// 全部读它，**不要在 UI 层各写一份 switch**，否则两边会漂移。
enum SharePlatform: String, CaseIterable, Codable, Identifiable {

    case quark
    case uc
    case xunlei
    case baidu
    case c139
    case pan123
    case pan115
    case guangya
    case ilanzou
    case lanzou
    case github

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .quark: return "夸克网盘"
        case .uc: return "UC 网盘"
        case .xunlei: return "迅雷网盘"
        case .baidu: return "百度网盘"
        case .c139: return "139 网盘"
        case .pan123: return "123 云盘"
        case .pan115: return "115 网盘"
        case .guangya: return "光鸭云盘"
        case .ilanzou: return "蓝奏云优享版"
        case .lanzou: return "蓝奏云"
        case .github: return "GitHub"
        }
    }

    /// 列表里的短名（卡片标题空间有限）
    var shortName: String {
        switch self {
        case .quark: return "夸克"
        case .uc: return "UC"
        case .xunlei: return "迅雷"
        case .baidu: return "百度"
        case .c139: return "139"
        case .pan123: return "123"
        case .pan115: return "115"
        case .guangya: return "光鸭"
        case .ilanzou: return "蓝奏优享"
        case .lanzou: return "蓝奏云"
        case .github: return "GitHub"
        }
    }

    /// 平台主色。只用于图标底和胶囊文字，**不要拿它铺大面积底色**。
    var tint: Color {
        switch self {
        case .quark: return Color(hex: 0x3B6CFF)
        case .uc: return Color(hex: 0xFF7A1A)
        case .xunlei: return Color(hex: 0x2F7BFF)
        case .baidu: return Color(hex: 0x2A6FF0)
        case .c139: return Color(hex: 0x1F8F6F)
        case .pan123: return Color(hex: 0x2D6BFF)
        case .pan115: return Color(hex: 0x19A05B)
        case .guangya: return Color(hex: 0x6E5BE8)
        case .ilanzou: return Color(hex: 0x7A5AF8)
        case .lanzou: return Color(hex: 0x4C6EF5)
        case .github: return Aurora.ink
        }
    }

    var systemIcon: String {
        switch self {
        case .github: return "chevron.left.forwardslash.chevron.right"
        case .lanzou, .ilanzou: return "shippingbox"
        default: return "cloud"
        }
    }

    /// 落库到下载任务时用的平台标识（与 `DownloadPlatform` 常量一致）。
    var downloadPlatform: String {
        switch self {
        case .github: return "github"
        default: return rawValue
        }
    }

    /// 是否已经接入了解析实现。未接入的平台在解析入口会给出**明确**提示，
    /// 而不是转圈到超时 —— 这比假装支持更诚实。
    var isImplemented: Bool {
        switch self {
        case .quark, .uc: return true
        default: return false
        }
    }

    /// 需要账号的平台（cookie / JWT 类）
    var needsAccount: Bool {
        switch self {
        case .lanzou, .ilanzou, .quark, .uc, .baidu, .c139, .pan123, .pan115, .xunlei, .guangya:
            return true
        case .github:
            return false
        }
    }
}

// MARK: - 解析结果

/// 网盘分享链接的识别结果：share_id + 提取码 + 平台。
struct ParsedShare: Equatable {

    let shareId: String
    var pwd: String?
    let platform: SharePlatform

    /// 提取码是否已带上（决定要不要在详情页弹输入框）
    var hasPasscode: Bool {
        guard let pwd else { return false }
        return !pwd.isEmpty
    }
}

/// 分享里的一个条目（文件或文件夹）。
///
/// 与 Android 版不同，这里**不把 share token 塞进每个条目**：token 属于「一次分享会话」，
/// 放在 `ShareSnapshot` 上更准确，条目只保留平台自己的 fid。
struct ShareEntry: Identifiable, Equatable {

    let id: String
    var name: String
    var isFolder: Bool
    var size: Int64
    /// 形如 `2026-11-01 12:30` 的展示时间；平台没给就为空
    var updatedText: String = ""
    /// 平台侧的文件类型提示（如 `application/zip`）；未知为空
    var mimeHint: String = ""
    /// 取直链要用的条目 token（夸克/UC 是 `share_fid_token`）
    var token: String = ""

    var isArchive: Bool {
        let lower = name.lowercased()
        return [".zip", ".rar", ".7z", ".tar", ".gz", ".iso"].contains { lower.hasSuffix($0) }
    }

    var isVideo: Bool {
        FileKind.videoExtensions.contains { name.lowercased().hasSuffix("." + $0) }
    }
}

/// 一次分享的快照（文件夹浏览时按目录重新拉取，快照只保存会话级信息）。
struct ShareSnapshot: Equatable {

    let platform: SharePlatform
    let shareId: String
    var title: String
    /// 平台返回的分享会话 token（夸克/UC 是 `stoken`），后续翻目录与取直链都要带
    var stoken: String
    /// 当前目录 id（根目录用平台自己的根值，夸克是 "0"）
    var dirId: String = "0"
    var entries: [ShareEntry] = []
    /// 是否需要提取码但还没提供
    var needsPasscode: Bool = false
}

/// 一条可下载的直链。
struct ShareDownloadLink: Equatable {

    let url: String
    var fileName: String
    var size: Int64 = -1
    /// 下载这条直链**必须**带上的请求头（Referer / UA / Cookie）；
    /// 各平台 CDN 都按这些头校验，缺了直接 403。
    var headers: [String: String] = [:]
    var platform: SharePlatform = .quark
    /// 下载完成后需要清理的云端临时目录（夸克转存类接口会用到），空 = 不需要
    var cleanupId: String = ""
}

// MARK: - 平台错误

/// 网盘解析/取链失败的原因分类 —— 决定给用户看什么话，而不是把 HTTP 状态码甩出去。
enum PanError: LocalizedError {

    /// 平台要求登录态，但当前账号里没有可用凭证
    case needLogin(SharePlatform)
    /// 分享需要提取码（还没提供）
    case needPasscode
    /// 提取码错误
    case wrongPasscode
    /// 该平台的解析实现还没接入
    case notImplemented(SharePlatform)
    /// 提取码错误 / 分享已失效
    case shareUnavailable(String)
    /// 平台风控（403/418/验证码）
    case blocked(String)
    /// 网络问题
    case network(String)
    /// 其它（接口改版、响应格式变化）
    case message(String)

    var errorDescription: String? {
        switch self {
        case .needLogin(let platform):
            return "需要先在「账号」页登录\(platform.displayName)"
        case .needPasscode:
            return "该分享需要提取码"
        case .wrongPasscode:
            return "提取码不正确"
        case .notImplemented(let platform):
            return "\(platform.displayName)的解析适配还没接入，可参考 QuarkAPI 补一个实现"
        case .shareUnavailable(let detail):
            return detail.isEmpty ? "分享不存在或已失效" : detail
        case .blocked(let detail):
            return detail.isEmpty ? "平台风控拦截了本次请求，请稍后重试" : detail
        case .network(let detail):
            return detail.isEmpty ? "网络请求失败，请检查网络后重试" : detail
        case .message(let detail):
            return detail.isEmpty ? "解析失败，请稍后重试" : detail
        }
    }
}

// MARK: - 下载来源平台标识

/// 下载来源平台（用于按平台独立设置分片并发数）。
enum DownloadPlatform {

    static let quark = "quark"
    static let uc = "uc"
    static let xunlei = "xunlei"
    static let baidu = "baidu"
    static let c139 = "c139"
    static let pan123 = "pan123"
    static let pan115 = "pan115"
    static let guangya = "guangya"
    static let ilanzou = "ilanzou"
    static let lanzou = "lanzou"
    static let github = "github"
    static let generic = "generic"
    /// 视频平台统一用通用线程设置，不做平台细分
    static let video = "video"

    static func displayName(_ key: String) -> String {
        switch key {
        case quark: return "夸克"
        case uc: return "UC"
        case xunlei: return "迅雷"
        case baidu: return "百度"
        case c139: return "139"
        case pan123: return "123"
        case pan115: return "115"
        case guangya: return "光鸭"
        case ilanzou: return "蓝奏优享"
        case lanzou: return "蓝奏"
        case github: return "GitHub"
        case video: return "视频平台"
        default: return "通用"
        }
    }
}
