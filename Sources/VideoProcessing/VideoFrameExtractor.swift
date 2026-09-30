import AVFoundation
import CoreGraphics

/// A decoded frame and the time actually chosen by AVFoundation.
public struct ExtractedVideoFrame: Sendable {
  public let image: CGImage
  public let actualTime: CMTime
}

/// Neutral failure categories. Associated causes are for host diagnostics, not display.
public enum VideoFrameExtractionError: Error {
  case invalidTime
  case invalidSize
  case frameUnavailable(cause: (any Error)?)
}

@MainActor
public enum VideoFrameExtractor {
  /// Extracts a frame without loading or assuming the asset's duration.
  ///
  /// `seconds` must be finite and nonnegative. Both size dimensions must be finite
  /// and within 1...4096 pixels. Exact requests use zero time tolerance; a duration
  /// endpoint need not be a decodable frame. Nonexact results may use a nearby time.
  public static func frame(
    for asset: AVAsset,
    at seconds: Double,
    maximumSize: CGSize,
    exact: Bool = false
  ) async throws -> ExtractedVideoFrame {
    try Task.checkCancellation()
    guard seconds.isFinite, seconds >= 0 else {
      throw VideoFrameExtractionError.invalidTime
    }
    let time = CMTime(seconds: seconds, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
    return try await frame(for: asset, at: time, maximumSize: maximumSize, exact: exact)
  }

  // Preserve an analyzed frame's rational timestamp for exact poster extraction.
  // The public seconds API remains the convenience entry point for host callers.
  static func frame(
    for asset: AVAsset,
    at time: CMTime,
    maximumSize: CGSize,
    exact: Bool
  ) async throws -> ExtractedVideoFrame {
    try Task.checkCancellation()
    guard maximumSize.width.isFinite, maximumSize.height.isFinite,
          (1...4096).contains(maximumSize.width),
          (1...4096).contains(maximumSize.height) else {
      throw VideoFrameExtractionError.invalidSize
    }
    guard time.isNumeric, time.seconds.isFinite, time.seconds >= 0 else {
      throw VideoFrameExtractionError.frameUnavailable(cause: nil)
    }
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = maximumSize
    if exact {
      generator.requestedTimeToleranceBefore = .zero
      generator.requestedTimeToleranceAfter = .zero
    }
    do {
      let frame = try await generatedFrame { completion in
        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, image, actualTime, result, error in
          if result == .succeeded, let image {
            completion(.success(ExtractedVideoFrame(image: image, actualTime: actualTime)))
          } else {
            completion(.failure(VideoFrameExtractionError.frameUnavailable(cause: error)))
          }
        }
      } cancel: {
        generator.cancelAllCGImageGeneration()
      }
      try Task.checkCancellation()
      guard frame.actualTime.isNumeric, frame.actualTime.seconds.isFinite,
            frame.actualTime.seconds >= 0 else {
        throw VideoFrameExtractionError.frameUnavailable(cause: nil)
      }
      return frame
    } catch {
      try Task.checkCancellation()
      if let failure = error as? VideoFrameExtractionError { throw failure }
      throw VideoFrameExtractionError.frameUnavailable(cause: error)
    }
  }

  // Registration runs synchronously in this actor turn. Cancellation is queued
  // on the same actor, so it cannot miss a request that has not registered yet.
  // The local closures also let tests control that exact native boundary.
  static func generatedFrame(
    start: (@escaping @Sendable (Result<ExtractedVideoFrame, any Error>) -> Void) -> Void,
    cancel: @escaping @MainActor () -> Void
  ) async throws -> ExtractedVideoFrame {
    try Task.checkCancellation()
    do {
      let frame = try await withTaskCancellationHandler {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
          start { continuation.resume(with: $0) }
        }
      } onCancel: {
        Task { @MainActor in cancel() }
      }
      try Task.checkCancellation()
      return frame
    } catch {
      try Task.checkCancellation()
      throw error
    }
  }
}
