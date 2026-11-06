import SwiftUI
import UIKit

// MARK: - 网盘分享浏览

/// 网盘分享的内容浏览页：面包屑 + 文件列表 + 多选下载。
///
/// 交互与上游一致：
/// - 点文件夹直接下钻（面包屑可点回退）；
/// - 点文件弹「直链已生成」弹窗（复制 / 开始下载）；
/// - 右上「选择」进入多选，底部条变成「下载所选」。
struct ShareBrowserScreen: View {

    @EnvironmentObject private var model: AppModel

    let snapshot: ShareSnapshot

    @State private var selecting = false
    @State private var selectedIDs: Set<String> = []
    @State private var showFolderDownloadHint = false

    private var resolve: ResolveCoordinator { model.resolve }

    var body: some View {
        VStack(spacing: 0) {
            AppTopBar(
                title: snapshot.title.isEmpty ? snapshot.platform.displayName : snapshot.title,
                subtitle: subtitle,
                onBack: {
                    if selecting {
                        selecting = false
                        selectedIDs.removeAll()
                    } else {
                        resolve.reset()
                    }
                }
            ) {
                HStack(spacing: 6) {
                    GlassIconButton(systemIcon: "arrow.clockwise", tint: Aurora.inkSoft, diameter: 32, iconSize: 12) {
                        Task { await resolve.refreshShare() }
                    }
                    GlassIconButton(
                        systemIcon: selecting ? "xmark.circle" : "checkmark.circle",
                        tint: selecting ? Aurora.rose : Aurora.inkSoft,
                        diameter: 32,
                        iconSize: 12
                    ) {
                        withAnimation(.easeOut(duration: 0.18)) {
                            selecting.toggle()
                            if !selecting { selectedIDs.removeAll() }
                        }
                    }
                    Menu {
                        Button {
                            model.accounts.addBookmark(
                                title: snapshot.title,
                                link: ShareLinkParser.webURL(for: ParsedShare(
                                    shareId: snapshot.shareId,
                                    pwd: nil,
                                    platform: snapshot.platform
                                )),
                                platform: snapshot.platform.rawValue
                            )
                            model.show("已加入快捷方式", .success)
                        } label: {
                            Label("收藏这个分享", systemImage: "bookmark")
                        }
                        Button {
                            openInBrowser()
                        } label: {
                            Label("用浏览器打开", systemImage: "safari")
                        }
                        Divider()
                        Button(role: .destructive) {
                            resolve.reset()
                        } label: {
                            Label("退出分享", systemImage: "xmark")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Aurora.inkSoft)
                            .frame(width: 32, height: 32)
                            .background(GlassSurface(shape: Circle(), shadowRadius: 8, highlight: 0.32))
                            .contentShape(Circle())
                    }
                }
            }

            breadcrumb

            if snapshot.entries.isEmpty {
                Spacer()
                EmptyStateView(
                    systemIcon: "folder",
                    title: "这个目录是空的",
                    message: "分享可能是空文件夹，或者内容已被分享者移动。"
                )
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(snapshot.entries) { entry in
                            row(entry)
                        }
                    }
                    .padding(.horizontal, AuroraMetrics.pagePadding)
                    .padding(.top, 6)
                    .padding(.bottom, 20)
                }
                .scrollIndicators(.hidden)
                .refreshable {
                    await resolve.refreshShare()
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomBar
                .padding(.horizontal, AuroraMetrics.pagePadding)
                .padding(.top, 6)
                .padding(.bottom, 8)
        }
        .alert("下载整个文件夹？", isPresented: $showFolderDownloadHint) {
            Button("取消", role: .cancel) {}
            Button("开始") {
                Task { await resolve.download(entries: currentTargets()) }
            }
        } message: {
            Text("会递归展开子文件夹并把所有文件加入下载队列（最多 4 层、300 个文件）。")
        }
    }

    // MARK: 面包屑

    private var breadcrumb: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(resolve.dirStack.enumerated()), id: \.offset) { pair in
                    if pair.offset > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Aurora.outline)
                    }
                    Button {
                        guard pair.offset != resolve.dirStack.count - 1 else { return }
                        Task { await resolve.goToDir(index: pair.offset) }
                    } label: {
                        Text(pair.element.name)
                            .font(AuroraFont.labelMedium)
                            .foregroundStyle(pair.offset == resolve.dirStack.count - 1 ? Aurora.ink : Aurora.brand)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, AuroraMetrics.pagePadding)
            .padding(.vertical, 6)
        }
    }

    // MARK: 行

    private func row(_ entry: ShareEntry) -> some View {
        Button {
            if selecting {
                toggle(entry)
            } else if entry.isFolder {
                Task { await resolve.openFolder(entry) }
            } else {
                Task { await resolve.fetchLink(for: entry) }
            }
        } label: {
            HStack(spacing: 10) {
                if selecting {
                    SelectDot(isOn: selectedIDs.contains(entry.id))
                }

                PlatformIcon(
                    systemIcon: entry.isFolder ? "folder.fill" : FileKind.kind(for: entry.name).systemIcon,
                    tint: entry.isFolder ? Aurora.warning : FileKind.kind(for: entry.name).tint,
                    size: 40
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.name)
                        .font(AuroraFont.labelLarge)
                        .foregroundStyle(Aurora.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        if entry.isFolder {
                            Text("文件夹")
                                .font(.system(size: 11))
                                .foregroundStyle(Aurora.muted)
                        } else {
                            Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                                .font(.system(size: 11))
                                .foregroundStyle(Aurora.muted)
                            if !entry.updatedText.isEmpty {
                                Text("·").font(.system(size: 11)).foregroundStyle(Aurora.outline)
                                Text(entry.updatedText)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Aurora.muted)
                            }
                        }
                    }
                }

                Spacer(minLength: 4)

                if resolve.busyFileID == entry.id {
                    ProgressView().tint(Aurora.brand)
                } else if entry.isFolder {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Aurora.outline)
                } else {
                    // 行本身已经是按钮，这里只放一个装饰性图标：
                    // 嵌套按钮在 SwiftUI 里会互相抢点击，直链/下载走 contextMenu 更稳。
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(Aurora.brand.opacity(0.85))
                        .frame(width: 30, height: 30)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                AuroraShape.control
                    .fill(selectedIDs.contains(entry.id) ? Aurora.brand.tint(0.07) : Color.white)
            )
            .overlay(
                AuroraShape.control.stroke(
                    selectedIDs.contains(entry.id) ? Aurora.brand.opacity(0.35) : Aurora.line.opacity(0.6),
                    lineWidth: 1
                )
            )
        }
        .buttonStyle(PressScaleStyle(scale: 0.995))
        .contextMenu {
            if !entry.isFolder {
                Button {
                    Task { await resolve.fetchLink(for: entry) }
                } label: {
                    Label("取下载直链", systemImage: "link")
                }
                Button {
                    Task { await resolve.download(entries: [entry]) }
                } label: {
                    Label("加入下载", systemImage: "arrow.down.circle")
                }
            } else {
                Button {
                    Task { await resolve.download(entries: [entry]) }
                } label: {
                    Label("下载整个文件夹", systemImage: "arrow.down.circle")
                }
            }
        }
    }

    // MARK: 底部

    private var bottomBar: some View {
        GlassBar {
            if selecting {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("已选 \(selectedIDs.count) 项")
                            .font(AuroraFont.labelLarge)
                            .foregroundStyle(Aurora.ink)
                        Text("点击条目继续选择")
                            .font(.system(size: 11))
                            .foregroundStyle(Aurora.muted)
                    }
                    Spacer(minLength: 0)
                    SmallTonalButton(text: "全选", systemIcon: "checkmark.circle") {
                        selectedIDs = Set(snapshot.entries.map { $0.id })
                    }
                    SmallTonalButton(text: "下载", systemIcon: "arrow.down.circle.fill", enabled: !selectedIDs.isEmpty) {
                        let targets = snapshot.entries.filter { selectedIDs.contains($0.id) }
                        Task {
                            await resolve.download(entries: targets)
                            selecting = false
                            selectedIDs.removeAll()
                        }
                    }
                }
            } else {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(snapshot.platform.displayName)
                            .font(AuroraFont.labelLarge)
                            .foregroundStyle(Aurora.ink)
                        Text("共 \(snapshot.entries.count) 项 · 点文件可先取直链")
                            .font(.system(size: 11))
                            .foregroundStyle(Aurora.muted)
                    }
                    Spacer(minLength: 0)
                    SmallTonalButton(text: "全部下载", systemIcon: "arrow.down.circle") {
                        showFolderDownloadHint = true
                    }
                }
            }
        }
    }

    // MARK: 工具

    private var subtitle: String {
        var parts: [String] = [snapshot.platform.displayName]
        parts.append("共 \(snapshot.entries.count) 项")
        if let first = snapshot.entries.first, !first.updatedText.isEmpty {
            parts.append(first.updatedText)
        }
        return parts.joined(separator: " · ")
    }

    private func toggle(_ entry: ShareEntry) {
        if selectedIDs.contains(entry.id) {
            selectedIDs.remove(entry.id)
        } else {
            selectedIDs.insert(entry.id)
        }
    }

    private func currentTargets() -> [ShareEntry] {
        if selecting && !selectedIDs.isEmpty {
            return snapshot.entries.filter { selectedIDs.contains($0.id) }
        }
        return snapshot.entries
    }

    private func openInBrowser() {
        let share = ParsedShare(shareId: snapshot.shareId, pwd: nil, platform: snapshot.platform)
        guard let url = URL(string: ShareLinkParser.webURL(for: share)) else { return }
        UIApplication.shared.open(url)
    }
}
