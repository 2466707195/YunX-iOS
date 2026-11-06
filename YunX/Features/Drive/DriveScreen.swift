import SwiftUI
import UIKit

// MARK: - 网盘浏览页

/// 「网盘」Tab：浏览已登录网盘里的文件，逐级下钻、勾选下载。
///
/// 状态分五档，界面上互斥呈现：
/// - `needLogin` → 空状态 + 「去登录」（切到账号 Tab）
/// - `loading`   → 居中转圈
/// - `failed`    → 空状态 + 错误文案 + 「重试」
/// - `loaded` 且空 → 「这个文件夹是空的」
/// - `loaded` 且有内容 → 列表
///
/// 多选操作条放在**顶部**（面包屑下方）而不是底部：
/// Tab 胶囊已经占了底部，再来一条玻璃条，两条中间会漏出滚动内容（这坑在 `AuroraScreen` 里有记录）。
struct DriveScreen: View {

    @EnvironmentObject private var model: AppModel

    private var drive: DriveBrowserModel { model.drive }

    var body: some View {
        VStack(spacing: 0) {
            AppTopBar(title: "网盘", subtitle: subtitle, onBack: backAction) {
                HStack(spacing: 6) {
                    GlassIconButton(
                        systemIcon: "arrow.clockwise",
                        tint: Aurora.inkSoft,
                        diameter: 32,
                        iconSize: 12
                    ) {
                        Task { await drive.reload() }
                    }
                    .disabled(!drive.isLoggedIn || drive.busy)
                    .opacity(drive.isLoggedIn ? 1 : 0.4)

                    if drive.isLoggedIn {
                        GlassIconButton(
                            systemIcon: drive.selecting ? "xmark.circle" : "checkmark.circle",
                            tint: drive.selecting ? Aurora.rose : Aurora.inkSoft,
                            diameter: 32,
                            iconSize: 12
                        ) {
                            withAnimation(.easeOut(duration: 0.18)) { drive.toggleSelecting() }
                        }
                    }
                }
            }

            if drive.availablePlatforms.count > 1 && drive.isLoggedIn {
                platformSwitcher
            }

            if drive.isLoggedIn && drive.selecting {
                selectionBar
            }

            if drive.isLoggedIn && needsBreadcrumb {
                breadcrumb
            }

            content
        }
        .task { await drive.refreshIfNeeded() }
        .overlay {
            if drive.busy {
                busyOverlay
            }
        }
    }

    // MARK: 标题 / 返回

    private var subtitle: String {
        guard drive.isLoggedIn else { return "登录后可浏览自己的网盘文件" }
        var parts = [drive.platform.displayName]
        if case .loaded = drive.phase {
            parts.append("共 \(drive.files.count) 项")
        }
        if drive.canGoUp {
            parts.append("当前：\(drive.currentDirName)")
        }
        return parts.joined(separator: " · ")
    }

    /// 顶栏返回键：只在有上一级时出现，点了退出当前目录（不会退出 App）
    private var backAction: (() -> Void)? {
        guard drive.canGoUp, drive.isLoggedIn, !drive.selecting else { return nil }
        return { Task { await drive.goUp() } }
    }

    private var needsBreadcrumb: Bool {
        if case .needLogin = drive.phase { return false }
        return drive.canGoUp
    }

    // MARK: 平台切换

    private var platformSwitcher: some View {
        HStack(spacing: 6) {
            ForEach(drive.availablePlatforms) { platform in
                let active = platform == drive.platform
                Button {
                    Task { await drive.switchPlatform(platform) }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: platform.systemIcon)
                            .font(.system(size: 11, weight: .semibold))
                        Text(platform.shortName)
                            .font(AuroraFont.labelMedium)
                    }
                    .foregroundStyle(active ? Color.white : Aurora.inkSoft)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule().fill(
                            active
                                ? AnyShapeStyle(Aurora.brand)
                                : AnyShapeStyle(Color.white.opacity(0.92))
                        )
                    )
                    .overlay(
                        Capsule().stroke(
                            active ? Color.clear : Aurora.line.opacity(0.75),
                            lineWidth: 1
                        )
                    )
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AuroraMetrics.pagePadding)
        .padding(.bottom, 4)
    }

    // MARK: 多选条

    private var selectionBar: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("已选 \(drive.selected.count) 项")
                    .font(AuroraFont.labelLarge)
                    .foregroundStyle(Aurora.ink)
                Text(drive.selected.count > 0 ? drive.selectedSizeText : "点条目继续选择")
                    .font(.system(size: 11))
                    .foregroundStyle(Aurora.muted)
            }
            Spacer(minLength: 0)
            SmallTonalButton(text: "全选", systemIcon: "checkmark.circle") {
                drive.selectAll()
            }
            GradientButton(
                text: "下载",
                systemIcon: "arrow.down.circle.fill",
                enabled: !drive.selected.isEmpty,
                expands: false
            ) {
                Task { await drive.downloadSelected() }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(GlassSurface(shape: AuroraShape.control, highlight: 0.30))
        .padding(.horizontal, AuroraMetrics.pagePadding)
        .padding(.bottom, 6)
    }

    // MARK: 面包屑

    private var breadcrumb: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(drive.path.enumerated()), id: \.offset) { pair in
                    if pair.offset > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Aurora.outline)
                    }
                    Button {
                        guard pair.offset != drive.path.count - 1 else { return }
                        Task { await drive.goTo(index: pair.offset) }
                    } label: {
                        Text(pair.element.name)
                            .font(AuroraFont.labelMedium)
                            .foregroundStyle(
                                pair.offset == drive.path.count - 1 ? Aurora.ink : Aurora.brand
                            )
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

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        switch drive.phase {
        case .needLogin:
            centered {
                EmptyStateView(
                    systemIcon: "person.crop.circle.badge.exclamationmark",
                    title: "还没有登录网盘",
                    message: "登录夸克或 UC 后，可以在这里浏览网盘里的文件，勾选后直接下载。"
                ) {
                    GradientButton(
                        text: "去登录",
                        systemIcon: "person.crop.circle",
                        expands: false
                    ) {
                        model.tab = .accounts
                    }
                }
            }

        case .loading:
            centered {
                VStack(spacing: 10) {
                    ProgressView().tint(Aurora.brand)
                    Text("正在读取目录…")
                        .font(AuroraFont.bodySmall)
                        .foregroundStyle(Aurora.inkSoft)
                }
            }

        case .failed(let detail):
            centered {
                EmptyStateView(
                    systemIcon: "exclamationmark.triangle",
                    title: "加载失败",
                    message: detail
                ) {
                    SmallTonalButton(text: "重试", systemIcon: "arrow.clockwise") {
                        Task { await drive.reload() }
                    }
                }
            }

        case .idle, .loaded:
            if drive.files.isEmpty {
                centered {
                    EmptyStateView(
                        systemIcon: "folder",
                        title: "这个文件夹是空的",
                        message: "换个目录看看，或者到网盘网页端上传文件后再回来刷新。"
                    )
                }
            } else {
                list
            }
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(drive.files) { file in
                    row(file)
                }
            }
            .padding(.horizontal, AuroraMetrics.pagePadding)
            .padding(.top, 4)
            .padding(.bottom, 20)
        }
        .scrollIndicators(.hidden)
        .refreshable {
            await drive.reload()
        }
    }

    private func row(_ file: DriveFile) -> some View {
        let kind = FileKind.kind(for: file.name)
        let checked = drive.selected.contains(file.id)

        return Button {
            if drive.selecting {
                drive.toggle(file)
            } else if file.isFolder {
                Task { await drive.open(file) }
            } else {
                // 单击文件 = 立即下载这一个；要多选先点右上「选择」
                Task { await drive.download([file]) }
            }
        } label: {
            HStack(spacing: 10) {
                if drive.selecting {
                    SelectDot(isOn: checked)
                }

                PlatformIcon(
                    systemIcon: file.isFolder ? "folder.fill" : kind.systemIcon,
                    tint: file.isFolder ? Aurora.warning : kind.tint,
                    size: 40
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text(file.name)
                        .font(AuroraFont.labelLarge)
                        .foregroundStyle(Aurora.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        Text(file.sizeText)
                            .font(.system(size: 11))
                            .foregroundStyle(Aurora.muted)
                        if !file.updatedText.isEmpty {
                            Text("·")
                                .font(.system(size: 11))
                                .foregroundStyle(Aurora.outline)
                            Text(file.updatedText)
                                .font(.system(size: 11))
                                .foregroundStyle(Aurora.muted)
                        }
                    }
                }

                Spacer(minLength: 4)

                if file.isFolder {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Aurora.outline)
                } else {
                    // 行本身已经是按钮，这里只放装饰图标；下载走点击或 contextMenu
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
                    .fill(checked ? Aurora.brand.tint(0.07) : Color.white)
            )
            .overlay(
                AuroraShape.control.stroke(
                    checked ? Aurora.brand.opacity(0.35) : Aurora.line.opacity(0.6),
                    lineWidth: 1
                )
            )
        }
        .buttonStyle(PressScaleStyle(scale: 0.995))
        .contextMenu {
            if file.isFolder {
                Button {
                    Task { await drive.download([file]) }
                } label: {
                    Label("下载整个文件夹", systemImage: "arrow.down.circle")
                }
            } else {
                Button {
                    Task { await drive.download([file]) }
                } label: {
                    Label("加入下载", systemImage: "arrow.down.circle")
                }
            }
            Button {
                UIPasteboard.general.string = file.name
                model.show("已复制文件名", .success)
            } label: {
                Label("复制文件名", systemImage: "doc.on.doc")
            }
        }
    }

    // MARK: 辅助视图

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack {
            Spacer(minLength: 0)
            content()
                .padding(.horizontal, 24)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 批量取链时的遮罩：挡住误触，同时给出「3/20」的确定进度
    private var busyOverlay: some View {
        ZStack {
            Color.black.opacity(0.05).ignoresSafeArea()
            HStack(spacing: 10) {
                ProgressView().tint(Aurora.brand)
                Text(drive.busyText)
                    .font(AuroraFont.labelMedium)
                    .foregroundStyle(Aurora.ink)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(GlassSurface(shape: Capsule(), highlight: 0.40))
        }
        .transition(.opacity)
    }
}
