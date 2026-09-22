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
  let content: Content
  let overlay: (VideoZoomContext) -> Overlay

  @State private var currentScale: CGFloat = 1
  @State private var currentAnchor: UnitPoint = .center
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
    self.content = content()
    self.overlay = overlay
  }

  var body: some View {
    GeometryReader { proxy in
      ZStack {
        ZStack {
          content
            .frame(width: proxy.size.width, height: proxy.size.height)
            .scaleEffect(currentScale, anchor: currentAnchor)
            .offset(currentOffset)
        }
        .frame(width: proxy.size.width, height: proxy.size.height)
        .clipShape(clipShape(for: currentScale, in: proxy.size))

        if isGestureEnabled {
          VideoGestureSurface(
            isZoomed: isCurrentScaleZoomed,
            isMultiTouchGestureActive: isMultiTouchGestureActive,
            shouldReceivePlaybackTouch: shouldReceivePlaybackTouch,
            onPinchUpdate: { value in
              handlePinch(value, in: proxy.size)
            },
            onPanUpdate: handlePan,
            onLongPressStateChanged: onLongPressStateChanged,
            onDoubleTap: onDoubleTap
          )
          .frame(width: proxy.size.width, height: proxy.size.height)
          .onDisappear {
            hardResetZoom()
          }
        }

        overlay(zoomContext)
          .frame(width: proxy.size.width, height: proxy.size.height)
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

      let clampedLocation = clampedContentLocation(value.location, containerSize: containerSize)
      let anchor = VideoZoomAnchorCalculator.anchor(
        for: clampedLocation,
        containerSize: containerSize,
        contentAspectRatio: contentAspectRatio
      )
      gestureStartLocation = clampedLocation
      gestureStartOffset = currentOffset
      panStartOffset = currentOffset
      gestureStartScale = currentScale
      if !VideoZoomConfig.isZoomed(currentScale) {
        currentAnchor = UnitPoint(x: anchor.x, y: anchor.y)
      }
      currentScale = VideoZoomConfig.scale(
        startScale: gestureStartScale,
        gestureScale: value.scale
      )
      currentOffset = gestureStartOffset
      updateIsZooming()
    case .changed:
      guard isActivePinchGesture else { return }
      isMultiTouchGestureActive = true
      let clampedLocation = clampedContentLocation(value.location, containerSize: containerSize)
      currentScale = VideoZoomConfig.scale(
        startScale: gestureStartScale,
        gestureScale: value.scale
      )
      currentOffset = CGSize(
        width: gestureStartOffset.width + (clampedLocation.x - gestureStartLocation.x),
        height: gestureStartOffset.height + (clampedLocation.y - gestureStartLocation.y)
      )
      updateIsZooming()
    case .ended, .cancelled, .failed:
      finishPinchGesture()
    default:
      break
    }
  }

  private func handlePan(_ value: SupplementPanGestureValue) {
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
      currentOffset = CGSize(
        width: panStartOffset.width + value.translation.width,
        height: panStartOffset.height + value.translation.height
      )
    case .ended, .cancelled, .failed:
      panStartOffset = currentOffset
    default:
      break
    }
  }

  private func clampedContentLocation(_ location: CGPoint, containerSize: CGSize) -> CGPoint {
    let rect = VideoZoomAnchorCalculator.contentRect(
      containerSize: containerSize,
      contentAspectRatio: contentAspectRatio
    )
    return CGPoint(
      x: min(max(location.x, rect.minX), rect.maxX),
      y: min(max(location.y, rect.minY), rect.maxY)
    )
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
    currentAnchor = .center
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

  private func clipShape(for scale: CGFloat, in containerSize: CGSize) -> some InsettableShape {
    let clampedScale = VideoZoomConfig.clampedScale(scale)
    let expansion: CGFloat
    if clampedScale <= VideoZoomConfig.zoomThreshold {
      expansion = 0
    } else {
      let extraWidth = containerSize.width * (clampedScale - 1)
      let extraHeight = containerSize.height * (clampedScale - 1)
      expansion = max(extraWidth, extraHeight)
    }

    return RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
      .inset(by: -expansion)
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

  func makeCoordinator() -> Coordinator {
    Coordinator(
      isZoomed: isZoomed,
      isMultiTouchGestureActive: isMultiTouchGestureActive,
      shouldReceivePlaybackTouch: shouldReceivePlaybackTouch,
      onPinchUpdate: onPinchUpdate,
      onPanUpdate: onPanUpdate,
      onLongPressStateChanged: onLongPressStateChanged,
      onDoubleTap: onDoubleTap
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
    weak var pinchRecognizer: UIPinchGestureRecognizer?
    weak var panRecognizer: UIPanGestureRecognizer?
    weak var longPressRecognizer: UILongPressGestureRecognizer?
    weak var tapRecognizer: UITapGestureRecognizer?

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
      onDoubleTap: @escaping @MainActor () -> Void
    ) {
      self.isZoomed = isZoomed
      self.isMultiTouchGestureActive = isMultiTouchGestureActive
      self.shouldReceivePlaybackTouch = shouldReceivePlaybackTouch
      self.onPinchUpdate = onPinchUpdate
      self.onPanUpdate = onPanUpdate
      self.onLongPressStateChanged = onLongPressStateChanged
      self.onDoubleTap = onDoubleTap
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
      pinchRecognizer = nil
      panRecognizer = nil
      longPressRecognizer = nil
      tapRecognizer = nil
      isPinchActive = false
    }

    @objc
    func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
      guard let view = recognizer.view else { return }
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
      let state = recognizer.state
      guard VideoGesturePolicy.allowsHoldBoost(
        isMultiTouchGestureActive: hasActiveMultiTouchGesture
      ) else {
        if isActive(state) {
          Task { @MainActor in onLongPressStateChanged(.cancelled) }
        }
        return
      }

      switch state {
      case .began, .ended, .cancelled, .failed:
        Task { @MainActor in onLongPressStateChanged(state) }
      default:
        break
      }
    }

    @objc
    func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
      guard recognizer.state == .ended,
            VideoGesturePolicy.allowsDoubleTapPlayback(
              isMultiTouchGestureActive: hasActiveMultiTouchGesture
            ) else {
        return
      }
      Task { @MainActor in onDoubleTap() }
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
      Task { @MainActor in onLongPressStateChanged(.cancelled) }
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
