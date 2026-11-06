import Foundation
import SwiftUI
import UIKit

// MARK: - 应用设置

/// 设置项统一落 `UserDefaults`（都是标量，没有必要建库）。
///
/// 按平台分线程数是这个应用最关键的性能开关：每个平台的风控策略不同，
/// 夸克给 32 并发通常没问题，百度给多了会被限速甚至风控，所以要能分开调。
@MainActor
final class AppSettings: ObservableObject {

    // MARK: 下载

    /// 每个平台的分片并发数（键是 `DownloadPlatform` 常量），默认 32，最高 512
    @Published private(set) var threads: [String: Int] = [:]

    /// 同时下载的任务数，超出排队
    @Published var maxConcurrentTasks: Int = 3 {
        didSet { defaults.set(maxConcurrentTasks, forKey: "yunx.maxConcurrentTasks") }
    }

    /// 单个分片不小于这么多 MB（服务器不支持 Range 时整文件单线程）
    @Published var minChunkMB: Int = 4 {
        didSet { defaults.set(minChunkMB, forKey: "yunx.minChunkMB") }
    }

    /// 仅 Wi-Fi 下载（蜂窝网络下暂停排队）
    @Published var wifiOnly: Bool = false {
        didSet { defaults.set(wifiOnly, forKey: "yunx.wifiOnly") }
    }

    /// 失败自动重试次数
    @Published var autoRetryCount: Int = 2 {
        didSet { defaults.set(autoRetryCount, forKey: "yunx.autoRetryCount") }
    }

    /// 下载完自动存入相册（仅图片/视频）
    @Published var autoSaveToPhotos: Bool = false {
        didSet { defaults.set(autoSaveToPhotos, forKey: "yunx.autoSaveToPhotos") }
    }

    /// 下载中保持屏幕常亮
    @Published var keepScreenAwake: Bool = false {
        didSet {
            defaults.set(keepScreenAwake, forKey: "yunx.keepScreenAwake")
            UIApplication.shared.isIdleTimerDisabled = keepScreenAwake
        }
    }

    // MARK: 解析

    /// 回到前台时读剪贴板，发现分享链接就提示一键解析
    @Published var clipboardWatch: Bool = true {
        didSet { defaults.set(clipboardWatch, forKey: "yunx.clipboardWatch") }
    }

    /// 解析成功后自动把直链复制到剪贴板（默认关，避免覆盖用户剪贴板）
    @Published var copyLinkAfterResolve: Bool = false {
        didSet { defaults.set(copyLinkAfterResolve, forKey: "yunx.copyLinkAfterResolve") }
    }

    /// 网盘解析失败时，用内置浏览器打开分享页兜底
    @Published var openInBrowserOnFailure: Bool = false {
        didSet { defaults.set(openInBrowserOnFailure, forKey: "yunx.openInBrowserOnFailure") }
    }

    // MARK: 界面

    /// 下载页默认展开分组
    @Published var expandGroups: Bool = true {
        didSet { defaults.set(expandGroups, forKey: "yunx.expandGroups") }
    }

    /// 列表里显示缩略图（图集/视频封面）
    @Published var showThumbnails: Bool = true {
        didSet { defaults.set(showThumbnails, forKey: "yunx.showThumbnails") }
    }

    private let defaults = UserDefaults.standard

    init() {
        maxConcurrentTasks = Self.readInt(defaults, "yunx.maxConcurrentTasks", 3)
        minChunkMB = Self.readInt(defaults, "yunx.minChunkMB", 4)
        autoRetryCount = Self.readInt(defaults, "yunx.autoRetryCount", 2)
        wifiOnly = defaults.bool(forKey: "yunx.wifiOnly")
        autoSaveToPhotos = defaults.bool(forKey: "yunx.autoSaveToPhotos")
        clipboardWatch = defaults.object(forKey: "yunx.clipboardWatch") as? Bool ?? true
        copyLinkAfterResolve = defaults.bool(forKey: "yunx.copyLinkAfterResolve")
        openInBrowserOnFailure = defaults.bool(forKey: "yunx.openInBrowserOnFailure")
        expandGroups = defaults.object(forKey: "yunx.expandGroups") as? Bool ?? true
        showThumbnails = defaults.object(forKey: "yunx.showThumbnails") as? Bool ?? true

        var loaded: [String: Int] = [:]
        if let stored = defaults.dictionary(forKey: "yunx.threads") as? [String: Int] {
            loaded = stored
        }
        // 默认值：网盘 32，视频 16，通用 8
        for key in Self.platformKeys {
            threads[key] = min(512, max(1, loaded[key] ?? Self.defaultThreads(key)))
        }
    }

    // MARK: 线程

    static let platformKeys: [String] = [
        DownloadPlatform.quark,
        DownloadPlatform.uc,
        DownloadPlatform.xunlei,
        DownloadPlatform.baidu,
        DownloadPlatform.c139,
        DownloadPlatform.pan123,
        DownloadPlatform.pan115,
        DownloadPlatform.guangya,
        DownloadPlatform.ilanzou,
        DownloadPlatform.lanzou,
        DownloadPlatform.github,
        DownloadPlatform.video,
        DownloadPlatform.generic
    ]

    static func defaultThreads(_ key: String) -> Int {
        switch key {
        case DownloadPlatform.video: return 16
        case DownloadPlatform.generic, DownloadPlatform.github: return 8
        default: return 32
        }
    }

    func threads(for platform: String) -> Int {
        threads[platform] ?? Self.defaultThreads(platform)
    }

    func setThreads(_ value: Int, for platform: String) {
        let clamped = min(512, max(1, value))
        threads[platform] = clamped
        defaults.set(threads, forKey: "yunx.threads")
        objectWillChange.send()
    }

    func resetThreads() {
        threads = [:]
        for key in Self.platformKeys {
            threads[key] = Self.defaultThreads(key)
        }
        defaults.set(threads, forKey: "yunx.threads")
        objectWillChange.send()
    }

    // MARK: 工具

    private static func readInt(_ defaults: UserDefaults, _ key: String, _ fallback: Int) -> Int {
        guard defaults.object(forKey: key) != nil else { return fallback }
        return defaults.integer(forKey: key)
    }
}
