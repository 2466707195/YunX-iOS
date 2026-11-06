import SwiftUI
import UIKit

// MARK: - 下载页

/// Tab 3：任务队列。分组可折叠，单条可暂停/继续/删除/预览。
struct DownloadScreen: View {

    @EnvironmentObject private var model: AppModel

    @State private var preview: DownloadTask?
    @State private var pendingDelete: DownloadTask?

    private var downloads: DownloadManager { model.downloads }

    var body: some View {
        VStack(spacing: 0) {
            AppTopBar(title: "下载", subtitle: subtitle) {
                HStack(spacing: 6) {
                    GlassIconButton(
                        systemIcon: downloads.queuePaused ? "play.fill" : "pause.fill",
                        tint: Aurora.inkSoft,
                        diameter: 32,
                        iconSize: 12
                    ) {
                        if downloads.queuePaused {
                            downloads.resumeAll()
                        } else {
                            downloads.pauseAll()
                        }
                    }
                    Menu {
                        Button {
                            downloads.resumeAll()
                        } label: {
                            Label("全部开始", systemImage: "play.fill")
                        }
                        Button {
                            downloads.pauseAll()
                        } label: {
                            Label("全部暂停", systemImage: "pause.fill")
                        }
                        Divider()
                        Button {
                            // 只清任务记录，文件保留在「文件」App 里 —— 不需要二次确认
                            downloads.clearCompleted(deleteFile: false)
                            model.show("已清理完成的任务记录", .info)
                        } label: {
                            Label("清理已完成任务", systemImage: "trash")
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

            if downloads.tasks.isEmpty {
                Spacer()
                EmptyStateView(
                    systemIcon: "arrow.down.circle",
                    title: "还没有下载任务",
                    message: "在「解析」页解析分享或视频后，点下载就会出现在这里。"
                )
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: AuroraMetrics.cardSpacing) {
                        statsCard
                        ForEach(Array(downloads.groupedTasks.enumerated()), id: \.offset) { pair in
                            groupSection(group: pair.element.group, tasks: pair.element.tasks)
                        }
                    }
                    .padding(.horizontal, AuroraMetrics.pagePadding)
                    .padding(.top, 4)
                    .padding(.bottom, 28)
                }
                .scrollIndicators(.hidden)
            }
        }
        .sheet(item: $preview) { task in
            MediaPreviewScreen(media: VideoMedia(
                url: task.url,
                kind: task.kind == .image ? .image : (task.kind == .audio ? .audio : .video),
                fileName: task.fileName,
                size: task.totalSize,
                headers: task.headers
            ))
        }
        .confirmationDialog(
            "删除「\(pendingDelete?.fileName ?? "")」？",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("只删任务（保留文件）") {
                if let task = pendingDelete { downloads.remove(task.id, deleteFile: false) }
                pendingDelete = nil
            }
            Button("任务和文件一起删除", role: .destructive) {
                if let task = pendingDelete { downloads.remove(task.id, deleteFile: true) }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        }
    }

    // MARK: 统计

    private var subtitle: String {
        if downloads.tasks.isEmpty { return "断点续传 · Range 分片并发" }
        return "进行中 \(downloads.runningCount) · 等待 \(downloads.tasks.filter { $0.status == .pending }.count)"
    }

    private var statsCard: some View {
        SectionCard {
            HStack(spacing: 10) {
                StatTile(
                    title: "总速度",
                    value: downloads.totalSpeed > 0
                        ? ByteCountFormatter.string(fromByteCount: downloads.totalSpeed, countStyle: .file) + "/s"
                        : "—",
                    tint: Aurora.brand
                )
                Divider().frame(height: 28).background(Aurora.hairline)
                StatTile(title: "进行中", value: "\(downloads.runningCount)", tint: Aurora.info)
                Divider().frame(height: 28).background(Aurora.hairline)
                StatTile(title: "已完成", value: "\(downloads.tasks.filter { $0.status == .completed }.count)", tint: Aurora.success)
                Divider().frame(height: 28).background(Aurora.hairline)
                StatTile(title: "失败", value: "\(downloads.failedCount)", tint: Aurora.rose)
            }
        }
    }

    // MARK: 分组

    @ViewBuilder
    private func groupSection(group: DownloadGroup?, tasks: [DownloadTask]) -> some View {
        if let group {
            Button {
                withAnimation(.easeOut(duration: 0.18)) {
                    downloads.toggleGroup(group)
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: downloads.isCollapsed(group) ? "chevron.right" : "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Aurora.muted)
                    PlatformIcon(systemIcon: "folder.fill", tint: Aurora.brand, size: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(group.title)
                            .font(AuroraFont.labelLarge)
                            .foregroundStyle(Aurora.ink)
                            .lineLimit(1)
                        Text("\(group.platformName) · \(tasks.count) 个文件")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Aurora.muted)
                    }
                    Spacer(minLength: 0)
                    Text(groupProgressText(tasks))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Aurora.brand)
                        .monospacedDigit()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(AuroraShape.control.fill(Color.white.opacity(0.65)))
                .overlay(AuroraShape.control.stroke(Aurora.line.opacity(0.5), lineWidth: 1))
            }
            .buttonStyle(.plain)

            if !downloads.isCollapsed(group) {
                ForEach(tasks) { task in
                    taskCard(task)
                }
            }
        } else {
            ForEach(tasks) { task in
                taskCard(task)
            }
        }
    }

    private func groupProgressText(_ tasks: [DownloadTask]) -> String {
        let done = tasks.filter { $0.status == .completed }.count
        return "\(done)/\(tasks.count)"
    }

    // MARK: 任务卡片

    private func taskCard(_ task: DownloadTask) -> some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    PlatformIcon(systemIcon: task.kind.systemIcon, tint: task.kind.tint, size: 38)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(task.fileName)
                            .font(AuroraFont.labelLarge)
                            .foregroundStyle(Aurora.ink)
                            .lineLimit(1)
                        Text(statusLine(task))
                            .font(.system(size: 11))
                            .foregroundStyle(task.status == .failed ? Aurora.danger : Aurora.muted)
                            .lineLimit(1)
                            .monospacedDigit()
                    }

                    Spacer(minLength: 4)

                    if task.status == .completed {
                        GlassIconButton(systemIcon: "play.rectangle", tint: Aurora.success, diameter: 30, iconSize: 12) {
                            preview = task
                        }
                    } else if task.status == .running {
                        GlassIconButton(systemIcon: "pause.fill", tint: Aurora.inkSoft, diameter: 30, iconSize: 12) {
                            downloads.pause(task.id)
                        }
                    } else {
                        GlassIconButton(systemIcon: "play.fill", tint: Aurora.brand, diameter: 30, iconSize: 12) {
                            downloads.resume(task.id)
                        }
                    }

                    GlassIconButton(systemIcon: "xmark", tint: Aurora.rose, diameter: 30, iconSize: 11) {
                        pendingDelete = task
                    }
                }

                if task.status == .running || task.status == .paused {
                    ThinProgressBar(value: task.progress)
                    HStack(spacing: 6) {
                        Text(task.sizeText)
                        if task.status == .running, !task.speedText.isEmpty {
                            Text("·")
                            Text(task.speedText)
                        }
                        if task.status == .running, !task.remainingText.isEmpty {
                            Text("·")
                            Text(task.remainingText)
                        }
                        if task.chunkCount > 1 {
                            Text("·")
                            Text("\(task.chunkCount) 分片")
                        }
                        Spacer(minLength: 0)
                        Text(task.progressText)
                            .foregroundStyle(Aurora.brand)
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(Aurora.muted)
                    .monospacedDigit()
                }

                if task.status == .failed, !task.errorMessage.isEmpty {
                    HStack(spacing: 8) {
                        Text(task.errorMessage)
                            .font(.system(size: 11))
                            .foregroundStyle(Aurora.danger)
                            .lineLimit(2)
                        Spacer(minLength: 0)
                        TextLinkButton(text: "重试", systemIcon: "arrow.clockwise") {
                            downloads.retry(task.id)
                        }
                    }
                }
            }
        }
        .contextMenu {
            if task.status == .completed {
                Button {
                    preview = task
                } label: {
                    Label("预览", systemImage: "eye")
                }
                Button {
                    if let url = downloads.openURL(for: task) {
                        UIPasteboard.general.string = url.absoluteString
                        model.show("已复制文件路径", .success)
                    }
                } label: {
                    Label("复制文件路径", systemImage: "doc.on.doc")
                }
                Button {
                    if let url = downloads.openURL(for: task) {
                        model.saveToPhotos(url: url, isVideo: task.kind == .video)
                    }
                } label: {
                    Label("存入相册", systemImage: "photo.on.rectangle")
                }
            }
            Button {
                UIPasteboard.general.string = task.url
                model.show("已复制直链", .success)
            } label: {
                Label("复制直链", systemImage: "link")
            }
            Divider()
            Button(role: .destructive) {
                pendingDelete = task
            } label: {
                Label("删除任务", systemImage: "trash")
            }
        }
    }

    private func statusLine(_ task: DownloadTask) -> String {
        if task.isPreparing { return "准备中：探测文件大小…" }
        switch task.status {
        case .running:
            var parts = ["下载中"]
            if !task.speedText.isEmpty { parts.append(task.speedText) }
            if !task.remainingText.isEmpty { parts.append(task.remainingText) }
            return parts.joined(separator: " · ")
        case .pending: return "等待中 · 排队"
        case .paused: return "已暂停 · " + task.sizeText
        case .completed:
            var parts = ["已完成", task.sizeText]
            if task.avgSpeed > 0 {
                parts.append("均速 " + ByteCountFormatter.string(fromByteCount: task.avgSpeed, countStyle: .file) + "/s")
            }
            return parts.joined(separator: " · ")
        case .failed: return "失败 · " + task.sizeText
        }
    }
}
