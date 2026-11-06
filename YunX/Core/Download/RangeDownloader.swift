import Foundation

// MARK: - 下载错误

enum DownloadError: LocalizedError {

    case badStatus(Int)
    case notResumable
    case noSpace(need: Int64, free: Int64)
    case cancelled
    case io(String)
    case empty

    var errorDescription: String? {
        switch self {
        case .badStatus(let code):
            return "服务器返回 \(code)，直链可能已过期（网盘直链通常只有 15~30 分钟有效期）"
        case .notResumable:
            return "该直链不支持分片，已回退单线程下载"
        case .noSpace(let need, let free):
            let n = ByteCountFormatter.string(fromByteCount: need, countStyle: .file)
            let f = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
            return "存储空间不足：需要约 \(n)，剩余 \(f)"
        case .cancelled:
            return "已取消"
        case .io(let detail):
            return "写入失败：\(detail)"
        case .empty:
            return "服务器返回了空内容"
        }
    }
}

// MARK: - 分片规划

struct ChunkRange: Equatable {

    let index: Int
    let offset: Int64
    let length: Int64

    var end: Int64 { offset + length - 1 }
}

/// 探测结果：总大小 + 是否支持 Range。
struct RangeProbe {

    let totalSize: Int64
    let supportsRange: Bool
    let finalURL: String
    let contentType: String
}

// MARK: - 分片下载器

/// Range 分片并发 + 断点续传。
///
/// 工作方式（与上游 `ChunkDownloader` 的关键行为一致）：
/// 1. `probe`：用 `Range: bytes=0-0` 探一次，拿 `Content-Range` 里的总大小，并确认服务器支持分片；
/// 2. `plan`：把文件均分成 N 片（N = 平台线程设置），**规划只依赖总大小与 N**，
///    所以进程被杀之后能算出完全一样的切片，已下载的分片不会重下；
/// 3. 每片独立下载到分片临时文件 → 按偏移写入预分配的 `.part` 文件 → 删临时文件；
///    中途取消时临时文件留在原地，下次从它的长度接着要 Range；
/// 4. 全部完成后 `.part` 直接改名成成品，**不需要再合并一遍**（省一次全量磁盘拷贝）。
final class RangeDownloader {

    private let lock = NSLock()
    private var activeFetchers: [UUID: ChunkFetcher] = [:]
    private var cancelled = false

    // MARK: 探测

    /// 用 `Range: bytes=0-0` 探一次。
    ///
    /// ★ 必须「拿到响应头就掐断」：如果服务器**不支持** Range，它会无视 Range 头返回 200 +
    ///   整个文件，用 `data(for:)` 会把 13 GB 全塞进内存直接 OOM。所以这里用 delegate
    ///   在 `didReceive response` 里读完头部立刻 `completionHandler(.cancel)`。
    func probe(url: String, headers: [String: String]) async throws -> RangeProbe {
        try await RangeProber().run(url: url, headers: headers)
    }

    // MARK: 分片规划

    static func plan(totalSize: Int64, chunkCount: Int, minChunkBytes: Int64) -> [ChunkRange] {
        guard totalSize > 0 else { return [] }
        let minBytes = max(1, minChunkBytes)
        var count = max(1, chunkCount)
        let maxBySize = Int(max(1, totalSize / minBytes))
        count = min(count, maxBySize)
        guard count > 0 else { return [] }
        let base = totalSize / Int64(count)
        var ranges: [ChunkRange] = []
        var offset: Int64 = 0
        for index in 0..<count {
            let length = index == count - 1 ? totalSize - offset : base
            ranges.append(ChunkRange(index: index, offset: offset, length: length))
            offset += length
        }
        return ranges
    }

    // MARK: 下载

    /// - Parameters:
    ///   - partURL: 预分配的半成品文件
    ///   - completedChunks: 已下完的分片下标（断点续传的账本）
    ///   - parallelism: 同时开几条连接（不超过分片数）
    func download(
        url: String,
        headers: [String: String],
        totalSize: Int64,
        chunkCount: Int,
        minChunkBytes: Int64,
        partURL: URL,
        taskID: UUID,
        completedChunks: Set<Int>,
        parallelism: Int,
        onProgress: @escaping (Int, Int64) -> Void,
        onChunkCompleted: @escaping (Int) -> Void,
        isCancelled: @escaping () -> Bool
    ) async throws {
        let ranges = Self.plan(totalSize: totalSize, chunkCount: chunkCount, minChunkBytes: minChunkBytes)
        guard !ranges.isEmpty else { throw DownloadError.empty }
        try preparePart(partURL, size: totalSize)

        let pending = ranges.filter { !completedChunks.contains($0.index) }
        guard !pending.isEmpty else { return }

        // 已存在的分片临时文件说明上次是在这一片里被中断的，先把进度报上去
        for range in pending {
            let existing = fileSize(DownloadStore.shared.chunkURL(for: taskID, index: range.index))
            if existing > 0 { onProgress(range.index, min(existing, range.length)) }
        }

        let limit = max(1, min(parallelism, pending.count))
        try await withThrowingTaskGroup(of: Void.self) { group in
            var cursor = 0
            var running = 0
            while cursor < pending.count && running < limit {
                let range = pending[cursor]
                cursor += 1
                running += 1
                group.addTask { [weak self] in
                    guard let self else { return }
                    try await self.fetchChunk(
                        range: range,
                        url: url,
                        headers: headers,
                        totalSize: totalSize,
                        partURL: partURL,
                        taskID: taskID,
                        onProgress: onProgress,
                        onChunkCompleted: onChunkCompleted,
                        isCancelled: isCancelled
                    )
                }
            }
            while running > 0 {
                _ = try await group.next()
                running -= 1
                if cursor < pending.count {
                    let range = pending[cursor]
                    cursor += 1
                    running += 1
                    group.addTask { [weak self] in
                        guard let self else { return }
                        try await self.fetchChunk(
                            range: range,
                            url: url,
                            headers: headers,
                            totalSize: totalSize,
                            partURL: partURL,
                            taskID: taskID,
                            onProgress: onProgress,
                            onChunkCompleted: onChunkCompleted,
                            isCancelled: isCancelled
                        )
                    }
                }
            }
        }
    }

    /// 取消所有在途连接（暂停时调用，让 `download` 尽快抛出 `.cancelled`）
    func cancel() {
        lock.lock()
        cancelled = true
        let fetchers = Array(activeFetchers.values)
        lock.unlock()
        for fetcher in fetchers { fetcher.cancel() }
    }

    // MARK: 单片

    private func fetchChunk(
        range: ChunkRange,
        url: String,
        headers: [String: String],
        totalSize: Int64,
        partURL: URL,
        taskID: UUID,
        onProgress: @escaping (Int, Int64) -> Void,
        onChunkCompleted: @escaping (Int) -> Void,
        isCancelled: @escaping () -> Bool
    ) async throws {
        if isCancelled() || Task.isCancelled { throw DownloadError.cancelled }

        let chunkURL = DownloadStore.shared.chunkURL(for: taskID, index: range.index)
        var existing = fileSize(chunkURL)
        if existing > range.length { existing = 0; try? FileManager.default.removeItem(at: chunkURL) }
        if existing == range.length {
            onProgress(range.index, range.length)
            onChunkCompleted(range.index)
            return
        }

        guard let target = URL(string: url) else { throw DownloadError.io("直链不合法") }
        var request = URLRequest(url: target)
        request.httpMethod = "GET"
        request.timeoutInterval = 60
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue("bytes=\(range.offset + existing)-\(range.end)", forHTTPHeaderField: "Range")

        let fetcherID = UUID()
        let fetcher = ChunkFetcher(scratchURL: chunkURL, existingBytes: existing) { bytes in
            onProgress(range.index, min(range.length, existing + bytes))
        }
        lock.lock()
        if cancelled {
            lock.unlock()
            throw DownloadError.cancelled
        }
        activeFetchers[fetcherID] = fetcher
        lock.unlock()

        do {
            _ = try await fetcher.run(request: request)
        } catch {
            lock.lock()
            activeFetchers[fetcherID] = nil
            lock.unlock()
            throw error
        }
        lock.lock()
        activeFetchers[fetcherID] = nil
        lock.unlock()

        // 分片文件 → 半成品的对应偏移
        try copyChunk(chunkURL, to: partURL, at: range.offset)
        try? FileManager.default.removeItem(at: chunkURL)
        onProgress(range.index, range.length)
        onChunkCompleted(range.index)
    }

    // MARK: 文件操作

    private func preparePart(_ url: URL, size: Int64) throws {
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path) {
            guard manager.createFile(atPath: url.path, contents: nil) else {
                throw DownloadError.io("无法创建半成品文件")
            }
            let free = StoragePaths.freeSpace()
            if free > 0 && size > free {
                try? manager.removeItem(at: url)
                throw DownloadError.noSpace(need: size, free: free)
            }
        }
        let current = fileSize(url)
        if current < size {
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(size))
            try handle.close()
        }
    }

    private func copyChunk(_ source: URL, to destination: URL, at offset: Int64) throws {
        let reader = try FileHandle(forReadingFrom: source)
        defer { try? reader.close() }
        let writer = try FileHandle(forWritingTo: destination)
        defer { try? writer.close() }
        try writer.seek(toOffset: UInt64(offset))
        while true {
            guard let data = try reader.read(upToCount: 1 << 20), !data.isEmpty else { break }
            try writer.write(contentsOf: data)
        }
    }

    private func fileSize(_ url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let number = attributes[.size] as? NSNumber else { return 0 }
        return number.int64Value
    }
}

// MARK: - 单分片抓取

/// 一个分片 = 一个 `URLSessionDownloadTask`。
///
/// 为什么用 downloadTask 而不是 `data(for:)`：13 GB 的文件不能进内存；
/// downloadTask 由系统直接落盘，内存占用恒定。
/// 进度靠 `didWriteData` 回调（这是唯一能在下载过程中拿到字节数的路径）。
final class ChunkFetcher: NSObject, URLSessionDownloadDelegate {

    private let scratchURL: URL
    private let existingBytes: Int64
    private let onProgress: (Int64) -> Void

    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var continuation: CheckedContinuation<Void, Error>?
    private var movedURL: URL?
    private var failure: Error?
    private var finished = false
    private let lock = NSLock()

    init(scratchURL: URL, existingBytes: Int64, onProgress: @escaping (Int64) -> Void) {
        self.scratchURL = scratchURL
        self.existingBytes = existingBytes
        self.onProgress = onProgress
        super.init()
    }

    /// 下载成功后，分片内容会**追加**到 `scratchURL`（断点续传复用它）
    func run(request: URLRequest) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 60
            config.timeoutIntervalForResource = 3600
            config.httpShouldSetCookies = false
            let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            self.session = session
            let task = session.downloadTask(with: request)
            self.task = task
            task.resume()
        }
        return scratchURL
    }

    func cancel() {
        task?.cancel()
        session?.invalidateAndCancel()
        finish(error: DownloadError.cancelled)
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        onProgress(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            failure = DownloadError.badStatus(http.statusCode)
            return
        }
        let manager = FileManager.default
        do {
            // 系统给的临时文件在本次回调返回后就会被删，必须立刻搬走
            let staged = scratchURL.appendingPathExtension("incoming")
            if manager.fileExists(atPath: staged.path) { try? manager.removeItem(at: staged) }
            do {
                try manager.moveItem(at: location, to: staged)
            } catch {
                // 跨卷时 move 会失败，退回复制
                try manager.copyItem(at: location, to: staged)
            }

            if existingBytes > 0, manager.fileExists(atPath: scratchURL.path) {
                // 续传：把新下的字节追加到已有分片后面
                let writer = try FileHandle(forWritingTo: scratchURL)
                defer { try? writer.close() }
                _ = try writer.seekToEnd()
                let reader = try FileHandle(forReadingFrom: staged)
                defer { try? reader.close() }
                while true {
                    guard let data = try reader.read(upToCount: 1 << 20), !data.isEmpty else { break }
                    try writer.write(contentsOf: data)
                }
                try? manager.removeItem(at: staged)
            } else {
                if manager.fileExists(atPath: scratchURL.path) { try? manager.removeItem(at: scratchURL) }
                try manager.moveItem(at: staged, to: scratchURL)
            }
            movedURL = scratchURL
        } catch {
            failure = DownloadError.io(error.localizedDescription)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(error: error)
    }

    // MARK: 收尾

    private func finish(error: Error?) {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        session?.finishTasksAndInvalidate()

        if let error {
            let nsError = error as NSError
            if nsError.code == NSURLErrorCancelled {
                continuation?.resume(throwing: DownloadError.cancelled)
            } else {
                continuation?.resume(throwing: DownloadError.io(error.localizedDescription))
            }
            return
        }
        if let failure {
            continuation?.resume(throwing: failure)
            return
        }
        if movedURL != nil {
            continuation?.resume(returning: ())
            return
        }
        continuation?.resume(throwing: DownloadError.empty)
    }
}

// MARK: - 大小探测

/// 只读响应头、不读正文的探测会话。
final class RangeProber: NSObject, URLSessionDataDelegate {

    private var continuation: CheckedContinuation<RangeProbe, Error>?
    private var session: URLSession?
    private var result: RangeProbe?
    private var statusError: Error?
    private var finished = false
    private let lock = NSLock()

    func run(url: String, headers: [String: String]) async throws -> RangeProbe {
        guard let target = URL(string: url) else { throw DownloadError.io("直链不合法") }
        var request = URLRequest(url: target)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 20
            config.timeoutIntervalForResource = 40
            config.httpShouldSetCookies = false
            let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            self.session = session
            session.dataTask(with: request).resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let http = response as? HTTPURLResponse {
            let contentRange = http.value(forHTTPHeaderField: "Content-Range") ?? ""
            let contentLength = Int64(http.value(forHTTPHeaderField: "Content-Length") ?? "") ?? 0
            let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
            let finalURL = http.url?.absoluteString ?? dataTask.originalRequest?.url?.absoluteString ?? ""
            if let groups = RegexUtil.match("bytes\\s+(\\d+)-(\\d+)/(\\d+|\\*)", in: contentRange),
               groups.count > 3,
               let total = Int64(groups[3]),
               total > 0 {
                result = RangeProbe(
                    totalSize: total,
                    supportsRange: true,
                    finalURL: finalURL,
                    contentType: contentType
                )
            } else if http.statusCode == 200 && contentLength > 0 {
                // 服务器无视了 Range：只能单线程整文件下载
                result = RangeProbe(
                    totalSize: contentLength,
                    supportsRange: false,
                    finalURL: finalURL,
                    contentType: contentType
                )
            } else {
                statusError = DownloadError.badStatus(http.statusCode)
            }
        } else {
            statusError = DownloadError.empty
        }
        // 头部信息已经够用，正文一个字节都不收
        completionHandler(.cancel)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish()
    }

    private func finish() {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        let probe = result
        let failure = statusError
        lock.unlock()

        session?.finishTasksAndInvalidate()

        if let probe = probe {
            continuation?.resume(returning: probe)
        } else {
            continuation?.resume(throwing: failure ?? DownloadError.empty)
        }
    }
}
