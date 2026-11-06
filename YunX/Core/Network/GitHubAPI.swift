import Foundation

// MARK: - GitHub 仓库

/// GitHub 仓库 / Release 解析。
///
/// 上游把 GitHub 也当成一个「网盘」：粘贴仓库地址就能列 Release 里的安装包直接下载。
/// 这里只做只读查询（不需要 token），未登录每小时 60 次限额，够个人用。
enum GitHubAPI {

    private static let client = HTTPClient.desktop

    private static var headers: [String: String] {
        [
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28"
        ]
    }

    static func releaseAssets(owner: String, repo: String) async throws -> (title: String, links: [ShareDownloadLink]) {
        let url = "https://api.github.com/repos/\(owner)/\(repo)/releases/latest"
        do {
            let json = try await client.getJSON(url, headers: headers, referer: "https://github.com")
            let tag = JSONSearch.str(json, "tag_name")
            let name = JSONSearch.str(json, "name")
            let title = name.isEmpty ? "\(owner)/\(repo) \(tag)" : "\(owner)/\(repo) \(name)"
            var links: [ShareDownloadLink] = []
            for item in JSONSearch.array(in: json, path: ["assets"]) {
                guard let asset = item as? [String: Any] else { continue }
                let fileName = JSONSearch.str(asset, "name")
                let downloadURL = JSONSearch.str(asset, "browser_download_url")
                guard !fileName.isEmpty, !downloadURL.isEmpty else { continue }
                links.append(ShareDownloadLink(
                    url: downloadURL,
                    fileName: fileName,
                    size: JSONSearch.num(asset, "size"),
                    headers: ["User-Agent": HTTPClient.uaDesktop],
                    platform: .github
                ))
            }
            if links.isEmpty {
                throw PanError.message("该仓库的最新 Release 里没有可下载的资源")
            }
            return (title, links)
        } catch let error as HTTPError {
            if error.statusCode == 404 {
                throw PanError.message("仓库或 Release 不存在（私有仓库需要带 token，暂不支持）")
            }
            if error.statusCode == 403 {
                throw PanError.message("GitHub 接口限流了（每小时 60 次），请过一会儿再试")
            }
            throw PanError.message(error.localizedDescription)
        }
    }
}
