import Foundation
import SwiftUI
import Combine

// MARK: - 下载管理器

/// 下载队列：排队、并发、暂停/继续、断点续传、分组、完成后落盘。
///
/// 一条任务的完整生命周期：
/// ```
/// pending → (probe 拿总大小) → running(分片并发) → completed
///                ↘ paused（用户暂停/退出）      ↘ failed（可重试）
/// ```
/// 关键设计：
/// - **规划稳定**：分片只由「总大小 + 线程数」决定，恢复时能算出同样的切片；
/// - **账本优先**：`completedChunks` 是进度真相，重启后按它跳过已下完的片；
/// - **进度不跳主线程**：分片回调写进 `ProgressBox`，UI 由 0.5s 的 ticker 统一刷新。
@MainActor
final class DownloadManager: ObservableObject {

    enum Event {
        case finished(DownloadTask)
        case failed(DownloadTask, String)
    }

    @Published private(set) var tasks: [DownloadTask] = []
    @Published private(set) var groups: [DownloadGroup] = []
    @Published private(set) var collapsedGroups: Set<UUID> = []
    @Published private(set) var queuePaused = false
    /// 保存失败/成功的一次性提示（由 AppModel 转成 toast）
    var onEvent: ((Event) -> Void)?

    private let store = DownloadStore.shared
    private let ledgerURL = StoragePaths.supportFile("tasks.json")
    private let settings: AppSettings

    private var runners: [UUID: Task<Void, Never>] = [:]
    private var downloaders: [UUID: RangeDownloader] = [:]
    private var flags: [UUID: CancellationFlag] = [:]
    private var boxes: [UUID: ProgressBox] = [:]
    private var lastBytes: [UUID: Int64] = [:]
    private var ticker: Timer?
    private var lastPersist = Date()

    init(settings: AppSettings) {
        self.settings = settings
        load()
        // 上次退出时还在跑的任务：一律回到「已暂停」，让用户自己点继续
        for index in tasks.indices where tasks[index].status == .running || tasks[index].isPreparing {
            tasks[index].status = .paused
            tasks[index].isPreparing = false
            tasks[index].liveSpeed = 0
        }
        // 设置里关掉「分组默认展开」时，启动就把已有分组折叠起来
        if !settings.expandGroups {
            collapsedGroups = Set(groups.map { $0.id })
        }
        persist()
    }

    // MARK: 统计

    var activeCount: Int {
        tasks.filter { $0.status == .running || $0.status == .pending }.count
    }

    var runningCount: Int {
        tasks.filter { $0.status == .running }.count
    }

    var failedCount: Int {
        tasks.filter { $0.status == .failed }.count
    }

    var overallProgress: Double {
        let relevant = tasks.filter { $0.status == .running || $0.status == .pending || $0.status == .paused }
        let total = relevant.reduce(Int64(0)) { $0 + max($1.totalSize, 0) }
        guard total > 0 else { return 0 }
        let done = relevant.reduce(Int64(0)) { $0 + min($1.downloadedSize, $1.totalSize) }
        return min(1, max(0, Double(done) / Double(total)))
    }

    var totalSpeed: Int64 {
        tasks.reduce(Int64(0)) { $0 + $1.liveSpeed }
    }

    /// 未分组的任务排在最前面，其余按分组创建时间倒序
    var groupedTasks: [(group: DownloadGroup?, tasks: [DownloadTask])] {
        var result: [(DownloadGroup?, [DownloadTask])] = []
        let loose = tasks.filter { $0.groupId == nil }.sorted { $0.createdAt > $1.createdAt }
        if !loose.isEmpty { result.append((nil, loose)) }
        for group in groups.sorted(by: { $0.createdAt > $1.createdAt }) {
            let items = tasks.filter { $0.groupId == group.id }.sorted { $0.createdAt < $1.createdAt }
            if !items.isEmpty { result.append((group, items)) }
        }
        return result
    }

    func isCollapsed(_ group: DownloadGroup) -> Bool {
        collapsedGroups.contains(group.id)
    }

    func toggleGroup(_ group: DownloadGroup) {
        if collapsedGroups.contains(group.id) {
            collapsedGroups.remove(group.id)
        } else {
            collapsedGroups.insert(group.id)
        }
    }

    // MARK: 入队

    @discardableResult
    func enqueue(links: [ShareDownloadLink], groupTitle: String?, platform: String) -> Int {
        guard !links.isEmpty else { return 0 }
        var group: DownloadGroup?
        if let groupTitle, !groupTitle.isEmpty {
            group = makeGroup(title: groupTitle, platformName: DownloadPlatform.displayName(platform))
        }
        var added = 0
        for link in links {
            let name = store.uniqueName(link.fileName.isEmpty ? "未命名文件" : link.fileName)
            var task = DownloadTask(url: link.url, fileName: name)
            task.headers = link.headers
            task.platform = platform.isEmpty ? link.platform.downloadPlatform : platform
            task.totalSize = max(0, link.size)
            task.groupId = group?.id
            tasks.append(task)
            added += 1
        }
        persist()
        pump()
        return added
    }

    @discardableResult
    func enqueue(medias: [VideoMedia], groupTitle: String?, platform: VideoPlatform) -> Int {
        guard !medias.isEmpty else { return 0 }
        var group: DownloadGroup?
        if let groupTitle, !groupTitle.isEmpty {
            group = makeGroup(title: groupTitle, platformName: platform.displayName)
        }
        var added = 0
        for media in medias {
            let fallback = "\(platform.rawValue)_\(Int(Date().timeIntervalSince1970))"
            let name = store.uniqueName(media.fileName.isEmpty ? fallback : media.fileName)
            var task = DownloadTask(url: media.url, fileName: name)
            task.headers = media.headers
            task.platform = DownloadPlatform.video
            task.totalSize = max(0, media.size)
            task.isHls = media.isHls
            task.audioUrl = media.audioUrl
            task.audioHeaders = media.audioHeaders
            task.groupId = group?.id
            tasks.append(task)
            added += 1

            // 动图：静图与动图资源各存一份（iOS 没有「动态照片」单文件的通用写法）
            if !media.motionUrl.isEmpty {
                let motionName = store.uniqueName("\(stripExtension(name))_动图.mov")
                var motionTask = DownloadTask(url: media.motionUrl, fileName: motionName)
                motionTask.headers = media.headers
                motionTask.platform = DownloadPlatform.video
                motionTask.groupId = group?.id
                tasks.append(motionTask)
                added += 1
            }
        }
        persist()
        pump()
        return added
    }

    /// 手动添加一条直链（设置页/收藏里「新建下载」用）
    @discardableResult
    func addDirectLink(url: String, fileName: String) -> Bool {
        guard !url.isEmpty, URL(string: url) != nil else { return false }
        let name = store.uniqueName(fileName.isEmpty ? "直链下载" : fileName)
        tasks.append(DownloadTask(url: url, fileName: name, platform: DownloadPlatform.generic))
        persist()
        pump()
        return true
    }

    private func stripExtension(_ name: String) -> String {
        (name as NSString).deletingPathExtension
    }

    private func makeGroup(title: String, platformName: String) -> DownloadGroup {
        let group = DownloadGroup(title: title, platformName: platformName)
        groups.append(group)
        return group
    }

    // MARK: 控制

    func pause(_ id: UUID) {
        flags[id]?.set()
        downloaders[id]?.cancel()
        runners[id]?.cancel()
        runners[id] = nil
        downloaders[id] = nil
        update(id) { task in
            task.status = .paused
            task.isPreparing = false
            task.liveSpeed = 0
        }
        persist()
    }

    func resume(_ id: UUID) {
        update(id) { task in
            task.status = .pending
            task.errorMessage = ""
            task.liveSpeed = 0
        }
        persist()
        queuePaused = false
        pump()
    }

    func retry(_ id: UUID) {
        resume(id)
    }

    func remove(_ id: UUID, deleteFile: Bool = false) {
        guard let task = tasks.first(where: { $0.id == id }) else { return }
        flags[id]?.set()
        downloaders[id]?.cancel()
        runners[id]?.cancel()
        runners[id] = nil
        downloaders[id] = nil
        flags[id] = nil
        boxes[id] = nil
        store.cleanTemps(for: id)
        if deleteFile { store.deleteFile(named: task.fileName) }
        tasks.removeAll { $0.id == id }
        pruneGroups()
        persist()
        pump()
    }

    func pauseAll() {
        queuePaused = true
        for task in tasks where task.status == .running || task.status == .pending {
            pause(task.id)
        }
        queuePaused = true
    }

    func resumeAll() {
        queuePaused = false
        for task in tasks where task.status == .paused || task.status == .failed {
            update(task.id) { item in
                item.status = .pending
                item.errorMessage = ""
            }
        }
        persist()
        pump()
    }

    func clearCompleted(deleteFile: Bool = false) {
        let ids = tasks.filter { $0.status == .completed }.map { $0.id }
        for id in ids { remove(id, deleteFile: deleteFile) }
    }

    func removeGroup(_ group: DownloadGroup, deleteFile: Bool = false) {
        let ids = tasks.filter { $0.groupId == group.id }.map { $0.id }
        for id in ids { remove(id, deleteFile: deleteFile) }
        groups.removeAll { $0.id == group.id }
        persist()
    }

    func openURL(for task: DownloadTask) -> URL? {
        let url = store.fileURL(for: task.fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func task(_ id: UUID) -> DownloadTask? {
        tasks.first { $0.id == id }
    }

    // MARK: 调度

    private func pump() {
        guard !queuePaused else { return }
        if settings.wifiOnly && !NetworkMonitor.shared.isWiFi { return }
        var slots = max(0, settings.maxConcurrentTasks - runningCount)
        guard slots > 0 else { return }
        for task in tasks where task.status == .pending {
            if slots <= 0 { break }
            slots -= 1
            start(task.id)
        }
    }

    private func start(_ id: UUID) {
        guard runners[id] == nil else { return }
        guard let task = tasks.first(where: { $0.id == id }) else { return }
        if settings.wifiOnly && !NetworkMonitor.shared.isWiFi {
            update(id) { item in
                item.status = .paused
                item.errorMessage = "已开启「仅 Wi-Fi 下载」，当前不是 Wi-Fi"
            }
            return
        }

        let flag = CancellationFlag()
        flags[id] = flag
        boxes[id] = ProgressBox()
        update(id) { item in
            item.status = .running
            item.isPreparing = true
            item.errorMessage = ""
        }
        startTicker()
        runners[id] = Task { [weak self] in
            await self?.run(taskID: id, flag: flag)
        }
    }

    // MARK: 执行

    private func run(taskID id: UUID, flag: CancellationFlag) async {
        guard let snapshot = tasks.first(where: { $0.id == id }) else { return }
        let box = boxes[id] ?? ProgressBox()
        let started = Date()

        do {
            let finalURL: URL
            if snapshot.isHls {
                finalURL = try await runHls(task: snapshot, flag: flag, box: box)
            } else if !snapshot.audioUrl.isEmpty {
                finalURL = try await runSplit(task: snapshot, flag: flag, box: box)
            } else {
                finalURL = try await runSingle(task: snapshot, flag: flag, box: box)
            }

            let elapsed = max(Date().timeIntervalSince(started), 0.2)
            update(id) { task in
                task.status = .completed
                task.isPreparing = false
                task.finishedAt = Date()
                task.fileName = finalURL.lastPathComponent
                if task.totalSize > 0 { task.downloadedSize = task.totalSize }
                task.avgSpeed = Int64(Double(task.downloadedSize) / elapsed)
                task.liveSpeed = 0
                task.errorMessage = ""
            }
            if let finished = tasks.first(where: { $0.id == id }) {
                onEvent?(.finished(finished))
            }
        } catch {
            if flag.isSet || isCancellation(error) {
                update(id) { task in
                    task.status = .paused
                    task.isPreparing = false
                    task.liveSpeed = 0
                }
            } else {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                update(id) { task in
                    task.status = .failed
                    task.isPreparing = false
                    task.liveSpeed = 0
                    task.errorMessage = message
                }
                if let failed = tasks.first(where: { $0.id == id }) {
                    onEvent?(.failed(failed, message))
                }
            }
        }

        runners[id] = nil
        downloaders[id] = nil
        flags[id] = nil
        boxes[id] = nil
        persist()
        pump()
        if runningCount == 0 { stopTicker() }
    }

    /// 普通单文件：Range 分片并发
    private func runSingle(task: DownloadTask, flag: CancellationFlag, box: ProgressBox) async throws -> URL {
        let downloader = RangeDownloader()
        downloaders[task.id] = downloader

        let probe = try await downloader.probe(url: task.url, headers: task.headers)
        if flag.isSet { downloader.cancel(); throw DownloadError.cancelled }

        let threads = settings.threads(for: task.platform)
        let chunkCount = probe.supportsRange ? max(1, threads) : 1
        let minChunkBytes = Int64(settings.minChunkMB) * 1024 * 1024
        let parallelism = min(chunkCount, 32)

        update(task.id) { item in
            item.totalSize = probe.totalSize
            item.plannedTotalSize = probe.totalSize
            item.chunkCount = chunkCount
            item.isPreparing = false
        }
        persist()

        try await downloader.download(
            url: probe.finalURL,
            headers: task.headers,
            totalSize: probe.totalSize,
            chunkCount: chunkCount,
            minChunkBytes: minChunkBytes,
            partURL: store.partURL(for: task.id),
            taskID: task.id,
            completedChunks: Set(task.completedChunks),
            parallelism: parallelism,
            onProgress: { index, bytes in box.set(index, bytes) },
            onChunkCompleted: { index in
                Task { @MainActor [weak self] in self?.markChunk(id: task.id, index: index) }
            },
            isCancelled: { flag.isSet }
        )

        return try store.commit(taskID: task.id, fileName: task.fileName)
    }

    /// B 站 DASH：先下视频轨与音轨，再用 AVFoundation 透传合轨
    private func runSplit(task: DownloadTask, flag: CancellationFlag, box: ProgressBox) async throws -> URL {
        let downloader = RangeDownloader()
        downloaders[task.id] = downloader
        let threads = settings.threads(for: task.platform)
        let minChunkBytes = Int64(settings.minChunkMB) * 1024 * 1024

        let videoPart = StoragePaths.parts.appendingPathComponent("\(task.id.uuidString).video")
        let audioPart = StoragePaths.parts.appendingPathComponent("\(task.id.uuidString).audio")

        let videoProbe = try await downloader.probe(url: task.url, headers: task.headers)
        if flag.isSet { downloader.cancel(); throw DownloadError.cancelled }
        if !FileManager.default.fileExists(atPath: videoPart.path) {
            FileManager.default.createFile(atPath: videoPart.path, contents: nil)
        }
        update(task.id) { item in
            item.totalSize = videoProbe.totalSize
            item.isPreparing = false
        }

        try await downloader.download(
            url: videoProbe.finalURL,
            headers: task.headers,
            totalSize: videoProbe.totalSize,
            chunkCount: videoProbe.supportsRange ? max(1, threads) : 1,
            minChunkBytes: minChunkBytes,
            partURL: videoPart,
            taskID: task.id,
            completedChunks: Set(task.completedChunks.filter { $0 < 10_000 }),
            parallelism: min(threads, 32),
            onProgress: { index, bytes in box.set(index, bytes) },
            onChunkCompleted: { index in
                Task { @MainActor [weak self] in self?.markChunk(id: task.id, index: index) }
            },
            isCancelled: { flag.isSet }
        )

        let audioProbe = try await downloader.probe(url: task.audioUrl, headers: task.audioHeaders)
        if flag.isSet { downloader.cancel(); throw DownloadError.cancelled }
        if !FileManager.default.fileExists(atPath: audioPart.path) {
            FileManager.default.createFile(atPath: audioPart.path, contents: nil)
        }
        update(task.id) { item in
            item.totalSize = videoProbe.totalSize + audioProbe.totalSize
        }

        try await downloader.download(
            url: audioProbe.finalURL,
            headers: task.audioHeaders,
            totalSize: audioProbe.totalSize,
            chunkCount: audioProbe.supportsRange ? max(1, min(threads, 8)) : 1,
            minChunkBytes: minChunkBytes,
            partURL: audioPart,
            taskID: task.id,
            completedChunks: [],
            parallelism: 4,
            onProgress: { index, bytes in
                box.set(10_000 + index, bytes + videoProbe.totalSize)
            },
            onChunkCompleted: { _ in },
            isCancelled: { flag.isSet }
        )

        let merged = StoragePaths.parts.appendingPathComponent("\(task.id.uuidString).merged.mp4")
        try await MediaMerger.merge(videoURL: videoPart, audioURL: audioPart, outputURL: merged)
        try? FileManager.default.removeItem(at: videoPart)
        try? FileManager.default.removeItem(at: audioPart)
        return try store.move(tempURL: merged, fileName: task.fileName)
    }

    /// m3u8：分片顺序抓取后拼接
    private func runHls(task: DownloadTask, flag: CancellationFlag, box: ProgressBox) async throws -> URL {
        update(task.id) { item in
            item.totalSize = 0
            item.isPreparing = true
        }
        let output = StoragePaths.parts.appendingPathComponent("\(task.id.uuidString).hls.ts")
        let total = try await HlsDownloader.download(
            m3u8: task.url,
            headers: task.headers,
            destination: output,
            onBytes: { bytes in box.set(0, bytes) },
            isCancelled: { flag.isSet }
        )
        update(task.id) { item in
            item.totalSize = total
            item.downloadedSize = total
            item.isPreparing = false
        }
        return try store.move(tempURL: output, fileName: task.fileName)
    }

    private func markChunk(id: UUID, index: Int) {
        guard let position = tasks.firstIndex(where: { $0.id == id }) else { return }
        if !tasks[position].completedChunks.contains(index) {
            tasks[position].completedChunks.append(index)
            tasks[position].completedChunks.sort()
        }
        persistIfNeeded()
    }

    // MARK: 进度 ticker

    private func startTicker() {
        guard ticker == nil else { return }
        lastPersist = Date()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        var anyRunning = false
        for index in tasks.indices {
            let id = tasks[index].id
            guard tasks[index].status == .running else { continue }
            anyRunning = true
            guard let box = boxes[id] else { continue }
            let bytes = box.total
            let previous = lastBytes[id] ?? 0
            let delta = max(0, bytes - previous)
            lastBytes[id] = bytes
            // 0.5s 的采样，乘 2 得到每秒速度；再和上一秒做指数平滑，数字才不会乱跳
            let instant = delta * 2
            let smoothed = tasks[index].liveSpeed == 0
                ? instant
                : (tasks[index].liveSpeed * 3 + instant) / 4
            tasks[index].liveSpeed = smoothed
            if tasks[index].totalSize > 0 {
                tasks[index].downloadedSize = min(bytes, tasks[index].totalSize)
            } else {
                tasks[index].downloadedSize = bytes
            }
        }
        if !anyRunning { stopTicker() }
        persistIfNeeded()
    }

    // MARK: 持久化

    private struct Ledger: Codable {
        var tasks: [DownloadTask]
        var groups: [DownloadGroup]
    }

    private func load() {
        guard let ledger = JSONDisk.load(Ledger.self, from: ledgerURL) else { return }
        tasks = ledger.tasks
        groups = ledger.groups
        // 已完成的任务如果文件被用户删了，标成失败，避免点开是空白
        for index in tasks.indices where tasks[index].status == .completed {
            if !FileManager.default.fileExists(atPath: tasks[index].destinationURL.path) {
                tasks[index].status = .failed
                tasks[index].errorMessage = "文件已被删除，可重新下载"
            }
        }
    }

    private func persist() {
        JSONDisk.save(Ledger(tasks: tasks, groups: groups), to: ledgerURL)
        lastPersist = Date()
    }

    private func persistIfNeeded() {
        guard Date().timeIntervalSince(lastPersist) > 2 else { return }
        persist()
    }

    private func pruneGroups() {
        let alive = Set(tasks.compactMap { $0.groupId })
        groups.removeAll { !alive.contains($0.id) }
    }

    private func update(_ id: UUID, _ mutate: (inout DownloadTask) -> Void) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        mutate(&tasks[index])
    }

    private func isCancellation(_ error: Error) -> Bool {
        if let downloadError = error as? DownloadError, case .cancelled = downloadError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }
}
