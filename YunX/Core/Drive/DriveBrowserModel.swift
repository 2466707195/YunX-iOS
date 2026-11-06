import Foundation
import Combine

// MARK: - 网盘浏览状态机

/// 「网盘」页的状态机：平台切换 / 目录栈 / 列表 / 多选 / 批量下载。
///
/// 为什么单独一个类而不塞进 `AppModel`：
/// 目录栈、勾选集合、取链进度都是这一页私有的状态，页面重建（切 Tab）时不该被清空，
/// 但也不该让别的页面看到。挂在 `AppModel` 上的只是一个引用，状态仍归这里。
@MainActor
final class DriveBrowserModel: ObservableObject {

    /// 页面状态。`loaded` 且 `files` 为空 = 空目录，属于正常情况，不是错误。
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case needLogin
        case failed(String)
    }

    // MARK: 对外状态

    @Published private(set) var platform: SharePlatform
    @Published private(set) var path: [DrivePathItem] = [.root]
    @Published private(set) var files: [DriveFile] = []
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var selecting = false
    @Published private(set) var selected: Set<String> = []
    /// 批量取链时的进度文案（空 = 空闲）
    @Published private(set) var busyText: String = ""

    /// 轻提示出口，由 `AppModel` 接到全局 toast
    var onToast: ((String, Toast.Kind) -> Void)?

    // MARK: 依赖

    private let accounts: AccountStore
    private let downloads: DownloadManager

    private var loadedOnce = false
    /// 递归展开文件夹时的文件计数（封顶 300，防止超大目录把界面卡死）
    private var walkCount = 0

    init(accounts: AccountStore, downloads: DownloadManager) {
        self.accounts = accounts
        self.downloads = downloads
        // 默认选第一个已登录的平台；都没登录就选夸克（会走未登录态引导）
        self.platform = [SharePlatform.quark, .uc].first { accounts.hasAccount($0) } ?? .quark
    }

    // MARK: 派生

    /// 已登录的网盘平台（用于顶部切换条）
    var availablePlatforms: [SharePlatform] {
        [SharePlatform.quark, .uc].filter { accounts.hasAccount($0) }
    }

    var isLoggedIn: Bool { accounts.hasAccount(platform) }

    var currentDirId: String { path.last?.id ?? "0" }

    var canGoUp: Bool { path.count > 1 }

    var currentDirName: String { path.last?.name ?? DrivePathItem.root.name }

    var selectedFiles: [DriveFile] {
        files.filter { selected.contains($0.id) }
    }

    var selectedSizeText: String {
        let total = selectedFiles.reduce(Int64(0)) { $0 + $1.size }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    var busy: Bool { !busyText.isEmpty }

    // MARK: 加载

    /// 进入页面时调用：未登录 → 引导；已登录且没加载过 → 拉根目录。
    /// 从别的 Tab 切回来时不会重复请求（`loadedOnce`）。
    func refreshIfNeeded() async {
        guard accounts.hasAccount(platform) else {
            phase = .needLogin
            files = []
            loadedOnce = false
            return
        }
        if !loadedOnce {
            await load(dirId: currentDirId)
        }
    }

    /// 账号变动（登录 / 退出）后调用，让页面下次进入时重新取数
    func invalidate() {
        loadedOnce = false
        files = []
        selected.removeAll()
        selecting = false
        phase = .idle
        if !accounts.hasAccount(platform) {
            let other = availablePlatforms.first
            if let other { platform = other }
            path = [.root]
        }
    }

    func switchPlatform(_ next: SharePlatform) async {
        guard next != platform, accounts.hasAccount(next) else { return }
        platform = next
        path = [.root]
        files = []
        selected.removeAll()
        selecting = false
        loadedOnce = false
        await load(dirId: DrivePathItem.root.id)
    }

    func reload() async {
        await load(dirId: currentDirId)
    }

    private func load(dirId: String) async {
        guard accounts.hasAccount(platform) else {
            phase = .needLogin
            files = []
            return
        }
        let cookie = accounts.credential(for: platform)
        guard !cookie.isEmpty else {
            phase = .needLogin
            files = []
            return
        }

        phase = .loading
        do {
            let api = try DriveRegistry.require(platform)
            let list = try await api.list(parentId: dirId, cookie: cookie)
            files = list
            phase = .loaded
            loadedOnce = true
        } catch let error as PanError {
            // 「需要登录」单独成一态，页面直接给登录入口，而不是让用户点重试
            if case .needLogin = error {
                phase = .needLogin
                files = []
                loadedOnce = false
            } else {
                phase = .failed(error.localizedDescription)
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: 目录浏览

    func open(_ folder: DriveFile) async {
        guard folder.isFolder else { return }
        path.append(DrivePathItem(id: folder.id, name: folder.name))
        selected.removeAll()
        files = []
        await load(dirId: folder.id)
    }

    func goTo(index: Int) async {
        guard index >= 0, index < path.count - 1 else { return }
        let target = path[index]
        path = Array(path.prefix(index + 1))
        selected.removeAll()
        files = []
        await load(dirId: target.id)
    }

    /// 返回上一级；已经在根目录时返回 false（由页面决定是否退出）
    @discardableResult
    func goUp() async -> Bool {
        guard canGoUp else { return false }
        await goTo(index: path.count - 2)
        return true
    }

    // MARK: 多选

    func toggleSelecting() {
        selecting.toggle()
        if !selecting { selected.removeAll() }
    }

    func toggle(_ file: DriveFile) {
        if selected.contains(file.id) {
            selected.remove(file.id)
        } else {
            selected.insert(file.id)
        }
    }

    func selectAll() {
        selected = Set(files.map { $0.id })
    }

    func clearSelection() {
        selected.removeAll()
    }

    // MARK: 下载

    func downloadSelected() async {
        await download(selectedFiles)
    }

    /// 把条目（可含文件夹）展开成文件列表，逐个取直链后整体入队。
    ///
    /// 取链为什么串行：夸克这条接口对**并发**比较敏感（同时打多个容易触发频控），
    /// 而且串行能给出「正在取直链 3/20」的确定进度，比并发转圈更可预期。
    func download(_ targets: [DriveFile]) async {
        guard !targets.isEmpty else { return }
        guard accounts.hasAccount(platform) else {
            phase = .needLogin
            onToast?("请先在「账号」页登录\(platform.displayName)", .warning)
            return
        }
        let cookie = accounts.credential(for: platform)
        guard !cookie.isEmpty else {
            phase = .needLogin
            return
        }
        let api: DriveAPI
        do {
            api = try DriveRegistry.require(platform)
        } catch {
            onToast?(error.localizedDescription, .error)
            return
        }

        // 1. 展开文件夹
        var flat: [DriveFile] = []
        walkCount = 0
        for item in targets {
            if item.isFolder {
                busyText = "正在展开 \(item.name)…"
                flat += await walk(item.id, depth: 0, cookie: cookie)
            } else {
                flat.append(item)
            }
        }
        guard !flat.isEmpty else {
            busyText = ""
            onToast?("选中的文件夹里没有可下载的文件", .warning)
            return
        }

        // 2. 逐个取直链
        var links: [ShareDownloadLink] = []
        var failures = 0
        for (index, file) in flat.enumerated() {
            busyText = "正在取直链 \(index + 1)/\(flat.count)"
            do {
                links.append(try await api.downloadLink(for: file, cookie: cookie))
            } catch {
                failures += 1
            }
        }
        busyText = ""

        guard !links.isEmpty else {
            onToast?("没有取到任何直链，登录态可能已失效，请到「账号」页重新登录", .error)
            return
        }

        // 3. 入队
        let added = downloads.enqueue(
            links: links,
            groupTitle: platform.displayName,
            platform: platform.downloadPlatform
        )
        selecting = false
        selected.removeAll()

        var text = "已加入下载队列：\(added) 个文件"
        if failures > 0 { text += "（\(failures) 个取链失败）" }
        onToast?(text, failures > 0 ? .warning : .success)
    }

    /// 递归列目录（最多 4 层、300 个文件）
    private func walk(_ dirId: String, depth: Int, cookie: String) async -> [DriveFile] {
        guard depth < 4, walkCount < 300,
              let api = DriveRegistry.api(for: platform) else { return [] }
        guard let list = try? await api.list(parentId: dirId, cookie: cookie) else { return [] }

        var output: [DriveFile] = []
        for item in list {
            if item.isFolder {
                output += await walk(item.id, depth: depth + 1, cookie: cookie)
            } else if walkCount < 300 {
                walkCount += 1
                output.append(item)
            }
            if walkCount >= 300 { break }
        }
        return output
    }
}
