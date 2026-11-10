import AVFoundation
import SwiftUI
import UIKit

/// Bare `AVPlayerLayer` surface with no `AVKit` controls.
///
/// `VideoPlayer` wraps `AVPlayerViewController` and therefore always brings the
/// native transport bar (the source of the double player in the viewer). A plain
/// layer host renders the video only, so the SwiftUI controls own every
/// interaction.
struct AVPlayerSurfaceView: UIViewRepresentable {
    /// Player to render; `nil` shows the layer's background fill.
    var player: AVPlayer?
    /// `.resizeAspect` keeps the video inside the frame (viewer), `.resizeAspectFill`
    /// fills a grid card.
    var videoGravity: AVLayerVideoGravity = .resizeAspect

    func makeUIView(context: Context) -> AVPlayerSurfaceUIView {
        let view = AVPlayerSurfaceUIView()
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false
        view.clipsToBounds = true
        view.playerLayer.videoGravity = videoGravity
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: AVPlayerSurfaceUIView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
        if view.playerLayer.videoGravity != videoGravity {
            view.playerLayer.videoGravity = videoGravity
        }
    }

    /// Releases the layer's player when SwiftUI tears the view down so an
    /// off-screen card never keeps a video pipeline alive.
    static func dismantleUIView(_ view: AVPlayerSurfaceUIView, coordinator: ()) {
        view.playerLayer.player = nil
    }
}

/// `UIView` whose backing layer is an `AVPlayerLayer`; no sublayer bookkeeping
/// and no implicit resizing work while the card scrolls.
final class AVPlayerSurfaceUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        // `layerClass` guarantees the backing layer type.
        layer as! AVPlayerLayer
    }
}
