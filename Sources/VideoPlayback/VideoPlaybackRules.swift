import CoreGraphics
import Foundation

public struct VideoPlaybackConfig: Equatable {
  public static let normalRate: Float = 1.0
  private static let holdBoostMultiplier: Float = 2.0

  public private(set) var playbackRate: Float
  public private(set) var isLooping: Bool

  public init(
    playbackRate: Float = normalRate,
    isLooping: Bool = false
  ) {
    self.playbackRate = Self.normalizedRate(playbackRate)
    self.isLooping = isLooping
  }

  public var holdBoostedRate: Float {
    let rate = playbackRate
    guard rate >= Self.normalRate else { return Self.normalRate }
    return rate * Self.holdBoostMultiplier
  }

  mutating func update(playbackRate: Float, isLooping: Bool) {
    self.playbackRate = Self.normalizedRate(playbackRate)
    self.isLooping = isLooping
  }

  static func normalizedRate(_ rate: Float) -> Float {
    guard rate.isFinite,
          rate > 0 else {
      return Self.normalRate
    }
    return rate
  }
}

enum VideoPlaybackRateDisplay {
  static func indicatorText(playbackRate: Float, isHolding: Bool) -> String? {
    let config = VideoPlaybackConfig(playbackRate: playbackRate)
    if isHolding {
      return text(for: config.holdBoostedRate)
    }

    let rate = config.playbackRate
    guard abs(rate - VideoPlaybackConfig.normalRate) > 0.001 else {
      return nil
    }
    return text(for: rate)
  }

  private static func text(for rate: Float) -> String {
    String(format: "%.2fx", VideoPlaybackConfig.normalizedRate(rate))
  }
}

enum VideoZoomConfig {
  static let minScale: CGFloat = 1.0
  static let maxScale: CGFloat = 3.0
  static let zoomThreshold: CGFloat = 1.01

  static func clampedScale(_ scale: CGFloat) -> CGFloat {
    guard scale.isFinite else { return minScale }
    return min(max(scale, minScale), maxScale)
  }

  static func scale(startScale: CGFloat, gestureScale: CGFloat) -> CGFloat {
    clampedScale(startScale * gestureScale)
  }

  static func isZoomed(_ scale: CGFloat) -> Bool {
    clampedScale(scale) > zoomThreshold
  }

  static func shouldRestoreIdentityOnPinchEnd(scale: CGFloat) -> Bool {
    !isZoomed(scale)
  }
}

enum VideoZoomAnchorCalculator {
  static func contentRect(containerSize: CGSize, contentAspectRatio: CGFloat?) -> CGRect {
    guard containerSize.width > 0,
          containerSize.height > 0 else {
      return .zero
    }

    guard let contentAspectRatio,
          contentAspectRatio > 0,
          contentAspectRatio.isFinite else {
      return CGRect(origin: .zero, size: containerSize)
    }

    let containerAspectRatio = containerSize.width / containerSize.height
    if contentAspectRatio > containerAspectRatio {
      let width = containerSize.width
      let height = width / contentAspectRatio
      return CGRect(x: 0, y: (containerSize.height - height) / 2, width: width, height: height)
    }

    let height = containerSize.height
    let width = height * contentAspectRatio
    return CGRect(x: (containerSize.width - width) / 2, y: 0, width: width, height: height)
  }

  static func anchor(
    for location: CGPoint,
    containerSize: CGSize,
    contentAspectRatio: CGFloat?
  ) -> CGPoint {
    guard containerSize.width > 0,
          containerSize.height > 0 else {
      return CGPoint(x: 0.5, y: 0.5)
    }

    let rect = contentRect(containerSize: containerSize, contentAspectRatio: contentAspectRatio)
    let clampedX = min(max(location.x, rect.minX), rect.maxX)
    let clampedY = min(max(location.y, rect.minY), rect.maxY)
    return CGPoint(
      x: clampedX / containerSize.width,
      y: clampedY / containerSize.height
    )
  }
}

enum VideoPlayerLayout {
  static let targetWidth: CGFloat = 320
  static let targetHeight: CGFloat = 450
  static let defaultMaximumSize = CGSize(width: targetWidth, height: targetHeight)

  static func adaptiveCardSize(
    forAvailableSize availableSize: CGSize,
    contentAspectRatio: CGFloat?,
    maximumSize: CGSize = defaultMaximumSize
  ) -> CGSize {
    let boundingSize = CGSize(
      width: min(maximumSize.width, max(0, availableSize.width)),
      height: min(maximumSize.height, max(0, availableSize.height))
    )
    guard boundingSize.width > 0, boundingSize.height > 0 else { return .zero }
    let aspectRatio = contentAspectRatio.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
      ?? targetWidth / targetHeight

    var width = boundingSize.width
    var height = width / aspectRatio
    if height > boundingSize.height {
      height = boundingSize.height
      width = height * aspectRatio
    }
    return CGSize(width: width, height: height)
  }
}

enum VideoPlaybackPresentation {
  static func normalizedProgress(_ progress: Double) -> Double {
    guard progress.isFinite else { return 0 }
    return min(max(progress, 0), 1)
  }
}

enum VideoScrubBarGeometry {
  static func progress(forX x: CGFloat, width: CGFloat) -> Double {
    guard x.isFinite,
          width.isFinite,
          width > 0 else {
      return 0
    }
    return VideoPlaybackPresentation.normalizedProgress(Double(x / width))
  }
}

enum VideoOuterScrollLockPolicy {
  static func shouldDisableOuterScroll(
    isZoomed: Bool,
    isMultiTouchGestureActive: Bool
  ) -> Bool {
    isZoomed || isMultiTouchGestureActive
  }
}

enum VideoGesturePolicy {
  static func allowsSingleFingerPan(isZoomed: Bool, isMultiTouchGestureActive: Bool) -> Bool {
    isZoomed && !isMultiTouchGestureActive
  }

  static func allowsHoldBoost(isMultiTouchGestureActive: Bool) -> Bool {
    !isMultiTouchGestureActive
  }

  static func allowsDoubleTapPlayback(isMultiTouchGestureActive: Bool) -> Bool {
    !isMultiTouchGestureActive
  }
}

enum VideoGestureRegion {
  static let fullscreenTopControlAvoidance: CGFloat = 96
  static let fullscreenBottomControlAvoidance: CGFloat = 132

  static func containsInlinePoint(
    y: CGFloat,
    height: CGFloat
  ) -> Bool {
    guard y.isFinite,
          height.isFinite,
          height > 0 else {
      return false
    }

    // Inline controls have their own region outside the image.
    return y >= 0 && y <= height
  }

  static func containsFullscreenPoint(
    y: CGFloat,
    height: CGFloat,
    safeAreaTop: CGFloat,
    safeAreaBottom: CGFloat
  ) -> Bool {
    guard y.isFinite,
          height.isFinite,
          height > 0 else {
      return false
    }

    let minimumY = max(0, safeAreaTop) + fullscreenTopControlAvoidance
    let maximumY = height - max(0, safeAreaBottom) - fullscreenBottomControlAvoidance
    return minimumY < maximumY && y >= minimumY && y <= maximumY
  }
}
