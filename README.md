# 云析 YunX · iOS

原生 iOS 客户端（Swift + SwiftUI，iOS 16.4+），参照 [CYQawa/YunX](https://github.com/CYQawa/YunX)（Android/Compose，AGPL-3.0）的
项目结构与业务逻辑重写：**网盘分享解析 + 短视频/图集解析 + Range 分片断点续传下载 + 多平台登录**。

本仓库是「无 Mac 也能装到真机」的形态：XcodeGen 生成工程 → GitHub Actions 云端 macOS 编译出**未签名 ipa** →
全能签重签侧载。不需要 Apple 开发者账号，也不需要在本地安装 Xcode。

---

## 1. 功能矩阵

| 能力 | 状态 | 说明 |
| --- | --- | --- |
| 夸克网盘 分享解析 / 直链 / 下载 | ✅ 完整 | `sharepage/token → detail → download` 三步 |
| UC 网盘 分享解析 / 直链 / 下载 | ✅ 完整 | 与夸克同接口族，仅 host/Referer 不同 |
| 百度 / 迅雷 / 139 / 123 / 115 / 光鸭 / 蓝奏云 / 蓝奏云优享版 | 🔶 仅链接识别 | 正则已对齐上游，适配器未注册；UI 显示「适配中」 |
| 抖音（视频 / 图集 / 动图，去水印） | ✅ | 隐藏 WKWebView 过 `byted_acrawler` 挑战，钩 `aweme/detail` 响应取数；HTTP+SSR 仅作回退 |
| 快手 | ✅ | iPhone UA + `v.kuaishou.com` Referer，跟一跳进移动作品页，读 `window.INIT_STATE` 的 `mainMvUrls` / 图集 atlas |
| 微博（status / fid / tv） | ✅ | `statuses/show` 优先，`fid/tv` 走页面正则 |
| AcFun | ✅ | `window.pageInfo` → `ksPlayJson` → m3u8 |
| 哔哩哔哩 | ✅ | 登录走 DASH 分轨，未登录退 html5 单文件 |
| 小红书 | ✅（需登录） | 必须 Cookie + 桌面 UA + 1280 viewport |
| Pixiv | ✅（仅手动 Cookie） | 原图全量 + 动图 zip |
| GitHub Release 直链 | ✅ | `releases/latest` 资产列 |
| Range 分片并发 / 断点续传 / 暂停继续 | ✅ | `.part` 预分配 + 分片账本 |
| HLS(m3u8) 下载 | ✅ | 顺序抓片拼 `.ts`，不依赖 ffmpeg |
| B 站音视频合轨 | ✅ | `AVMutableComposition` + passthrough，不重编码 |
| 下载自动归组 | ✅ | 按分享标题/视频标题成组 |
| 网页登录抓 Cookie | ✅ | WKWebView + `httpCookieStore` |
| 凭证加密 / 口令备份 | ✅ | AES-GCM + Keychain；备份 `YNXBK1` |
| 剪贴板识别 / 自动存相册 / 仅 Wi-Fi / 屏幕常亮 | ✅ | 设置页可开关 |
| 相册保存、文件 App 可见 | ✅ | `Documents/YunXDownloads` |

---

## 2. 目录结构

```
YunX/
├── project.yml                       # XcodeGen 工程定义（Info.plist 内联在此）
├── .github/workflows/ios-build.yml   # 云端 macOS 编译 → 未签名 ipa artifact
├── scripts/
│   ├── install-xcodegen.sh           # 固定 2.38.0 安装 XcodeGen
│   ├── build-unsigned-ipa.sh         # xcodebuild archive → 解包重签为未签名 ipa
│   ├── inspect-ipa.ps1               # 本地验包（Bundle ID / 版本 / 架构）
│   ├── publish-github.ps1            # Windows 一键推到 GitHub 并盯 Actions
│   └── upload-to-qnq.py              # 上传到手机「全能签」无线传输地址
└── YunX/
    ├── App/
    │   ├── YunXApp.swift             # @main、五 Tab 容器（原生 TabView）、Toast 层
    │   └── AppModel.swift            # 全局状态机，聚合四个子系统
    ├── Theme/                        # Aurora 设计系统（色板/字阶/日期格式）
    ├── UI/Common/                    # 玻璃、按钮、输入框、Tab 宿主、YunX 专用组件
    ├── Core/
    │   ├── Model/                    # ShareModels / VideoModels / DownloadModels / AccountModels
    │   ├── Network/                  # 解析层（见下）
    │   ├── Download/                 # 下载引擎（见下）
    │   ├── Account/                  # CredentialVault / AccountStore
    │   ├── Settings/AppSettings.swift
    │   ├── Resolve/ResolveCoordinator.swift
    │   └── StoragePaths.swift
    └── Features/
        ├── Resolve/ResolveScreen.swift
        ├── Share/ShareBrowserScreen.swift
        ├── Video/VideoResultScreen.swift
        ├── Preview/MediaPreviewScreen.swift
        ├── Download/DownloadScreen.swift
        ├── Accounts/AccountsScreen.swift + WebLoginScreen.swift
        └── Settings/SettingsScreen.swift
```

**解析层（`Core/Network/`）**

| 文件 | 职责 |
| --- | --- |
| `ShareLinkParser` | 文本 → `ParsedShare`（11 个网盘的正则 + 提取码） |
| `VideoLinkParser` | 文本 → `DetectedVideoLink`（7 个平台的规则表，短链优先） |
| `ResolveRouter` | 统一入口：GitHub → 视频 → 网盘 → unknown |
| `PanAPI` | `protocol PanAPI` + `PanRegistry` + `QuarkFamily` |
| `ParserSupport` | `HTMLPayload`（平衡括号扫描 JSON）、`protocol VideoParser` |
| `BilibiliParser` / `PixivParser` / `ShortVideoParsers` | 各平台实现 |
| `VideoResolveService` | 解析器工厂 + 短链展开 + Cookie 校验 |
| `HTTPClient` | 信封式请求/JSON + `JSONSearch` 递归取值 |
| `GitHubAPI` | Release 资产 |

**下载层（`Core/Download/`）**

| 文件 | 职责 |
| --- | --- |
| `RangeDownloader` | 探测 / 分片规划 / TaskGroup 并发 / 追加写 / 断点续传 |
| `DownloadManager` | 队列调度、速度平滑、任务持久化、分组 |
| `DownloadStore` | 路径管理、临时文件、落盘改名去重 |
| `MediaPipeline` | `HlsDownloader` 拼 m3u8；`MediaMerger` 合轨 |
| `NetworkMonitor` | 网络状态、取消标志、进度盒子 |

---

## 3. 关键设计

### 3.1 分片规划只依赖「总大小 + 线程数」

断点续传要能复现同一套分片，否则上次的 `completedChunks` 对不上。所以
`plan(totalSize:chunkCount:minChunkBytes:)` 是纯函数：均分，最后一片吸收除不尽的余量；
分片数还会被「最小分片大小」压下来（小文件不会切出几百个碎片）。

```swift
static func plan(totalSize: Int64, chunkCount: Int, minChunkBytes: Int64) -> [ChunkRange] {
    guard totalSize > 0 else { return [] }
    let minBytes = max(1, minChunkBytes)
    var count = max(1, chunkCount)
    count = min(count, Int(max(1, totalSize / minBytes)))
    let base = totalSize / Int64(count)
    var ranges: [ChunkRange] = []
    var offset: Int64 = 0
    for index in 0..<count {
        let length = index == count - 1 ? totalSize - offset : base
        ranges.append(ChunkRange(index: index, offset: offset, length: length))
        offset += length
    }
    return ranges
}
```

### 3.2 探测只读响应头

大文件如果先 `GET` 全量再判断能否分片，等于把文件塞进内存。`RangeProber` 用
`URLSessionDataDelegate`，在 `didReceive response` 里读完 `Content-Range` 立刻
`completionHandler(.cancel)`：拿到总大小就走人，一个字节都不下。

### 3.3 落盘策略

- `.part` 文件用 `FileHandle` 预分配到总大小（避免边写边扩容的碎片）；
- 每片下到 `chunk_<i>.tmp`，完成即按 `offset` 追加进 `.part`，然后删临时片；
- `completedChunks` 每 2 秒限流持久化，杀进程后重启只补缺片；
- 全部完成后 `.part → 最终文件名`，重名自动加 `(1)`。

### 3.4 平台差异

| 平台 | 处理 |
| --- | --- |
| B 站（登录） | `fnval=4048` 取 DASH，音视频分轨同时下，再 `AVMutableComposition` + `passthrough` 合轨 |
| B 站（未登录） | `fnval=1&platform=html5` 取单文件 `durl` |
| 小红书 | 无 Cookie 直接抛「需登录」；WebView 用桌面 UA + 1280 viewport |
| AcFun | 只有 m3u8，顺序抓片拼 `.ts`（`isHls = true`） |
| Pixiv | 不支持网页登录抓 Cookie，只能手动粘贴；动图给 zip |
| 夸克/UC | 直链 15~30 分钟过期，下载失败文案会提示重新取链 |

### 3.5 凭证安全

- 设备内：Keychain 存 32 字节随机密钥（`AfterFirstUnlockThisDeviceOnly`），Cookie/JWT 用
  AES-GCM 密封后才写 `accounts.json`；`Account.credential` 永远是密文。
- 备份：`YNXBK1` + 16 字节随机盐 + `sealed.combined`；口令经 12 万次迭代 SHA-256 派生密钥。
  口令错误只会得到「口令错误或备份文件已损坏」。
- 未用 PBKDF2 的原因：iOS 的 CommonCrypto 需要 bridging header，本工程没有；迭代哈希功能等价。

### 3.6 队列调度

`DownloadManager.pump()` 每次状态变化都重算：可运行任务 = 未开始/未暂停/未失败，
按 `maxConcurrentTasks` 取前 N 个；`wifiOnly` 且当前是蜂窝网络时整体挂起。
速度由单个 0.5s 定时器统一算，指数平滑 `(prev*3 + instant)/4`，避免 UI 抖动。

---

### 3.7 按钮与播放器

- **操作条按钮统一小胶囊**：38pt 高、左右内边距 16、图标 14、图标↔文字 7、13pt semibold 墨色字。
  同一行不会再出现「38pt 小胶囊 + 50pt 蓝字按钮」这种高矮配色都对不上的情况；
  整行 CTA 才用 50pt 的 `PrimaryButton`。按钮文字一律不染品牌色，危险操作用玫瑰字。
- **视频预览不用 `VideoPlayer`**：它在点击播放/暂停时会浮出系统控制层，压住自绘的顶栏。
  改成 `PlayerLayerView`（`AVPlayerLayer`，不画任何 chrome），播放/暂停、±15 秒、点画面切换全部自绘，
  同时设 `AVAudioSession(.playback)` 保证静音键拨下也有声。

## 4. 构建（无 Mac）

### 4.1 一键发到 GitHub 并编译

```powershell
cd YunX
./scripts/publish-github.ps1 -Repo YunX
```

脚本会 init/commit/push，并等待 Actions 完成。**前提**：`gh auth refresh -h github.com -s workflow`
（token 缺 `workflow` scope 推不上 `.github/workflows/*.yml`）。

### 4.2 手动跑

```bash
gh workflow run ios-build.yml
gh run watch
gh run download --name ios-unsigned-ipa --dir build
```

### 4.3 装到手机

```bash
python scripts/upload-to-qnq.py build/YunX-unsigned.ipa
```

手机全能签 →「资源 App」→ 选 ipa → 签名安装。首次启动需在
设置 → 通用 → VPN与设备管理里信任证书。

### 4.4 本地有 Mac 时

```bash
brew install xcodegen && xcodegen generate && open YunX.xcodeproj
```

---

## 5. 扩展一个新平台

**网盘**：新建 `final class XxxAPI: PanAPI`，实现 `snapshot / entries / downloadLink`，
在 `PanRegistry.api(for:)` 里注册。失败一律抛 `PanError` 的对应 case（UI 靠它决定
弹提取码框还是提示「分享失效」）。

**短视频**：新建 `struct XxxParser: VideoParser`，实现 `parse(link:cookie:)`，
在 `VideoResolveService.parser(for:)` 注册；需要登录就实现 `validateCookie`。

**链接识别**：在 `ShareLinkParser` / `VideoLinkParser` 里加一条正则——注意顺序，
短链和子域名要排在父域名前面（`ilanzou` 必须早于 `lanzou`）。

---

## 6. 已知边界

1. 除夸克/UC 外的网盘只有识别，没有接口适配（上游也是逐步加的）。
2. B 站 >1080P 需要大会员 Cookie；未登录最高 480P 左右。
3. m3u8 若带 `EXT-X-KEY`（AES-128），明确报「不支持加密流」，不做破解。
4. 抖音/快手/微博的 SSR 字段会漂移；解析失败时错误里带原始 detail，便于按需修规则。
5. 抖音必须让页面 JS 跑起来（纯 HTTP 只会拿到 `byted_acrawler` 挑战页），所以解析时会挂一个 1×1 的隐藏 WKWebView，最长约 40 秒；快手只走 HTTP。
5. `NSAllowsArbitraryLoads` 是为 http 直链/m3u8 放开的；若要上架 App Store 得改成按域白名单。
6. 本工程只做「解析自己有权访问的分享」；不含任何绕过权限、破解加密的能力。

---

## 7. 许可与来源

接口路径、正则规则、字段名参照上游 [CYQawa/YunX](https://github.com/CYQawa/YunX)（AGPL-3.0）。
沿用其规则的部分请遵守 AGPL-3.0；UI 与下载引擎为本工程重写（Aurora 设计系统）。
