import Foundation
import SwiftUI

// MARK: - 文件类型

/// 只按扩展名判类型，够用且不会误判（不读文件头）。
enum FileKind {

    static let videoExtensions = ["mp4", "mov", "m4v", "mkv", "flv", "ts", "webm", "avi", "m3u8"]
    static let imageExtensions = ["jpg", "jpeg", "png", "gif", "webp", "heic", "bmp", "avif"]
    static let audioExtensions = ["mp3", "m4a", "aac", "flac", "wav", "ogg", "opus"]
    static let textExtensions = ["txt", "md", "json", "log", "csv", "xml", "html", "srt", "ass"]

    enum Kind {
        case video, image, audio, text, archive, other

        var systemIcon: String {
            switch self {
            case .video: return "play.rectangle"
            case .image: return "photo"
            case .audio: return "waveform"
            case .text: return "doc.text"
            case .archive: return "shippingbox"
            case .other: return "doc"
            }
        }

        var tint: Color {
            switch self {
            case .video: return Aurora.brand
            case .image: return Aurora.teal
            case .audio: return Aurora.rose
            case .text: return Aurora.info
            case .archive: return Aurora.warning
            case .other: return Aurora.muted
            }
        }

        /// 能否在应用内预览
        var isPreviewable: Bool {
            switch self {
            case .video, .image, .audio, .text: return true
            case .archive, .other: return false
            }
        }
    }

    static func kind(for fileName: String) -> Kind {
        let ext = (fileName as NSString).pathExtension.lowercased()
        if videoExtensions.contains(ext) { return .video }
        if imageExtensions.contains(ext) { return .image }
        if audioExtensions.contains(ext) { return .audio }
        if textExtensions.contains(ext) { return .text }
        if ["zip", "rar", "7z", "tar", "gz", "iso", "apk", "ipa"].contains(ext) { return .archive }
        return .other
    }

    /// 文件名清洗：去掉会破坏路径的字符，保留中文与常见符号。
    static func sanitize(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        name = name.components(separatedBy: illegal).joined(separator: "_")
        // 隐藏文件前缀会让文件在「文件」App 里看不见
        while name.hasPrefix(".") { name.removeFirst() }
        if name.count > 120 {
            let ext = (name as NSString).pathExtension
            let base = (name as NSString).deletingPathExtension
            let kept = String(base.prefix(max(1, 110 - ext.count)))
            name = ext.isEmpty ? kept : "\(kept).\(ext)"
        }
        return name.isEmpty ? "未命名文件" : name
    }

    /// 同名文件去重：`a.mp4` → `a(1).mp4`
    static func uniqueName(_ name: String, existing: Set<String>) -> String {
        guard existing.contains(name) else { return name }
        let ns = name as NSString
        let ext = ns.pathExtension
        let base = ns.deletingPathExtension
        var index = 1
        while true {
            let candidate = ext.isEmpty ? "\(base)(\(index))" : "\(base)(\(index)).\(ext)"
            if !existing.contains(candidate) { return candidate }
            index += 1
        }
    }
}

// MARK: - 下载任务

enum DownloadStatus: String, Codable {

    case pending
    case running
    case paused
    case completed
    case failed

    var title: String {
        switch self {
        case .pending: return "等待中"
        case .running: return "下载中"
        case .paused: return "已暂停"
        case .completed: return "已完成"
        case .failed: return "失败"
        }
    }

    var isActive: Bool {
        self == .running || self == .pending
    }
}

/// 一条下载任务。
///
/// 断点续传依赖两样东西：磁盘上的 `.part` 文件 + `chunkPlan`（首次探测后**固定**的分片规划）。
/// 恢复时按 `completedChunks` 跳过已下完的分片，所以即使中途退出也不会从头再来。
struct DownloadTask: Identifiable, Codable, Equatable {

    var id = UUID()
    var url: String
    var fileName: String
    var totalSize: Int64 = 0
    var downloadedSize: Int64 = 0
    var status: DownloadStatus = .pending
    var errorMessage: String = ""
    /// 恢复任务所需的请求头（Cookie / Referer / UA）
    var headers: [String: String] = [:]
    /// 首次探测大小后固定的分片数，恢复时不随设置变化
    var chunkCount: Int = 0
    /// 与 chunkCount 对应的服务器总大小
    var plannedTotalSize: Int64 = 0
    /// 已完成的分片下标（断点续传的进度账本）
    var completedChunks: [Int] = []
    /// 下载来源平台标识（按平台应用线程设置）
    var platform: String = DownloadPlatform.generic
    /// 分组 id（整个文件夹或一次批量下载归为一组）
    var groupId: UUID?
    /// 需要合轨的音轨直链（B 站 DASH）
    var audioUrl: String = ""
    var audioHeaders: [String: String] = [:]
    /// m3u8 流
    var isHls: Bool = false
    /// 下载完成时的平均速度（B/s）
    var avgSpeed: Int64 = 0
    var createdAt = Date()
    var finishedAt: Date?

    /// 实时速度（B/s），只在内存里，不落库
    var liveSpeed: Int64 = 0
    /// 是否正在「准备中」（探测大小、建分片）
    var isPreparing: Bool = false

    var progress: Double {
        guard totalSize > 0 else { return 0 }
        return min(1, max(0, Double(downloadedSize) / Double(totalSize)))
    }

    var progressText: String {
        guard totalSize > 0 else { return "--" }
        return "\(Int(progress * 100))%"
    }

    var sizeText: String {
        let done = ByteCountFormatter.string(fromByteCount: downloadedSize, countStyle: .file)
        guard totalSize > 0 else { return done }
        let total = ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
        return "\(done) / \(total)"
    }

    var speedText: String {
        guard liveSpeed > 0 else { return "" }
        return ByteCountFormatter.string(fromByteCount: liveSpeed, countStyle: .file) + "/s"
    }

    /// 剩余时间（秒），未知返回 nil
    var remainingSeconds: Int64? {
        guard liveSpeed > 0, totalSize > downloadedSize else { return nil }
        return max(0, (totalSize - downloadedSize) / liveSpeed)
    }

    var remainingText: String {
        guard let seconds = remainingSeconds else { return "" }
        if seconds >= 3600 {
            return "剩余 \(seconds / 3600) 小时 \(seconds % 3600 / 60) 分"
        }
        if seconds >= 60 {
            return "剩余 \(seconds / 60) 分 \(seconds % 60) 秒"
        }
        return "剩余 \(seconds) 秒"
    }

    var kind: FileKind.Kind { FileKind.kind(for: fileName) }

    /// 磁盘上的最终文件（未完成时不存在）
    var destinationURL: URL { DownloadStore.shared.fileURL(for: fileName) }
    /// 下载中的临时文件
    var partURL: URL { DownloadStore.shared.partURL(for: id) }
}

// MARK: - 下载分组

/// 一次批量下载 / 整个文件夹收纳成一组，下载页可折叠。
struct DownloadGroup: Identifiable, Codable, Equatable {

    var id = UUID()
    var title: String
    var platformName: String = ""
    var createdAt = Date()
}
