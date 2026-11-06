import Foundation
import SwiftUI

// MARK: - 账号

enum AccountScope: String, Codable {
    case pan
    case video
}

/// 登录方式，只用于展示（决定账号行下方的说明文字）。
enum AccountMethod: String, Codable {

    case webLogin = "网页登录"
    case manualCookie = "手动 Cookie"
    case password = "账号密码"
    case qrScan = "扫码登录"
}

/// 一条账号记录。
///
/// 网盘和视频平台共用同一张表：`scope` 区分，`key` 存平台枚举的 rawValue。
/// `credential` 永远是**密文**（由 `CredentialVault` 加解密），落盘时不出现明文。
struct Account: Identifiable, Codable, Equatable {

    var id = UUID()
    var scope: AccountScope
    var key: String
    var nickname: String = ""
    var credential: String = ""
    var method: AccountMethod = .webLogin
    var createdAt = Date()
    var updatedAt = Date()

    var panPlatform: SharePlatform? {
        scope == .pan ? SharePlatform(rawValue: key) : nil
    }

    var videoPlatform: VideoPlatform? {
        scope == .video ? VideoPlatform(rawValue: key) : nil
    }

    var displayTitle: String {
        panPlatform?.displayName ?? videoPlatform?.displayName ?? key
    }

    var tint: Color {
        panPlatform?.tint ?? videoPlatform?.tint ?? Aurora.brand
    }

    var systemIcon: String {
        panPlatform?.systemIcon ?? videoPlatform?.systemIcon ?? "person.crop.circle"
    }

    /// 账号行下方的说明：登录方式 + 昵称
    var subtitle: String {
        var parts: [String] = [method.rawValue]
        if !nickname.isEmpty { parts.append(nickname) }
        parts.append("更新于 " + updatedAt.formatted("MM-dd HH:mm"))
        return parts.joined(separator: " · ")
    }

    /// Cookie 太长的账号（如从浏览器整段复制）用长度做个体检提示
    var credentialLooksShort: Bool {
        credential.count < 8
    }
}

// MARK: - 收藏 / 快捷方式

/// 收藏的分享链接：解析页「快捷方式」区与账号页的收藏列表都用它。
struct Bookmark: Identifiable, Codable, Equatable {

    var id = UUID()
    var title: String
    var link: String
    var platform: String = ""
    var createdAt = Date()

    var tint: Color {
        SharePlatform(rawValue: platform)?.tint ?? Aurora.brand
    }
}

// MARK: - 解析历史

/// 解析成功过的链接（只存元信息，不存直链 —— 直链有有效期）。
struct ResolveHistory: Identifiable, Codable, Equatable {

    var id = UUID()
    var title: String
    var link: String
    var platform: String
    var kind: String
    var createdAt = Date()
}
