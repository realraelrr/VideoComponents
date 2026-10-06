import SwiftUI
import UIKit

struct VideoZoomContext {
  let isZooming: Bool
  let isMultiTouchGestureActive: Bool
  let resetZoom: @MainActor () -> Void
}

struct ZoomableVideoContainer<Content: View, Overlay: View>: View {
  let contentAspectRatio: CGFloat?
  @Binding var isZooming: Bool
  @Binding var isMultiTouchGestureActive: Bool
  let isGestureEnabled: Bool
  let cornerRadius: CGFloat
  let shouldReceivePlaybackTouch: ((UITouch, UIView) -> Bool)?
  let onLongPressStateChanged: @MainActor (UIGestureRecognizer.State) -> Void
  let onDoubleTap: @MainActor () -> Void
  let onSingleTap: (@MainActor () -> Void)?
  let content: Content
  let overlay: (VideoZoomContext) -> Overlay

  @State private var currentScale: CGFloat = 1
  @State private var currentOffset: CGSize = .zero
  @State private var isActivePinchGesture = false
  @State private var gestureStartLocation: CGPoint = .zero
  @State private var gestureStartOffset: CGSize = .zero
  @State private var gestureStartScale: CGFloat = 1
  @State private var panStartOffset: CGSize = .zero

  init(
    contentAspectRatio: CGFloat?,
    isZooming: Binding<Bool>,
    isMultiTouchGestureActive: Binding<Bool>,
    isGestureEnabled: Bool,
    cornerRadius: CGFloat,
    shouldReceivePlaybackTouch: ((UITouch, UIView) -> Bool)?,
    onLongPressStateChanged: @escaping @MainActor (UIGestureRecognizer.State) -> Void,
    onDoubleTap: @escaping @MainActor () -> Void,
    onSingleTap: (@MainActor () -> Void)? = nil,
    @ViewBuilder content: () -> Content,
    @ViewBuilder overlay: @escaping (VideoZoomContext) -> Overlay
  ) {
    self.contentAspectRatio = contentAspectRatio
    _isZooming = isZooming
    _isMultiTouchGestureActive = isMultiTouchGestureActive
    self.isGestureEnabled = isGestureEnabled
    self.cornerRadius = cornerRadius
    self.shouldReceivePlaybackTouch = shouldReceivePlaybackTouch
    self.onLongPressStateChanged = onLongPressStateChanged
    self.onDoubleTap = onDoubleTap
    self.onSingleTap = onSingleTap
    self.content = content()
    self.overlay = overlay
  }

  var body: some View {
    GeometryReader { proxy in
      ZStack {
        ZStack {
          content
            .frame(width: proxy.size.width, height: proxy.size.height)
            .scaleEffect(currentScale)
            .offset(currentOffset)
        }
        .frame(width: proxy.size.width, height: proxy.size.height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))

        if isGestureEnabled {
          VideoGestureSurface(
            isZoomed: isCurrentScaleZoomed,
            isMultiTouchGestureActive: isMultiTouchGestureActive,
            shouldReceivePlaybackTouch: shouldReceivePlaybackTouch,
            onPinchUpdate: { value in
              handlePinch(value, in: proxy.size)
            },
            onPanUpdate: { value in handlePan(value, in: proxy.size) },
            onLongPressStateChanged: onLongPressStateChanged,
            onDoubleTap: onDoubleTap,
            onSingleTap: onSingleTap
          )
          .frame(width: proxy.size.width, height: proxy.size.height)
          .onDisappear {
            hardResetZoom()
          }
        }

        overlay(zoomContext)
          .frame(width: proxy.size.width, height: proxy.size.height)
      }
      .onChange(of: proxy.size) { _, _ in
        constrainOffset(in: proxy.size)
      }
      .onChange(of: contentAspectRatio) { _, _ in
        constrainOffset(in: proxy.size)
      }
    }
    .onDisappear {
      hardResetZoom()
    }
  }

  private func handlePinch(_ value: SupplementPinchGestureValue, in containerSize: CGSize) {
    guard value.numberOfTouches >= 2 else {
      finishPinchGesture()
      return
    }

    switch value.state {
    case .began:
      isActivePinchGesture = value.location.x >= 0 &&
        value.location.x <= containerSize.width &&
        value.location.y >= 0 &&
        value.location.y <= containerSize.height
      guard isActivePinchGesture else { return }
      isMultiTouchGestureActive = true

      gestureStartLocation = value.location
      gestureStartOffset = currentOffset
      panStartOffset = currentOffset
      gestureStartScale = currentScale
      updatePinch(value, in: containerSize)
    case .changed:
      guard isActivePinchGesture else { return }
      isMultiTouchGestureActive = true
      updatePinch(value, in: containerSize)
    case .ended, .cancelled, .failed:
      finishPinchGesture()
    default:
      break
    }
  }

  private func handlePan(_ value: SupplementPanGestureValue, in containerSize: CGSize) {
    guard VideoGesturePolicy.allowsSingleFingerPan(
      isZoomed: VideoZoomConfig.isZoomed(currentScale),
      isMultiTouchGestureActive: isMultiTouchGestureActive
    ) else {
      panStartOffset = currentOffset
      return
    }

    switch value.state {
    case .began:
      panStartOffset = currentOffset
    case .changed:
      currentOffset = boundedOffset(CGSize(
        width: panStartOffset.width + value.translation.width,
        height: panStartOffset.height + value.translation.height
      ), in: containerSize)
    case .ended, .cancelled, .failed:
      panStartOffset = currentOffset
    default:
      break
    }
  }

  private func updatePinch(_ value: SupplementPinchGestureValue, in containerSize: CGSize) {
    currentScale = VideoZoomConfig.scale(startScale: gestureStartScale, gestureScale: value.scale)
    let ratio = currentScale / gestureStartScale
    let center = CGPoint(x: containerSize.width / 2, y: containerSize.height / 2)
    // Keep the source point beneath the starting fingers beneath the current fingers.
    currentOffset = boundedOffset(CGSize(
      width: value.location.x - center.x - (gestureStartLocation.x - center.x - gestureStartOffset.width) * ratio,
      height: value.location.y - center.y - (gestureStartLocation.y - center.y - gestureStartOffset.height) * ratio
    ), in: containerSize)
    updateIsZooming()
  }

  private func finishPinchGesture() {
    guard isActivePinchGesture else {
      isMultiTouchGestureActive = false
      return
    }
    if VideoZoomConfig.shouldRestoreIdentityOnPinchEnd(scale: currentScale) {
      restoreIdentityZoom()
    } else {
      updateIsZooming()
    }
    isMultiTouchGestureActive = false
    isActivePinchGesture = false
  }

  private func hardResetZoom() {
    restoreIdentityZoom()
    isActivePinchGesture = false
    isMultiTouchGestureActive = false
    gestureStartLocation = .zero
    gestureStartOffset = .zero
    gestureStartScale = 1
    panStartOffset = .zero
  }

  private func restoreIdentityZoom() {
    currentScale = 1
    currentOffset = .zero
    updateIsZooming()
  }

  private func updateIsZooming() {
    isZooming = isCurrentScaleZoomed
  }

  private var isCurrentScaleZoomed: Bool {
    VideoZoomConfig.isZoomed(currentScale)
  }

  private var zoomContext: VideoZoomContext {
    VideoZoomContext(
      isZooming: isCurrentScaleZoomed,
      isMultiTouchGestureActive: isMultiTouchGestureActive,
      resetZoom: {
        restoreIdentityZoom()
      }
    )
  }

  private func boundedOffset(_ offset: CGSize, in containerSize: CGSize) -> CGSize {
    VideoZoomBounds.clampedOffset(offset, scale: currentScale,
      containerSize: containerSize, contentAspectRatio: contentAspectRatio)
  }

  private func constrainOffset(in containerSize: CGSize) {
    currentOffset = boundedOffset(currentOffset, in: containerSize)
    panStartOffset = currentOffset
    gestureStartOffset = currentOffset
  }
}

extension ZoomableVideoContainer where Overlay == EmptyView {
  init(
    contentAspectRatio: CGFloat?,
    isZooming: Binding<Bool>,
    isMultiTouchGestureActive: Binding<Bool>,
    isGestureEnabled: Bool,
    cornerRadius: CGFloat,
    shouldReceivePlaybackTouch: ((UITouch, UIView) -> Bool)?,
    onLongPressStateChanged: @escaping @MainActor (UIGestureRecognizer.State) -> Void,
    onDoubleTap: @escaping @MainActor () -> Void,
    @ViewBuilder content: () -> Content
  ) {
    self.init(
      contentAspectRatio: contentAspectRatio,
      isZooming: isZooming,
      isMultiTouchGestureActive: isMultiTouchGestureActive,
      isGestureEnabled: isGestureEnabled,
      cornerRadius: cornerRadius,
      shouldReceivePlaybackTouch: shouldReceivePlaybackTouch,
      onLongPressStateChanged: onLongPressStateChanged,
      onDoubleTap: onDoubleTap,
      content: content,
      overlay: { _ in EmptyView() }
    )
  }
}

struct SupplementPinchGestureValue: Equatable {
  let scale: CGFloat
  let location: CGPoint
  let state: UIGestureRecognizer.State
  let numberOfTouches: Int
}

struct SupplementPanGestureValue: Equatable {
  let translation: CGSize
  let state: UIGestureRecognizer.State
  let numberOfTouches: Int
}

struct VideoGestureSurface: UIViewRepresentable {
  let isZoomed: Bool
  let isMultiTouchGestureActive: Bool
  var shouldReceivePlaybackTouch: ((UITouch, UIView) -> Bool)?
  let onPinchUpdate: (SupplementPinchGestureValue) -> Void
  let onPanUpdate: (SupplementPanGestureValue) -> Void
  let onLongPressStateChanged: @MainActor (UIGestureRecognizer.State) -> Void
  let onDoubleTap: @MainActor () -> Void
  var onSingleTap: (@MainActor () -> Void)? = nil

  func makeCoordinator() -> Coordinator {
    Coordinator(
      isZoomed: isZoomed,
      isMultiTouchGestureActive: isMultiTouchGestureActive,
      shouldReceivePlaybackTouch: shouldReceivePlaybackTouch,
      onPinchUpdate: onPinchUpdate,
      onPanUpdate: onPanUpdate,
      onLongPressStateChanged: onLongPressStateChanged,
      onDoubleTap: onDoubleTap,
      onSingleTap: onSingleTap
    )
  }

  func makeUIView(context: Context) -> UIView {
    let view = UIView()
    view.backgroundColor = .clear
    view.isMultipleTouchEnabled = true

    let pinchRecognizer = UIPinchGestureRecognizer(
      target: context.coordinator,
      action: #selector(Coordinator.handlePinch(_:))
    )
    pinchRecognizer.cancelsTouchesInView = false
    pinchRecognizer.delegate = context.coordinator
    view.addGestureRecognizer(pinchRecognizer)

    let panRecognizer = UIPanGestureRecognizer(
      target: context.coordinator,
      action: #selector(Coordinator.handlePan(_:))
    )
    panRecognizer.minimumNumberOfTouches = 1
    panRecognizer.maximumNumberOfTouches = 1
    panRecognizer.cancelsTouchesInView = false
    panRecognizer.delegate = context.coordinator
    view.addGestureRecognizer(panRecognizer)

    let longPressRecognizer = UILongPressGestureRecognizer(
      target: context.coordinator,
      action: #selector(Coordinator.handleLongPress(_:))
    )
    longPressRecognizer.cancelsTouchesInView = false
    longPressRecognizer.delegate = context.coordinator
    view.addGestureRecognizer(longPressRecognizer)

    let tapRecognizer = UITapGestureRecognizer(
      target: context.coordinator,
      action: #selector(Coordinator.handleDoubleTap(_:))
    )
    tapRecognizer.numberOfTapsRequired = 2
    tapRecognizer.cancelsTouchesInView = false
    tapRecognizer.delegate = context.coordinator
    view.addGestureRecognizer(tapRecognizer)

    context.coordinator.pinchRecognizer = pinchRecognizer
    context.coordinator.panRecognizer = panRecognizer
    context.coordinator.longPressRecognizer = longPressRecognizer
    context.coordinator.tapRecognizer = tapRecognizer
    if onSingleTap != nil {
      let singleTap = UITapGestureRecognizer(
        target: context.coordinator, action: #selector(Coordinator.handleSingleTap(_:))
      )
      singleTap.cancelsTouchesInView = false
      singleTap.delegate = context.coordinator
      singleTap.require(toFail: tapRecognizer)
      view.addGestureRecognizer(singleTap)
      context.coordinator.singleTapRecognizer = singleTap
    }
    return view
  }

  func updateUIView(_ view: UIView, context: Context) {
    context.coordinator.isZoomed = isZoomed
    context.coordinator.isMultiTouchGestureActive = isMultiTouchGestureActive
    context.coordinator.shouldReceivePlaybackTouch = shouldReceivePlaybackTouch
    context.coordinator.onPinchUpdate = onPinchUpdate
    context.coordinator.onPanUpdate = onPanUpdate
    context.coordinator.onLongPressStateChanged = onLongPressStateChanged
    context.coordinator.onDoubleTap = onDoubleTap
    context.coordinator.onSingleTap = onSingleTap
  }

  static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
    coordinator.removeGestures()
  }

  final class Coordinator: NSObject, UIGestureRecognizerDelegate {
    var isZoomed: Bool
    var isMultiTouchGestureActive: Bool
    var shouldReceivePlaybackTouch: ((UITouch, UIView) -> Bool)?
    var onPinchUpdate: (SupplementPinchGestureValue) -> Void
    var onPanUpdate: (SupplementPanGestureValue) -> Void
    @MainActor var onLongPressStateChanged: (UIGestureRecognizer.State) -> Void
    @MainActor var onDoubleTap: () -> Void
    @MainActor var onSingleTap: (() -> Void)?
    weak var pinchRecognizer: UIPinchGestureRecognizer?
    weak var panRecognizer: UIPanGestureRecognizer?
    weak var longPressRecognizer: UILongPressGestureRecognizer?
    weak var tapRecognizer: UITapGestureRecognizer?
    weak var singleTapRecognizer: UITapGestureRecognizer?

    private var isPinchActive = false

    private var hasActiveMultiTouchGesture: Bool {
      isPinchActive || isMultiTouchGestureActive
    }

    init(
      isZoomed: Bool,
      isMultiTouchGestureActive: Bool,
      shouldReceivePlaybackTouch: ((UITouch, UIView) -> Bool)?,
      onPinchUpdate: @escaping (SupplementPinchGestureValue) -> Void,
      onPanUpdate: @escaping (SupplementPanGestureValue) -> Void,
      onLongPressStateChanged: @escaping @MainActor (UIGestureRecognizer.State) -> Void,
      onDoubleTap: @escaping @MainActor () -> Void,
      onSingleTap: (@MainActor () -> Void)? = nil
    ) {
      self.isZoomed = isZoomed
      self.isMultiTouchGestureActive = isMultiTouchGestureActive
      self.shouldReceivePlaybackTouch = shouldReceivePlaybackTouch
      self.onPinchUpdate = onPinchUpdate
      self.onPanUpdate = onPanUpdate
      self.onLongPressStateChanged = onLongPressStateChanged
      self.onDoubleTap = onDoubleTap
      self.onSingleTap = onSingleTap
    }

    func removeGestures() {
      if isActive(pinchRecognizer) {
        onPinchUpdate(
          SupplementPinchGestureValue(
            scale: 1,
            location: .zero,
            state: .cancelled,
            numberOfTouches: 0
          )
        )
      }
      cancelLongPressIfNeeded()
      remove(pinchRecognizer)
      remove(panRecognizer)
      remove(longPressRecognizer)
      remove(tapRecognizer)
      remove(singleTapRecognizer)
      pinchRecognizer = nil
      panRecognizer = nil
      longPressRecognizer = nil
      tapRecognizer = nil
      singleTapRecognizer = nil
      isPinchActive = false
    }

    @objc
    func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
      guard recognizer === pinchRecognizer, let view = recognizer.view else { return }
      let state = recognizer.state
      if isActive(state) {
        isPinchActive = true
        cancelLongPressIfNeeded()
      }
      onPinchUpdate(
        SupplementPinchGestureValue(
          scale: recognizer.scale,
          location: recognizer.location(in: view),
          state: state,
          numberOfTouches: recognizer.numberOfTouches
        )
      )
      if isTerminal(state) {
        isPinchActive = false
      }
    }

    @objc
    func handlePan(_ recognizer: UIPanGestureRecognizer) {
      guard recognizer === panRecognizer, recognizer.view != nil else { return }
      let state = recognizer.state
      if isActive(state) {
        cancelLongPressIfNeeded()
      }
      let translation = recognizer.translation(in: recognizer.view)
      onPanUpdate(
        SupplementPanGestureValue(
          translation: CGSize(width: translation.x, height: translation.y),
          state: state,
          numberOfTouches: recognizer.numberOfTouches
        )
      )
    }

    @objc
    func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
      guard recognizer === longPressRecognizer, recognizer.view != nil else { return }
      let state = recognizer.state
      guard VideoGesturePolicy.allowsHoldBoost(
        isMultiTouchGestureActive: hasActiveMultiTouchGesture
      ) else {
        if isActive(state) {
          MainActor.assumeIsolated { onLongPressStateChanged(.cancelled) }
        }
        return
      }

      switch state {
      case .began, .ended, .cancelled, .failed:
        MainActor.assumeIsolated { onLongPressStateChanged(state) }
      default:
        break
      }
    }

    @objc
    func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
      guard recognizer === tapRecognizer, recognizer.view != nil, recognizer.state == .ended,
            VideoGesturePolicy.allowsDoubleTapPlayback(
              isMultiTouchGestureActive: hasActiveMultiTouchGesture
            ) else {
        return
      }
      MainActor.assumeIsolated { onDoubleTap() }
    }

    @objc
    func handleSingleTap(_ recognizer: UITapGestureRecognizer) {
      guard recognizer === singleTapRecognizer, recognizer.view != nil,
        recognizer.state == .ended, !hasActiveMultiTouchGesture else { return }
      MainActor.assumeIsolated { onSingleTap?() }
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
      if let panRecognizer, gestureRecognizer === panRecognizer {
        return VideoGesturePolicy.allowsSingleFingerPan(
          isZoomed: isZoomed,
          isMultiTouchGestureActive: hasActiveMultiTouchGesture
        )
      }
      if let longPressRecognizer, gestureRecognizer === longPressRecognizer {
        return VideoGesturePolicy.allowsHoldBoost(
          isMultiTouchGestureActive: hasActiveMultiTouchGesture
        )
      }
      if let tapRecognizer, gestureRecognizer === tapRecognizer {
        return VideoGesturePolicy.allowsDoubleTapPlayback(
          isMultiTouchGestureActive: hasActiveMultiTouchGesture
        )
      }
      return true
    }

    func gestureRecognizer(
      _ gestureRecognizer: UIGestureRecognizer,
      shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
      isPinchGesture(gestureRecognizer) || isPinchGesture(otherGestureRecognizer)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
      guard isPlaybackGesture(gestureRecognizer),
            let view = gestureRecognizer.view,
            let shouldReceivePlaybackTouch else {
        return true
      }
      return shouldReceivePlaybackTouch(touch, view)
    }

    private func isPlaybackGesture(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
      if let singleTapRecognizer, gestureRecognizer === singleTapRecognizer { return true }
      if let longPressRecognizer,
         gestureRecognizer === longPressRecognizer {
        return true
      }
      if let tapRecognizer,
         gestureRecognizer === tapRecognizer {
        return true
      }
      return false
    }

    private func isPinchGesture(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
      guard let pinchRecognizer else { return false }
      return gestureRecognizer === pinchRecognizer
    }

    private func cancelLongPressIfNeeded() {
      guard isActive(longPressRecognizer) else { return }
      MainActor.assumeIsolated { onLongPressStateChanged(.cancelled) }
    }

    private func remove(_ recognizer: UIGestureRecognizer?) {
      guard let recognizer else { return }
      recognizer.view?.removeGestureRecognizer(recognizer)
    }

    private func isActive(_ recognizer: UIGestureRecognizer?) -> Bool {
      guard let recognizer else { return false }
      return isActive(recognizer.state)
    }

    private func isActive(_ state: UIGestureRecognizer.State) -> Bool {
      state == .began || state == .changed
    }

    private func isTerminal(_ state: UIGestureRecognizer.State) -> Bool {
      state == .ended || state == .cancelled || state == .failed
    }
  }
}
