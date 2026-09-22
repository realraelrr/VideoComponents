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

    XCTAssertEqual(times.count, 5)
    XCTAssertEqual(times, times.sorted())
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
