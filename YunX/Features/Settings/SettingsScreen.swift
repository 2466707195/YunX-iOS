import SwiftUI
import UIKit

// MARK: - 设置页

/// Tab 4：下载 / 解析 / 存储 / 关于。
struct SettingsScreen: View {

    @EnvironmentObject private var model: AppModel

    @State private var showThreads = false
    @State private var showAbout = false

    private var settings: AppSettings { model.settings }

    var body: some View {
        VStack(spacing: 0) {
            AppTopBar(title: "设置", subtitle: "下载速度与解析行为的开关都在这里")

            ScrollView {
                VStack(alignment: .leading, spacing: AuroraMetrics.cardSpacing) {

                    SectionHeader(title: "下载")
                    downloadCard

                    SectionHeader(title: "解析")
                    resolveCard

                    SectionHeader(title: "存储")
                    storageCard
                    maintenanceCard

                    SectionHeader(title: "关于")
                    aboutCard

                    disclaimer
                }
                .padding(.horizontal, AuroraMetrics.pagePadding)
                .padding(.top, 4)
                .padding(.bottom, 30)
            }
            .scrollIndicators(.hidden)
        }
        .sheet(isPresented: $showThreads) {
            ThreadSettingsSheet()
                .presentationDetents([.large])
        }
        .sheet(isPresented: $showAbout) {
            AboutSheet()
                .presentationDetents([.large])
        }
    }

    // MARK: 下载

    private var downloadCard: some View {
        SectionCard {
            VStack(spacing: 0) {
                navRow(
                    icon: "slider.horizontal.3",
                    title: "下载线程数",
                    subtitle: "按平台分别设置分片并发（夸克当前 \(settings.threads(for: DownloadPlatform.quark))）"
                ) {
                    showThreads = true
                }
                divider
                concurrentRow
                divider
                chunkRow
                divider
                toggleRow(
                    icon: "wifi",
                    title: "仅 Wi-Fi 下载",
                    subtitle: "蜂窝网络下任务保持暂停",
                    isOn: Binding(get: { settings.wifiOnly }, set: { settings.wifiOnly = $0 })
                )
                divider
                toggleRow(
                    icon: "photo.on.rectangle",
                    title: "完成后存入相册",
                    subtitle: "仅图片与视频，需要相册写入权限",
                    isOn: Binding(get: { settings.autoSaveToPhotos }, set: { settings.autoSaveToPhotos = $0 })
                )
                divider
                toggleRow(
                    icon: "sun.max",
                    title: "下载时屏幕常亮",
                    subtitle: "大文件下载时避免锁屏中断",
                    isOn: Binding(get: { settings.keepScreenAwake }, set: { settings.keepScreenAwake = $0 })
                )
            }
        }
    }

    private var concurrentRow: some View {
        HStack(spacing: 10) {
            PlatformIcon(systemIcon: "square.stack.3d.up", tint: Aurora.info, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text("同时下载任务数")
                    .font(AuroraFont.labelLarge)
                    .foregroundStyle(Aurora.ink)
                Text("超出后排队等待")
                    .font(.system(size: 11))
                    .foregroundStyle(Aurora.muted)
            }
            Spacer(minLength: 0)
            Stepper(
                "",
                value: Binding(get: { settings.maxConcurrentTasks }, set: { settings.maxConcurrentTasks = $0 }),
                in: 1...8
            )
            .labelsHidden()
            Text("\(settings.maxConcurrentTasks) 个")
                .font(AuroraFont.labelMedium)
                .foregroundStyle(Aurora.brand)
                .monospacedDigit()
                .frame(minWidth: 32, alignment: .trailing)
        }
        .padding(.vertical, 10)
    }

    private var chunkRow: some View {
        HStack(spacing: 10) {
            PlatformIcon(systemIcon: "scissors", tint: Aurora.warning, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text("最小分片大小")
                    .font(AuroraFont.labelLarge)
                    .foregroundStyle(Aurora.ink)
                Text("分片太小反而会拖慢速度")
                    .font(.system(size: 11))
                    .foregroundStyle(Aurora.muted)
            }
            Spacer(minLength: 0)
            Menu {
                ForEach([1, 2, 4, 8, 16], id: \.self) { size in
                    Button("\(size) MB") { settings.minChunkMB = size }
                }
            } label: {
                HStack(spacing: 4) {
                    Text("\(settings.minChunkMB) MB")
                        .font(AuroraFont.labelMedium)
                        .foregroundStyle(Aurora.brand)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Aurora.muted)
                }
            }
        }
        .padding(.vertical, 10)
    }

    // MARK: 解析

    private var resolveCard: some View {
        SectionCard {
            VStack(spacing: 0) {
                toggleRow(
                    icon: "doc.on.clipboard",
                    title: "剪贴板识别",
                    subtitle: "回到应用时提示一键解析（iOS 会弹系统粘贴提示）",
                    isOn: Binding(get: { settings.clipboardWatch }, set: { settings.clipboardWatch = $0 })
                )
                divider
                toggleRow(
                    icon: "doc.on.doc",
                    title: "取链后自动复制",
                    subtitle: "拿到直链就复制到剪贴板",
                    isOn: Binding(get: { settings.copyLinkAfterResolve }, set: { settings.copyLinkAfterResolve = $0 })
                )
                divider
                toggleRow(
                    icon: "square.stack",
                    title: "分组默认展开",
                    subtitle: "关闭后下载页的分组默认折叠",
                    isOn: Binding(get: { settings.expandGroups }, set: { settings.expandGroups = $0 })
                )
            }
        }
    }

    // MARK: 存储

    private var storageCard: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    PlatformIcon(systemIcon: "internaldrive", tint: Aurora.info, size: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("下载保存目录")
                            .font(AuroraFont.labelLarge)
                            .foregroundStyle(Aurora.ink)
                        Text(model.downloadFolderPath)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Aurora.muted)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    SmallTonalButton(text: "复制", systemIcon: "doc.on.doc") {
                        UIPasteboard.general.string = model.downloadFolderPath
                        model.show("已复制路径", .success)
                    }
                }
                HStack(spacing: 10) {
                    StatTile(title: "已下载占用", value: model.usedSpaceText)
                    Divider().frame(height: 26).background(Aurora.hairline)
                    StatTile(title: "剩余可用", value: model.freeSpaceText)
                }
                Text("iOS 沙盒里只有 Documents 对「文件」App 可见，所以目录固定在这里：文件 App → 我的 iPhone → 云析 → YunXDownloads。")
                    .font(.system(size: 11))
                    .foregroundStyle(Aurora.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var maintenanceCard: some View {
        SectionCard {
            VStack(spacing: 0) {
                navRow(
                    icon: "clock.arrow.circlepath",
                    title: "清空解析历史",
                    subtitle: "\(model.accounts.history.count) 条记录（只删记录，不影响已下载文件）"
                ) {
                    model.accounts.clearHistory()
                    model.show("已清空历史", .info)
                }
                divider
                navRow(
                    icon: "speedometer",
                    title: "恢复默认设置",
                    subtitle: "线程数、并发数、分片大小回到出厂值"
                ) {
                    settings.resetThreads()
                    settings.maxConcurrentTasks = 3
                    settings.minChunkMB = 4
                    model.show("已恢复默认设置", .success)
                }
                divider
                navRow(
                    icon: "lock.shield",
                    title: "认证备份",
                    subtitle: "\(model.accounts.accounts.count) 个账号 · 入口在「账号」页右上角"
                ) {
                    model.show("请在「账号」页右上角打开备份", .info)
                }
            }
        }
    }

    // MARK: 关于

    private var aboutCard: some View {
        SectionCard {
            navRow(icon: "info.circle", title: "关于云析", subtitle: "版本 \(SettingsScreen.version) · 开源说明与平台清单") {
                showAbout = true
            }
        }
    }

    private var disclaimer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("本应用仅供个人学习与技术交流")
                .font(AuroraFont.labelMedium)
                .foregroundStyle(Aurora.inkSoft)
            Text("解析与下载依赖各平台的公开接口；平台改版或提高风控时，对应解析器可能失效。请遵守平台服务条款，下载内容请在 24 小时内删除。")
                .font(.system(size: 11))
                .foregroundStyle(Aurora.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 6)
        .padding(.top, 6)
    }

    // MARK: 行组件

    private var divider: some View {
        Rectangle()
            .fill(Aurora.hairline)
            .frame(height: 1)
            .padding(.leading, 48)
    }

    private func navRow(icon: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                PlatformIcon(systemIcon: icon, tint: Aurora.brand, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(AuroraFont.labelLarge)
                        .foregroundStyle(Aurora.ink)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Aurora.muted)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Aurora.outline)
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggleRow(icon: String, title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            PlatformIcon(systemIcon: icon, tint: Aurora.teal, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AuroraFont.labelLarge)
                    .foregroundStyle(Aurora.ink)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Aurora.muted)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(Aurora.brand)
        }
        .padding(.vertical, 8)
    }

    static var version: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}

// MARK: - 线程设置

struct ThreadSettingsSheet: View {

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private var settings: AppSettings { model.settings }

    var body: some View {
        SheetScaffold(title: "下载线程数", subtitle: "数字 = 每个文件切成多少片并发下载（上限 512）") {
            SectionCard {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(AppSettings.platformKeys, id: \.self) { key in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(DownloadPlatform.displayName(key))
                                    .font(AuroraFont.labelLarge)
                                    .foregroundStyle(Aurora.ink)
                                Spacer()
                                Text("\(settings.threads(for: key))")
                                    .font(AuroraFont.labelMedium)
                                    .foregroundStyle(Aurora.brand)
                                    .monospacedDigit()
                            }
                            Slider(
                                value: Binding(
                                    get: { Double(settings.threads(for: key)) },
                                    set: { settings.setThreads(Int($0), for: key) }
                                ),
                                in: 1...128,
                                step: 1
                            )
                            .tint(Aurora.brand)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            Text("建议：夸克/UC 32；百度给多了容易被风控，建议 8；视频平台（B 站 CDN）16。改完立即生效，已在跑的任务不受影响。")
                .font(.system(size: 11))
                .foregroundStyle(Aurora.muted)
                .padding(.horizontal, 6)

            HStack(spacing: 10) {
                SmallTonalButton(text: "恢复默认", systemIcon: "arrow.counterclockwise") {
                    settings.resetThreads()
                }
                GradientButton(text: "完成", systemIcon: "checkmark") {
                    dismiss()
                }
            }
        }
    }
}

// MARK: - 关于

struct AboutSheet: View {

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetScaffold(title: "云析 · YunX", subtitle: "网盘分享解析 + 视频解析下载（iOS 原生版）") {
            SectionCard {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        PlatformIcon(systemIcon: "cloud.fill", tint: Aurora.brand, size: 46)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("云析")
                                .font(AuroraFont.titleLarge)
                                .foregroundStyle(Aurora.ink)
                            Text("版本 \(SettingsScreen.version)")
                                .font(.system(size: 11))
                                .foregroundStyle(Aurora.muted)
                        }
                        Spacer(minLength: 0)
                    }
                    Text("原生 SwiftUI 实现：链接识别、网盘分享浏览、视频/图集解析、Range 分片并发下载与断点续传、凭证加密。")
                        .font(AuroraFont.bodySmall)
                        .foregroundStyle(Aurora.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            SectionCard {
                VStack(alignment: .leading, spacing: 6) {
                    Text("技术栈")
                        .font(AuroraFont.labelLarge)
                        .foregroundStyle(Aurora.ink)
                    ForEach(techStack, id: \.self) { item in
                        HStack(alignment: .top, spacing: 6) {
                            Circle().fill(Aurora.brand.opacity(0.5)).frame(width: 4, height: 4).padding(.top, 6)
                            Text(item)
                                .font(AuroraFont.bodySmall)
                                .foregroundStyle(Aurora.inkSoft)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            SectionCard {
                VStack(alignment: .leading, spacing: 6) {
                    Text("已接入的解析能力")
                        .font(AuroraFont.labelLarge)
                        .foregroundStyle(Aurora.ink)
                    Text("网盘：夸克 / UC（分享 token → 目录 → 直链）\n视频：哔哩哔哩、Pixiv、抖音、快手、微博、小红书、AcFun\nGitHub：仓库最新 Release 资源列表")
                        .font(AuroraFont.bodySmall)
                        .foregroundStyle(Aurora.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text("本项目参考 CYQawa/YunX（AGPL-3.0）的功能与交互重新实现，仅用于个人学习与技术交流；下载内容版权归原作者所有。")
                .font(.system(size: 11))
                .foregroundStyle(Aurora.muted)
                .padding(.horizontal, 6)

            TextLinkButton(text: "关闭", systemIcon: nil) { dismiss() }
                .frame(maxWidth: .infinity)
        }
    }

    private var techStack: [String] {
        [
            "SwiftUI + Combine（最低 iOS 16.4）",
            "URLSession Range 分片并发 + .part 断点续传",
            "AVFoundation：DASH 音视频透传合轨",
            "CryptoKit：AES-GCM 凭证加密（钥匙串设备密钥）",
            "WKWebView：网页登录 + Cookie 抓取",
            "JSONSerialization：平台 SSR 数据解析"
        ]
    }
}
