import AVFoundation
import SwiftUI
import UIKit

public struct InlineVideoPlayerLayer: UIViewRepresentable {
  let player: AVPlayer?
  let videoGravity: AVLayerVideoGravity

  public init(player: AVPlayer?, videoGravity: AVLayerVideoGravity = .resizeAspect) {
    self.player = player
    self.videoGravity = videoGravity
  }

  public func makeUIView(context: Context) -> PlayerLayerView {
    let view = PlayerLayerView()
    view.playerLayer.videoGravity = videoGravity
    view.playerLayer.player = player
    return view
  }

  public func updateUIView(_ view: PlayerLayerView, context: Context) {
    view.playerLayer.videoGravity = videoGravity
    if view.playerLayer.player !== player {
      view.playerLayer.player = player
    }
  }

  public static func dismantleUIView(_ view: PlayerLayerView, coordinator: ()) {
    view.playerLayer.player = nil
  }

  public final class PlayerLayerView: UIView {
    public override static var layerClass: AnyClass {
      AVPlayerLayer.self
    }

    var playerLayer: AVPlayerLayer {
      layer as! AVPlayerLayer
    }
  }
}
