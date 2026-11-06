import Foundation

// MARK: - 我的网盘

/// 已登录网盘里的一个条目。
///
/// 和 `ShareEntry` 的区别：分享条目带 `share_fid_token`（换取直链必须回传），
/// 而自己网盘里的文件只需要 `fid`。两者刻意分开，避免把「分享会话」的字段
/// 混进「我的文件」里，导致取链时多传了服务端不认识的东西。
struct DriveFile: Identifiable, Hashable {

    /// 平台侧的文件 id（夸克/UC 是 `fid`）
    let id: String
    var name: String
    var isFolder: Bool
    /// 文件夹记为 0
    var size: Int64 = 0
    /// 形如 `2026-11-01 12:30`；平台没给就为空
    var updatedText: String = ""
    /// 所属目录 fid
    var parentId: String = "0"

    var sizeText: String {
        isFolder ? "文件夹" : ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

/// 目录栈的一层（面包屑用）。
struct DrivePathItem: Identifiable, Hashable {

    /// 目录 fid，根目录是 "0"
    let id: String
    var name: String

    static let root = DrivePathItem(id: "0", name: "全部文件")
}
