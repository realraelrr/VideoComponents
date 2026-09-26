import AVFoundation
import UIKit
import XCTest

@testable import VideoProcessing

@MainActor
final class VideoPosterSelectionAlgorithmTests: XCTestCase {
  func testFrameQualityRejectsBlackAndPrefersDetailedFrame() throws {
    let black = try XCTUnwrap(testImage(color: .black, detailed: false).cgImage)
    let detailed = try XCTUnwrap(testImage(color: .white, detailed: true).cgImage)

    let blackScore = VideoFrameQualityScorer.score(black)
    let detailedScore = VideoFrameQualityScorer.score(detailed)

    XCTAssertTrue(blackScore.isObviouslyBad)
    XCTAssertFalse(detailedScore.isObviouslyBad)
    XCTAssertGreaterThan(detailedScore.value, blackScore.value)
  }

  func testFrameQualityRejectsLowContrastBlurredFrame() throws {
    let blurred = try XCTUnwrap(testLowContrastBlurredImage().cgImage)
    let detailed = try XCTUnwrap(testImage(color: .white, detailed: true).cgImage)

    XCTAssertTrue(VideoFrameQualityScorer.score(blurred).isObviouslyBad)
    XCTAssertFalse(VideoFrameQualityScorer.score(detailed).isObviouslyBad)
  }

  func testAutomaticCandidateSamplingIsBoundedAndOrdered() {
    let times = AutomaticVideoPosterSelector.candidateTimes(duration: 20)

    XCTAssertEqual(times.count, 12)
    XCTAssertEqual(times, times.sorted())
    for (index, time) in times.enumerated() {
      XCTAssertEqual(time, 20 * (Double(index) + 0.5) / 12, accuracy: 0.000_001)
    }
  }

  func testCandidateSamplingReducesShortClipsAndHandlesInvalidNumbers() {
    XCTAssertEqual(AutomaticVideoPosterSelector.candidateTimes(duration: 1.0 / 30), [1.0 / 60])
    XCTAssertEqual(AutomaticVideoPosterSelector.candidateTimes(duration: 0.45).count, 4)
    XCTAssertEqual(AutomaticVideoPosterSelector.candidateTimes(duration: 0), [0])
    for duration in [Double.nan, .infinity, -.infinity, -1] {
      XCTAssertTrue(AutomaticVideoPosterSelector.candidateTimes(duration: duration).isEmpty)
    }
    for duration in [Double.leastNonzeroMagnitude, 0.1, 0.25, 1, 60, .greatestFiniteMagnitude] {
      let times = AutomaticVideoPosterSelector.candidateTimes(duration: duration)
      XCTAssertTrue((1...12).contains(times.count))
      XCTAssertEqual(times.count, Set(times).count)
      XCTAssertTrue(times.allSatisfy { $0.isFinite && $0 >= 0 && $0 < duration })
    }
  }

  func testAnalysisPreservesAspectRatioAndRejectsInvalidDimensions() {
    XCTAssertEqual(VideoFrameQualityScorer.analysisSize(for: CGSize(width: 1_920, height: 1_080)), CGSize(width: 96, height: 54))
    XCTAssertEqual(VideoFrameQualityScorer.analysisSize(for: CGSize(width: 1_080, height: 1_920)), CGSize(width: 54, height: 96))
    XCTAssertEqual(VideoFrameQualityScorer.analysisSize(for: CGSize(width: 1, height: 1_000)), CGSize(width: 1, height: 96))
    for size in [CGSize.zero, CGSize(width: -1, height: 10), CGSize(width: CGFloat.nan, height: 1), CGSize(width: 1, height: CGFloat.infinity)] {
      XCTAssertNil(VideoFrameQualityScorer.analysisSize(for: size))
    }
  }

  func testQualityIsBoundedAndHistogramIsNormalized() throws {
    for image in [testImage(color: .black, detailed: false), testImage(color: .white, detailed: false), testImage(color: .white, detailed: true)] {
      let score = VideoFrameQualityScorer.score(try XCTUnwrap(image.cgImage))
      XCTAssertTrue((0...1).contains(score.value))
      XCTAssertEqual(score.histogram.count, 16)
      XCTAssertEqual(score.histogram.reduce(0, +), 1, accuracy: 0.000_001)
    }
    XCTAssertTrue(VideoFrameQualityScorer.score(try XCTUnwrap(testImage(color: .white, detailed: false).cgImage)).isObviouslyBad)
  }

  func testQualityThresholdPrecedesRepresentativeness() throws {
    let best = candidate(seconds: 0, quality: 1, histogram: [1, 0])
    let representative = candidate(seconds: 1, quality: 0.79, histogram: [0.5, 0.5])
    let other = candidate(seconds: 2, quality: 0.9, histogram: [0, 1])

    let selected = try XCTUnwrap(AutomaticVideoPosterSelector.bestCandidate(in: [other, representative, best]))

    XCTAssertEqual(CMTimeCompare(selected.actualTime, best.actualTime), 0)
  }

  func testRepresentativeFrameAtQualityThresholdBeatsTechnicalMaximum() throws {
    let best = candidate(seconds: 0, quality: 1, histogram: [1, 0])
    let representative = candidate(seconds: 1, quality: 0.8, histogram: [0.5, 0.5])
    let other = candidate(seconds: 2, quality: 0.9, histogram: [0, 1])

    let selected = try XCTUnwrap(AutomaticVideoPosterSelector.bestCandidate(in: [best, representative, other]))

    XCTAssertEqual(CMTimeCompare(selected.actualTime, representative.actualTime), 0)
  }

  func testEqualHistogramDistancesChooseEarliestActualTimeRegardlessOfInputOrder() throws {
    let early = candidate(seconds: 1, quality: 0.8, histogram: [1, 0])
    let late = candidate(seconds: 3, quality: 1, histogram: [0, 1])
    for order in [[early, late], [late, early]] {
      let selected = try XCTUnwrap(AutomaticVideoPosterSelector.bestCandidate(in: order))
      XCTAssertEqual(CMTimeCompare(selected.actualTime, early.actualTime), 0)
    }
  }

  func testInvalidQualityAndHistogramNumbersCannotWin() {
    for value in [Double.nan, .infinity, -.infinity, -1] {
      XCTAssertNil(AutomaticVideoPosterSelector.bestCandidate(in: [candidate(seconds: 0, quality: value, histogram: [1, 0])]))
    }
    for histogram in [[Double.nan, 0], [Double.infinity, 0], [-1, 2], [0, 0]] {
      XCTAssertNil(AutomaticVideoPosterSelector.bestCandidate(in: [candidate(seconds: 0, quality: 1, histogram: histogram)]))
    }
    let rejected = AutomaticVideoPosterSelector.Candidate(
      actualTime: .zero,
      quality: VideoFrameQualityScore(isObviouslyBad: true, value: 1, histogram: [1] + Array(repeating: 0, count: 15))
    )
    XCTAssertNil(AutomaticVideoPosterSelector.bestCandidate(in: [rejected]))
  }

  private func candidate(seconds: Double, quality: Double, histogram: [Double]) -> AutomaticVideoPosterSelector.Candidate {
    AutomaticVideoPosterSelector.Candidate(
      actualTime: CMTime(seconds: seconds, preferredTimescale: 600),
      quality: VideoFrameQualityScore(isObviouslyBad: false, value: quality, histogram: histogram + Array(repeating: 0, count: 16 - histogram.count))
    )
  }

  private func testImage(color: UIColor, detailed: Bool) -> UIImage {
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 128, height: 128))
    return renderer.image { context in
      color.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
      if detailed {
        UIColor.black.setFill()
        for index in 0..<8 {
          context.fill(
            CGRect(
              x: index * 16,
              y: index.isMultiple(of: 2) ? 0 : 64,
              width: 8,
              height: 64
            ))
        }
      }
    }
  }

  private func testLowContrastBlurredImage() -> UIImage {
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 128, height: 128))
    return renderer.image { context in
      for x in 0..<128 {
        let component = CGFloat(120 + (x * 16 / 127)) / 255
        UIColor(white: component, alpha: 1).setFill()
        context.fill(CGRect(x: x, y: 0, width: 1, height: 128))
      }
    }
  }
}
