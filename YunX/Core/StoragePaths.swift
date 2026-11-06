import Foundation

// MARK: - 存储位置

/// 统一的目录约定。
///
/// - `downloads`：**用户可见**（Documents + `UIFileSharingEnabled`），文件 App 里能直接看到、拖走；
/// - `support`：应用私有（Application Support），放任务账本、账号、备份；
/// - `cache`：可随时被系统清掉的缩略图/临时分片。
///
/// iOS 没有 Android 那种「自定义保存目录」的自由度 —— 沙盒里只有 Documents 对用户可见，
/// 所以设置页的「下载保存目录」只做说明，不提供假的选择器。
enum StoragePaths {

    static let fileManager = FileManager.default

    static var documents: URL {
        ensure(fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents"))
    }

    static var downloads: URL {
        ensure(documents.appendingPathComponent("YunXDownloads", isDirectory: true))
    }

    static var support: URL {
        ensure(fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support"))
    }

    static var cache: URL {
        ensure(fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory()))
    }

    /// 私有 JSON 账本文件
    static func supportFile(_ name: String) -> URL {
        support.appendingPathComponent(name)
    }

    /// 下载中的临时分片目录
    static var parts: URL {
        ensure(support.appendingPathComponent("parts", isDirectory: true))
    }

    @discardableResult
    private static func ensure(_ url: URL) -> URL {
        if !fileManager.fileExists(atPath: url.path) {
            try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    /// 剩余空间（字节）。写大文件前做预检，避免下到一半撑爆。
    static func freeSpace() -> Int64 {
        guard let values = try? documents.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let capacity = values.volumeAvailableCapacityForImportantUsage else { return 0 }
        return Int64(capacity)
    }

    /// 下载目录里已占用的空间
    static func usedSpace() -> Int64 {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let files = try? fileManager.contentsOfDirectory(
            at: downloads,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for file in files {
            if let values = try? file.resourceValues(forKeys: Set(keys)),
               values.isRegularFile == true {
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }
}

// MARK: - 轻量 JSON 落盘

/// 小账本（任务列表、账号、收藏）统一走这里：原子写 + 失败不抛。
enum JSONDisk {

    static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(T.self, from: data)
    }

    @discardableResult
    static func save<T: Encodable>(_ value: T, to url: URL) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
