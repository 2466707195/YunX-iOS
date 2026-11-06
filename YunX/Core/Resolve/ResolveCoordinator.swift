import Foundation
import SwiftUI
import UIKit

// MARK: - 直链弹窗模型

/// 「直链已生成」弹窗：展示一条（或多条）可复制的下载地址。
struct LinkSheetModel: Identifiable {

    let id = UUID()
    var title: String
    var links: [ShareDownloadLink]
    var groupTitle: String?
    var platformKey: String

    var primary: ShareDownloadLink? { links.first }
}

// MARK: - 解析协调器

/// 解析页的全部状态与动作。
///
/// 分成两条互不干扰的路径（和 Android 版 `ResolveViewModel` 一致）：
/// - **网盘**：分享 token → 目录浏览（可下钻）→ 单文件取直链 → 入队；
/// - **视频**：识别平台 → 解析器 → 结果页（视频单条 / 图集多选）。
@MainActor
final class ResolveCoordinator: ObservableObject {

    enum Phase {
        case idle
        case share(ShareSnapshot)
        case video(VideoParseResult)
    }

    // MARK: 输入

    @Published var input: String = ""
    @Published var passcode: String = ""

    // MARK: 状态

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var detectedLabel: String = ""
    @Published private(set) var loading: Bool = false
    @Published private(set) var busyFileID: String?
    @Published var errorMessage: String?
    @Published var passcodePrompt: Bool = false
    @Published var linkSheet: LinkSheetModel?

    /// 网盘目录栈（根目录固定是 `0`，夸克/UC 的根 pdir_fid 就是 "0"）
    @Published private(set) var dirStack: [(id: String, name: String)] = [("0", "根目录")]

    /// 视频结果页的多选（图集批量下载）
    @Published private(set) var selectedMediaIDs: Set<UUID> = []

    var onToast: ((String, Toast.Kind) -> Void)?

    private let accounts: AccountStore
    private let downloads: DownloadManager
    private var pendingShare: ParsedShare?

    init(accounts: AccountStore, downloads: DownloadManager) {
        self.accounts = accounts
        self.downloads = downloads
    }

    // MARK: 派生状态

    var snapshot: ShareSnapshot? {
        if case .share(let snapshot) = phase { return snapshot }
        return nil
    }

    var videoResult: VideoParseResult? {
        if case .video(let result) = phase { return result }
        return nil
    }

    var isSharePhase: Bool { snapshot != nil }

    var selectedMedias: [VideoMedia] {
        guard let result = videoResult else { return [] }
        return result.medias.filter { selectedMediaIDs.contains($0.id) }
    }

    var canGoUp: Bool { dirStack.count > 1 }

    // MARK: 识别

    /// 粘贴后立刻给出「识别到哪个平台」，让用户在点解析之前就知道对不对
    func detect() {
        let target = ResolveRouter.route(input)
        if case .unknown = target {
            detectedLabel = ""
        } else {
            detectedLabel = ResolveRouter.describe(target)
        }
    }

    /// 清空输入时一并清掉识别提示（`detectedLabel` 对外只读，由这里统一改）
    func clearDetectedLabel() {
        detectedLabel = ""
    }

    // MARK: 主流程

    func resolve() async {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            onToast?("先粘贴一个分享链接", .warning)
            return
        }
        switch ResolveRouter.route(text) {
        case .video(let link):
            await resolveVideo(text: text, hint: link)
        case .share(let share):
            await open(share: share, passcode: passcode.isEmpty ? share.pwd : passcode)
        case .github(let owner, let repo):
            await resolveGitHub(owner: owner, repo: repo)
        case .unknown:
            errorMessage = "没有识别到支持的链接。支持夸克/UC/迅雷/百度/139/123/115/光鸭/蓝奏云分享，以及抖音/小红书/快手/微博/AcFun/B站/Pixiv 作品链接。"
        }
    }

    /// 收藏/剪贴板一键解析
    func resolve(text: String) async {
        input = text
        detect()
        await resolve()
    }

    // MARK: 视频

    private func resolveVideo(text: String, hint: DetectedVideoLink) async {
        loading = true
        detectedLabel = hint.platform.displayName
        errorMessage = nil
        selectedMediaIDs = []
        defer { loading = false }
        do {
            let result = try await VideoResolveService.parse(text: text) { platform in
                self.accounts.credential(for: platform)
            }
            phase = .video(result)
            accounts.recordHistory(
                title: result.title,
                link: text,
                platform: result.platform.rawValue,
                kind: "video"
            )
            if !result.notice.isEmpty {
                onToast?(result.notice, .warning)
            }
            if result.medias.count == 1 {
                selectedMediaIDs = Set(result.medias.map { $0.id })
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            errorMessage = message
            onToast?(message, .error)
        }
    }

    // MARK: GitHub

    private func resolveGitHub(owner: String, repo: String) async {
        loading = true
        detectedLabel = "GitHub · \(owner)/\(repo)"
        errorMessage = nil
        defer { loading = false }
        do {
            let result = try await GitHubAPI.releaseAssets(owner: owner, repo: repo)
            linkSheet = LinkSheetModel(
                title: result.title,
                links: result.links,
                groupTitle: result.links.count > 1 ? result.title : nil,
                platformKey: DownloadPlatform.github
            )
            accounts.recordHistory(title: result.title, link: input, platform: "github", kind: "release")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            errorMessage = message
            onToast?(message, .error)
        }
    }

    // MARK: 网盘

    func open(share: ParsedShare, passcode explicitPasscode: String? = nil) async {
        guard let api = PanRegistry.api(for: share.platform) else {
            let message = PanError.notImplemented(share.platform).errorDescription ?? "该平台暂不支持"
            errorMessage = message
            onToast?(message, .warning)
            return
        }
        loading = true
        errorMessage = nil
        defer { loading = false }

        let effective = ParsedShare(
            shareId: share.shareId,
            pwd: (explicitPasscode?.isEmpty == false ? explicitPasscode : share.pwd),
            platform: share.platform
        )
        let cookie = accounts.credential(for: share.platform)
        do {
            var snapshot = try await api.snapshot(share: effective, cookie: cookie)
            snapshot.dirId = "0"
            phase = .share(snapshot)
            dirStack = [("0", "根目录")]
            passcode = ""
            pendingShare = nil
            accounts.recordHistory(
                title: snapshot.title,
                link: ShareLinkParser.webURL(for: effective),
                platform: share.platform.rawValue,
                kind: "share"
            )
        } catch let error as PanError {
            switch error {
            case .needPasscode, .wrongPasscode:
                pendingShare = effective
                passcodePrompt = true
                errorMessage = error.errorDescription
            default:
                errorMessage = error.errorDescription
                onToast?(error.errorDescription ?? "解析失败", .error)
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            errorMessage = message
            onToast?(message, .error)
        }
    }

    /// 提取码弹窗提交
    func submitPasscode(_ code: String) async {
        guard let share = pendingShare else { return }
        passcodePrompt = false
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await open(share: share, passcode: trimmed)
    }

    func openFolder(_ entry: ShareEntry) async {
        guard let snapshot, let api = PanRegistry.api(for: snapshot.platform) else { return }
        loading = true
        defer { loading = false }
        let cookie = accounts.credential(for: snapshot.platform)
        do {
            var updated = snapshot
            updated.entries = try await api.entries(in: snapshot, dirId: entry.id, cookie: cookie)
            updated.dirId = entry.id
            phase = .share(updated)
            dirStack.append((entry.id, entry.name))
        } catch {
            onToast?((error as? LocalizedError)?.errorDescription ?? "打开文件夹失败", .error)
        }
    }

    /// 面包屑回退到第 index 层
    func goToDir(index: Int) async {
        guard let snapshot, let api = PanRegistry.api(for: snapshot.platform) else { return }
        guard index >= 0, index < dirStack.count else { return }
        let target = dirStack[index]
        loading = true
        defer { loading = false }
        let cookie = accounts.credential(for: snapshot.platform)
        do {
            var updated = snapshot
            updated.entries = try await api.entries(in: snapshot, dirId: target.id, cookie: cookie)
            updated.dirId = target.id
            phase = .share(updated)
            dirStack.removeSubrange((index + 1)..<dirStack.count)
        } catch {
            onToast?((error as? LocalizedError)?.errorDescription ?? "切换目录失败", .error)
        }
    }

    func goUp() async {
        guard dirStack.count > 1 else { return }
        await goToDir(index: dirStack.count - 2)
    }

    func refreshShare() async {
        guard snapshot != nil else { return }
        await goToDir(index: dirStack.count - 1)
    }

    // MARK: 取直链

    /// 单文件：取直链后弹窗（可复制、可下载）
    func fetchLink(for entry: ShareEntry) async {
        guard let snapshot, let api = PanRegistry.api(for: snapshot.platform) else { return }
        busyFileID = entry.id
        defer { busyFileID = nil }
        let cookie = accounts.credential(for: snapshot.platform)
        do {
            let link = try await api.downloadLink(for: entry, in: snapshot, cookie: cookie)
            linkSheet = LinkSheetModel(
                title: entry.name,
                links: [link],
                groupTitle: nil,
                platformKey: snapshot.platform.downloadPlatform
            )
            if downloads.settingsSnapshotAutoCopy { copy(link.url) }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "取直链失败"
            onToast?(message, .error)
        }
    }

    /// 直接下载（不弹窗）：文件直下，文件夹递归展开后整组入队
    func download(entries: [ShareEntry]) async {
        guard let snapshot, let api = PanRegistry.api(for: snapshot.platform) else { return }
        guard !entries.isEmpty else { return }
        if entries.count == 1, !entries[0].isFolder {
            await fetchAndEnqueue(entries[0], snapshot: snapshot, api: api, silently: false)
            return
        }

        loading = true
        defer { loading = false }
        let cookie = accounts.credential(for: snapshot.platform)
        var collected: [(entry: ShareEntry, parentDir: String)] = []
        do {
            for entry in entries {
                if entry.isFolder {
                    let files = try await walk(api: api, snapshot: snapshot, dirId: entry.id, cookie: cookie, depth: 0)
                    collected.append(contentsOf: files)
                } else {
                    collected.append((entry, snapshot.dirId))
                }
            }
        } catch {
            onToast?((error as? LocalizedError)?.errorDescription ?? "遍历文件夹失败", .error)
            return
        }
        guard !collected.isEmpty else {
            onToast?("文件夹里没有可下载的文件", .warning)
            return
        }

        var links: [ShareDownloadLink] = []
        var lastError: String?
        for item in collected {
            var scoped = snapshot
            scoped.dirId = item.parentDir
            do {
                links.append(try await api.downloadLink(for: item.entry, in: scoped, cookie: cookie))
            } catch {
                lastError = (error as? LocalizedError)?.errorDescription ?? "取直链失败"
            }
        }
        guard !links.isEmpty else {
            onToast?(lastError ?? "没有取到任何直链", .error)
            return
        }
        let groupTitle = entries.count == 1 ? entries[0].name : snapshot.title
        let added = downloads.enqueue(
            links: links,
            groupTitle: groupTitle,
            platform: snapshot.platform.downloadPlatform
        )
        onToast?("已加入下载 \(added) 项" + (lastError == nil ? "" : "（部分失败：\(lastError!)）"), lastError == nil ? .info : .warning)
    }

    private func fetchAndEnqueue(
        _ entry: ShareEntry,
        snapshot: ShareSnapshot,
        api: PanAPI,
        silently: Bool
    ) async {
        busyFileID = entry.id
        defer { busyFileID = nil }
        let cookie = accounts.credential(for: snapshot.platform)
        do {
            let link = try await api.downloadLink(for: entry, in: snapshot, cookie: cookie)
            let added = downloads.enqueue(
                links: [link],
                groupTitle: nil,
                platform: snapshot.platform.downloadPlatform
            )
            if added > 0 {
                onToast?("已加入下载：\(entry.name)", .success)
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "取直链失败"
            onToast?(message, .error)
        }
    }

    private func walk(
        api: PanAPI,
        snapshot: ShareSnapshot,
        dirId: String,
        cookie: String,
        depth: Int
    ) async throws -> [(entry: ShareEntry, parentDir: String)] {
        guard depth < 4 else { return [] }
        let children = try await api.entries(in: snapshot, dirId: dirId, cookie: cookie)
        var output: [(entry: ShareEntry, parentDir: String)] = []
        for child in children {
            if child.isFolder {
                output.append(contentsOf: try await walk(
                    api: api,
                    snapshot: snapshot,
                    dirId: child.id,
                    cookie: cookie,
                    depth: depth + 1
                ))
            } else {
                output.append((entry: child, parentDir: dirId))
            }
            if output.count > 300 { break }
        }
        return output
    }

    // MARK: 视频下载

    func toggleSelection(_ media: VideoMedia) {
        if selectedMediaIDs.contains(media.id) {
            selectedMediaIDs.remove(media.id)
        } else {
            selectedMediaIDs.insert(media.id)
        }
    }

    func selectAll() {
        guard let result = videoResult else { return }
        selectedMediaIDs = Set(result.medias.map { $0.id })
    }

    func clearSelection() {
        selectedMediaIDs.removeAll()
    }

    func downloadVideo(all: Bool) {
        guard let result = videoResult else { return }
        let medias = all ? result.medias : selectedMedias
        guard !medias.isEmpty else {
            onToast?("先选中要下载的内容", .warning)
            return
        }
        let groupTitle = medias.count > 1 ? result.title : nil
        let added = downloads.enqueue(medias: medias, groupTitle: groupTitle, platform: result.platform)
        onToast?("已加入下载 \(added) 项", added > 0 ? .success : .warning)
    }

    /// 结果页里单条媒体的「立即下载」
    func downloadVideo(_ media: VideoMedia) {
        guard let result = videoResult else { return }
        let added = downloads.enqueue(medias: [media], groupTitle: nil, platform: result.platform)
        onToast?("已加入下载 \(added) 项", added > 0 ? .success : .warning)
    }

    func downloadLinksFromSheet() {
        guard let sheet = linkSheet else { return }
        let added = downloads.enqueue(
            links: sheet.links,
            groupTitle: sheet.groupTitle,
            platform: sheet.platformKey
        )
        onToast?("已加入下载 \(added) 项", .success)
        linkSheet = nil
    }

    // MARK: 收尾

    func reset() {
        phase = .idle
        dirStack = [("0", "根目录")]
        selectedMediaIDs = []
        errorMessage = nil
        detectedLabel = ""
        input = ""
        passcode = ""
        pendingShare = nil
    }

    func copy(_ text: String) {
        UIPasteboard.general.string = text
        onToast?("已复制到剪贴板", .success)
    }
}

// MARK: - 小补丁

private extension DownloadManager {
    /// 「取直链后自动复制」是设置项，但协调器不该直接依赖 AppSettings 的可变状态，
    /// 这里只读它一次做个便捷判断。
    var settingsSnapshotAutoCopy: Bool {
        UserDefaults.standard.bool(forKey: "yunx.copyLinkAfterResolve")
    }
}
