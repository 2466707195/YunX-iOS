import SwiftUI
import UIKit

// MARK: - 视频/图集结果页

/// 一条作品解析成功后的结果页。
///
/// - 视频：单条（或多条，如 B 站分轨只有一条），行内可直接预览或下载；
/// - 图集：两列网格，进「选择」模式后可批量下载。
struct VideoResultScreen: View {

    @EnvironmentObject private var model: AppModel
    let result: VideoParseResult

    @State private var preview: VideoMedia?
    @State private var selecting = false

    private var resolve: ResolveCoordinator { model.resolve }

    private var images: [VideoMedia] {
        result.medias.filter { $0.kind == .image }
    }

    private var videos: [VideoMedia] {
        result.medias.filter { $0.kind != .image }
    }

    var body: some View {
        VStack(spacing: 0) {
            AppTopBar(
                title: result.platform.displayName,
                subtitle: result.author.isEmpty ? nil : "@" + result.author,
                onBack: {
                    if selecting {
                        selecting = false
                        resolve.clearSelection()
                    } else {
                        resolve.reset()
                    }
                }
            ) {
                HStack(spacing: 6) {
                    if !result.medias.isEmpty {
                        GlassIconButton(
                            systemIcon: selecting ? "xmark.circle" : "checkmark.circle",
                            tint: selecting ? Aurora.rose : Aurora.inkSoft,
                            diameter: 32,
                            iconSize: 12
                        ) {
                            withAnimation(.easeOut(duration: 0.18)) {
                                selecting.toggle()
                                if selecting {
                                    resolve.selectAll()
                                } else {
                                    resolve.clearSelection()
                                }
                            }
                        }
                    }
                    GlassIconButton(systemIcon: "doc.on.doc", tint: Aurora.inkSoft, diameter: 32, iconSize: 12) {
                        resolve.copy(result.url)
                    }
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: AuroraMetrics.cardSpacing) {
                    headerCard

                    if !result.notice.isEmpty {
                        noticeCard(result.notice)
                    }

                    if !result.text.isEmpty, result.text != result.title {
                        textCard
                    }

                    if !videos.isEmpty {
                        SectionHeader(title: "视频", hint: "\(videos.count) 个")
                        ForEach(videos) { media in
                            videoRow(media)
                        }
                    }

                    if !images.isEmpty {
                        SectionHeader(
                            title: "图集",
                            hint: "\(images.count) 张" + (selecting ? " · 已选 \(resolve.selectedMediaIDs.count)" : ""),
                            action: selecting ? ({ resolve.selectAll() }) : nil,
                            actionTitle: "全选"
                        )
                        imageGrid
                    }

                    disclaimer
                }
                .padding(.horizontal, AuroraMetrics.pagePadding)
                .padding(.top, 4)
                .padding(.bottom, 30)
            }
            .scrollIndicators(.hidden)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomBar
                .padding(.horizontal, AuroraMetrics.pagePadding)
                .padding(.top, 6)
                .padding(.bottom, 8)
        }
        .sheet(item: $preview) { media in
            MediaPreviewScreen(media: media)
        }
    }

    // MARK: 头部

    private var headerCard: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 10) {
                if !result.cover.isEmpty {
                    RemoteImageFill(url: result.cover, headers: headerFields, height: 176, cornerRadius: 14)
                }
                HStack(spacing: 6) {
                    PlatformBadge(text: result.platform.displayName, tint: result.platform.tint, systemIcon: result.platform.systemIcon)
                    if !result.timeText.isEmpty {
                        TinyChip(text: result.timeText)
                    }
                    if result.videoCount > 0 {
                        TinyChip(text: "视频 \(result.videoCount)", tint: Aurora.brand)
                    }
                    if result.imageCount > 0 {
                        TinyChip(text: "图片 \(result.imageCount)", tint: Aurora.teal)
                    }
                }
                Text(result.title.isEmpty ? "未命名作品" : result.title)
                    .font(AuroraFont.titleLarge)
                    .foregroundStyle(Aurora.ink)
                    .fixedSize(horizontal: false, vertical: true)

                if !result.author.isEmpty {
                    HStack(spacing: 8) {
                        if !result.avatar.isEmpty {
                            RemoteThumbnail(url: result.avatar, size: 26, cornerRadius: 13, systemIcon: "person.crop.circle")
                        }
                        Text(result.author)
                            .font(AuroraFont.labelMedium)
                            .foregroundStyle(Aurora.inkSoft)
                        Spacer(minLength: 0)
                        TextLinkButton(text: "打开原链接", systemIcon: "arrow.up.right") {
                            if let url = URL(string: result.url) { UIApplication.shared.open(url) }
                        }
                    }
                }
            }
        }
    }

    private var headerFields: [String: String] {
        result.medias.first?.headers ?? [:]
    }

    private func noticeCard(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Aurora.warning)
            Text(text)
                .font(AuroraFont.bodySmall)
                .foregroundStyle(Aurora.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Aurora.warningContainer))
    }

    private var textCard: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 6) {
                Text("正文")
                    .font(AuroraFont.labelLarge)
                    .foregroundStyle(Aurora.ink)
                Text(result.text)
                    .font(AuroraFont.bodyMedium)
                    .foregroundStyle(Aurora.inkSoft)
                    .lineLimit(8)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: 视频行

    private func videoRow(_ media: VideoMedia) -> some View {
        SectionCard {
            HStack(spacing: 10) {
                Button {
                    preview = media
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Aurora.brand.tint(0.10))
                            .frame(width: 46, height: 46)
                        Image(systemName: "play.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Aurora.brand)
                    }
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 3) {
                    Text(media.fileName.isEmpty ? "视频" : media.fileName)
                        .font(AuroraFont.labelLarge)
                        .foregroundStyle(Aurora.ink)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if !media.quality.isEmpty {
                            TinyChip(text: media.quality, tint: Aurora.brand)
                        }
                        if media.isHls {
                            TinyChip(text: "HLS", tint: Aurora.teal)
                        }
                        if media.isSplitTrack {
                            TinyChip(text: "音视频分轨", tint: Aurora.warning)
                        }
                        Text(media.sizeText)
                            .font(.system(size: 11))
                            .foregroundStyle(Aurora.muted)
                    }
                }

                Spacer(minLength: 0)

                GlassIconButton(systemIcon: "arrow.down", tint: Aurora.brand, diameter: 32, iconSize: 12) {
                    resolve.downloadVideo(media)
                }
            }
        }
    }

    // MARK: 图集网格

    private var imageGrid: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 8),
                GridItem(.flexible(), spacing: 8)
            ],
            spacing: 8
        ) {
            ForEach(images) { media in
                Button {
                    if selecting {
                        resolve.toggleSelection(media)
                    } else {
                        preview = media
                    }
                } label: {
                    ZStack(alignment: .topTrailing) {
                        RemoteImageFill(
                            url: media.url,
                            headers: media.headers,
                            height: 150,
                            cornerRadius: 16,
                            systemIcon: "photo"
                        )
                        if selecting {
                            SelectDot(isOn: resolve.selectedMediaIDs.contains(media.id))
                                .padding(8)
                        } else if !media.motionUrl.isEmpty {
                            TinyChip(text: "动图", tint: Aurora.rose)
                                .padding(8)
                        }
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(
                                resolve.selectedMediaIDs.contains(media.id) ? Aurora.brand : Color.clear,
                                lineWidth: 2
                            )
                    )
                }
                .buttonStyle(PressScaleStyle(scale: 0.97))
            }
        }
    }

    // MARK: 底部

    private var bottomBar: some View {
        GlassBar {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(result.platform.displayName)
                        .font(AuroraFont.labelLarge)
                        .foregroundStyle(Aurora.ink)
                    Text("已选 \(resolve.selectedMediaIDs.count) / \(result.medias.count)")
                        .font(.system(size: 11))
                        .foregroundStyle(Aurora.muted)
                }
                Spacer(minLength: 0)
                SmallTonalButton(text: "全部下载", systemIcon: "arrow.down.circle") {
                    resolve.downloadVideo(all: true)
                }
                SmallTonalButton(
                    text: "下载所选",
                    systemIcon: "arrow.down.to.line",
                    enabled: !resolve.selectedMediaIDs.isEmpty
                ) {
                    resolve.downloadVideo(all: false)
                }
            }
        }
    }

    private var disclaimer: some View {
        Text("内容版权归原作者所有，下载仅用于个人学习与备份，请勿传播。")
            .font(.system(size: 11))
            .foregroundStyle(Aurora.muted)
            .padding(.horizontal, 6)
            .padding(.top, 6)
    }
}
