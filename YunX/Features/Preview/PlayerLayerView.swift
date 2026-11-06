import SwiftUI
import AVFoundation

// MARK: - 纯画面播放层

/// 只把 `AVPlayer` 的画面画出来，**不带任何 AVKit 系统控件**。
///
/// 为什么不用 `VideoPlayer`（= `AVPlayerViewController`）：
/// 它在点击播放/暂停时会浮出一整套系统控制层（关闭、标题、下载、分享…），
/// 正好压在我们自己的顶栏上，形成「这块有遮挡」。
/// 这里改用 `AVPlayerLayer`，一帧 chrome 都不画，播放/暂停由我们自己实现。
struct PlayerLayerView: UIViewRepresentable {

    let player: AVPlayer
    var videoGravity: AVLayerVideoGravity = .resizeAspect

    func makeUIView(context: Context) -> PlayerHostView {
        let view = PlayerHostView()
        view.backgroundColor = .clear
        view.playerLayer.videoGravity = videoGravity
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ uiView: PlayerHostView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
        uiView.playerLayer.videoGravity = videoGravity
    }
}

/// 承载 `AVPlayerLayer` 的容器：把 layerClass 换成 AVPlayerLayer，
/// 这样不用手动维护 frame，旋转、分屏都不会错位。
final class PlayerHostView: UIView {

    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        // layerClass 已经保证类型
        layer as! AVPlayerLayer
    }
}
