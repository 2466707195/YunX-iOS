import Foundation
import AVFoundation

// MARK: - HLS

/// m3u8 分片下载：把整条流按顺序抓下来拼成一个 `.ts`。
///
/// 不做转码 —— 只做「拼接」。好处是不依赖 ffmpeg，任意播放器（VLC/IINA）都能放；
/// 代价是产物是 TS 容器，iOS 相册不认。AcFun 这类只有 m3u8 的平台走这条路。
enum HlsDownloader {

    static func download(
        m3u8: String,
        headers: [String: String],
        destination: URL,
        onBytes: @escaping (Int64) -> Void,
        isCancelled: @escaping () -> Bool
    ) async throws -> Int64 {
        let client = HTTPClient.desktop
        var playlistURL = m3u8
        var playlist = try await fetchPlaylist(client: client, url: playlistURL, headers: headers)

        // 主播放列表：取第一档码率的子播放列表（第一档通常是最高画质）
        if playlist.contents.contains("#EXT-X-STREAM-INF") {
            if let variant = firstVariantURL(in: playlist.contents, base: playlistURL) {
                playlistURL = variant
                playlist = try await fetchPlaylist(client: client, url: variant, headers: headers)
            }
        }

        if playlist.contents.contains("#EXT-X-KEY") && !playlist.contents.contains("METHOD=NONE") {
            throw VideoParseError(.unsupported, "该 HLS 流是加密的（AES-128），暂不支持下载")
        }

        let segments = segmentURLs(in: playlist.contents, base: playlistURL)
        guard !segments.isEmpty else {
            throw VideoParseError(.notFound, "m3u8 里没有分片")
        }

        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path) {
            try? manager.removeItem(at: destination)
        }
        guard manager.createFile(atPath: destination.path, contents: nil) else {
            throw DownloadError.io("无法创建输出文件")
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        var total: Int64 = 0
        for segment in segments {
            if isCancelled() || Task.isCancelled { throw DownloadError.cancelled }
            let response = try await client.get(segment, headers: headers)
            guard response.isOK else {
                throw DownloadError.badStatus(response.status)
            }
            try handle.write(contentsOf: response.data)
            total += Int64(response.data.count)
            onBytes(total)
        }
        return total
    }

    private struct Playlist {
        let contents: String
    }

    private static func fetchPlaylist(client: HTTPClient, url: String, headers: [String: String]) async throws -> Playlist {
        let response = try await client.get(url, headers: headers)
        guard response.isOK else { throw DownloadError.badStatus(response.status) }
        let text = response.text
        guard text.contains("#EXTM3U") else {
            throw VideoParseError(.unknown, "返回内容不是 m3u8 播放列表")
        }
        return Playlist(contents: text)
    }

    private static func firstVariantURL(in playlist: String, base: String) -> String? {
        var expectURL = false
        for rawLine in playlist.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#EXT-X-STREAM-INF") {
                expectURL = true
                continue
            }
            if expectURL && !line.hasPrefix("#") {
                return absolute(line, base: base)
            }
        }
        return nil
    }

    private static func segmentURLs(in playlist: String, base: String) -> [String] {
        var output: [String] = []
        for rawLine in playlist.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#EXT-X-MAP") {
                // 初始化分片（fMP4 的 moov），必须排在所有分片前面
                if let range = line.range(of: "URI=\"") {
                    let rest = line[range.upperBound...]
                    if let end = rest.firstIndex(of: "\"") {
                        output.append(absolute(String(rest[..<end]), base: base))
                    }
                }
                continue
            }
            if line.hasPrefix("#") { continue }
            output.append(absolute(line, base: base))
        }
        return output
    }

    private static func absolute(_ path: String, base: String) -> String {
        if path.hasPrefix("http") { return path }
        if let baseURL = URL(string: base), let resolved = URL(string: path, relativeTo: baseURL) {
            return resolved.absoluteString
        }
        return path
    }
}

// MARK: - DASH 合轨

/// 音视频分轨合并（B 站 DASH）。
///
/// 用 `AVMutableComposition` + 透传导出：**逐样本重封装，不重编码**，
/// 所以速度取决于磁盘 IO 而不是 CPU，画质也一点不掉。
/// 这与上游用 MediaExtractor/MediaMuxer 的做法等价，只是换成了 AVFoundation。
enum MediaMerger {

    static func merge(videoURL: URL, audioURL: URL, outputURL: URL) async throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: outputURL.path) {
            try? manager.removeItem(at: outputURL)
        }

        let videoAsset = AVURLAsset(url: videoURL)
        let audioAsset = AVURLAsset(url: audioURL)

        let composition = AVMutableComposition()
        guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first else {
            throw DownloadError.io("视频轨读取失败")
        }
        guard let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first else {
            throw DownloadError.io("音轨读取失败")
        }

        let videoDuration = try await videoAsset.load(.duration)
        let audioDuration = try await audioAsset.load(.duration)

        if let target = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try target.insertTimeRange(
                CMTimeRange(start: .zero, duration: videoDuration),
                of: videoTrack,
                at: .zero
            )
            target.preferredTransform = try await videoTrack.load(.preferredTransform)
        }
        if let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try target.insertTimeRange(
                CMTimeRange(start: .zero, duration: audioDuration),
                of: audioTrack,
                at: .zero
            )
        }

        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw DownloadError.io("无法创建导出会话")
        }
        export.outputURL = outputURL
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = false

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously {
                continuation.resume()
            }
        }

        if export.status != .completed {
            let reason = export.error?.localizedDescription ?? "未知原因"
            throw DownloadError.io("合轨失败：\(reason)")
        }
    }
}
