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

/// 夸克网盘与 UC 网盘共用同一套私有接口（同一家，只是 host 与 Referer 不同）。
///
/// 三步流程：
/// 1. `sharepage/token`：分享 id + 提取码 → `stoken`（会话票据）；
/// 2. `sharepage/detail`：带 `stoken` 翻目录，拿到 `fid` 与 `share_fid_token`；
/// 3. `sharepage/download`：用 `fid + share_fid_token` 换 CDN 直链（有效期 15~30 分钟）。
///
/// ★ 接口路径与参数取自上游实现（AGPL-3.0，`QuarkApi.kt`）。平台改版时这里会先失败，
///   错误信息里会带上原始 `message`，方便定位是「提取码错」「分享失效」还是「参数变了」。
final class QuarkFamily: PanAPI {

    static let quark = QuarkFamily(platform: .quark, host: "https://drive-pc.quark.cn", referer: "https://pan.quark.cn/")
    static let uc = QuarkFamily(platform: .uc, host: "https://drive-pc.uc.cn", referer: "https://drive.uc.cn/")

    let platform: SharePlatform
    private let host: String
    private let referer: String
    private let client = HTTPClient.desktop

    private init(platform: SharePlatform, host: String, referer: String) {
        self.platform = platform
        self.host = host
        self.referer = referer
    }

    private var commonQuery: String { "pr=ucpro&fr=pc&uc_param_str=" }

    private func headers(cookie: String) -> [String: String] {
        var headers: [String: String] = [
            "Accept": "application/json, text/plain, */*",
            "Origin": referer.hasSuffix("/") ? String(referer.dropLast()) : referer,
            "Referer": referer
        ]
        if !cookie.isEmpty { headers["Cookie"] = cookie }
        return headers
    }

    // MARK: 1. 会话票据

    func snapshot(share: ParsedShare, cookie: String) async throws -> ShareSnapshot {
        let url = "\(host)/1/clouddrive/share/sharepage/token?\(commonQuery)"
        let body: [String: Any] = [
            "pwd_id": share.shareId,
            "passcode": share.pwd ?? ""
        ]
        let json = try await client.postJSON(url, body: body, headers: headers(cookie: cookie), referer: referer)
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
        var components = URLComponents(string: "\(host)/1/clouddrive/share/sharepage/detail")
        components?.queryItems = [
            URLQueryItem(name: "pr", value: "ucpro"),
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

        let json = try await client.getJSON(url, headers: headers(cookie: cookie), referer: referer)
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
        let url = "\(host)/1/clouddrive/share/sharepage/download?\(commonQuery)"
        let body: [String: Any] = [
            "fids": [entry.id],
            "pwd_id": snapshot.shareId,
            "stoken": snapshot.stoken,
            "fid_token_list": [entry.token],
            "pdir_fid": snapshot.dirId,
            "share_id": snapshot.shareId
        ]
        let json = try await client.postJSON(url, body: body, headers: headers(cookie: cookie), referer: referer)
        try Self.check(json, hasPasscode: true, platform: platform)

        guard var link = JSONSearch.string(in: json, keys: ["download_url"]) else {
            throw PanError.message("接口没有返回直链，可能是文件过大或需要转存")
        }
        link = TextUtil.httpsURL(link)

        var downloadHeaders: [String: String] = [
            "User-Agent": HTTPClient.uaDesktop,
            "Referer": referer
        ]
        if !cookie.isEmpty { downloadHeaders["Cookie"] = cookie }

        return ShareDownloadLink(
            url: link,
            fileName: entry.name,
            size: entry.size,
            headers: downloadHeaders,
            platform: platform
        )
    }

    // MARK: 错误映射

    /// 夸克/UC 的业务码：`code == 0` 才是成功；HTTP 200 不代表业务成功。
    private static func check(_ json: [String: Any], hasPasscode: Bool, platform: SharePlatform) throws {
        let code = JSONSearch.num(json, "code")
        let status = JSONSearch.num(json, "status")
        let message = JSONSearch.str(json, "message")
        if code == 0 && (status == 0 || status == 200) { return }
        if code == 0 && status == 0 { return }

        if message.contains("提取码") || message.contains("密码") || code == 41008 {
            throw hasPasscode ? PanError.wrongPasscode : PanError.needPasscode
        }
        if message.contains("不存在") || message.contains("失效") || message.contains("删除") || code == 41006 {
            throw PanError.shareUnavailable(message.isEmpty ? "分享不存在或已失效" : message)
        }
        if status == 401 || code == 31001 || message.contains("登录") {
            throw PanError.needLogin(platform)
        }
        throw PanError.message(message.isEmpty ? "接口返回 \(code)" : "\(message)（code \(code)）")
    }
}
