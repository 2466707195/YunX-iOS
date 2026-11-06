import SwiftUI
import UIKit

// MARK: - 平台图标

/// 平台图标小方块：浅色底 + 单色图标。全应用唯一入口，不要在页面里各画一份。
struct PlatformIcon: View {

    let systemIcon: String
    let tint: Color
    var size: CGFloat = 42

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(tint.tint(0.12))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: systemIcon)
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(tint)
            )
    }
}

// MARK: - 平台胶囊

struct PlatformBadge: View {

    let text: String
    var tint: Color = Aurora.brand
    var systemIcon: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let systemIcon {
                Image(systemName: systemIcon)
                    .font(.system(size: 9, weight: .bold))
            }
            Text(text)
                .font(AuroraFont.labelSmall)
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(tint.tint(0.12)))
    }
}

// MARK: - 细进度条

struct ThinProgressBar: View {

    var value: Double
    var tint: Color = Aurora.brand
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Aurora.surfaceVariant)
                Capsule()
                    .fill(tint)
                    .frame(width: max(0, min(1, value)) * proxy.size.width)
            }
        }
        .frame(height: height)
    }
}

// MARK: - 统计块

struct StatTile: View {

    let title: String
    let value: String
    var tint: Color = Aurora.ink

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(AuroraFont.labelSmall)
                .foregroundStyle(Aurora.muted)
            Text(value)
                .font(AuroraFont.titleMedium)
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 小标签

struct TinyChip: View {

    let text: String
    var tint: Color = Aurora.inkSoft

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(tint.tint(0.10)))
    }
}

// MARK: - 多行输入

/// 解析页的链接输入框：要能吃下整段分享文案（多行），所以用 TextEditor。
struct MultiLineInput: View {

    @Binding var text: String
    var placeholder: String
    var minHeight: CGFloat = 96

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(AuroraFont.bodyMedium)
                    .foregroundStyle(Aurora.muted)
                    .padding(.top, 8)
                    .padding(.leading, 5)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .font(AuroraFont.bodyMedium)
                .foregroundStyle(Aurora.ink)
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .frame(minHeight: minHeight, alignment: .topLeading)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(AuroraShape.control.fill(Color.white))
        .overlay(AuroraShape.control.stroke(Aurora.line, lineWidth: 1))
    }
}

// MARK: - 弹窗骨架

/// 所有 sheet 的统一骨架：极光底 + 标题 + 关闭按钮 + 可滚动内容。
struct SheetScaffold<Content: View>: View {

    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: () -> Content

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            AuroraBackdrop()
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(AuroraFont.titleLarge)
                            .foregroundStyle(Aurora.ink)
                            .lineLimit(2)
                        if let subtitle {
                            Text(subtitle)
                                .font(AuroraFont.bodySmall)
                                .foregroundStyle(Aurora.inkSoft)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                    GlassIconButton(systemIcon: "xmark", tint: Aurora.inkSoft, diameter: 30, iconSize: 12) {
                        dismiss()
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 12)

                ScrollView {
                    VStack(alignment: .leading, spacing: AuroraMetrics.cardSpacing) {
                        content()
                    }
                    .padding(.horizontal, AuroraMetrics.pagePadding)
                    .padding(.bottom, 28)
                }
                .scrollIndicators(.hidden)
            }
        }
    }
}

// MARK: - 加载遮罩

struct BlockingLoading: View {

    let text: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.06).ignoresSafeArea()
            HStack(spacing: 10) {
                ProgressView()
                    .tint(Aurora.brand)
                Text(text)
                    .font(AuroraFont.labelMedium)
                    .foregroundStyle(Aurora.ink)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(GlassSurface(shape: Capsule(), highlight: 0.4))
        }
        .transition(.opacity)
    }
}

// MARK: - 选择圆点

struct SelectDot: View {

    let isOn: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(isOn ? Aurora.brand : Color.white)
                .frame(width: 22, height: 22)
            Circle()
                .strokeBorder(isOn ? Aurora.brand : Aurora.outline, lineWidth: 1.4)
                .frame(width: 22, height: 22)
            if isOn {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.white)
            }
        }
    }
}

// MARK: - 远程缩略图

/// 带内存缓存的远程图片。列表里用它，避免每次滚动都重新下载。
struct RemoteThumbnail: View {

    let url: String
    var size: CGFloat = 44
    var cornerRadius: CGFloat = 12
    var systemIcon: String = "photo"

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Aurora.surfaceVariant)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            } else {
                Image(systemName: failed ? systemIcon : "photo")
                    .font(.system(size: size * 0.34, weight: .regular))
                    .foregroundStyle(Aurora.muted)
            }
        }
        .frame(width: size, height: size)
        .task(id: url) {
            await load()
        }
    }

    private func load() async {
        guard !url.isEmpty, let target = URL(string: TextUtil.httpsURL(url)) else {
            failed = true
            return
        }
        if let cached = ImageCache.shared.object(forKey: target.absoluteString as NSString) {
            image = cached
            return
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: target)
            guard let decoded = UIImage(data: data) else {
                failed = true
                return
            }
            ImageCache.shared.setObject(decoded, forKey: target.absoluteString as NSString)
            image = decoded
        } catch {
            failed = true
        }
    }
}

/// 缩略图内存缓存（列表滚动时不重复下载）
enum ImageCache {

    static let shared: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 200
        return cache
    }()
}

// MARK: - 远程图片（带请求头、自适应宽度）

/// 图集网格用：宽度跟随容器、高度固定、aspectFill。
/// 必须能带请求头 —— 小红书/Pixiv 的原图直链不带 Referer 会 403。
struct RemoteImageFill: View {

    let url: String
    var headers: [String: String] = [:]
    var height: CGFloat = 148
    var cornerRadius: CGFloat = 16
    var systemIcon: String = "photo"

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Aurora.surfaceVariant)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(height: height)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            } else {
                VStack(spacing: 6) {
                    Image(systemName: failed ? systemIcon : "photo")
                        .font(.system(size: 22))
                        .foregroundStyle(Aurora.muted)
                    if !failed {
                        ProgressView().scaleEffect(0.7).tint(Aurora.muted)
                    }
                }
            }
        }
        .frame(height: height)
        .task(id: url) { await load() }
    }

    private func load() async {
        guard !url.isEmpty, let target = URL(string: TextUtil.httpsURL(url)) else {
            failed = true
            return
        }
        let key = (url + "|" + headers.values.joined()).hash.description as NSString
        if let cached = ImageCache.shared.object(forKey: key) {
            image = cached
            return
        }
        var request = URLRequest(url: target)
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let decoded = UIImage(data: data) else {
                failed = true
                return
            }
            ImageCache.shared.setObject(decoded, forKey: key)
            image = decoded
        } catch {
            failed = true
        }
    }
}

// MARK: - 分组标题

struct SectionHeader: View {

    let title: String
    var hint: String? = nil
    var action: (() -> Void)? = nil
    var actionTitle: String = "管理"

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(AuroraFont.labelLarge)
                .foregroundStyle(Aurora.inkSoft)
            if let hint {
                Text(hint)
                    .font(AuroraFont.labelSmall)
                    .foregroundStyle(Aurora.muted)
            }
            Spacer(minLength: 0)
            if let action {
                TextLinkButton(text: actionTitle, systemIcon: nil, action: action)
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 6)
    }
}
