import Foundation

// MARK: - 抖音

/// 抖音解析：**隐藏 WebView 真跑一遍页面**，从页面自己的详情响应里取数。
///
/// 为什么不能只走 HTTP（2026-10 实测）：`iesdouyin.com/share/{video|note}/<id>/` 会 302 到
/// `www.douyin.com/{video|note}/<id>`，纯 HTTP 拿到的是一张 `byted_acrawler` 的 JS 挑战页
/// （用 `__ac_nonce` 算出 `__ac_signature` 写回 Cookie 再 `location.reload()`），页面里
/// 根本没有作品数据；而真页面里的数据也不在任何 SSR 全局变量里（`RENDER_DATA` 只有应用配置），
/// 要么渲染进 DOM，要么靠页面自己发 `aweme/v1/web/aweme/detail` 才拿回来。
/// 这两步都只有「真的把页面跑起来」才能过 —— 在解析器里改字段名是没用的。
///
/// 视频 和 图文（note / slides）**是两条不同的前端路由**，同一个 id 走错路由页面会空着，
/// 所以这里按「多通道 + 早退 + 诊断」来跑：
/// 1. `www.douyin.com/{note|video}/<id>`（桌面 UA，PC 详情页）；
/// 2. `www.iesdouyin.com/share/{note|video}/<id>/?from_ssr=1`（手机 UA，移动分享页）；
/// 3. 还不行就把另一种路由也试一遍（用户从短链进来时，类型可能判断错）。
///
/// 注入（文档开始前）：XHR 钩子 + `fetch` 钩子 + `navigator.platform` 伪装。
/// 取数优先级：钩子拿到的详情（视频直链 / 图文图集都在里面）→ SSR `#RENDER_DATA` → DOM。
///
/// HTTP + SSR 那条老路只作回退保留（抖音万一回退回去时还有用）。
struct DouyinParser: VideoParser {

    let platform: VideoPlatform = .douyin

    /// 桌面 UA：站点是 PC 版详情页，桌面 UA 才走「服务端直出 + 页面自取详情」那条分支
    private let webUA = HTTPClient.uaDesktop

    /// 媒体直链请求头（CDN 静态文件，只认 UA + Referer，不需要 Cookie）
    private var mediaHeaders: [String: String] {
        ["User-Agent": HTTPClient.uaMobile, "Referer": "https://www.douyin.com/"]
    }

    func parse(link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        guard !link.id.isEmpty else {
            throw VideoParseError(.unsupported, "抖音短链没能展开出作品 id")
        }

        // ① 主路线：隐藏 WebView（纯 HTTP 已经拿不到数据）
        let (payload, notes) = await fetchViaWebView(link: link)
        if let payload {
            return build(link: link, payload: payload)
        }

        // ② 回退：老的 SSR 路线（报错时带上各通道的实测状态，方便一眼定位）
        return try await parseViaSSR(link: link, cookie: cookie, webNotes: notes)
    }

    // MARK: WebView 路线

    private struct WebPayload {
        var title: String
        var desc: String
        var author: String
        var video: String
        var images: [String]
        var motions: [String]
        var cover: String
    }

    /// 一次尝试 = 一个落地页 + 一套取数脚本
    private struct PageCandidate {
        let label: String
        let url: String
        let userAgent: String
        /// 图文 / 动图页的图只有「作品图」一种，DOM 兜底可以放宽（视频页不行：封面和推荐图会混进来）
        let relaxImages: Bool
    }

    private func candidates(for link: DetectedVideoLink) -> [PageCandidate] {
        // ★ 类型只能从链接判断：`share/note/…`、`share/slides/…` 都是图文
        let isNote = link.url.contains("/note/") || link.url.contains("/slides/")
        let primary = isNote ? "note" : "video"
        let secondary = isNote ? "video" : "note"
        return [
            PageCandidate(
                label: "pc-\(primary)",
                url: "https://www.douyin.com/\(primary)/\(link.id)",
                userAgent: webUA,
                relaxImages: primary == "note"
            ),
            PageCandidate(
                label: "share-\(primary)",
                url: "https://www.iesdouyin.com/share/\(primary)/\(link.id)/?from_ssr=1&region=CN",
                userAgent: HTTPClient.uaMobile,
                relaxImages: primary == "note"
            ),
            PageCandidate(
                label: "m-\(primary)",
                url: "https://m.douyin.com/share/\(primary)/\(link.id)",
                userAgent: HTTPClient.uaMobile,
                relaxImages: primary == "note"
            ),
            PageCandidate(
                label: "pc-\(secondary)",
                url: "https://www.douyin.com/\(secondary)/\(link.id)",
                userAgent: webUA,
                relaxImages: secondary == "note"
            )
        ]
    }

    /// 依次尝试；返回 payload（成功时）和每个通道的实测说明（失败时拼进报错）。
    private func fetchViaWebView(link: DetectedVideoLink) async -> (WebPayload?, [String]) {
        var notes: [String] = []
        // 总预算 60s：单通道最多 20s，剩下的时间留给下一个通道
        let deadline = Date().addingTimeInterval(60)

        for candidate in candidates(for: link) {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 8 else {
                notes.append("\(candidate.label):预算用尽")
                break
            }

            let outcome = await HeadlessWebView.shared.loadAndExtract(
                url: candidate.url,
                userAgent: candidate.userAgent,
                readyCheckJS: Self.readyCheckJS(relaxImages: candidate.relaxImages),
                extractJS: Self.extractJS(awemeID: link.id, relaxImages: candidate.relaxImages),
                diagnoseJS: Self.diagnoseJS,
                timeout: min(20, remaining),
                // 图文页的图是懒加载的，多等一会儿让轮播把整册铺开
                settle: candidate.relaxImages ? 0.9 : 0.3,
                documentStartScripts: [Self.detailHookJS] + WebViewDisguise.scripts(for: candidate.userAgent)
            )

            guard let json = outcome.json,
                  let data = json.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                notes.append("\(candidate.label):\(outcome.diagnostics)")
                continue
            }
            if let error = object["error"] as? String, !error.isEmpty {
                notes.append("\(candidate.label):\(error)[\(outcome.diagnostics)]")
                continue
            }

            let images = (object["images"] as? [Any])?.compactMap { $0 as? String } ?? []
            let motions = (object["motions"] as? [Any])?.compactMap { $0 as? String } ?? []
            let video = JSONSearch.str(object, "video")
            guard !images.isEmpty || !video.isEmpty else {
                let src = JSONSearch.str(object, "src")
                let ssr = JSONSearch.str(object, "ssr")
                notes.append("\(candidate.label):无媒体(src=\(src.isEmpty ? "?" : src),ssr=\(ssr.isEmpty ? "?" : ssr))")
                continue
            }

            notes.append("\(candidate.label):ok(src=\(JSONSearch.str(object, "src")))")
            return (WebPayload(
                title: JSONSearch.str(object, "title"),
                desc: JSONSearch.str(object, "desc"),
                author: JSONSearch.str(object, "author"),
                video: video,
                images: images,
                motions: motions,
                cover: JSONSearch.str(object, "cover")
            ), notes)
        }

        return (nil, notes)
    }

    private func build(link: DetectedVideoLink, payload: WebPayload) -> VideoParseResult {
        let base = TextUtil.fileName(payload.title, fallback: "douyin_\(link.id)", ext: "")
        var medias: [VideoMedia] = []

        if !payload.images.isEmpty {
            for index in payload.images.indices {
                let raw = payload.images[index]
                guard !raw.isEmpty else { continue }
                let motion = index < payload.motions.count ? payload.motions[index] : ""
                let ext = motion.isEmpty ? Self.imageExtension(url: raw) : "jpg"
                medias.append(VideoMedia(
                    url: TextUtil.httpsURL(raw),
                    kind: .image,
                    fileName: "\(base)_\(index + 1).\(ext)",
                    size: -1,
                    headers: mediaHeaders,
                    quality: motion.isEmpty ? "原图" : "动图",
                    motionUrl: motion.isEmpty ? "" : TextUtil.httpsURL(motion)
                ))
            }
        } else if !payload.video.isEmpty {
            let url = payload.video
                .replacingOccurrences(of: "/playwm/", with: "/play/")
                .replacingOccurrences(of: "playwm", with: "play")
            medias.append(VideoMedia(
                url: TextUtil.httpsURL(url),
                kind: .video,
                fileName: "\(base).\(ParserSupport.extensionForVideo(url: url))",
                size: -1,
                headers: mediaHeaders,
                quality: "无水印"
            ))
        }

        return VideoParseResult(
            platform: platform,
            title: payload.title.isEmpty ? "抖音作品" : payload.title,
            author: payload.author,
            cover: TextUtil.httpsURL(payload.cover.isEmpty ? (payload.images.first ?? "") : payload.cover),
            text: payload.desc.isEmpty ? payload.title : payload.desc,
            url: payload.images.isEmpty ? "https://www.douyin.com/video/\(link.id)" : "https://www.douyin.com/note/\(link.id)",
            medias: medias
        )
    }

    private static func imageExtension(url: String) -> String {
        let lower = url.lowercased()
        if lower.contains(".webp") { return "webp" }
        if lower.contains(".png") { return "png" }
        if lower.contains(".jpeg") || lower.contains(".jpg") { return "jpg" }
        return "jpg"
    }

    // MARK: HTTP + SSR 回退

    private func parseViaSSR(link: DetectedVideoLink, cookie: String, webNotes: [String]) async throws -> VideoParseResult {
        let isNote = link.url.contains("/note/") || link.url.contains("/slides/")
        let webDetail = webNotes.isEmpty ? "未尝试" : webNotes.joined(separator: " / ")

        do {
            var headers: [String: String] = [
                "User-Agent": HTTPClient.uaMobile,
                "Referer": "https://www.iesdouyin.com/",
                "Accept-Language": "zh-CN,zh;q=0.9"
            ]
            if !cookie.isEmpty { headers["Cookie"] = cookie }

            // ★ 图文必须走 share/note，视频必须走 share/video：走错路由页面能开但没有作品数据
            let type = isNote ? "note" : "video"
            let shareURL = "https://www.iesdouyin.com/share/\(type)/\(link.id)/?from_ssr=1&region=CN"
            let response = try await HTTPClient.shared.get(shareURL, headers: headers)
            guard response.isOK else {
                throw VideoParseError(.blocked, "分享页返回 \(response.status)（web: \(webDetail)）")
            }
            let html = response.text
            guard let payload = HTMLPayload.jsonObject(afterAny: ["window._ROUTER_DATA"], in: html) else {
                throw VideoParseError(.unknown, "抖音分享页里没有 window._ROUTER_DATA（被风控拦成挑战页或平台改版）[web: \(webDetail)]")
            }

            let page = JSONSearch.dictionary(in: payload, path: ["loaderData", "\(type)_(id)/page"])
            let info = JSONSearch.dictionary(in: page, path: ["videoInfoRes"])
            let items = JSONSearch.array(in: info, path: ["item_list"])
            guard let item = items.first as? [String: Any] else {
                // 服务端没给作品数据：页面本身不报错（HTTP 200），只是没有 videoInfoRes。
                // 把实测到的事实带进报错里，让「哪层缺了 / id 对不对 / 是否被判成爬虫」一眼可辨。
                let echoed = JSONSearch.str(page, "itemId").isEmpty ? "缺失" : JSONSearch.str(page, "itemId")
                let detail = "route=\(type), videoInfoRes=\(info.isEmpty ? "缺失" : "存在"), item_list=\(items.count), itemId=\(echoed), 请求id=\(link.id)"
                throw VideoParseError(
                    .unknown,
                    "抖音没有返回该作品的数据（作品不可见 / 需要登录 / 平台改版）[\(detail)] [web: \(webDetail)]"
                )
            }

            let video = JSONSearch.dictionary(in: item, path: ["video"])
            let author = JSONSearch.dictionary(in: item, path: ["author"])
            let title = JSONSearch.str(item, "desc")
            let base = TextUtil.fileName(title, fallback: "douyin_\(link.id)", ext: "")
            var medias: [VideoMedia] = []

            let images = JSONSearch.array(in: item, path: ["images"])
            for (index, raw) in images.enumerated() {
                guard let dict = raw as? [String: Any],
                      let url = JSONSearch.strings(in: dict, keys: ["url_list"]).first,
                      let media = ParserSupport.imageMedia(
                        url: url,
                        fileName: "\(base)_\(index + 1).jpg",
                        quality: "原图",
                        headers: mediaHeaders
                      ) else { continue }
                medias.append(media)
            }

            let playAddr = JSONSearch.dictionary(in: video, path: ["play_addr"])
            var videoURL = JSONSearch.strings(in: playAddr, keys: ["url_list"]).first ?? ""
            let uri = JSONSearch.str(playAddr, "uri")

            if videoURL.isEmpty, !uri.isEmpty {
                videoURL = "https://aweme.snssdk.com/aweme/v1/play/?video_id=\(uri)&ratio=1080p&line=0"
            }
            if !videoURL.isEmpty {
                let cleaned = videoURL
                    .replacingOccurrences(of: "/playwm/", with: "/play/")
                    .replacingOccurrences(of: "playwm", with: "play")
                medias.append(VideoMedia(
                    url: TextUtil.httpsURL(cleaned),
                    kind: .video,
                    fileName: "\(base).\(ParserSupport.extensionForVideo(url: cleaned))",
                    size: -1,
                    headers: mediaHeaders,
                    quality: "无水印"
                ))
            }

            guard !medias.isEmpty else {
                throw VideoParseError(.unknown, "抖音作品里没有可下载的图片或视频（作品可能已删除或不可见）")
            }

            let cover = JSONSearch.strings(in: JSONSearch.dictionary(in: video, path: ["cover"]), keys: ["url_list"]).first
                ?? JSONSearch.strings(in: JSONSearch.dictionary(in: video, path: ["origin_cover"]), keys: ["url_list"]).first
                ?? ""

            return VideoParseResult(
                platform: platform,
                title: title.isEmpty ? "抖音作品" : title,
                author: JSONSearch.str(author, "nickname"),
                avatar: TextUtil.httpsURL(JSONSearch.strings(in: JSONSearch.dictionary(in: author, path: ["avatar_thumb"]), keys: ["url_list"]).first ?? ""),
                cover: TextUtil.httpsURL(cover),
                text: title,
                timestampSeconds: JSONSearch.num(item, "create_time"),
                url: "https://www.douyin.com/\(isNote ? "note" : "video")/\(link.id)",
                medias: medias
            )
        } catch {
            throw ParserSupport.translate(error)
        }
    }

    // MARK: 注入脚本

    /// 「文档开始前」注入：把页面**自己发出的**作品详情响应原文存到 `window.__yunxAwemeDetail`。
    ///
    /// ★ 为什么抓接口而不是抓 DOM：详情接口的响应才是干净的结构化数据 —— 图文页 `innerText`
    ///   只有一百多字（图都在轮播里），视频页播放器还可能走 MSE（`blob:`）拿不到直链。
    /// ★ 必须钩在文档开始前：挂晚了页面自己的请求已经发完。
    /// ★ **XHR 和 fetch 都要钩**：抖音不同路由混着用（图文页大量走 fetch），只钩 XHR 会一直不就绪。
    /// ★ 只收成功的、响应体里带 `aweme_detail` / `aweme_list` / `image_post_info` 的。
    private static let detailHookJS = """
    (function () {
      try {
        if (window.__yunxDetailHookInstalled) return;
        window.__yunxDetailHookInstalled = true;
        function interesting(url) {
          if (!url) return false;
          return url.indexOf('aweme/detail') >= 0
              || url.indexOf('aweme/post') >= 0
              || url.indexOf('note/detail') >= 0;
        }
        function keep(text) {
          try {
            if (!text || text.length < 40) return;
            if (text.indexOf('aweme_detail') < 0
                && text.indexOf('aweme_list') < 0
                && text.indexOf('image_post_info') < 0) return;
            window.__yunxAwemeDetail = text;
          } catch (e) {}
        }
        // ---- XHR ----
        var rawOpen = XMLHttpRequest.prototype.open;
        var rawSend = XMLHttpRequest.prototype.send;
        XMLHttpRequest.prototype.open = function (method, url) {
          try { this.__yunxUrl = String(url || ''); } catch (e) { this.__yunxUrl = ''; }
          return rawOpen.apply(this, arguments);
        };
        XMLHttpRequest.prototype.send = function () {
          var xhr = this;
          try {
            xhr.addEventListener('load', function () {
              try {
                if (!interesting(xhr.__yunxUrl)) return;
                if (xhr.status !== 200) return;
                // 不能只读 responseText：responseType 是 'json' 时会抛 InvalidStateError，
                // 被 try 吞掉 → 钩子永远拿不到值（表现就是「一直不就绪」）
                var text = '';
                try { text = xhr.responseText || ''; } catch (e) { text = ''; }
                if (!text) {
                  try {
                    var r = xhr.response;
                    if (r) text = (typeof r === 'string') ? r : JSON.stringify(r);
                  } catch (e) { text = ''; }
                }
                keep(text);
              } catch (e) {}
            });
          } catch (e) {}
          return rawSend.apply(this, arguments);
        };
        // ---- fetch ----
        var rawFetch = window.fetch;
        if (rawFetch) {
          window.fetch = function (input, init) {
            var url = '';
            try {
              url = (typeof input === 'string') ? input : ((input && input.url) || '');
            } catch (e) { url = ''; }
            var promise = rawFetch.apply(this, arguments);
            try {
              if (interesting(url)) {
                promise.then(function (res) {
                  try {
                    if (!res) return;
                    if (res.status && res.status !== 200) return;
                    res.clone().text().then(keep).catch(function () {});
                  } catch (e) {}
                }).catch(function () {});
              }
            } catch (e) {}
            return promise;
          };
        }
      } catch (e) {}
    })()
    """

    /// 就绪判据：钩子拿到详情 **或** DOM 出现真正的作品图（两条路任一条成立即可）；
    /// 页面明确「作品不存在」时立刻返回 `abort`，不再白等 26 秒。
    ///
    /// 不能按链接里的类型分支：`/video/<id>`、`?modal_id=<id>` 都会被抖音 302 到真正的作品页
    /// （图文会落到 `/note/<id>`），「按链接判类型」必然判错，只能干等超时。
    /// DOM 那条只认 `biz_tag=aweme_images` / `tplv-dy-aweme-images`：封面是 `pcweb_cover`、
    /// 相关推荐带 `WEBPC_RELATED`，都不算 —— 否则视频页刚渲染出封面就「就绪」，丢掉直链。
    private static func readyCheckJS(relaxImages: Bool) -> String {
        let relax = relaxImages ? "true" : "false"
        return """
        (function () {
          try {
            var RELAX = \(relax);
            var raw = window.__yunxAwemeDetail;
            if (typeof raw === 'string' && raw.length > 0) return 'true';
            var body = (document.body && document.body.textContent) || '';
            body = body.substring(0, 3000);
            if (body.indexOf('作品不存在') >= 0
                || body.indexOf('该作品已删除') >= 0
                || body.indexOf('页面不见了') >= 0
                || body.indexOf('内容不可见') >= 0) return 'abort';
            var imgs = document.querySelectorAll('img');
            for (var i = 0; i < imgs.length; i++) {
              var s = (imgs[i].currentSrc || imgs[i].src || '') + '';
              if (s.indexOf('douyinpic') < 0 && s.indexOf('byteimg') < 0) continue;
              if (s.indexOf('WEBPC_RELATED') >= 0) continue;
              if (s.indexOf('pcweb_cover') >= 0) continue;
              if (s.indexOf('aweme-avatar') >= 0) continue;
              var isWork = s.indexOf('aweme_images') >= 0 || s.indexOf('aweme-images') >= 0;
              if (isWork) return 'true';
              // 图文页可能不挂 aweme_images 的 tag，页面上除了作品图没有别的图，放宽即可
              if (RELAX) return 'true';
            }
            // 有些图册用 background-image 铺，没有 <img>
            if (RELAX) {
              var styled = document.querySelectorAll('[style*="background-image"]');
              for (var j = 0; j < styled.length; j++) {
                var style = (styled[j].getAttribute('style') || '') + '';
                if (style.indexOf('douyinpic') >= 0) return 'true';
              }
            }
            return 'false';
          } catch (e) {
            return 'false';
          }
        })()
        """
    }

    /// 失败时用来说明「到底卡在哪」：标题 / 正文长度 / 图片数 / 钩子有没有命中。
    /// 拼进解析报错里，下一次不用再猜是风控还是字段变了。
    private static let diagnoseJS = """
    (function () {
      try {
        var title = (document.title || '').substring(0, 40);
        var body = ((document.body && document.body.textContent) || '').replace(/\\s+/g, ' ').substring(0, 60);
        var imgs = document.querySelectorAll('img');
        var works = 0, dypic = 0;
        for (var i = 0; i < imgs.length; i++) {
          var s = (imgs[i].currentSrc || imgs[i].src || '') + '';
          if (s.indexOf('douyinpic') >= 0 || s.indexOf('byteimg') >= 0) {
            dypic++;
            if (s.indexOf('aweme_images') >= 0 || s.indexOf('aweme-images') >= 0) works++;
          }
        }
        var hooked = (typeof window.__yunxAwemeDetail === 'string' && window.__yunxAwemeDetail.length > 0) ? 1 : 0;
        return 'title=' + (title || '-') + '|rs=' + (document.readyState || '?')
             + '|img=' + imgs.length + '(dy=' + dypic + ',work=' + works + ')'
             + '|hook=' + hooked + '|body=' + body;
      } catch (e) {
        return 'diagnose-error';
      }
    })()
    """

    /// 取数：多条数据源都试，只回传必要字段（整份详情 100KB+，回传又慢又容易出问题）。
    ///
    /// - `awemeID`: 用于在 `aweme_list`（个人页列表接口）里挑出当前作品。
    /// - `relaxImages`: 图文/动图页放宽 DOM 兜底（该页的图只有作品图）。
    private static func extractJS(awemeID: String, relaxImages: Bool) -> String {
        let target = awemeID.replacingOccurrences(of: "\"", with: "")
        let relax = relaxImages ? "true" : "false"
        return """
        (function () {
          try {
            var TARGET_ID = '\(target)';
            var RELAX = \(relax);
            function firstUrl(node) {
              if (!node) return '';
              var list = node.url_list || node.urlList || null;
              if (list && list.length) return String(list[0] || '');
              return '';
            }
            function keysOf(node) {
              if (!node || typeof node !== 'object') return '';
              var keys = [];
              for (var p in node) keys.push(p);
              return keys.join(',');
            }
            function motionUrl(item) {
              if (!item) return '';
              var v = item.video;
              if (!v) return '';
              var direct = firstUrl(v.playAddr) || firstUrl(v.play_addr)
                  || firstUrl(v.playApi) || firstUrl(v.downloadAddr) || firstUrl(v.download_addr);
              if (direct) return direct;
              var list = v.playAddr || v.play_addr || null;
              if (list && list.length) {
                var first = list[0];
                if (first) return String(first.src || first.url || '');
              }
              return '';
            }
            function hookDetail() {
              var raw = window.__yunxAwemeDetail || '';
              if (!raw) return null;
              try {
                var root = JSON.parse(raw);
                var detail = root.aweme_detail || root.awemeDetail || (root.data && root.data.aweme_detail) || null;
                if (!detail && root.aweme_list && root.aweme_list.length) {
                  // 个人页列表接口：优先挑 id 对得上的那条
                  for (var i = 0; i < root.aweme_list.length; i++) {
                    var it = root.aweme_list[i];
                    if (it && String(it.aweme_id) === TARGET_ID) { detail = it; break; }
                  }
                  if (!detail) detail = root.aweme_list[0];
                }
                return detail;
              } catch (e) { return null; }
            }
            var ssrNote = 'none';
            function readSsrDetail() {
              var node = document.querySelector('#RENDER_DATA');
              if (node && node.textContent) {
                try {
                  var app = JSON.parse(decodeURIComponent(node.textContent)).app;
                  if (app && app.videoDetail) { ssrNote = 'rd-ok'; return app.videoDetail; }
                  ssrNote = 'rd-no-videoDetail';
                } catch (e) { ssrNote = 'rd-parse-fail'; }
              } else {
                ssrNote = 'rd-missing';
              }
              try {
                var ssr = window.SSR_RENDER_DATA;
                if (ssr && ssr.app && ssr.app.videoDetail) { ssrNote += '+global-ok'; return ssr.app.videoDetail; }
              } catch (e) {}
              return null;
            }
            function imagesFrom(node) {
              if (!node || !node.length) return null;
              var list = [];
              var mlist = [];
              for (var i = 0; i < node.length; i++) {
                var item = node[i];
                var u = firstUrl(item);
                if (!u && item.display_image) u = firstUrl(item.display_image);
                if (u) { list.push(u); mlist.push(motionUrl(item)); }
              }
              if (!list.length) return null;
              return { images: list, motions: mlist, imgKeys: keysOf(node[0]), videoKeys: keysOf(node[0] && node[0].video) };
            }
            function domWorkImages() {
              var result = [];
              var seen = {};
              var all = document.querySelectorAll('img');
              for (var i = 0; i < all.length; i++) {
                // 懒加载图的 src 常常只是占位，真地址在 currentSrc
                var src = (all[i].currentSrc || all[i].src || '') + '';
                if (src.indexOf('douyinpic') < 0 && src.indexOf('byteimg') < 0) continue;
                if (src.indexOf('WEBPC_RELATED') >= 0) continue;
                if (src.indexOf('pcweb_cover') >= 0) continue;
                if (src.indexOf('aweme-avatar') >= 0) continue;
                var isWork = src.indexOf('aweme_images') >= 0 || src.indexOf('aweme-images') >= 0;
                if (!isWork && !RELAX) continue;
                var key = src.split('?')[0];
                if (seen[key]) continue;
                seen[key] = 1;
                result.push(src);
              }
              return result;
            }

            var hooked = hookDetail();
            var ssr = readSsrDetail();

            // 图片与动图资源必须成对、来自同一个源，否则下标会错位
            var images = [];
            var motions = [];
            var src = '';
            var picked = imagesFrom(hooked && hooked.images);
            if (picked) { src = 'hook'; }
            if (!picked) {
              picked = imagesFrom(hooked && hooked.image_post_info && hooked.image_post_info.images);
              if (picked) { src = 'hook'; }
            }
            if (!picked) {
              picked = imagesFrom(ssr && ssr.images);
              if (picked) { src = 'ssr'; }
            }
            if (picked) {
              images = picked.images;
              motions = picked.motions;
            } else {
              images = domWorkImages();
              src = images.length ? 'dom' : 'none';
            }

            var v = (hooked && hooked.video) || (ssr && ssr.video) || null;
            var video = '';
            if (v) {
              video = firstUrl(v.play_addr) || firstUrl(v.playAddr) || firstUrl(v.play_addr_h264);
              if (!video && v.bit_rate && v.bit_rate.length) {
                for (var i = 0; i < v.bit_rate.length; i++) {
                  var candidate = firstUrl(v.bit_rate[i].play_addr);
                  if (candidate) { video = candidate; break; }
                }
              }
              video = video.replace('/playwm/', '/play/');
            }

            var d = hooked || ssr;
            var author = '';
            if (d && d.author) author = d.author.nickname || d.author.unique_id || '';

            var title = (d && d.desc) || '';
            if (!title) {
              var pageTitle = document.title || '';
              var tail = pageTitle.lastIndexOf(' - 抖音');
              if (tail > 0) pageTitle = pageTitle.substring(0, tail);
              title = pageTitle;
            }

            return JSON.stringify({
              title: title,
              desc: (d && d.desc) || '',
              author: author,
              video: video,
              images: images,
              motions: motions,
              cover: (v && (firstUrl(v.cover) || firstUrl(v.origin_cover))) || '',
              src: src,
              ssr: ssrNote
            });
          } catch (e) {
            return JSON.stringify({ error: 'js: ' + e });
          }
        })()
        """
    }
}

// MARK: - 快手

/// 快手解析：读作品页 SSR 里的 `window.INIT_STATE`（一张「作品 id → 作品数据」的映射）。
///
/// 三个容易踩的点（都是实测结论）：
/// 1. **UA 必须是 iPhone UA，Referer 必须是 `https://v.kuaishou.com/`**。用桌面 UA 请求时
///    快手返回的是「桌面 SPA 页」，里面**根本没有** `window.INIT_STATE`，表象就是
///    「作品已删除/页面改版」这种误导性报错；
/// 2. `www.kuaishou.com/short-video/<id>` 与 `www.kuaishou.com/f/<码>` 都是**入口页**，
///    要先跟一次 302 落到移动端作品页 `v.m.chenzhongtech.com/fw/photo/...` 才有数据；
/// 3. 长视频页（`/fw/long-video/`）返回结构不同，统一改按 `/fw/photo/` 请求。
///
/// 视频在 `photo.mainMvUrls[].url`，图集在 `photo.ext_params.atlas`（CDN + 路由拼出直链）。
struct KuaishouParser: VideoParser {

    let platform: VideoPlatform = .kuaishou

    private func headers(cookie: String) -> [String: String] {
        var headers: [String: String] = [
            "User-Agent": HTTPClient.uaMobile,
            "Referer": "https://v.kuaishou.com/",
            "Accept-Language": "zh-CN,zh;q=0.9"
        ]
        if !cookie.isEmpty { headers["Cookie"] = cookie }
        return headers
    }

    func parse(link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        do {
            let headers = self.headers(cookie: cookie)
            var pageURL = link.url.hasPrefix("http")
                ? link.url
                : "https://www.kuaishou.com/short-video/\(link.id)"

            // 入口页先跟一次 302（要带着 iPhone UA 才跳得到移动端作品页）
            if !pageURL.contains("/fw/photo/") {
                if let location = try? await HTTPClient.shared.firstRedirectLocation(pageURL, headers: headers),
                   location.hasPrefix("http") {
                    pageURL = location
                }
            }
            pageURL = pageURL.replacingOccurrences(of: "/fw/long-video/", with: "/fw/photo/")

            let response = try await HTTPClient.shared.get(pageURL, headers: headers)
            guard response.isOK else {
                throw VideoParseError(.blocked, "作品页返回 \(response.status)")
            }
            let html = response.text
            guard let payload = HTMLPayload.jsonObject(
                afterAny: ["window.INIT_STATE", "window.__APOLLO_STATE__", "_APOLLO_STATE__ = "],
                in: html
            ) else {
                throw VideoParseError(
                    .unknown,
                    "快手页面里没有 window.INIT_STATE（作品可能已删除或页面改版）[HTTP \(response.status) · \(html.count / 1024)KB]"
                )
            }

            guard let photo = Self.findPhoto(payload) else {
                // 兜底：整页找一条 mp4 直链（改版时字段名变了也能救回来）
                if let raw = RegexUtil.allGroups("(https?:[^\"']+\\.mp4[^\"']*)", in: html).first {
                    let title = Self.pageTitle(html)
                    let base = TextUtil.fileName(title, fallback: "kuaishou_\(link.id)", ext: "")
                    return VideoParseResult(
                        platform: platform,
                        title: title.isEmpty ? "快手作品" : title,
                        text: title,
                        url: pageURL,
                        medias: [VideoMedia(
                            url: TextUtil.httpsURL(raw),
                            kind: .video,
                            fileName: "\(base).mp4",
                            size: -1,
                            headers: headers,
                            quality: "原画"
                        )]
                    )
                }
                throw VideoParseError(.unknown, "快手 INIT_STATE 里没有作品数据（页面可能只给了壳，客户端二次加载）")
            }

            let title = JSONSearch.str(photo, "caption")
            let base = TextUtil.fileName(title, fallback: "kuaishou_\(link.id)", ext: "")
            var medias: [VideoMedia] = []

            if let videoURL = Self.firstCDNURL(photo["mainMvUrls"]) ?? Self.firstCDNURL(photo["playUrls"]) {
                medias.append(VideoMedia(
                    url: TextUtil.httpsURL(videoURL),
                    kind: .video,
                    fileName: "\(base).mp4",
                    size: -1,
                    headers: headers,
                    quality: "原画"
                ))
            }

            let atlas = JSONSearch.dictionary(in: photo, path: ["ext_params", "atlas"])
            for (index, url) in Self.atlasURLs(atlas).enumerated() {
                medias.append(VideoMedia(
                    url: TextUtil.httpsURL(url),
                    kind: .image,
                    fileName: "\(base)_\(index + 1).jpg",
                    size: -1,
                    headers: headers,
                    quality: "原图"
                ))
            }

            guard !medias.isEmpty else {
                throw VideoParseError(.unknown, "快手作品里没有解析到视频直链或图集")
            }

            // 昵称里常见的 U+3164 是占位空白字符，参考实现也会先剥掉
            let author = JSONSearch.str(photo, "userName").replacingOccurrences(of: "\u{3164}", with: "")

            return VideoParseResult(
                platform: platform,
                title: title.isEmpty ? "快手作品" : title,
                author: author.trimmingCharacters(in: .whitespacesAndNewlines),
                avatar: TextUtil.httpsURL(JSONSearch.str(photo, "headUrl")),
                cover: TextUtil.httpsURL(Self.firstCDNURL(photo["coverUrls"]) ?? ""),
                text: title,
                timestampSeconds: JSONSearch.num(photo, "timestamp") / 1000,
                url: pageURL,
                medias: medias
            )
        } catch {
            throw ParserSupport.translate(error)
        }
    }

    // MARK: 解析工具

    /// `INIT_STATE` 是一张「作品 id → { photo: {...} }」的映射，取第一个 `photo` 非空的对象。
    /// （链接里虽然有 id，但 value 的 key 并不总是那个 id，所以不按 id 精确定位）
    private static func findPhoto(_ payload: Any) -> [String: Any]? {
        guard let dict = payload as? [String: Any] else { return nil }
        if let photo = dict["photo"] as? [String: Any], !photo.isEmpty { return photo }
        for value in dict.values {
            guard let sub = value as? [String: Any] else { continue }
            if let photo = sub["photo"] as? [String: Any], !photo.isEmpty { return photo }
            for inner in sub.values {
                if let deeper = inner as? [String: Any],
                   let photo = deeper["photo"] as? [String: Any], !photo.isEmpty {
                    return photo
                }
            }
        }
        return nil
    }

    /// `[{"url": "..."}]` / `["..."]` 两种形态都认
    private static func firstCDNURL(_ raw: Any?) -> String? {
        guard let array = raw as? [Any] else { return nil }
        for node in array {
            if let dict = node as? [String: Any] {
                let url = JSONSearch.str(dict, "url")
                if !url.isEmpty { return url }
            } else if let text = node as? String, !text.isEmpty {
                return text
            }
        }
        return nil
    }

    /// 图集直链：CDN 域名 + 路由拼出来（`ext_params.atlas.cdnList[0].cdn` + `list`）
    private static func atlasURLs(_ atlas: [String: Any]) -> [String] {
        guard !atlas.isEmpty else { return [] }
        var cdn = ""
        for node in JSONSearch.array(in: atlas, path: ["cdnList"]) {
            if let dict = node as? [String: Any] {
                cdn = JSONSearch.str(dict, "cdn")
            } else if let text = node as? String {
                cdn = text
            }
            if !cdn.isEmpty { break }
        }
        guard !cdn.isEmpty else { return [] }
        let routes = (atlas["list"] as? [Any])?.compactMap { $0 as? String } ?? []
        return routes.filter { !$0.isEmpty }.map { "https://\(cdn)/\($0)" }
    }

    private static func pageTitle(_ html: String) -> String {
        guard let raw = RegexUtil.firstGroup("<title>([^<]*)</title>", in: html, index: 1) else { return "" }
        return TextUtil.decodeHTMLEntities(raw).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - 微博

/// 微博解析：m 站 JSON 接口（`m.weibo.cn/statuses/show`）。
///
/// 视频在 `page_info.media_info.stream_url`（或 `page_info.urls` 里的 mp4），
/// 图片在 `pics[].large.url`；带 `videoSrc` 的图片其实是动图。
struct WeiboParser: VideoParser {

    let platform: VideoPlatform = .weibo

    private var headers: [String: String] {
        [
            "User-Agent": HTTPClient.uaMobile,
            "Referer": "https://m.weibo.cn/",
            "Accept": "application/json, text/plain, */*",
            "X-Requested-With": "XMLHttpRequest"
        ]
    }

    func parse(link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        do {
            if link.kind == "fid" || link.kind == "tv" {
                return try await parseVideoPage(link: link)
            }
            let api = "https://m.weibo.cn/statuses/show?id=\(link.id)"
            let json = try await HTTPClient.shared.getJSON(api, headers: headers, referer: "https://m.weibo.cn/")
            let data = JSONSearch.dictionary(in: json, path: ["data"])
            guard !data.isEmpty else {
                throw VideoParseError(.notFound, "微博不存在、已删除或不可见")
            }

            let text = HTMLPayload.plainText(fromHTML: JSONSearch.str(data, "text"))
            let user = JSONSearch.dictionary(in: data, path: ["user"])
            let author = JSONSearch.str(user, "screen_name")
            let base = TextUtil.fileName(text, fallback: "weibo_\(link.id)", ext: "")
            var medias: [VideoMedia] = []

            // ① 视频
            let pageInfo = JSONSearch.dictionary(in: data, path: ["page_info"])
            if !pageInfo.isEmpty {
                var stream = JSONSearch.str(JSONSearch.dictionary(in: pageInfo, path: ["media_info"]), "stream_url")
                if stream.isEmpty { stream = JSONSearch.str(pageInfo, "page_url") }
                if stream.isEmpty {
                    let urls = JSONSearch.dictionary(in: pageInfo, path: ["urls"])
                    stream = JSONSearch.strings(in: urls, keys: ["mp4_720p_mp4", "mp4_hd_url", "mp4_sd_url", "hevc_mp4_hd_url"]).first ?? ""
                }
                if !stream.isEmpty {
                    let ext = ParserSupport.extensionForVideo(url: stream)
                    medias.append(VideoMedia(
                        url: TextUtil.httpsURL(stream),
                        kind: .video,
                        fileName: "\(base).\(ext)",
                        headers: headers,
                        quality: "视频"
                    ))
                }
            }

            // ② 图片（含动图）
            let pics = JSONSearch.array(in: data, path: ["pics"])
            for (index, raw) in pics.enumerated() {
                guard let dict = raw as? [String: Any] else { continue }
                var url = JSONSearch.str(JSONSearch.dictionary(in: dict, path: ["large"]), "url")
                if url.isEmpty { url = JSONSearch.str(dict, "url") }
                guard let media = ParserSupport.imageMedia(
                    url: url,
                    fileName: "\(base)_\(index + 1).jpg",
                    quality: "原图",
                    headers: headers
                ) else { continue }
                var withMotion = media
                let motion = JSONSearch.str(dict, "videoSrc")
                if !motion.isEmpty { withMotion.motionUrl = TextUtil.httpsURL(motion) }
                medias.append(withMotion)
            }

            guard !medias.isEmpty else {
                throw VideoParseError(.unsupported, "这条微博里没有可下载的图片或视频")
            }

            return VideoParseResult(
                platform: platform,
                title: text.isEmpty ? "微博" : String(text.prefix(40)),
                author: author,
                avatar: TextUtil.httpsURL(JSONSearch.str(user, "profile_image_url")),
                cover: medias.first?.kind == .image ? medias[0].url : "",
                text: text,
                timestampSeconds: Self.timestamp(JSONSearch.str(data, "created_at")),
                url: "https://m.weibo.cn/detail/\(link.id)",
                medias: medias
            )
        } catch {
            throw ParserSupport.translate(error)
        }
    }

    /// `video.weibo.com/show?fid=` 这类只有播放页的链接：从页面里抠 stream_url
    private func parseVideoPage(link: DetectedVideoLink) async throws -> VideoParseResult {
        let pageURL = link.kind == "fid"
            ? "https://video.weibo.com/show?fid=\(link.id)"
            : link.url
        let response = try await HTTPClient.shared.get(pageURL, headers: headers)
        let html = response.text
        var candidates = RegexUtil.allGroups("\"(https?:[^\"]*\\.mp4[^\"]*)\"", in: html)
        if candidates.isEmpty {
            candidates = RegexUtil.allGroups("(https?:[^\"'\\s]*\\.m3u8[^\"'\\s]*)", in: html)
        }
        guard let url = candidates.first else {
            throw VideoParseError(.notFound, "播放页里没有可下载的直链")
        }
        let base = TextUtil.fileName(JSONSearch.str(HTMLPayload.jsonObject(after: "window.$render_data", in: html) as? [String: Any] ?? [:], "title"), fallback: "weibo_video", ext: "")
        let media = VideoMedia(
            url: TextUtil.httpsURL(url),
            kind: .video,
            fileName: "\(base).mp4",
            headers: headers,
            quality: "视频"
        )
        return VideoParseResult(
            platform: platform,
            title: base,
            url: pageURL,
            medias: [media]
        )
    }

    private static func timestamp(_ text: String) -> Int64 {
        guard !text.isEmpty else { return 0 }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM dd HH:mm:ss Z yyyy"
        if let date = formatter.date(from: text) {
            return Int64(date.timeIntervalSince1970)
        }
        return 0
    }
}

// MARK: - 小红书

/// 小红书解析：读笔记页 `window.__INITIAL_STATE__`。
///
/// ★ 必须登录：未登录访问笔记页会被 302 到登录/验证码页，页面里没有 `__INITIAL_STATE__`。
struct XhsParser: VideoParser {

    let platform: VideoPlatform = .xhs

    private func headers(cookie: String) -> [String: String] {
        var headers: [String: String] = [
            "User-Agent": HTTPClient.uaDesktop,
            "Referer": "https://www.xiaohongshu.com/",
            "Accept-Language": "zh-CN,zh;q=0.9"
        ]
        if !cookie.isEmpty { headers["Cookie"] = cookie }
        return headers
    }

    func parse(link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        if cookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw VideoParseError(.unsupported, "小红书要求登录后才能查看笔记，请先到「账号」页登录")
        }
        do {
            let pageURL = "https://www.xiaohongshu.com/explore/\(link.id)"
            let response = try await HTTPClient.desktop.get(pageURL, headers: headers(cookie: cookie))
            guard response.isOK else {
                throw VideoParseError(.blocked, "笔记页返回 \(response.status)")
            }
            let html = response.text
            guard let payload = HTMLPayload.jsonObject(afterAny: ["window.__INITIAL_STATE__", "__INITIAL_STATE__ = "], in: html) else {
                throw VideoParseError(.blocked, "笔记页没有返回数据：登录态可能已失效，请到「账号」页重新登录")
            }

            let note = JSONSearch.dictionaries(in: payload, containingKey: "imageList").first
                ?? JSONSearch.dictionaries(in: payload, containingKey: "noteCard").first
                ?? [:]
            let title = JSONSearch.str(note, "title")
            let desc = JSONSearch.str(note, "desc")
            let user = JSONSearch.dictionary(in: note, path: ["user"])
            let base = TextUtil.fileName(title.isEmpty ? desc : title, fallback: "xhs_\(link.id)", ext: "")
            var medias: [VideoMedia] = []

            let masterURL = JSONSearch.string(in: payload, keys: ["masterUrl", "master_url"]) ?? ""
            if !masterURL.isEmpty {
                medias.append(VideoMedia(
                    url: TextUtil.httpsURL(masterURL),
                    kind: .video,
                    fileName: "\(base).mp4",
                    headers: headers(cookie: cookie),
                    quality: "视频"
                ))
            }

            let imageList = JSONSearch.array(in: note, path: ["imageList"])
            for (index, raw) in imageList.enumerated() {
                guard let dict = raw as? [String: Any] else { continue }
                var url = JSONSearch.str(dict, "urlDefault")
                if url.isEmpty { url = JSONSearch.str(dict, "urlPre") }
                if url.isEmpty { url = JSONSearch.strings(in: dict, keys: ["url"]).first ?? "" }
                guard let media = ParserSupport.imageMedia(
                    url: url,
                    fileName: "\(base)_\(index + 1).jpg",
                    quality: "原图",
                    headers: headers(cookie: cookie)
                ) else { continue }
                medias.append(media)
            }

            guard !medias.isEmpty else {
                throw VideoParseError(.notFound, "笔记里没有可下载的媒体")
            }

            return VideoParseResult(
                platform: platform,
                title: title.isEmpty ? String(desc.prefix(30)) : title,
                author: JSONSearch.str(user, "nickname"),
                avatar: TextUtil.httpsURL(JSONSearch.str(user, "avatar")),
                cover: medias.first?.url ?? "",
                text: desc,
                url: pageURL,
                medias: medias
            )
        } catch {
            throw ParserSupport.translate(error)
        }
    }
}

// MARK: - AcFun

/// AcFun：`window.pageInfo` 里的 `ksPlayJson`（内容是 JSON 字符串），
/// 里面给的是 m3u8 —— 下载走 HLS 分片合并路径。
struct AcFunParser: VideoParser {

    let platform: VideoPlatform = .acfun

    private var headers: [String: String] {
        [
            "User-Agent": HTTPClient.uaDesktop,
            "Referer": "https://www.acfun.cn/",
            "Accept-Language": "zh-CN,zh;q=0.9"
        ]
    }

    func parse(link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        do {
            let pageURL = "https://www.acfun.cn/v/ac\(link.id)"
            let response = try await HTTPClient.shared.get(pageURL, headers: headers)
            guard response.isOK else {
                throw VideoParseError(.blocked, "作品页返回 \(response.status)")
            }
            let html = response.text
            guard let payload = HTMLPayload.jsonObject(afterAny: ["window.pageInfo", "pageInfo = "], in: html) else {
                throw VideoParseError(.unknown, "作品页里没有找到视频数据（平台可能改版）")
            }

            let title = JSONSearch.string(in: payload, keys: ["title"]) ?? "AcFun \(link.id)"
            let base = TextUtil.fileName(title, fallback: "acfun_\(link.id)", ext: "")

            // ksPlayJson 本身是字符串，里面还有一层 JSON
            var m3u8: String?
            if let raw = JSONSearch.string(in: payload, keys: ["ksPlayJson"]),
               let inner = HTMLPayload.unescapedJSONString(raw) {
                m3u8 = JSONSearch.strings(in: inner, keys: ["url"]).first { $0.contains(".m3u8") }
                    ?? JSONSearch.strings(in: inner, keys: ["url"]).first
            }
            if m3u8 == nil {
                m3u8 = RegexUtil.allGroups("(https?:[^\"'\\s]*\\.m3u8[^\"'\\s]*)", in: html).first
            }
            guard let finalURL = m3u8 else {
                throw VideoParseError(.notFound, "没有解析到 m3u8 地址")
            }

            let media = VideoMedia(
                url: TextUtil.httpsURL(finalURL),
                kind: .video,
                fileName: "\(base).ts",
                isHls: true,
                headers: headers,
                quality: "HLS 原画"
            )
            return VideoParseResult(
                platform: platform,
                title: title,
                author: JSONSearch.string(in: payload, keys: ["userName", "authorName"]) ?? "",
                cover: TextUtil.httpsURL(JSONSearch.string(in: payload, keys: ["coverImage", "image"]) ?? ""),
                text: JSONSearch.string(in: payload, keys: ["description"]) ?? "",
                url: pageURL,
                medias: [media],
                notice: "AcFun 是 HLS 流，下载会合并成单个 .ts 文件（可用 VLC 播放）"
            )
        } catch {
            throw ParserSupport.translate(error)
        }
    }
}
