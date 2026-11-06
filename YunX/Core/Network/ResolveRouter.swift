import Foundation

// MARK: - 解析分流

/// 一条粘贴文本的归属。
enum ResolvedTarget {

    /// GitHub 仓库（可以直接列 Release 资源下载）
    case github(owner: String, repo: String)
    /// 视频 / 图集平台
    case video(DetectedVideoLink)
    /// 网盘分享
    case share(ParsedShare)
    /// 认不出来
    case unknown
}

/// 解析页的**唯一**分流入口。
///
/// 优先级：GitHub → 视频 → 网盘。
/// 顺序不能反：`pan.baidu.com` 和 `bilibili.com` 的链接互不重叠，但
/// 抖音/快手的分享文案经常同时带网盘链接，先认视频能少一次误判。
enum ResolveRouter {

    private static let githubPattern = "github\\.com/([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)"

    static func route(_ text: String) -> ResolvedTarget {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unknown }

        if let groups = RegexUtil.match(githubPattern, in: trimmed), groups.count > 2 {
            var repo = groups[2]
            if repo.hasSuffix(".git") { repo = String(repo.dropLast(4)) }
            let reserved: Set<String> = ["login", "join", "about", "pricing", "features", "settings", "notifications"]
            if !reserved.contains(groups[1].lowercased()), !repo.isEmpty {
                return .github(owner: groups[1], repo: repo)
            }
        }

        if let video = VideoLinkParser.parse(trimmed) {
            return .video(video)
        }

        if let share = ShareLinkParser.parse(trimmed) {
            return .share(share)
        }

        return .unknown
    }

    /// 给用户看的一句话：识别到了什么
    static func describe(_ target: ResolvedTarget) -> String {
        switch target {
        case .github(let owner, let repo): return "GitHub · \(owner)/\(repo)"
        case .video(let link): return link.platform.displayName
        case .share(let share):
            return share.platform.displayName + (share.hasPasscode ? " · 已带提取码" : "")
        case .unknown: return "未识别"
        }
    }
}
