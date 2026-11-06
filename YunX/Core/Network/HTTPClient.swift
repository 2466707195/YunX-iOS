import Foundation

// MARK: - 网络错误

enum HTTPError: LocalizedError {

    case invalidURL(String)
    case status(Int, String)
    case network(String)
    case decode(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "链接格式不正确：\(url)"
        case .status(let code, let body):
            let excerpt = body.count > 120 ? String(body.prefix(120)) + "…" : body
            return excerpt.isEmpty ? "服务端返回 \(code)" : "服务端返回 \(code)：\(excerpt)"
        case .network(let detail):
            return detail.isEmpty ? "网络请求失败" : detail
        case .decode(let detail):
            return "响应格式异常：\(detail)"
        }
    }

    var statusCode: Int? {
        if case .status(let code, _) = self { return code }
        return nil
    }
}

// MARK: - 响应

struct HTTPResponse {

    var data: Data
    var status: Int
    var headers: [String: String]
    var finalURL: String

    var text: String {
        String(decoding: data, as: UTF8.self)
    }

    var jsonObject: Any? {
        try? JSONSerialization.jsonObject(with: data)
    }

    var json: [String: Any] {
        (jsonObject as? [String: Any]) ?? [:]
    }

    var isOK: Bool { (200...299).contains(status) }
}

// MARK: - 客户端

/// 轻量 HTTP 客户端。
///
/// 三条约定（与 Android 版 `HttpClients` 对齐）：
/// 1. **不共享 Cookie 存储**：各平台 Cookie 由账号体系显式塞进请求头。
///    系统自动带 Cookie 会造成「登录了 A 平台，请求 B 平台时也带上 A 的 Cookie」；
/// 2. 默认桌面 Chrome UA —— 小红书/B站/微博的登录页与 SSR 数据在移动 UA 下形态不同；
/// 3. 所有错误统一转成 `HTTPError`，只有它需要区分 403（风控）。
final class HTTPClient {

    static let uaMobile = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1"
    static let uaDesktop = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
    static let uaAndroid = "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36"

    /// 全应用共用（会话是 ephemeral，不落盘 Cookie，也不占内存缓存）
    static let shared = HTTPClient()
    /// 桌面 UA 专用（网页登录态、SSR 页面都用它）
    static let desktop = HTTPClient(userAgent: HTTPClient.uaDesktop)
    /// 移动 UA 专用：快手这类站点对桌面 UA 返回的是 SPA 壳页，SSR 数据只在移动端页面上
    static let mobile = HTTPClient(userAgent: HTTPClient.uaMobile)

    private let session: URLSession
    private let userAgent: String
    private let timeout: TimeInterval

    init(userAgent: String = HTTPClient.uaDesktop, timeout: TimeInterval = 20) {
        self.userAgent = userAgent
        self.timeout = timeout
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 3
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpAdditionalHeaders = ["User-Agent": userAgent]
        self.session = URLSession(configuration: config)
    }

    // MARK: 基础请求

    func request(
        _ url: String,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil,
        referer: String? = nil
    ) async throws -> HTTPResponse {
        guard let target = URL(string: url) else { throw HTTPError.invalidURL(url) }
        var request = URLRequest(url: target)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let referer { request.setValue(referer, forHTTPHeaderField: "Referer") }
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = body

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw HTTPError.network("响应不是 HTTP")
            }
            var normalized: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                normalized[String(describing: key).lowercased()] = String(describing: value)
            }
            return HTTPResponse(
                data: data,
                status: http.statusCode,
                headers: normalized,
                finalURL: http.url?.absoluteString ?? url
            )
        } catch let error as HTTPError {
            throw error
        } catch {
            throw HTTPError.network(error.localizedDescription)
        }
    }

    // MARK: 便捷方法

    func get(
        _ url: String,
        headers: [String: String] = [:],
        referer: String? = nil
    ) async throws -> HTTPResponse {
        try await request(url, headers: headers, referer: referer)
    }

    /// 拿 JSON 对象。非 2xx 抛带状态码的错误，风控判断交给上层。
    func getJSON(
        _ url: String,
        headers: [String: String] = [:],
        referer: String? = nil
    ) async throws -> [String: Any] {
        let response = try await get(url, headers: headers, referer: referer)
        guard response.isOK else {
            throw HTTPError.status(response.status, response.text)
        }
        guard let any = response.jsonObject, let object = any as? [String: Any] else {
            let preview = String(decoding: response.data.prefix(160), as: UTF8.self)
            throw HTTPError.decode(preview)
        }
        return object
    }

    func postJSON(
        _ url: String,
        body: [String: Any],
        headers: [String: String] = [:],
        referer: String? = nil
    ) async throws -> [String: Any] {
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
        var merged = headers
        if merged["Content-Type"] == nil { merged["Content-Type"] = "application/json" }
        let response = try await request(url, method: "POST", headers: merged, body: data, referer: referer)
        guard response.isOK else {
            throw HTTPError.status(response.status, response.text)
        }
        guard let any = response.jsonObject, let object = any as? [String: Any] else {
            let preview = String(decoding: response.data.prefix(160), as: UTF8.self)
            throw HTTPError.decode(preview)
        }
        return object
    }

    func postForm(
        _ url: String,
        fields: [String: String],
        headers: [String: String] = [:],
        referer: String? = nil
    ) async throws -> HTTPResponse {
        var components = URLComponents()
        components.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        let body = Data((components.percentEncodedQuery ?? "").utf8)
        var merged = headers
        merged["Content-Type"] = "application/x-www-form-urlencoded"
        return try await request(url, method: "POST", headers: merged, body: body, referer: referer)
    }

    /// 跟随短链重定向，返回最终地址。
    ///
    /// 短链（`v.douyin.com/xxx`、`b23.tv/xxx`、`xhslink.com/xxx`）必须先在服务端展开：
    /// `URLSession` 会自动跟随 30x，我们只需要读最终 `response.url`。
    func expandShortLink(_ url: String, headers: [String: String] = [:]) async throws -> String {
        let response = try await get(url, headers: headers)
        if response.isOK || response.finalURL != url {
            return response.finalURL
        }
        throw HTTPError.status(response.status, "")
    }

    /// **只跟一跳**：返回第一次 3xx 的 `Location`（不跟到终点）。
    ///
    /// 快手要它：`v.kuaishou.com/<码>` / `www.kuaishou.com/short-video/<id>` 都是入口页，
    /// 302 到哪一跳很关键（移动端作品页 `v.m.chenzhongtech.com/fw/photo/...` 才有 SSR 数据），
    /// 而一次性跟到终点会丢掉作品 id。没有重定向时返回 nil。
    func firstRedirectLocation(_ url: String, headers: [String: String] = [:]) async throws -> String? {
        guard let target = URL(string: url) else { throw HTTPError.invalidURL(url) }
        var request = URLRequest(url: target)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        let delegate = RedirectStopDelegate()
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return nil }
        guard (300...399).contains(http.statusCode) else { return nil }
        let location = http.value(forHTTPHeaderField: "Location")
        guard let location, !location.isEmpty else { return nil }
        // Location 可能是协议相对地址
        if location.hasPrefix("//") { return "https:" + location }
        return location
    }
}

// MARK: - 重定向控制

/// 让请求**停在第一次 3xx**：`URLSession` 默认会自动跟到终点，跟完就看不见中间那跳的地址了。
/// 这里拒绝重定向，`data(for:)` 直接把 3xx 响应交回来，我们读它的 `Location`。
private final class RedirectStopDelegate: NSObject, URLSessionTaskDelegate {

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

// MARK: - JSON 递归检索

/// 各平台把数据塞在 `data` / `result` / `props` 好几层里，字段名还经常变。
/// 与其为每个版本写一套强类型模型，不如按「键名 + 值特征」递归找：
/// 找不到就是平台改版了，抛错比静默返回空更早暴露问题。
enum JSONSearch {

    static func string(in object: Any, keys: [String]) -> String? {
        if let dictionary = object as? [String: Any] {
            for key in keys {
                if let value = dictionary[key] as? String, !value.isEmpty, value != "null" {
                    return value
                }
            }
            for value in dictionary.values {
                if let found = string(in: value, keys: keys) { return found }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let found = string(in: value, keys: keys) { return found }
            }
        }
        return nil
    }

    static func strings(in object: Any, keys: [String]) -> [String] {
        var output: [String] = []
        collectStrings(object, keys: keys, into: &output)
        // 去重但保序
        var seen = Set<String>()
        return output.filter { seen.insert($0).inserted }
    }

    private static func collectStrings(_ object: Any, keys: [String], into output: inout [String]) {
        if let dictionary = object as? [String: Any] {
            for key in keys {
                if let value = dictionary[key] as? String, !value.isEmpty, value != "null" {
                    output.append(value)
                } else if let list = dictionary[key] as? [String] {
                    for item in list where !item.isEmpty && item != "null" {
                        output.append(item)
                    }
                }
            }
            for value in dictionary.values {
                collectStrings(value, keys: keys, into: &output)
            }
        } else if let array = object as? [Any] {
            for value in array {
                collectStrings(value, keys: keys, into: &output)
            }
        }
    }

    static func int(in object: Any, keys: [String]) -> Int? {
        if let dictionary = object as? [String: Any] {
            for key in keys {
                if let value = dictionary[key] as? Int { return value }
                if let value = dictionary[key] as? Double { return Int(value) }
                if let value = dictionary[key] as? String, let number = Int(value) { return number }
            }
            for value in dictionary.values {
                if let found = int(in: value, keys: keys) { return found }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let found = int(in: value, keys: keys) { return found }
            }
        }
        return nil
    }

    /// 找出所有包含某个键的字典（例如所有带 `video` 的对象）
    static func dictionaries(in object: Any, containingKey key: String) -> [[String: Any]] {
        var output: [[String: Any]] = []
        if let dictionary = object as? [String: Any] {
            if dictionary[key] != nil { output.append(dictionary) }
            for value in dictionary.values {
                output.append(contentsOf: dictionaries(in: value, containingKey: key))
            }
        } else if let array = object as? [Any] {
            for value in array {
                output.append(contentsOf: dictionaries(in: value, containingKey: key))
            }
        }
        return output
    }

    /// 按路径取值：`value(in: json, path: ["data", "list"])`
    static func value(in object: Any, path: [String]) -> Any? {
        var current: Any? = object
        for key in path {
            if let dictionary = current as? [String: Any] {
                current = dictionary[key]
            } else if let array = current as? [Any], let index = Int(key) {
                current = index < array.count ? array[index] : nil
            } else {
                return nil
            }
        }
        return current
    }

    static func array(in object: Any, path: [String]) -> [Any] {
        value(in: object, path: path) as? [Any] ?? []
    }

    static func dictionary(in object: Any, path: [String]) -> [String: Any] {
        value(in: object, path: path) as? [String: Any] ?? [:]
    }

    static func str(_ dictionary: [String: Any], _ key: String) -> String {
        if let value = dictionary[key] as? String { return value }
        if let value = dictionary[key] as? Int { return String(value) }
        if let value = dictionary[key] as? Int64 { return String(value) }
        if let value = dictionary[key] as? Double { return String(Int64(value)) }
        return ""
    }

    static func num(_ dictionary: [String: Any], _ key: String) -> Int64 {
        if let value = dictionary[key] as? Int64 { return value }
        if let value = dictionary[key] as? Int { return Int64(value) }
        if let value = dictionary[key] as? Double { return Int64(value) }
        if let value = dictionary[key] as? String, let number = Int64(value) { return number }
        return 0
    }

    static func bool(_ dictionary: [String: Any], _ key: String) -> Bool {
        if let value = dictionary[key] as? Bool { return value }
        if let value = dictionary[key] as? Int { return value != 0 }
        if let value = dictionary[key] as? String { return value == "1" || value == "true" }
        return false
    }
}
