import Foundation
import SwiftUI
import Combine
import UIKit
import Photos

// MARK: - 轻提示

struct Toast: Identifiable, Equatable {

    enum Kind { case info, success, warning, error }

    let id = UUID()
    var text: String
    var kind: Kind = .info
}

// MARK: - 全局状态

/// 应用级状态机：设置 / 账号 / 下载 / 解析四块子系统的持有者。
///
/// 子系统都是独立的 `ObservableObject`（各自可单测、可复用），
/// AppModel 只做三件事：
/// 1. 组装依赖（账号给解析用，设置给下载用）；
/// 2. 把子系统的变化冒泡上来，视图只监听 AppModel 一个对象；
/// 3. 处理跨子系统的边角：剪贴板识别、下载完成存相册、全局 toast。
@MainActor
final class AppModel: ObservableObject {

    @Published var toast: Toast?
    /// 回到前台时从剪贴板发现的可解析链接（解析页会显示成一条「一键解析」提示）
    @Published var clipboardSuggestion: String?
    @Published private(set) var downloadFolderPath: String = ""

    let settings: AppSettings
    let accounts: AccountStore
    let downloads: DownloadManager
    let resolve: ResolveCoordinator

    private var bag = Set<AnyCancellable>()
    private var lastClipboardText = ""

    init() {
        let settings = AppSettings()
        let accounts = AccountStore()
        let downloads = DownloadManager(settings: settings)
        let resolve = ResolveCoordinator(accounts: accounts, downloads: downloads)

        self.settings = settings
        self.accounts = accounts
        self.downloads = downloads
        self.resolve = resolve

        bind(settings)
        bind(accounts)
        bind(downloads)
        bind(resolve)

        downloads.onEvent = { [weak self] event in
            self?.handle(event)
        }
        resolve.onToast = { [weak self] text, kind in
            self?.show(text, kind)
        }
        downloadFolderPath = StoragePaths.downloads.path
    }

    /// 子系统的 `objectWillChange` 冒泡到 AppModel —— 否则视图读 `model.downloads.tasks` 不会刷新
    private func bind<T: ObservableObject>(_ object: T) {
        object.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &bag)
    }

    // MARK: 提示

    func show(_ text: String, _ kind: Toast.Kind = .info) {
        toast = Toast(text: text, kind: kind)
    }

    // MARK: 下载事件

    private func handle(_ event: DownloadManager.Event) {
        switch event {
        case .finished(let task):
            show("下载完成：\(task.fileName)", .success)
            if settings.autoSaveToPhotos, task.kind == .video || task.kind == .image {
                saveToPhotos(url: task.destinationURL, isVideo: task.kind == .video)
            }
        case .failed(let task, let message):
            show("\(task.fileName) 失败：\(message)", .error)
        }
    }

    // MARK: 相册

    func saveToPhotos(url: URL, isVideo: Bool) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            show("文件不存在，可能已被删除", .warning)
            return
        }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            guard status == .authorized || status == .limited else {
                Task { @MainActor in
                    self?.show("没有相册写入权限，请在系统设置里开启", .warning)
                }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                if isVideo {
                    PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: url)
                } else {
                    PHAssetCreationRequest.creationRequestForAssetFromImage(atFileURL: url)
                }
            } completionHandler: { success, error in
                Task { @MainActor in
                    if success {
                        self?.show("已存入相册", .success)
                    } else {
                        self?.show("存入相册失败：\(error?.localizedDescription ?? "未知原因")", .error)
                    }
                }
            }
        }
    }

    // MARK: 剪贴板

    /// 回到前台时读一次剪贴板：发现分享链接就给一条「一键解析」提示。
    /// 设置里可以关掉 —— 每次读剪贴板 iOS 都会顶一条系统提示，有人不喜欢。
    func checkClipboard() {
        guard settings.clipboardWatch else { return }
        guard let text = UIPasteboard.general.string?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
        guard text != lastClipboardText else { return }
        lastClipboardText = text
        // ResolvedTarget 带关联值，不是 Equatable，只能按 case 判
        if case .unknown = ResolveRouter.route(text) { return }
        clipboardSuggestion = text
    }

    func dismissClipboardSuggestion() {
        clipboardSuggestion = nil
    }

    // MARK: 存储信息

    var usedSpaceText: String {
        ByteCountFormatter.string(fromByteCount: StoragePaths.usedSpace(), countStyle: .file)
    }

    var freeSpaceText: String {
        ByteCountFormatter.string(fromByteCount: StoragePaths.freeSpace(), countStyle: .file)
    }

    func deleteLocalFile(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
            show("已删除 \(url.lastPathComponent)", .success)
        } catch {
            show("删除失败：\(error.localizedDescription)", .error)
        }
    }

    var localFiles: [URL] {
        DownloadStore.shared.localFiles()
    }
}
