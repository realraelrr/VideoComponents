import SwiftUI

public struct FullscreenPlaybackView<TrailingAccessory: View, StatusOverlay: View>: View {
  @ObservedObject var playbackSession: PlaybackSession
  let allowsHoldBoost: Bool
  let onClose: @MainActor @Sendable () -> Void
  let labels: VideoPlaybackLabels
  let trailingAccessory: () -> TrailingAccessory
  let statusOverlay: () -> StatusOverlay

  @State private var isZooming = false
  @State private var isMultiTouchGestureActive = false

  public init(
    playbackSession: PlaybackSession,
    allowsHoldBoost: Bool = true,
    onClose: @escaping @MainActor @Sendable () -> Void,
    labels: VideoPlaybackLabels = .init(),
    @ViewBuilder trailingAccessory: @escaping () -> TrailingAccessory,
    @ViewBuilder statusOverlay: @escaping () -> StatusOverlay
  ) {
    self.playbackSession = playbackSession
    self.allowsHoldBoost = allowsHoldBoost
    self.onClose = onClose
    self.labels = labels
    self.trailingAccessory = trailingAccessory
    self.statusOverlay = statusOverlay
  }

  public var body: some View {
    GeometryReader { proxy in
      fullscreenBody(safeAreaInsets: proxy.safeAreaInsets)
    }
    .onAppear {
      playbackSession.cancelHold()
    }
    .onDisappear {
      playbackSession.cancelHold()
    }
    .statusBarHidden(true)
  }

  private func fullscreenBody(safeAreaInsets: EdgeInsets) -> some View {
    ZStack {
      Color.black.ignoresSafeArea()

      ZoomableVideoContainer(
        contentAspectRatio: playbackSession.videoAspectRatio,
        isZooming: $isZooming,
        isMultiTouchGestureActive: $isMultiTouchGestureActive,
        isGestureEnabled: playbackSession.canUsePlaybackControls,
        cornerRadius: 0,
        shouldReceivePlaybackTouch: shouldReceiveFullscreenPlaybackTouch,
        onLongPressStateChanged: { state in
          playbackSession.handleHoldGestureStateChanged(state, allowsHoldBoost: allowsHoldBoost)
        },
        onDoubleTap: {
          playbackSession.togglePlayback()
        }
      ) {
        InlineVideoPlayerLayer(
          player: playbackSession.hasCurrentItem ? playbackSession.player : nil,
          videoGravity: .resizeAspect
        )
      } overlay: { zoomContext in
        fullscreenChrome(zoomContext: zoomContext, safeAreaInsets: safeAreaInsets)
      }
      .ignoresSafeArea()

      statusOverlay()
        .allowsHitTesting(playbackSession.status.allowsHitTesting)

      fullscreenOverlay
    }
  }

  private var fullscreenOverlay: some View {
    VStack(spacing: 0) {
      Spacer()

      if playbackSession.canUsePlaybackControls && !isZooming && !isMultiTouchGestureActive {
        fullscreenControls
          .padding(.horizontal, 16)
          .padding(.bottom, 20)
      }
    }
  }

  private func fullscreenChrome(
    zoomContext: VideoZoomContext,
    safeAreaInsets: EdgeInsets
  ) -> some View {
    VideoChromeOverlay(
      isZooming: zoomContext.isZooming,
      isMultiTouchGestureActive: zoomContext.isMultiTouchGestureActive,
      isBlockingStatusOverlayVisible: playbackSession.status.allowsHitTesting,
      safeAreaInsets: safeAreaInsets,
      playbackRateText: playbackSession.playbackRateIndicatorText,
      labels: labels,
      onResetZoom: zoomContext.resetZoom,
      leadingAction: {
        VideoChromeIconButton(
          systemName: "xmark",
          accessibilityLabel: labels.close,
          action: onClose
        )
      },
      trailingAction: {
        trailingAccessory()
      }
    )
  }

  private var fullscreenControls: some View {
    VideoPlaybackControls(
      playbackSession: playbackSession,
      style: .fullscreen,
      labels: labels,
      tint: .white,
      fullscreenAction: nil
    )
    .buttonStyle(.plain)
    .foregroundStyle(.white)
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 10))
  }

  private func shouldReceiveFullscreenPlaybackTouch(_ touch: UITouch, in view: UIView) -> Bool {
    guard !playbackSession.status.allowsHitTesting else { return false }
    let location = touch.location(in: view)
    return VideoGestureRegion.containsFullscreenPoint(
      y: location.y,
      height: view.bounds.height,
      safeAreaTop: view.safeAreaInsets.top,
      safeAreaBottom: view.safeAreaInsets.bottom
    )
  }

}
