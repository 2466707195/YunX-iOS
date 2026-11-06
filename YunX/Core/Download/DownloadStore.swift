import Foundation

// MARK: - 下载文件

/// 下载文件落盘与命名。
///
/// 目录结构（沙盒内，Documents 对用户可见）：
/// ```
/// Documents/YunXDownloads/        ← 成品，文件 App 里能直接看到
/// Library/Application Support/
///   ├─ parts/<taskID>.part        ← 下载中的半成品（预分配大小，按分片偏移写入）
///   ├─ parts/<taskID>.c<N>        ← 分片临时文件（断点续传复用）
///   ├─ tasks.json                 ← 任务账本
///   └─ accounts.json              ← 账号（凭证字段是密文）
/// ```
final class DownloadStore {

    static let shared = DownloadStore()

    private let manager = FileManager.default

    // MARK: 路径

    func fileURL(for fileName: String) -> URL {
        StoragePaths.downloads.appendingPathComponent(FileKind.sanitize(fileName))
    }

    func partURL(for id: UUID) -> URL {
        StoragePaths.parts.appendingPathComponent("\(id.uuidString).part")
    }

    func chunkURL(for id: UUID, index: Int) -> URL {
        StoragePaths.parts.appendingPathComponent("\(id.uuidString).c\(index)")
    }

    /// 清理这条任务的所有临时文件
    func cleanTemps(for id: UUID) {
        let part = partURL(for: id)
        try? manager.removeItem(at: part)
        guard let files = try? manager.contentsOfDirectory(atPath: StoragePaths.parts.path) else { return }
        for file in files where file.hasPrefix(id.uuidString) {
            try? manager.removeItem(at: StoragePaths.parts.appendingPathComponent(file))
        }
    }

    // MARK: 命名

    func existingNames() -> Set<String> {
        let names = (try? manager.contentsOfDirectory(atPath: StoragePaths.downloads.path)) ?? []
        return Set(names)
    }

    func uniqueName(_ name: String) -> String {
        FileKind.uniqueName(FileKind.sanitize(name), existing: existingNames())
    }

    func isDownloaded(_ fileName: String) -> Bool {
        manager.fileExists(atPath: fileURL(for: fileName).path)
    }

    func deleteFile(named fileName: String) {
        try? manager.removeItem(at: fileURL(for: fileName))
    }

    // MARK: 落盘

    /// 半成品 → 成品。同名时自动加 (1)。
    @discardableResult
    func commit(taskID: UUID, fileName: String) throws -> URL {
        let part = partURL(for: taskID)
        guard manager.fileExists(atPath: part.path) else {
            throw DownloadError.io("半成品文件不存在")
        }
        let finalName = uniqueName(fileName)
        let destination = fileURL(for: finalName)
        if manager.fileExists(atPath: destination.path) {
            try? manager.removeItem(at: destination)
        }
        try manager.moveItem(at: part, to: destination)
        cleanTemps(for: taskID)
        return destination
    }

    /// 单文件直存（HLS 合并、合轨产物等已经是一个完整文件）
    @discardableResult
    func move(tempURL: URL, fileName: String) throws -> URL {
        let finalName = uniqueName(fileName)
        let destination = fileURL(for: finalName)
        if manager.fileExists(atPath: destination.path) {
            try? manager.removeItem(at: destination)
        }
        try manager.moveItem(at: tempURL, to: destination)
        return destination
    }

    func totalBytes() -> Int64 {
        StoragePaths.usedSpace()
    }

    /// 已下载文件列表（本机素材页用）
    func localFiles() -> [URL] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let files = try? manager.contentsOfDirectory(
            at: StoragePaths.downloads,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return files
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true }
            .sorted { left, right in
                let l = (try? left.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let r = (try? right.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return l > r
            }
    }
}
