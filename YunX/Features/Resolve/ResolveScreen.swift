import SwiftUI
import UIKit

// MARK: - 解析页

/// Tab 1：粘贴链接 → 识别 → 分流到网盘浏览页或视频结果页。
///
/// 三个状态共用一个页面（不做 NavigationStack 压栈），这样 Tab 切换时状态不会丢：
/// - 空闲：输入表单（链接 + 提取码 + 快捷方式 + 最近解析）；
/// - 网盘：`ShareBrowserScreen`；
/// - 视频：`VideoResultScreen`。
struct ResolveScreen: View {

    @EnvironmentObject private var model: AppModel

    @State private var passcodeInput: String = ""
    @State private var showBookmarks = false

    private var resolve: ResolveCoordinator { model.resolve }

    var body: some View {
        ZStack {
            if let snapshot = resolve.snapshot {
                ShareBrowserScreen(snapshot: snapshot)
            } else if let video = resolve.videoResult {
                VideoResultScreen(result: video)
            } else {
                inputForm
            }

            if resolve.loading {
                BlockingLoading(text: "正在解析…")
            }
        }
        .sheet(item: linkSheetBinding) { sheet in
            LinkSheetView(sheet: sheet)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showBookmarks) {
            BookmarkSheet()
                .presentationDetents([.medium, .large])
        }
        .alert("该分享需要提取码", isPresented: passcodePromptBinding) {
            TextField("提取码", text: $passcodeInput)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("取消", role: .cancel) {
                passcodeInput = ""
            }
            Button("确定") {
                let code = passcodeInput
                passcodeInput = ""
                Task { await resolve.submitPasscode(code) }
            }
        } message: {
            Text("请输入分享者提供的提取码（一般在文案里）")
        }
    }

    // MARK: 输入表单

    private var inputForm: some View {
        VStack(spacing: 0) {
            AppTopBar(title: "解析", subtitle: "粘贴分享链接，一键解析分享内容") {
                if !resolve.input.isEmpty {
                    GlassIconButton(systemIcon: "xmark", tint: Aurora.inkSoft, diameter: 32, iconSize: 12) {
                        resolve.input = ""
                        resolve.clearDetectedLabel()
                    }
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: AuroraMetrics.cardSpacing) {

                    if let suggestion = model.clipboardSuggestion {
                        clipboardCard(suggestion)
                    }

                    if let error = resolve.errorMessage {
                        errorCard(error)
                    }

                    SectionCard {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 6) {
                                Image(systemName: "link")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Aurora.brand)
                                Text("分享链接 / 分享文案")
                                    .font(AuroraFont.labelLarge)
                                    .foregroundStyle(Aurora.ink)
                                Spacer(minLength: 0)
                                if !resolve.detectedLabel.isEmpty {
                                    PlatformBadge(text: resolve.detectedLabel, tint: Aurora.teal, systemIcon: "checkmark.circle.fill")
                                }
                            }

                            MultiLineInput(
                                text: inputBinding,
                                placeholder: "例如：\nhttps://pan.quark.cn/s/xxxx 提取码：abcd\n或抖音/小红书/B站的作品链接"
                            )

                            AuroraTextField(
                                placeholder: "提取码（可选，链接里带了就留空）",
                                text: passcodeBinding,
                                systemIcon: "key",
                                trailingSystemIcon: "doc.on.clipboard",
                                onTrailingTap: {
                                    if let text = UIPasteboard.general.string {
                                        resolve.input = text.trimmingCharacters(in: .whitespacesAndNewlines)
                                        resolve.detect()
                                    }
                                }
                            )

                            PrimaryButton(text: "开始解析", systemIcon: "bolt.fill") {
                                Task { await resolve.resolve() }
                            }
                        }
                    }

                    SectionHeader(title: "快捷方式", hint: "收藏的分享", action: { showBookmarks = true })
                    bookmarkRow

                    if !model.accounts.history.isEmpty {
                        SectionHeader(title: "最近解析", action: { model.accounts.clearHistory() }, actionTitle: "清空")
                        historyList
                    }
                }
                .padding(.horizontal, AuroraMetrics.pagePadding)
                .padding(.top, 4)
                .padding(.bottom, 28)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
        }
        .onChange(of: resolve.input) { _ in
            resolve.detect()
        }
    }

    // MARK: 剪贴板

    private func clipboardCard(_ text: String) -> some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "doc.on.clipboard.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Aurora.teal)
                    Text("剪贴板里有可解析的链接")
                        .font(AuroraFont.labelLarge)
                        .foregroundStyle(Aurora.ink)
                }
                Text(text)
                    .font(AuroraFont.bodySmall)
                    .foregroundStyle(Aurora.inkSoft)
                    .lineLimit(2)
                HStack(spacing: 10) {
                    SmallTonalButton(text: "解析它", systemIcon: "arrow.right.circle") {
                        model.dismissClipboardSuggestion()
                        Task { await resolve.resolve(text: text) }
                    }
                    TextLinkButton(text: "忽略") {
                        model.dismissClipboardSuggestion()
                    }
                }
            }
        }
    }

    // MARK: 错误提示

    private func errorCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Aurora.warning)
            Text(message)
                .font(AuroraFont.bodySmall)
                .foregroundStyle(Aurora.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                resolve.errorMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Aurora.muted)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Aurora.warningContainer)
        )
    }

    // MARK: 快捷方式

    @ViewBuilder
    private var bookmarkRow: some View {
        if model.accounts.bookmarks.isEmpty {
            SectionCard {
                HStack(spacing: 10) {
                    PlatformIcon(systemIcon: "bookmark", tint: Aurora.brand, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("还没有快捷方式")
                            .font(AuroraFont.labelLarge)
                            .foregroundStyle(Aurora.ink)
                        Text("解析成功后点收藏，就会出现在这里")
                            .font(AuroraFont.bodySmall)
                            .foregroundStyle(Aurora.inkSoft)
                    }
                    Spacer(minLength: 0)
                }
            }
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(model.accounts.bookmarks.prefix(12)) { bookmark in
                        Button {
                            Task { await resolve.resolve(text: bookmark.link) }
                        } label: {
                            HStack(spacing: 6) {
                                PlatformIcon(systemIcon: "bookmark.fill", tint: bookmark.tint, size: 26)
                                Text(bookmark.title)
                                    .font(AuroraFont.labelMedium)
                                    .foregroundStyle(Aurora.ink)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(GlassSurface(shape: Capsule(), shadowRadius: 6, highlight: 0.3))
                        }
                        .buttonStyle(PressScaleStyle(scale: 0.96))
                    }
                }
                .padding(.vertical, 2)
                .padding(.horizontal, 2)
            }
        }
    }

    // MARK: 历史

    private var historyList: some View {
        VStack(spacing: 8) {
            ForEach(model.accounts.history.prefix(8)) { item in
                Button {
                    Task { await resolve.resolve(text: item.link) }
                } label: {
                    HStack(spacing: 10) {
                        PlatformIcon(
                            systemIcon: platformIcon(for: item),
                            tint: platformTint(for: item),
                            size: 34
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title.isEmpty ? item.link : item.title)
                                .font(AuroraFont.labelLarge)
                                .foregroundStyle(Aurora.ink)
                                .lineLimit(1)
                            Text(item.createdAt.formatted("MM-dd HH:mm") + " · " + platformName(for: item))
                                .font(.system(size: 11))
                                .foregroundStyle(Aurora.muted)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.left")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Aurora.muted)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(AuroraShape.control.fill(Color.white))
                    .overlay(AuroraShape.control.stroke(Aurora.line.opacity(0.6), lineWidth: 1))
                }
                .buttonStyle(PressScaleStyle(scale: 0.99))
            }
        }
    }

    private func platformIcon(for item: ResolveHistory) -> String {
        if let platform = SharePlatform(rawValue: item.platform) { return platform.systemIcon }
        if let platform = VideoPlatform(rawValue: item.platform) { return platform.systemIcon }
        return "link"
    }

    private func platformTint(for item: ResolveHistory) -> Color {
        if let platform = SharePlatform(rawValue: item.platform) { return platform.tint }
        if let platform = VideoPlatform(rawValue: item.platform) { return platform.tint }
        return Aurora.brand
    }

    private func platformName(for item: ResolveHistory) -> String {
        if let platform = SharePlatform(rawValue: item.platform) { return platform.displayName }
        if let platform = VideoPlatform(rawValue: item.platform) { return platform.displayName }
        return item.platform
    }

    // MARK: 绑定

    private var inputBinding: Binding<String> {
        Binding(
            get: { model.resolve.input },
            set: { model.resolve.input = $0 }
        )
    }

    private var passcodeBinding: Binding<String> {
        Binding(
            get: { model.resolve.passcode },
            set: { model.resolve.passcode = $0 }
        )
    }

    private var passcodePromptBinding: Binding<Bool> {
        Binding(
            get: { model.resolve.passcodePrompt },
            set: { model.resolve.passcodePrompt = $0 }
        )
    }

    private var linkSheetBinding: Binding<LinkSheetModel?> {
        Binding(
            get: { model.resolve.linkSheet },
            set: { model.resolve.linkSheet = $0 }
        )
    }
}

// MARK: - 直链弹窗

struct LinkSheetView: View {

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let sheet: LinkSheetModel

    var body: some View {
        SheetScaffold(title: sheet.title, subtitle: subtitle) {
            if let link = sheet.primary {
                SectionCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("下载直链")
                            .font(AuroraFont.labelLarge)
                            .foregroundStyle(Aurora.ink)
                        Text(link.url)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(Aurora.inkSoft)
                            .lineLimit(5)
                            .textSelection(.enabled)
                        HStack(spacing: 10) {
                            SmallTonalButton(text: "复制链接", systemIcon: "doc.on.doc") {
                                UIPasteboard.general.string = link.url
                                model.show("已复制直链", .success)
                            }
                            if link.size > 0 {
                                TinyChip(text: ByteCountFormatter.string(fromByteCount: link.size, countStyle: .file))
                            }
                        }
                        Text("直链通常 15~30 分钟后失效，加入下载后请尽快开始。")
                            .font(.system(size: 11))
                            .foregroundStyle(Aurora.muted)
                    }
                }
            }

            if sheet.links.count > 1 {
                SectionCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("共 \(sheet.links.count) 个文件")
                            .font(AuroraFont.labelLarge)
                            .foregroundStyle(Aurora.ink)
                        ForEach(sheet.links.indices, id: \.self) { index in
                            HStack {
                                Text(sheet.links[index].fileName)
                                    .font(AuroraFont.bodySmall)
                                    .foregroundStyle(Aurora.ink)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                Text(ByteCountFormatter.string(fromByteCount: max(0, sheet.links[index].size), countStyle: .file))
                                    .font(.system(size: 11))
                                    .foregroundStyle(Aurora.muted)
                            }
                        }
                    }
                }
            }

            GradientButton(text: sheet.links.count > 1 ? "全部加入下载" : "开始下载", systemIcon: "arrow.down.circle.fill") {
                model.resolve.downloadLinksFromSheet()
                dismiss()
            }

            TextLinkButton(text: "关掉", systemIcon: nil) { dismiss() }
                .frame(maxWidth: .infinity)
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let link = sheet.primary, link.size > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: link.size, countStyle: .file))
        }
        if sheet.links.count > 1 { parts.append("\(sheet.links.count) 个文件") }
        parts.append("下载后可在「下载」页查看进度")
        return parts.joined(separator: " · ")
    }
}

// MARK: - 收藏管理

struct BookmarkSheet: View {

    @EnvironmentObject private var model: AppModel

    var body: some View {
        SheetScaffold(title: "快捷方式", subtitle: "点一条即可重新解析") {
            if model.accounts.bookmarks.isEmpty {
                EmptyStateView(systemIcon: "bookmark", title: "还没有收藏", message: "在网盘分享页点「收藏」，就会出现在这里。")
                    .padding(.top, 30)
            } else {
                ForEach(model.accounts.bookmarks) { bookmark in
                    SectionCard {
                        HStack(spacing: 10) {
                            PlatformIcon(systemIcon: "bookmark.fill", tint: bookmark.tint, size: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(bookmark.title)
                                    .font(AuroraFont.labelLarge)
                                    .foregroundStyle(Aurora.ink)
                                    .lineLimit(1)
                                Text(bookmark.link)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Aurora.muted)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            GlassIconButton(systemIcon: "trash", tint: Aurora.rose, diameter: 30, iconSize: 12) {
                                model.accounts.removeBookmark(bookmark)
                            }
                        }
                    }
                }
            }
        }
    }
}
