import SwiftUI
import AVKit
import UIKit

// MARK: - 媒体预览

/// 图片 / 视频 / 音频 / 文本的预览。
///
/// 本地已下载优先，其次走远程直链（带解析时拿到的 Referer/Cookie）。
/// 远程视频用 `AVPlayer` 直连 —— 有些 CDN 只校验 Referer，`AVPlayer` 带不上自定义头，
/// 这种情况会播放失败，属已知限制（下载下来再放就没问题）。
struct MediaPreviewScreen: View {

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let media: VideoMedia

    @State private var player: AVPlayer?
    @State private var image: UIImage?
    @State private var textContent: String?
    @State private var failedText: String?
    @State private var loaded = false

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var showShare = false

    var body: some View {
        ZStack {
            Color(hex: 0x0B0B12).ignoresSafeArea()

            content

            VStack {
                topBar
                Spacer()
                bottomBar
            }
        }
        .task { await load() }
        .sheet(isPresented: $showShare) {
            if let url = localURL, FileManager.default.fileExists(atPath: url.path) {
                ActivityView(items: [url])
            }
        }
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        switch media.kind {
        case .video, .audio:
            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
                    .onAppear { player.play() }
                    .onDisappear { player.pause() }
            } else {
                placeholder(icon: "play.slash", text: failedText ?? "准备中…")
            }
        case .image:
            if let image {
                GeometryReader { proxy in
                    ScrollView([.horizontal, .vertical], showsIndicators: false) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(width: proxy.size.width * scale)
                            .gesture(
                                MagnificationGesture()
                                    .onChanged { value in
                                        scale = min(5, max(1, lastScale * value))
                                    }
                                    .onEnded { _ in
                                        lastScale = scale
                                    }
                            )
                            .onTapGesture(count: 2) {
                                        withAnimation(.easeOut(duration: 0.2)) {
                                            scale = scale > 1 ? 1 : 2.2
                                            lastScale = scale
                                        }
                            }
                            .frame(minHeight: proxy.size.height)
                    }
                }
                .ignoresSafeArea()
            } else {
                placeholder(icon: "photo", text: failedText ?? "加载中…")
            }
        case .text:
            ScrollView {
                Text(textContent ?? failedText ?? "加载中…")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.92))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .textSelection(.enabled)
            }
            .padding(.top, 60)
            .padding(.bottom, 80)
        }
    }

    private func placeholder(icon: String, text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 34))
                .foregroundStyle(Color.white.opacity(0.6))
            Text(text)
                .font(AuroraFont.bodyMedium)
                .foregroundStyle(Color.white.opacity(0.75))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
        }
    }

    // MARK: 顶栏 / 底栏

    private var topBar: some View {
        HStack(spacing: 10) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.white.opacity(0.16)))
            }
            .buttonStyle(.plain)

            Text(media.fileName.isEmpty ? "预览" : media.fileName)
                .font(AuroraFont.labelLarge)
                .foregroundStyle(.white)
                .lineLimit(1)

            Spacer(minLength: 0)

            if media.kind == .image || media.kind == .video {
                Button {
                    exportToPhotos()
                } label: {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color.white.opacity(0.16)))
                }
                .buttonStyle(.plain)
            }

            Button {
                showShare = true
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.white.opacity(0.16)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }

    private var bottomBar: some View {
        VStack(spacing: 4) {
            Text(media.sizeText + (media.quality.isEmpty ? "" : " · " + media.quality))
                .font(AuroraFont.labelMedium)
                .foregroundStyle(.white.opacity(0.85))
            Text(media.url)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .padding(.bottom, 12)
    }

    // MARK: 加载

    private var localURL: URL? {
        let url = DownloadStore.shared.fileURL(for: media.fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func load() async {
        guard !loaded else { return }
        loaded = true

        if let local = localURL {
            switch media.kind {
            case .video, .audio:
                player = AVPlayer(url: local)
            case .image:
                image = UIImage(contentsOfFile: local.path)
            case .text:
                textContent = try? String(contentsOf: local, encoding: .utf8)
            }
            return
        }

        switch media.kind {
        case .video, .audio:
            if let url = URL(string: TextUtil.httpsURL(media.url)) {
                player = AVPlayer(url: url)
            }
        case .image:
            await loadRemoteImage()
        case .text:
            await loadRemoteText()
        }
    }

    private func loadRemoteImage() async {
        guard let url = URL(string: TextUtil.httpsURL(media.url)) else {
            failedText = "直链不合法"
            return
        }
        var request = URLRequest(url: url)
        for (name, value) in media.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let decoded = UIImage(data: data) else {
                failedText = "图片解码失败"
                return
            }
            image = decoded
        } catch {
            failedText = "加载失败：\(error.localizedDescription)"
        }
    }

    private func loadRemoteText() async {
        guard let url = URL(string: TextUtil.httpsURL(media.url)) else {
            failedText = "直链不合法"
            return
        }
        var request = URLRequest(url: url)
        for (name, value) in media.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            textContent = String(decoding: data.prefix(200_000), as: UTF8.self)
        } catch {
            failedText = "加载失败：\(error.localizedDescription)"
        }
    }

    private func exportToPhotos() {
        guard let local = localURL else {
            model.show("请先下载到本机再存入相册", .warning)
            return
        }
        model.saveToPhotos(url: local, isVideo: media.kind == .video)
    }
}

// MARK: - 系统分享

struct ActivityView: UIViewControllerRepresentable {

    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
