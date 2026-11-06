import Foundation
import Network

// MARK: - 网络状态

/// 只做一件小事：判断当前是不是 Wi-Fi。
/// 设置里的「仅 Wi-Fi 下载」需要一个可靠信号，`NWPathMonitor` 是系统给的正解。
@MainActor
final class NetworkMonitor: ObservableObject {

    static let shared = NetworkMonitor()

    @Published private(set) var isOnline = true
    @Published private(set) var isWiFi = true

    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let wifi = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
            Task { @MainActor in
                self?.isOnline = online
                self?.isWiFi = wifi
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.yunx.network-monitor"))
    }
}

// MARK: - 取消标记

/// 线程安全的取消标记。
/// 下载 worker 在后台线程轮询它，所以不能用 `@Published` 的布尔值（跨线程读不安全）。
final class CancellationFlag {

    private let lock = NSLock()
    private var value = false

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

// MARK: - 进度盒

/// 分片进度汇总。后台线程写入、主线程定时读取，
/// 这样每来一个 `didWriteData` 就不用往主线程跳一次（一个 13 GB 文件会有上万次回调）。
final class ProgressBox {

    private let lock = NSLock()
    private var chunkBytes: [Int: Int64] = [:]

    func set(_ index: Int, _ bytes: Int64) {
        lock.lock()
        chunkBytes[index] = bytes
        lock.unlock()
    }

    func reset(_ index: Int) {
        lock.lock()
        chunkBytes[index] = 0
        lock.unlock()
    }

    var total: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return chunkBytes.values.reduce(0, +)
    }
}
