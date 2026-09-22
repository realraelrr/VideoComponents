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

  public static let algorithmVersion = 1
  private static let analysisSize = CGSize(width: 192, height: 192)
  private static let masterSize = CGSize(width: 1_280, height: 1_280)

  /// Uses the version 1 five-point heuristic. Final extraction is nonexact and
  /// may differ from the analysis frame; this does not promise a best action frame.
  public static func select(from asset: AVAsset) async throws -> SelectedVideoPoster {
    try Task.checkCancellation()
    let duration: Double
    do {
      duration = try await asset.load(.duration).seconds
    } catch {
      try Task.checkCancellation()
      throw SelectionError.assetUnavailable(cause: error)
    }
    try Task.checkCancellation()
    let times = candidateTimes(duration: duration)
    var candidates: [(seconds: Double, score: Double)] = []
    for seconds in times {
      do {
        let frame = try await VideoFrameExtractor.frame(
          for: asset,
          at: seconds,
          maximumSize: analysisSize
        )
        let score = VideoFrameQualityScorer.score(frame.image)
        if !score.isObviouslyBad {
          candidates.append((frame.actualTime.seconds, score.value))
        }
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        continue
      }
    }
    guard let selectedSeconds = candidates.max(by: { $0.score < $1.score })?.seconds else {
      throw SelectionError.noUsableFrame
    }
    let frame = try await VideoFrameExtractor.frame(
      for: asset,
      at: selectedSeconds,
      maximumSize: masterSize
    )
    try Task.checkCancellation()
    return SelectedVideoPoster(image: UIImage(cgImage: frame.image))
  }

  static func candidateTimes(duration: Double) -> [Double] {
    guard duration.isFinite, duration > 0 else { return [0] }
    let end = max(0, duration - 0.05)
    let raw = [
      duration * 0.10,
      duration * 0.25,
      duration * 0.45,
      duration * 0.65,
      duration * 0.85
    ].map { min(max($0, 0), end) }
    var result: [Double] = []
    for value in raw where !result.contains(where: { abs($0 - value) < 0.05 }) {
      result.append(value)
    }
    return result
  }
}

struct VideoFrameQualityScore: Sendable {
  let isObviouslyBad: Bool
  let value: Double
}

enum VideoFrameQualityScorer {
  static func score(_ image: CGImage) -> VideoFrameQualityScore {
    let width = 96
    let height = 96
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
      return VideoFrameQualityScore(isObviouslyBad: true, value: -.infinity)
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
    for y in 1..<(height - 1) {
      for x in 1..<(width - 1) {
        let index = y * width + x
        gradient += abs(Double(pixels[index + 1]) - Double(pixels[index - 1]))
        gradient += abs(Double(pixels[index + width]) - Double(pixels[index - width]))
        gradientCount += 2
      }
    }
    let sharpness = gradient / Double(max(gradientCount, 1))
    let obviouslyBad = darkRatio >= 0.92 || brightRatio >= 0.92 ||
      standardDeviation < 3.5 || (sharpness < 1.5 && standardDeviation < 12)
    let exposurePenalty = abs(mean - 128) * 0.12
    return VideoFrameQualityScore(
      isObviouslyBad: obviouslyBad,
      value: standardDeviation * 2 + sharpness * 4 - exposurePenalty
    )
  }
}
