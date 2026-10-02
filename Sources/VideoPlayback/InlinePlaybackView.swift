import AVFoundation
import SwiftUI
import UIKit

public struct InlinePlaybackView<TopTrailingAccessory: View, StatusOverlay: View>: View {
  @ObservedObject var playbackSession: PlaybackSession
  let allowsHoldBoost: Bool
  let isFullscreenPresented: Bool
  let isScrollInteractionActive: Binding<Bool>?
  let maximumCardSize: CGSize
  let topTrailingAccessory: () -> TopTrailingAccessory
  let onRequestFullscreen: (() -> Void)?
  let statusOverlay: () -> StatusOverlay
  let placeholderImage: (@MainActor () -> UIImage?)?
  let sourceIdentity: AnyHashable?
  let labels: VideoPlaybackLabels
  let style: VideoPlaybackStyle

  @State private var isInlineZooming = false
  @State private var isInlineMultiTouchGestureActive = false

  public init(
    playbackSession: PlaybackSession,
    allowsHoldBoost: Bool = true,
    isFullscreenPresented: Bool = false,
    isScrollInteractionActive: Binding<Bool>? = nil,
    maximumCardSize: CGSize = CGSize(width: 320, height: 450),
    @ViewBuilder topTrailingAccessory: @escaping () -> TopTrailingAccessory,
    onRequestFullscreen: (() -> Void)? = nil,
    labels: VideoPlaybackLabels = .init(),
    style: VideoPlaybackStyle = .init(),
    placeholderImage: (@MainActor () -> UIImage?)? = nil,
    sourceIdentity: AnyHashable? = nil,
    @ViewBuilder statusOverlay: @escaping () -> StatusOverlay
  ) {
    self.playbackSession = playbackSession
    self.allowsHoldBoost = allowsHoldBoost
    self.isFullscreenPresented = isFullscreenPresented
    self.isScrollInteractionActive = isScrollInteractionActive
    self.maximumCardSize = maximumCardSize
    self.topTrailingAccessory = topTrailingAccessory
    self.onRequestFullscreen = onRequestFullscreen
    self.labels = labels
    self.style = style
    self.statusOverlay = statusOverlay
    self.placeholderImage = placeholderImage
    self.sourceIdentity = sourceIdentity
  }

  public var body: some View {
    playerBody
      .onChange(of: isFullscreenPresented) { _, _ in
        playbackSession.cancelHold()
      }
      .onChange(of: shouldLockOuterScroll) { _, shouldLock in
        updateOuterScrollLock(shouldLock)
      }
      .onDisappear {
        updateOuterScrollLock(false)
      }
  }

  @ViewBuilder
  private var playerBody: some View {
    VStack(alignment: .center, spacing: 12) {
      AdaptiveVideoCardLayout(
        contentAspectRatio: videoAspectRatio,
        maximumSize: maximumCardSize
      ) {
        videoCard
          .clipShape(RoundedRectangle(cornerRadius: 12))
      }
      .frame(maxWidth: .infinity, alignment: .center)

      if playbackSession.canTogglePlayback {
        // Keep the media proposal stable while a pinch is in progress.
        let hidesControls = isInlineZooming || isInlineMultiTouchGestureActive
        inlinePlaybackControls
          .opacity(hidesControls ? 0 : 1)
          .allowsHitTesting(!hidesControls)
          .accessibilityHidden(hidesControls)
      }
    }
  }

  private var videoCard: some View {
    ZStack {
      ZoomableVideoContainer(
        contentAspectRatio: videoAspectRatio,
        isZooming: $isInlineZooming,
        isMultiTouchGestureActive: $isInlineMultiTouchGestureActive,
        isGestureEnabled: playbackSession.canUsePlaybackControls,
        cornerRadius: 12,
        shouldReceivePlaybackTouch: shouldReceiveInlinePlaybackTouch,
        onLongPressStateChanged: { state in
          playbackSession.handleHoldGestureStateChanged(state, allowsHoldBoost: allowsHoldBoost)
        },
        onDoubleTap: {
          playbackSession.togglePlayback()
        }
      ) {
        mediaLayer
      } overlay: { zoomContext in
        inlineChrome(zoomContext: zoomContext)
      }

      statusOverlay()
        .allowsHitTesting(playbackSession.status.allowsHitTesting)
    }
  }

  private func inlineChrome(zoomContext: VideoZoomContext) -> some View {
    VideoChromeOverlay(
      isZooming: zoomContext.isZooming,
      isMultiTouchGestureActive: zoomContext.isMultiTouchGestureActive,
      isBlockingStatusOverlayVisible: playbackSession.status.allowsHitTesting,
      playbackRateText: playbackSession.playbackRateIndicatorText,
      labels: labels,
      onResetZoom: zoomContext.resetZoom
    ) {
      topTrailingAccessory()
    }
  }

  private var mediaLayer: some View {
    // A host provider is authoritative even when the current poster is unavailable.
    let image = if let placeholderImage { placeholderImage() } else { playbackSession.thumbnailImage }
    let identity = displayedSourceIdentity
    let presentationID = playbackSession.sourcePresentationID
    return InlineVideoPlayerLayer(
      player: inlineLayerPlayer,
      videoGravity: .resizeAspect,
      placeholderImage: image,
      isPlayerReady: playbackSession.isPlayerReady,
      sourceIdentity: identity,
      waitsForPlayback: true,
      hasPresentedVideo: identity == playbackSession.currentSourceIdentity && playbackSession.hasPresentedVideo,
      onVideoPresented: { [weak playbackSession] _ in
        guard let identity else { return }
        playbackSession?.didPresentVideo(for: identity, sourcePresentationID: presentationID)
      }
    )
    .background(.black)
  }

  private var inlineLayerPlayer: AVPlayer? {
    guard let identity = displayedSourceIdentity, playbackSession.isCurrentSource(identity),
      playbackSession.hasCurrentItem, !isFullscreenPresented else { return nil }
    return playbackSession.player
  }

  private var displayedSourceIdentity: AnyHashable? {
    sourceIdentity ?? playbackSession.currentSourceIdentity
  }

  private var inlinePlaybackControls: some View {
    VideoPlaybackControls(
      playbackSession: playbackSession,
      style: .inline,
      labels: labels,
      tint: style.tint,
      fullscreenAction: onRequestFullscreen
    )
    .buttonStyle(.plain)
    .foregroundStyle(style.foreground)
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(style.background, in: RoundedRectangle(cornerRadius: 12))
  }

  private var shouldLockOuterScroll: Bool {
    VideoOuterScrollLockPolicy.shouldDisableOuterScroll(
      isZoomed: isInlineZooming,
      isMultiTouchGestureActive: isInlineMultiTouchGestureActive
    )
  }

  private func shouldReceiveInlinePlaybackTouch(_ touch: UITouch, in view: UIView) -> Bool {
    guard !playbackSession.status.allowsHitTesting else { return false }
    let location = touch.location(in: view)
    return VideoGestureRegion.containsInlinePoint(
      y: location.y,
      height: view.bounds.height
    )
  }

  private func updateOuterScrollLock(_ shouldLock: Bool) {
    isScrollInteractionActive?.wrappedValue = shouldLock
  }

  private var videoAspectRatio: CGFloat? {
    playbackSession.videoAspectRatio
  }

}
