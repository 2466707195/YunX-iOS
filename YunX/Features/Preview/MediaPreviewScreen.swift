import SwiftUI
import AVFoundation
import UIKit

// MARK: - 媒体预览

/// 图片 / 视频 / 音频 / 文本的预览。
///
/// 本地已下载优先，其次走远程直链（带解析时拿到的 Referer/Cookie）。
/// 视频用 `AVPlayerLayer` 自绘（`PlayerLayerView`），**不挂 AVKit 的系统控件** ——
/// 否则一点播放/暂停，系统控制层就浮上来压住顶栏的标题和「存相册 / 分享」。
/// 播放控制（播放暂停、±15 秒）都在底部操作条里；点画面任意处也能切换播放。
/// 远程视频有些 CDN 只校验 Referer，`AVPlayer` 带不上自定义头，这类会播放失败（下载后即正常）。
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

    @State private var isPlaying = false
    /// 点画面切换播放时闪一下的图标（一会儿自动消失）
    @State private var flashGlyph: String?
    @State private var flashToken = 0

    var body: some View {
        ZStack {
            Color(hex: 0x0B0B12).ignoresSafeArea()

            content

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                bottomBar
            }
        }
        .task { await load() }
        .onDisappear { stopPlayback() }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { _ in
            isPlaying = false
        }
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
        case .video:
            if let player {
                ZStack {
                    PlayerLayerView(player: player)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { togglePlayback() }

                    if let flashGlyph {
                        Image(systemName: flashGlyph)
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 84, height: 84)
                            .background(Circle().fill(Color.black.opacity(0.42)))
                            .allowsHitTesting(false)
                    }
                }
                .onAppear { startPlayback() }
            } else {
                placeholder(icon: "play.slash", text: failedText ?? "准备中…")
            }
        case .audio:
            if let player {
                audioStage()
            } else {
                placeholder(icon: "waveform", text: failedText ?? "准备中…")
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

    /// 音频没有画面：一块「唱片」+ 中间播放键，点整块也能切播放。
    private func audioStage() -> some View {
        Button {
            togglePlayback()
        } label: {
            VStack(spacing: 18) {
                Image(systemName: "waveform")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(.white.opacity(isPlaying ? 0.95 : 0.55))
                    .frame(width: 132, height: 132)
                    .background(Circle().fill(Color.white.opacity(0.10)))
                    .overlay {
                        Circle()
                            .stroke(Color.white.opacity(0.16), lineWidth: 1)
                    }

                HStack(spacing: 7) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .bold))
                    Text(isPlaying ? "播放中" : "点击播放")
                        .font(AuroraFont.controlLabel)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, AuroraMetrics.controlButtonHPadding)
                .frame(height: AuroraMetrics.controlButtonHeight)
                .background(Capsule().fill(Color.white.opacity(0.14)))
            }
        }
        .buttonStyle(PressScaleStyle(scale: 0.97))
        .onAppear { startPlayback() }
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
        VStack(spacing: 8) {
            if media.kind == .video || media.kind == .audio {
                playbackControls
            }

            VStack(spacing: 4) {
                Text(media.sizeText + (media.quality.isEmpty ? "" : " · " + media.quality))
                    .font(AuroraFont.labelMedium)
                    .foregroundStyle(.white.opacity(0.85))
                Text(media.url)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .padding(.bottom, 12)
    }

    /// 自绘播放控制：播放/暂停 + 前后 15 秒。
    /// 放在底部操作条里，不压顶栏，也不占画面中间。
    private var playbackControls: some View {
        HStack(spacing: 10) {
            playerChip(icon: "gobackward.15", label: "后退 15 秒") { seek(by: -15) }

            Button {
                togglePlayback()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 14, weight: .bold))
                    Text(isPlaying ? "暂停" : "播放")
                        .font(AuroraFont.controlLabel)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, AuroraMetrics.controlButtonHPadding)
                .frame(height: AuroraMetrics.controlButtonHeight)
                .background(Capsule().fill(Color.white.opacity(0.18)))
            }
            .buttonStyle(PressScaleStyle(scale: 0.96))

            playerChip(icon: "goforward.15", label: "前进 15 秒") { seek(by: 15) }
        }
    }

    private func playerChip(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: AuroraMetrics.controlButtonHeight)
                .background(Capsule().fill(Color.white.opacity(0.12)))
                .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle(scale: 0.94))
        .accessibilityLabel(label)
    }

    // MARK: 播放控制

    private func startPlayback() {
        guard let player else { return }
        // 音频/视频都要能出声，静音键拨下也应该有声音（和系统播放器一致）
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: media.kind == .audio ? .default : .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        player.play()
        isPlaying = true
    }

    private func stopPlayback() {
        player?.pause()
        isPlaying = false
    }

    private func togglePlayback() {
        guard let player else { return }
        if player.timeControlStatus == .playing {
            player.pause()
            isPlaying = false
            flash("pause.fill")
        } else {
            startPlayback()
            flash("play.fill")
        }
    }

    private func seek(by seconds: Double) {
        guard let player else { return }
        let target = CMTimeAdd(player.currentTime(), CMTime(seconds: seconds, preferredTimescale: 600))
        let zero = CMTime.zero
        let end = player.currentItem?.duration ?? .indefinite
        var clamped = CMTimeMaximum(target, zero)
        if end.isNumeric {
            clamped = CMTimeMinimum(clamped, end)
        }
        player.seek(to: clamped, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// 点画面时闪一下刚触发的动作图标（0.55s 后自动淡出）。
    private func flash(_ glyph: String) {
        withAnimation(.easeOut(duration: 0.12)) { flashGlyph = glyph }
        flashToken += 1
        let token = flashToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            guard token == flashToken else { return }
            withAnimation(.easeOut(duration: 0.2)) { flashGlyph = nil }
        }
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
