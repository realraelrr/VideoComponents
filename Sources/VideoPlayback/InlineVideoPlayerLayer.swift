import AVFoundation
import SwiftUI
import UIKit

public struct InlineVideoPlayerLayer: UIViewRepresentable {
  let player: AVPlayer?
  let videoGravity: AVLayerVideoGravity
  let placeholderImage: UIImage?
  let isPlayerReady: Bool
  let sourceIdentity: AnyHashable?

  public init(
    player: AVPlayer?,
    videoGravity: AVLayerVideoGravity = .resizeAspect,
    placeholderImage: UIImage? = nil,
    isPlayerReady: Bool = true,
    sourceIdentity: AnyHashable? = nil
  ) {
    self.player = player
    self.videoGravity = videoGravity
    self.placeholderImage = placeholderImage
    self.isPlayerReady = isPlayerReady
    self.sourceIdentity = sourceIdentity
  }

  public func makeUIView(context: Context) -> PlayerLayerView {
    let view = PlayerLayerView()
    view.configure(player: player, videoGravity: videoGravity,
      placeholderImage: placeholderImage, isPlayerReady: isPlayerReady, sourceIdentity: sourceIdentity)
    return view
  }

  public func updateUIView(_ view: PlayerLayerView, context: Context) {
    view.configure(player: player, videoGravity: videoGravity,
      placeholderImage: placeholderImage, isPlayerReady: isPlayerReady, sourceIdentity: sourceIdentity)
  }

  public static func dismantleUIView(_ view: PlayerLayerView, coordinator: ()) {
    view.detach()
  }

  public final class PlayerLayerView: UIView {
    private let placeholder = UIImageView()
    private var isPlayerReady = false
    private var sourceIdentity: AnyHashable?
    private var hasDisplayedVideo = false
    private var displayObservation: NSKeyValueObservation?
    private var itemObservation: NSKeyValueObservation?
    private var observationGeneration = UUID()
    private weak var observedItem: AVPlayerItem?

    public override static var layerClass: AnyClass {
      AVPlayerLayer.self
    }

    var playerLayer: AVPlayerLayer {
      layer as! AVPlayerLayer
    }

    public override func layoutSubviews() {
      super.layoutSubviews()
      placeholder.frame = bounds
    }

    func configure(
      player: AVPlayer?, videoGravity: AVLayerVideoGravity,
      placeholderImage: UIImage?, isPlayerReady: Bool, sourceIdentity: AnyHashable? = nil
    ) {
      let playerChanged = playerLayer.player !== player
      if playerChanged || self.sourceIdentity != sourceIdentity {
        hasDisplayedVideo = false
      }
      self.sourceIdentity = sourceIdentity
      if playerChanged { invalidateObservations() }
      playerLayer.videoGravity = videoGravity
      if playerChanged { playerLayer.player = player }
      self.isPlayerReady = isPlayerReady
      placeholder.image = placeholderImage
      if placeholderImage != nil {
        if placeholder.superview == nil {
          // The whole fitted surface is opaque, including the poster's letterbox.
          placeholder.backgroundColor = .black
          placeholder.clipsToBounds = true
          placeholder.isUserInteractionEnabled = false
          placeholder.accessibilityElementsHidden = true
          addSubview(placeholder)
        }
        placeholder.contentMode = videoGravity == .resizeAspectFill ? .scaleAspectFill
          : videoGravity == .resize ? .scaleToFill : .scaleAspectFit
        placeholder.frame = bounds
      }
      // Remember a first display even when its saved poster arrives later.
      if placeholderImage != nil || sourceIdentity != nil {
        if displayObservation == nil || observedItem !== player?.currentItem { observeDisplayReadiness() }
      } else {
        invalidateObservations()
      }
      updatePlaceholderVisibility()
    }

    func detach() {
      invalidateObservations()
      playerLayer.player = nil
      isPlayerReady = false
      sourceIdentity = nil
      hasDisplayedVideo = false
      placeholder.image = nil
      placeholder.isHidden = true
    }

    private func observeDisplayReadiness() {
      invalidateObservations()
      observedItem = playerLayer.player?.currentItem
      let generation = observationGeneration
      displayObservation = playerLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] _, _ in
        Self.deliver(to: self, generation: generation, itemChanged: false)
      }
      itemObservation = playerLayer.player?.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
        Self.deliver(to: self, generation: generation, itemChanged: true)
      }
    }

    private nonisolated static func deliver(to view: PlayerLayerView?, generation: UUID, itemChanged: Bool) {
      if Thread.isMainThread {
        MainActor.assumeIsolated { view?.receive(generation: generation, itemChanged: itemChanged) }
      } else {
        Task { @MainActor [weak view] in
          view?.receive(generation: generation, itemChanged: itemChanged)
        }
      }
    }

    private func receive(generation: UUID, itemChanged: Bool) {
      guard observationGeneration == generation else { return }
      if itemChanged { observeDisplayReadiness() }
      // Read the current native facts, never a readiness value captured by old KVO.
      updatePlaceholderVisibility()
    }

    private func updatePlaceholderVisibility() {
      if playerLayer.player?.currentItem == nil { hasDisplayedVideo = false }
      let canDisplayVideo = isPlayerReady
        && playerLayer.player?.currentItem?.status == .readyToPlay
        && playerLayer.isReadyForDisplay
      if canDisplayVideo { hasDisplayedVideo = true }
      // Representation replacements belong to the same source. Once video has
      // been shown, keep its native picture rather than resurrecting the poster.
      let didHandOffSource = sourceIdentity != nil && hasDisplayedVideo
      placeholder.isHidden = placeholder.image == nil || canDisplayVideo || didHandOffSource
    }

    private func invalidateObservations() {
      observationGeneration = UUID()
      displayObservation?.invalidate()
      displayObservation = nil
      itemObservation?.invalidate()
      itemObservation = nil
      observedItem = nil
    }
  }
}
