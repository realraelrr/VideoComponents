import AVFoundation
import CoreGraphics
import UIKit

/// A poster image ready for the host's own persistence or presentation.
public struct SelectedVideoPoster: Sendable {
  public let image: UIImage

  public init(image: UIImage) {
    self.image = image
  }
}

@MainActor
public enum AutomaticVideoPosterSelector {
  public enum SelectionError: Error {
    case assetUnavailable(cause: any Error)
    case noUsableFrame
  }

  public static let algorithmVersion = 2
  private static let analysisSize = CGSize(width: 192, height: 192)
  private static let masterSize = CGSize(width: 1_280, height: 1_280)
  // Empirical cost and quality limits, not a claim of measured perceptual quality.
  private static let maximumCandidateCount = 12
  private static let minimumCandidateInterval = 0.10
  private static let relativeQualityThreshold = 0.80

  /// Selects a representative frame from candidates near the best technical quality.
  /// This bounded heuristic does not identify people, actions, or a best dance pose.
  public static func select(from asset: AVAsset) async throws -> SelectedVideoPoster {
    try Task.checkCancellation()
    let duration: Double
    do {
      duration = try await asset.load(.duration).seconds
    } catch {
      try Task.checkCancellation()
      throw SelectionError.assetUnavailable(cause: error)
    }
    return try await select(duration: duration) { time, maximumSize, exact in
      try await VideoFrameExtractor.frame(
        for: asset, at: time, maximumSize: maximumSize, exact: exact
      )
    }
  }

  // A local injection point keeps cancellation and timestamp tests independent
  // of media decoding without adding a public mocking protocol.
  static func select(
    duration: Double,
    extract: @MainActor (CMTime, CGSize, Bool) async throws -> ExtractedVideoFrame
  ) async throws -> SelectedVideoPoster {
    try Task.checkCancellation()
    var candidates: [Candidate] = []
    var observedTimes: [CMTime] = []
    for seconds in candidateTimes(duration: duration) {
      try Task.checkCancellation()
      let time = CMTime(seconds: seconds, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
      guard time.isNumeric else { continue }
      do {
        let frame = try await extract(time, analysisSize, false)
        try Task.checkCancellation()
        guard frame.actualTime.isNumeric, frame.actualTime.seconds.isFinite,
              frame.actualTime.seconds >= 0,
              !observedTimes.contains(where: { CMTimeCompare($0, frame.actualTime) == 0 }) else {
          continue
        }
        observedTimes.append(frame.actualTime)
        let quality = VideoFrameQualityScorer.score(frame.image)
        if quality.isUsable {
          candidates.append(Candidate(actualTime: frame.actualTime, quality: quality))
        }
      } catch {
        try Task.checkCancellation()
        if error is CancellationError { throw error }
        // One failed analysis frame does not invalidate the remaining samples.
        continue
      }
    }
    try Task.checkCancellation()
    guard let selected = bestCandidate(in: candidates) else {
      throw SelectionError.noUsableFrame
    }
    // Decode only the selected master. Failure or a different returned frame
    // must not silently change the selection to an unrelated fallback time.
    do {
      let frame = try await extract(selected.actualTime, masterSize, true)
      try Task.checkCancellation()
      guard frame.actualTime.isNumeric, CMTimeCompare(frame.actualTime, selected.actualTime) == 0 else {
        throw SelectionError.noUsableFrame
      }
      return SelectedVideoPoster(image: UIImage(cgImage: frame.image))
    } catch {
      try Task.checkCancellation()
      throw error
    }
  }

  static func candidateTimes(duration: Double) -> [Double] {
    guard duration.isFinite, duration >= 0 else { return [] }
    guard duration > 0 else { return [0] }
    // Equal segment midpoints cover the clip; short clips need fewer requests.
    // Bound before converting to Int, and multiply by a fraction to avoid overflow.
    let count = Int(min(Double(maximumCandidateCount), max(1, floor(duration / minimumCandidateInterval))))
    return (0..<count).map { duration * ((Double($0) + 0.5) / Double(count)) }
  }

  struct Candidate {
    let actualTime: CMTime
    let quality: VideoFrameQualityScore
  }

  static func bestCandidate(in candidates: [Candidate]) -> Candidate? {
    let usable = candidates.filter {
      $0.quality.isUsable && $0.actualTime.isNumeric &&
        $0.actualTime.seconds.isFinite && $0.actualTime.seconds >= 0
    }
    guard let bestQuality = usable.map(\.quality.value).max() else { return nil }
    var meanHistogram = [Double](repeating: 0, count: VideoFrameQualityScorer.histogramBinCount)
    for candidate in usable {
      for bin in meanHistogram.indices {
        meanHistogram[bin] += candidate.quality.histogram[bin] / Double(usable.count)
      }
    }
    // Inspired by FFmpeg's thumbnail representative-histogram approach. Only
    // technically competitive frames may win; all usable frames describe the clip.
    let eligible = usable.filter { $0.quality.value >= bestQuality * relativeQualityThreshold }
    return eligible.min { lhs, rhs in
      func distance(_ candidate: Candidate) -> Double {
        zip(candidate.quality.histogram, meanHistogram).reduce(0) { sum, values in
          let delta = values.0 - values.1
          return sum + delta * delta
        }
      }
      let lhsDistance = distance(lhs)
      let rhsDistance = distance(rhs)
      if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
      return CMTimeCompare(lhs.actualTime, rhs.actualTime) < 0
    }
  }
}

struct VideoFrameQualityScore: Sendable {
  let isObviouslyBad: Bool
  let value: Double
  let histogram: [Double]

  var isUsable: Bool {
    !isObviouslyBad && value.isFinite && value >= 0 &&
      histogram.count == VideoFrameQualityScorer.histogramBinCount &&
      histogram.allSatisfy { $0.isFinite && $0 >= 0 } &&
      abs(histogram.reduce(0, +) - 1) < 0.000_001
  }
}

enum VideoFrameQualityScorer {
  static let histogramBinCount = 16

  static func analysisSize(for original: CGSize) -> CGSize? {
    guard original.width.isFinite, original.height.isFinite,
          original.width > 0, original.height > 0 else { return nil }
    let longestSide = max(original.width, original.height)
    // Rounding to whole pixels preserves aspect ratio to the nearest pixel.
    return CGSize(
      width: max(1, (original.width / longestSide * 96).rounded()),
      height: max(1, (original.height / longestSide * 96).rounded())
    )
  }

  static func score(_ image: CGImage) -> VideoFrameQualityScore {
    let rejected = VideoFrameQualityScore(isObviouslyBad: true, value: 0, histogram: [])
    guard let size = analysisSize(for: CGSize(width: image.width, height: image.height)) else {
      return rejected
    }
    let width = Int(size.width)
    let height = Int(size.height)
    var pixels = [UInt8](repeating: 0, count: width * height)
    guard let context = CGContext(
      data: &pixels,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width,
      space: CGColorSpaceCreateDeviceGray(),
      bitmapInfo: CGImageAlphaInfo.none.rawValue
    ) else {
      return rejected
    }
    context.interpolationQuality = .low
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    let count = Double(pixels.count)
    let mean = pixels.reduce(0.0) { $0 + Double($1) } / count
    let variance = pixels.reduce(0.0) { partial, pixel in
      let delta = Double(pixel) - mean
      return partial + delta * delta
    } / count
    let standardDeviation = sqrt(variance)
    let darkRatio = Double(pixels.lazy.filter { $0 <= 12 }.count) / count
    let brightRatio = Double(pixels.lazy.filter { $0 >= 243 }.count) / count
    var gradient = 0.0
    var gradientCount = 0
    if width >= 3, height >= 3 {
      for y in 1..<(height - 1) {
        for x in 1..<(width - 1) {
          let index = y * width + x
          gradient += abs(Double(pixels[index + 1]) - Double(pixels[index - 1]))
          gradient += abs(Double(pixels[index + width]) - Double(pixels[index - width]))
          gradientCount += 2
        }
      }
    }
    let sharpness = gradient / Double(max(gradientCount, 1))
    let obviouslyBad = darkRatio >= 0.92 || brightRatio >= 0.92 ||
      standardDeviation < 3.5 || (sharpness < 1.5 && standardDeviation < 12)
    var histogram = [Double](repeating: 0, count: histogramBinCount)
    for pixel in pixels {
      histogram[Int(pixel) * histogramBinCount / 256] += 1
    }
    histogram = histogram.map { $0 / count }

    // Empirical caps prevent busy texture from earning an unbounded advantage.
    let contrastQuality = min(standardDeviation / 64, 1)
    let edgeQuality = min(sharpness / 24, 1)
    let exposureQuality = 1 - abs(mean - 128) / 128
    return VideoFrameQualityScore(
      isObviouslyBad: obviouslyBad,
      value: contrastQuality * 0.4 + edgeQuality * 0.4 + exposureQuality * 0.2,
      histogram: histogram
    )
  }
}
