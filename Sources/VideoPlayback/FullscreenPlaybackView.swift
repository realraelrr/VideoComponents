import AVFoundation
import SwiftUI

public struct FullscreenPlaybackView<TrailingAccessory: View, StatusOverlay: View>: View {
  @Environment(\.accessibilityVoiceOverEnabled) private var isVoiceOverEnabled
  @Environment(\.scenePhase) private var scenePhase
  @ObservedObject var playbackSession: PlaybackSession
  let allowsHoldBoost: Bool
  let onClose: @MainActor @Sendable () -> Void
  let labels: VideoPlaybackLabels
  let trailingAccessory: () -> TrailingAccessory
  let statusOverlay: () -> StatusOverlay
  let placeholderImage: (@MainActor () -> UIImage?)?
  let sourceIdentity: AnyHashable?

  @State private var isZooming = false
  @State private var isMultiTouchGestureActive = false
  @State private var isChromeVisible = true
  @State private var isVideoTouchActive = false
  @State private var interactionID = UUID()

  public init(
    playbackSession: PlaybackSession,
    allowsHoldBoost: Bool = true,
    onClose: @escaping @MainActor @Sendable () -> Void,
    labels: VideoPlaybackLabels = .init(),
    placeholderImage: (@MainActor () -> UIImage?)? = nil,
    sourceIdentity: AnyHashable? = nil,
    @ViewBuilder trailingAccessory: @escaping () -> TrailingAccessory,
    @ViewBuilder statusOverlay: @escaping () -> StatusOverlay
  ) {
    self.playbackSession = playbackSession
    self.allowsHoldBoost = allowsHoldBoost
    self.onClose = onClose
    self.labels = labels
    self.trailingAccessory = trailingAccessory
    self.statusOverlay = statusOverlay
    self.placeholderImage = placeholderImage
    self.sourceIdentity = sourceIdentity
  }

  public var body: some View {
    GeometryReader { proxy in
      fullscreenBody(safeAreaInsets: proxy.safeAreaInsets)
    }
    .background(FullscreenContactObserver { active in
      isVideoTouchActive = active
      interactionID = UUID()
    })
    .onAppear {
      playbackSession.cancelHold()
      showChrome()
    }
    .onDisappear {
      playbackSession.cancelHold()
    }
    .onChange(of: playbackSession.canUsePlaybackControls) { _, _ in showChrome() }
    .onChange(of: playbackSession.isPlaybackRequested) { _, _ in showChrome() }
    .onChange(of: scenePhase) { _, _ in showChrome() }
    .task(id: autoHideRequestID) {
      guard let request = autoHideRequestID else { return }
      do { try await Task.sleep(for: .seconds(3)) }
      catch { return }
      guard !Task.isCancelled, autoHideRequestID == request else { return }
      isChromeVisible = false
    }
    .statusBarHidden(true)
  }

  private func fullscreenBody(safeAreaInsets: EdgeInsets) -> some View {
    let identity = displayedSourceIdentity
    let presentationID = playbackSession.sourcePresentationID
    return ZStack {
      Color.black.ignoresSafeArea()

      ZoomableVideoContainer(
        contentAspectRatio: playbackSession.videoAspectRatio,
        isZooming: $isZooming,
        isMultiTouchGestureActive: $isMultiTouchGestureActive,
        isGestureEnabled: playbackSession.canUsePlaybackControls,
        cornerRadius: 0,
        shouldReceivePlaybackTouch: shouldReceiveFullscreenPlaybackTouch,
        onLongPressStateChanged: { state in
          if state == .began { showChrome() }
          playbackSession.handleHoldGestureStateChanged(state, allowsHoldBoost: allowsHoldBoost)
        },
        onDoubleTap: {
          showChrome()
          playbackSession.togglePlayback()
        },
        onSingleTap: {
          isChromeVisible.toggle()
          interactionID = UUID()
        }
      ) {
        InlineVideoPlayerLayer(
          player: layerPlayer,
          videoGravity: .resizeAspect,
          placeholderImage: placeholderImageValue,
          isPlayerReady: playbackSession.isPlayerReady,
          sourceIdentity: identity,
          waitsForPlayback: true,
          hasPresentedVideo: identity == playbackSession.currentSourceIdentity && playbackSession.hasPresentedVideo,
          onVideoPresented: { [weak playbackSession] _ in
            guard let identity else { return }
            playbackSession?.didPresentVideo(for: identity, sourcePresentationID: presentationID)
          }
        )
      } overlay: { zoomContext in
        ZStack {
          statusOverlay()
            .allowsHitTesting(playbackSession.status.allowsHitTesting)
          fullscreenChrome(zoomContext: zoomContext, safeAreaInsets: safeAreaInsets)
        }
      }
      .ignoresSafeArea()

      fullscreenOverlay
    }
  }

  private var placeholderImageValue: UIImage? {
    if let placeholderImage { return placeholderImage() }
    return playbackSession.thumbnailImage
  }

  private var displayedSourceIdentity: AnyHashable? {
    sourceIdentity ?? playbackSession.currentSourceIdentity
  }

  private var layerPlayer: AVPlayer? {
    guard let identity = displayedSourceIdentity, playbackSession.isCurrentSource(identity),
      playbackSession.hasCurrentItem else { return nil }
    return playbackSession.player
  }

  private var fullscreenOverlay: some View {
    VStack(spacing: 0) {
      Spacer()

      if playbackSession.canTogglePlayback {
        let showsControls = showsChrome && !isZooming && !isMultiTouchGestureActive
        fullscreenControls
          .opacity(showsControls ? 1 : 0)
          .allowsHitTesting(showsControls)
          .accessibilityHidden(!showsControls)
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
      onResetZoom: {
        zoomContext.resetZoom()
        showChrome()
      },
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
    .opacity(showsChrome ? 1 : 0)
    .allowsHitTesting(showsChrome)
    .accessibilityHidden(!showsChrome)
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
    if !showsChrome { return true }
    let location = touch.location(in: view)
    return VideoGestureRegion.containsFullscreenPoint(
      y: location.y,
      height: view.bounds.height,
      safeAreaTop: view.safeAreaInsets.top,
      safeAreaBottom: view.safeAreaInsets.bottom
    )
  }

  private var showsChrome: Bool {
    isChromeVisible || isVoiceOverEnabled || !playbackSession.canUsePlaybackControls
  }

  private var autoHideRequestID: UUID? {
    guard isChromeVisible, playbackSession.canUsePlaybackControls,
      !isVideoTouchActive, !isMultiTouchGestureActive,
      !isVoiceOverEnabled, scenePhase == .active else { return nil }
    return interactionID
  }

  private func showChrome() {
    isChromeVisible = true
    interactionID = UUID()
  }

}

/// Observes contact across video and controls without recognizing or competing with their gestures.
private struct FullscreenContactObserver: UIViewRepresentable {
  let onContactChanged: @MainActor (Bool) -> Void

  func makeUIView(context: Context) -> ContactView {
    let view = ContactView()
    view.isUserInteractionEnabled = false
    view.recognizer.onContactChanged = onContactChanged
    return view
  }

  func updateUIView(_ view: ContactView, context: Context) {
    view.recognizer.onContactChanged = onContactChanged
  }

  static func dismantleUIView(_ view: ContactView, coordinator: ()) {
    view.recognizer.view?.removeGestureRecognizer(view.recognizer)
    view.recognizer.finishContact()
  }

  final class ContactView: UIView {
    let recognizer = ContactRecognizer()
    override func didMoveToWindow() {
      super.didMoveToWindow()
      recognizer.view?.removeGestureRecognizer(recognizer)
      recognizer.finishContact()
      window?.addGestureRecognizer(recognizer)
    }
  }

  final class ContactRecognizer: UIGestureRecognizer {
    var onContactChanged: @MainActor (Bool) -> Void = { _ in }
    private var contacts: Set<UITouch> = []

    init() {
      super.init(target: nil, action: nil)
      cancelsTouchesInView = false
      delaysTouchesBegan = false
      delaysTouchesEnded = false
    }

    override func canPrevent(_ other: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by other: UIGestureRecognizer) -> Bool { false }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
      contacts.formUnion(touches)
      onContactChanged(true)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
      endContact(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
      endContact(touches)
    }

    override func reset() { finishContact() }

    func finishContact() {
      guard !contacts.isEmpty else { return }
      contacts.removeAll()
      onContactChanged(false)
    }

    private func endContact(_ touches: Set<UITouch>) {
      contacts.subtract(touches)
      if contacts.isEmpty {
        onContactChanged(false)
        state = .failed
      }
    }
  }
}
