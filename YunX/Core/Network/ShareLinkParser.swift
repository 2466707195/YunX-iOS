import Foundation

// MARK: - 网盘分享链接识别

/// 从分享链接或整段分享文案里提取 share_id 与提取码。
///
/// 规则全部照搬上游 `ShareLinkParser.kt`（逐条核对），包括几个容易踩的点：
/// - 百度 surl 要去掉开头的 `1`（verify/list 接口用的是 1 后面的部分）；
/// - 123 云盘有三种链接形态（`/s/<key>`、`<uid>.share.123pan.cn/123pan/<key>`、`api/srr?sk=<key>`）；
/// - 115 除了 `/s/<code>`，还有口令形态 `115.com/sws8lxs36jf-n307/`（code-提取码）；
/// - 蓝奏云的域名族有 `lanzou*` / `lan[zs]o[ux]` / `lanzn`，且**必须先判优享版**（ilanzou），
///   否则 `www.ilanzou.com` 里的 `lanzou.com` 会被误判。
enum ShareLinkParser {

    private static let quarkShareId = "pan\\.quark\\.cn/s/([A-Za-z0-9]+)"
    private static let ucShareId = "drive\\.uc\\.cn/s/([A-Za-z0-9]+)"
    private static let xunleiShareId = "pan\\.xunlei\\.com/s/([A-Za-z0-9_-]+)"
    private static let baiduShareId = "pan\\.baidu\\.com/s/(1[A-Za-z0-9_-]+)"
    private static let c139ShareId = "yun\\.139\\.com/shareweb/.*?/w/i/([A-Za-z0-9_-]+)"
    private static let pan123ShareId = "123(?:865|pan)\\.(?:com|cn)/s/([A-Za-z0-9]+-[A-Za-z0-9]+)"
    private static let pan123Sub = "share\\.123pan\\.cn/123pan/([A-Za-z0-9-]+)"
    private static let pan123Srr = "api/srr\\?sk=([A-Za-z0-9-]+)"
    private static let pan115ShareId = "115(?:cdn|rc)?\\.com/s/(sw[A-Za-z0-9]+)"
    private static let pan115Command = "115(?:cdn|rc)?\\.com/(sw[A-Za-z0-9]{8,})-([A-Za-z0-9]{4,8})"
    private static let guangyaShareId = "guangyapan\\.com/s/([A-Za-z0-9_-]+)"
    private static let ilanzouShareId = "(?:^|[/.])ilanzou\\.(?:com|net|org|cn)/s/([A-Za-z0-9_-]+)"
    private static let lanzouShareId = "(?:^|[/.])(?:lanzou[a-z0-9-]*|lan[zs]o[ux]|lanzn)\\.(?:com|net|org|cn)/([A-Za-z0-9]+)"

    /// 提取码参数：`?pwd=`（夸克/UC/百度/迅雷/139/123/光鸭）
    private static let pwdInURL = "[?&]pwd=([A-Za-z0-9]+)"
    /// 115 用 `?password=`
    private static let passwordIn115URL = "[?&]password=([A-Za-z0-9]+)"
    /// 蓝奏云的四种参数名
    private static let pwdInLanzouURL = "[?&](?:pwd|pass|passcode|password)=([A-Za-z0-9]+)"
    /// 文案里的「提取码：abcd」
    private static let pwdInText = "(?:提取码|访问码|密码|提取碼|密碼)[：:]\\s*([A-Za-z0-9]{4,8})"

    /// 识别文本里的网盘链接；识别不到返回 nil。
    static func parse(_ text: String) -> ParsedShare? {
        guard let url = TextUtil.firstURL(in: text) else { return nil }

        func pwd(_ pattern: String) -> String? {
            RegexUtil.firstGroup(pattern, in: url) ?? RegexUtil.firstGroup(pwdInText, in: text)
        }

        if let id = RegexUtil.firstGroup(quarkShareId, in: url) {
            return ParsedShare(shareId: id, pwd: pwd(pwdInURL), platform: .quark)
        }
        if let id = RegexUtil.firstGroup(ucShareId, in: url) {
            return ParsedShare(shareId: id, pwd: pwd(pwdInURL), platform: .uc)
        }
        if let id = RegexUtil.firstGroup(xunleiShareId, in: url) {
            return ParsedShare(shareId: id, pwd: pwd(pwdInURL), platform: .xunlei)
        }
        if let id = RegexUtil.firstGroup(baiduShareId, in: url) {
            // 百度 surl 不含开头的 "1"
            let surl = String(id.dropFirst())
            return ParsedShare(shareId: surl, pwd: pwd(pwdInURL), platform: .baidu)
        }
        if let id = RegexUtil.firstGroup(c139ShareId, in: url) {
            return ParsedShare(shareId: id, pwd: pwd(pwdInURL), platform: .c139)
        }
        if let id = RegexUtil.firstGroup(pan123ShareId, in: url) {
            return ParsedShare(shareId: id, pwd: pwd(pwdInURL), platform: .pan123)
        }
        if let id = RegexUtil.firstGroup(pan123Sub, in: url) {
            return ParsedShare(shareId: id, pwd: pwd(pwdInURL), platform: .pan123)
        }
        if let id = RegexUtil.firstGroup(pan123Srr, in: url) {
            return ParsedShare(shareId: id, pwd: pwd(pwdInURL), platform: .pan123)
        }
        if let id = RegexUtil.firstGroup(pan115ShareId, in: url) {
            return ParsedShare(shareId: id, pwd: pwd(passwordIn115URL), platform: .pan115)
        }
        // 115 口令：code-提取码 都在路径里
        if let groups = RegexUtil.match(pan115Command, in: url), groups.count > 2 {
            return ParsedShare(shareId: groups[1], pwd: groups[2], platform: .pan115)
        }
        if let id = RegexUtil.firstGroup(guangyaShareId, in: url) {
            return ParsedShare(shareId: id, pwd: pwd(pwdInURL), platform: .guangya)
        }
        // 优享版必须先判，避免被蓝奏云的域名规则吃掉
        if let id = RegexUtil.firstGroup(ilanzouShareId, in: url) {
            return ParsedShare(shareId: id, pwd: pwd(pwdInLanzouURL), platform: .ilanzou)
        }
        if let id = RegexUtil.firstGroup(lanzouShareId, in: url) {
            return ParsedShare(shareId: id, pwd: pwd(pwdInLanzouURL), platform: .lanzou)
        }
        return nil
    }

    /// 剪贴板建议用：这段文本里有没有可解析的网盘链接
    static func looksLikeShareLink(_ text: String) -> Bool {
        parse(text) != nil
    }

    /// 分享 id → 规范化后的分享页地址（失败时「用浏览器打开」兜底）
    static func webURL(for share: ParsedShare) -> String {
        switch share.platform {
        case .quark: return "https://pan.quark.cn/s/\(share.shareId)"
        case .uc: return "https://drive.uc.cn/s/\(share.shareId)"
        case .xunlei: return "https://pan.xunlei.com/s/\(share.shareId)"
        case .baidu: return "https://pan.baidu.com/s/1\(share.shareId)"
        case .c139: return "https://yun.139.com/shareweb/#/w/i/\(share.shareId)"
        case .pan123: return "https://www.123pan.com/s/\(share.shareId)"
        case .pan115: return "https://115.com/s/\(share.shareId)"
        case .guangya: return "https://www.guangyapan.com/s/\(share.shareId)"
        case .ilanzou: return "https://www.ilanzou.com/s/\(share.shareId)"
        case .lanzou: return "https://www.lanzou.com/\(share.shareId)"
        case .github: return share.shareId
        }
    }
}
