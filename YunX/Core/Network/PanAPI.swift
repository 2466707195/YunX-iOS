import Foundation

// MARK: - 网盘适配协议

/// 一个网盘平台的适配器。
///
/// 实现约定（与 Android 版 `*ResolveRepository` 的分层对应）：
/// - 只负责「分享 → 目录 → 直链」这三件事，不碰下载；
/// - 失败一律抛 `PanError`（带语义），不要抛裸 `HTTPError` —— 界面要靠它决定是弹提取码、
///   引导登录、还是提示「平台适配中」；
/// - 取到的直链必须带上该 CDN 真正需要的请求头，下载器会原样使用。
protocol PanAPI {

    var platform: SharePlatform { get }

    /// 打开分享：换会话 token + 拉根目录
    func snapshot(share: ParsedShare, cookie: String) async throws -> ShareSnapshot

    /// 列目录
    func entries(in snapshot: ShareSnapshot, dirId: String, cookie: String) async throws -> [ShareEntry]

    /// 取某个文件的下载直链
    func downloadLink(for entry: ShareEntry, in snapshot: ShareSnapshot, cookie: String) async throws -> ShareDownloadLink
}

// MARK: - 适配器注册表

/// 平台 → 适配器。没注册的平台会得到 `PanError.notImplemented`，
/// 界面据此显示「适配中」而不是转圈到超时。
enum PanRegistry {

    static func api(for platform: SharePlatform) -> PanAPI? {
        switch platform {
        case .quark: return QuarkFamily.quark
        case .uc: return QuarkFamily.uc
        default: return nil
        }
    }

    static func require(_ platform: SharePlatform) throws -> PanAPI {
        guard let api = api(for: platform) else {
            throw PanError.notImplemented(platform)
        }
        return api
    }
}

// MARK: - 夸克 / UC

/// 一家公司的两套皮：夸克网盘与 UC 网盘。接口路径几乎一样，但**域名、query 串、
/// detail 版本号、User-Agent 都不一样**，所以做成一份配置而不是三个方法各写一遍。
private struct QuarkConfig {

    let platform: SharePlatform
    /// 业务 API 域名（不是网页域名）
    let host: String
    /// Origin 头（不带尾斜杠）
    let origin: String
    /// Referer 头（带尾斜杠）
    let referer: String
    /// token / detail 的公共 query
    let shareQuery: String
    /// 分享目录接口路径。UC 走 `v2/detail`，夸克走 `detail`
    let detailPath: String
    /// 取直链的 query。夸克要 `sys=win32&ve=3.23.2`，UC 要 `entry=ft`
    let downloadQuery: String
    /// 业务 API 强制 UA。夸克必须伪装成 PC 客户端，否则取链会被拒
    let userAgent: String
}

/// 夸克网盘 / UC 网盘适配器。
///
/// 三步流程（与上游 `QuarkApi.kt` / `UCApi.kt` 一致）：
/// 1. `share/sharepage/token`：分享 id + 提取码 → `stoken`（会话票据）；
/// 2. `share/sharepage/detail`：带 `stoken` 翻目录，拿到 `fid` 与 `share_fid_token`；
/// 3. **`file/download`**：用 `fids + fids_token + pwd_id + stoken` 换 CDN 直链。
///
/// ★ 第 3 步的路径是 `/1/clouddrive/file/download`，**不是** `/share/sharepage/download`。
///   写成后者会命中服务端不存在的路由，返回 Spring 的
///   `{"timestamp":…,"status":404,"error":"Not Found","message":"No message available"}`，
///   看起来像「接口改版」，其实只是路径拼错了。
final class QuarkFamily: PanAPI {

    /// 夸克 PC 客户端 UA：取链接口按这个 UA 判定环境，换成普通浏览器 UA 会被拒
    static let uaQuark = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) "
        + "quark-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.12-a038f7b798 Safari/537.36 Channel/pckk_other_ch"

    static let uaUC = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) "
        + "Chrome/120.0.0.0 Safari/537.36"

    static let quark = QuarkFamily(config: QuarkConfig(
        platform: .quark,
        host: "https://drive-pc.quark.cn",
        origin: "https://pan.quark.cn",
        referer: "https://pan.quark.cn/",
        shareQuery: "pr=ucpro&fr=pc&uc_param_str=",
        detailPath: "/1/clouddrive/share/sharepage/detail",
        downloadQuery: "pr=ucpro&fr=pc&sys=win32&ve=3.23.2",
        userAgent: uaQuark
    ))

    static let uc = QuarkFamily(config: QuarkConfig(
        platform: .uc,
        host: "https://pc-api.uc.cn",
        origin: "https://drive.uc.cn",
        referer: "https://drive.uc.cn/",
        shareQuery: "pr=UCBrowser&fr=pc",
        detailPath: "/1/clouddrive/share/sharepage/v2/detail",
        downloadQuery: "entry=ft&fr=pc&pr=UCBrowser",
        userAgent: uaUC
    ))

    let platform: SharePlatform
    private let config: QuarkConfig
    private let client = HTTPClient.desktop

    private var host: String { config.host }
    private var referer: String { config.referer }

    private init(config: QuarkConfig) {
        self.platform = config.platform
        self.config = config
    }

    private func headers(cookie: String) -> [String: String] {
        var headers: [String: String] = [
            "Accept": "application/json, text/plain, */*",
            "Origin": config.origin,
            "Referer": config.referer,
            "User-Agent": config.userAgent
        ]
        // 游客（未登录）时**不要**发空的 Cookie 头：上游实测空串会被当成无效会话
        if !cookie.isEmpty { headers["Cookie"] = cookie }
        return headers
    }

    // MARK: 1. 会话票据

    func snapshot(share: ParsedShare, cookie: String) async throws -> ShareSnapshot {
        let url = "\(host)/1/clouddrive/share/sharepage/token?\(config.shareQuery)"
        let body: [String: Any] = [
            "pwd_id": share.shareId,
            "passcode": share.pwd ?? ""
        ]
        let json = try await post(url, body: body, cookie: cookie)
        try Self.check(json, hasPasscode: share.hasPasscode, platform: platform)

        let stoken = JSONSearch.string(in: json, keys: ["stoken"]) ?? ""
        guard !stoken.isEmpty else {
            throw PanError.shareUnavailable("没有拿到分享会话（stoken 为空）")
        }
        let title = JSONSearch.string(in: json, keys: ["title", "share_name"]) ?? share.platform.displayName

        var snapshot = ShareSnapshot(
            platform: platform,
            shareId: share.shareId,
            title: title,
            stoken: stoken
        )
        snapshot.entries = try await entries(in: snapshot, dirId: "0", cookie: cookie)
        return snapshot
    }

    // MARK: 2. 列目录

    func entries(in snapshot: ShareSnapshot, dirId: String, cookie: String) async throws -> [ShareEntry] {
        var components = URLComponents(string: "\(host)\(config.detailPath)")
        components?.queryItems = [
            URLQueryItem(name: "pr", value: platform == .uc ? "UCBrowser" : "ucpro"),
            URLQueryItem(name: "fr", value: "pc"),
            URLQueryItem(name: "pwd_id", value: snapshot.shareId),
            URLQueryItem(name: "stoken", value: snapshot.stoken),
            URLQueryItem(name: "pdir_fid", value: dirId),
            URLQueryItem(name: "force", value: "0"),
            URLQueryItem(name: "_page", value: "1"),
            URLQueryItem(name: "_size", value: "100"),
            URLQueryItem(name: "_fetch_banner", value: "1"),
            URLQueryItem(name: "_fetch_share", value: "1"),
            URLQueryItem(name: "_fetch_total", value: "1"),
            URLQueryItem(name: "_sort", value: "file_type:asc,updated_at:desc")
        ]
        guard let url = components?.url?.absoluteString else {
            throw PanError.message("目录地址构造失败")
        }

        let json = try await get(url, cookie: cookie)
        try Self.check(json, hasPasscode: true, platform: platform)

        let list = JSONSearch.array(in: json, path: ["data", "list"])
        var output: [ShareEntry] = []
        for item in list {
            guard let dict = item as? [String: Any] else { continue }
            if let entry = Self.mapEntry(dict) { output.append(entry) }
        }
        // 文件夹在前、文件在后，各自按名字排序（和网盘网页端一致）
        return output.sorted { left, right in
            if left.isFolder != right.isFolder { return left.isFolder }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
    }

    private static func mapEntry(_ dict: [String: Any]) -> ShareEntry? {
        let fid = JSONSearch.str(dict, "fid")
        guard !fid.isEmpty else { return nil }
        var name = JSONSearch.str(dict, "file_name")
        if name.isEmpty { name = JSONSearch.str(dict, "name") }
        if name.isEmpty { name = "未命名" }
        let isFolder = JSONSearch.bool(dict, "dir")
        let size = JSONSearch.num(dict, "size")
        // ★ 取直链时必须回传这个 token（字段名 share_fid_token），
        //   它和 stoken 绑定，缺了或换了就换不到直链
        let token = JSONSearch.str(dict, "share_fid_token")
        let formatType = JSONSearch.str(dict, "format_type")
        var updated = ""
        let updatedMs = JSONSearch.num(dict, "updated_at")
        if updatedMs > 0 {
            let date = Date(timeIntervalSince1970: TimeInterval(updatedMs) / 1000)
            updated = date.formatted("yyyy-MM-dd HH:mm")
        }
        return ShareEntry(
            id: fid,
            name: name,
            isFolder: isFolder,
            size: isFolder ? 0 : size,
            updatedText: updated,
            mimeHint: formatType,
            token: token
        )
    }

    // MARK: 3. 取直链

    func downloadLink(for entry: ShareEntry, in snapshot: ShareSnapshot, cookie: String) async throws -> ShareDownloadLink {
        guard !entry.token.isEmpty else {
            throw PanError.message("列表里没有 share_fid_token，无法换取直链；请下拉刷新分享后重试")
        }

        let url = "\(host)/1/clouddrive/file/download?\(config.downloadQuery)"
        // 字段名是 fids / fids_token（不是 fid_token_list），pwd_id 与 stoken 一起提交；
        // speedup_session / token 是「社交转存」用的占位，官方前端同样传空串。
        let body: [String: Any] = [
            "fids": [entry.id],
            "fids_token": [entry.token],
            "pwd_id": snapshot.shareId,
            "stoken": snapshot.stoken,
            "speedup_session": "",
            "token": ""
        ]

        let json = try await post(url, body: body, cookie: cookie)
        try Self.checkDownload(json, platform: platform)

        guard let item = JSONSearch.array(in: json, path: ["data"]).first as? [String: Any] else {
            throw PanError.message("接口没有返回直链（data 为空），该文件可能需要先转存到自己的网盘")
        }
        var link = JSONSearch.str(item, "download_url")
        guard !link.isEmpty else {
            throw PanError.message("接口没有返回 download_url，可能是文件过大或该分享限制了直接下载")
        }
        link = TextUtil.httpsURL(link)

        var name = JSONSearch.str(item, "file_name")
        if name.isEmpty { name = JSONSearch.str(item, "filename") }
        if name.isEmpty { name = entry.name }
        let size = JSONSearch.num(item, "size")

        // 直链防盗链：Referer 必须是网页域名，UC 缺了会被限速到 ~100KB/s
        var downloadHeaders: [String: String] = [
            "User-Agent": HTTPClient.uaDesktop,
            "Referer": referer
        ]
        if !cookie.isEmpty { downloadHeaders["Cookie"] = cookie }

        return ShareDownloadLink(
            url: link,
            fileName: name,
            size: size > 0 ? size : entry.size,
            headers: downloadHeaders,
            platform: platform
        )
    }

    // MARK: 请求（统一把 HTTPError 翻成 PanError）

    private func get(_ url: String, cookie: String) async throws -> [String: Any] {
        do {
            return try await client.getJSON(url, headers: headers(cookie: cookie), referer: referer)
        } catch let error as HTTPError {
            throw Self.mapHTTPError(error, platform: platform)
        }
    }

    private func post(_ url: String, body: [String: Any], cookie: String) async throws -> [String: Any] {
        do {
            return try await client.postJSON(url, body: body, headers: headers(cookie: cookie), referer: referer)
        } catch let error as HTTPError {
            throw Self.mapHTTPError(error, platform: platform)
        }
    }

    private static func mapHTTPError(_ error: HTTPError, platform: SharePlatform) -> PanError {
        switch error {
        case .status(let code, let body):
            if code == 401 || code == 403 { return .needLogin(platform) }
            if code == 404 {
                return .message("\(platform.displayName)接口地址不存在（404），平台可能已改版；服务端返回：\(excerpt(body))")
            }
            return .message("服务端返回 \(code)：\(excerpt(body))")
        case .network(let detail):
            return .network(detail)
        case .invalidURL, .decode:
            return .message(error.errorDescription ?? "请求失败")
        }
    }

    private static func excerpt(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 140 ? String(trimmed.prefix(140)) + "…" : trimmed
    }

    // MARK: 错误映射

    /// 夸克/UC 的业务码：`code == 0` 或 `status == 200` 才算成功；HTTP 200 不代表业务成功。
    private static func check(_ json: [String: Any], hasPasscode: Bool, platform: SharePlatform) throws {
        let code = JSONSearch.num(json, "code")
        let status = JSONSearch.num(json, "status")
        let message = JSONSearch.str(json, "message")
        if code == 0 || status == 200 { return }

        if message.contains("提取码") || message.contains("密码") || code == 41008 {
            throw hasPasscode ? PanError.wrongPasscode : PanError.needPasscode
        }
        if message.contains("不存在") || message.contains("失效") || message.contains("删除") || code == 41006 {
            throw PanError.shareUnavailable(message.isEmpty ? "分享不存在或已失效" : message)
        }
        if status == 401 || status == 403 || code == 31001 || message.contains("登录") {
            throw PanError.needLogin(platform)
        }
        throw PanError.message(message.isEmpty ? "接口返回 \(code)" : "\(message)（code \(code)）")
    }

    /// 取直链专用：多出两个码
    /// - `31001` 登录态失效 → 引导登录
    /// - `23018` 游客取链的大小上限（夸克实测约 50MB）→ 必须登录
    private static func checkDownload(_ json: [String: Any], platform: SharePlatform) throws {
        let code = JSONSearch.num(json, "code")
        let status = JSONSearch.num(json, "status")
        let message = JSONSearch.str(json, "message")
        if code == 0 || status == 200 { return }

        switch code {
        case 31001:
            throw PanError.needLogin(platform)
        case 23018:
            throw PanError.message("该文件超过游客可下载的大小上限（约 50MB），请先到「账号」页登录\(platform.displayName)再下载")
        default:
            break
        }
        if status == 401 || status == 403 { throw PanError.needLogin(platform) }
        if code == 41006 || message.contains("不存在") || message.contains("失效") {
            throw PanError.shareUnavailable(message.isEmpty ? "分享已失效，请重新解析" : message)
        }
        throw PanError.message(message.isEmpty ? "取链失败（code \(code)）" : "\(message)（code \(code)）")
    }
}
