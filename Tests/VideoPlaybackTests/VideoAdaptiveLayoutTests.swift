import XCTest
@testable import VideoPlayback

final class VideoAdaptiveLayoutTests: XCTestCase {
  func testAllocatedWidthDoesNotLoseASecondSetOfMargins() {
    let size = VideoPlayerLayout.adaptiveCardSize(
      forAvailableSize: CGSize(width: 288, height: 450),
      contentAspectRatio: 1,
      maximumSize: CGSize(width: 720, height: 540)
    )
    XCTAssertEqual(size, CGSize(width: 288, height: 288))
  }

  func testPracticeLandscapeVideoUsesLargerBoundWithoutExceedingIt() {
    let size = VideoPlayerLayout.adaptiveCardSize(
      forAvailableSize: CGSize(width: 720, height: 540),
      contentAspectRatio: 16 / 9,
      maximumSize: CGSize(width: 720, height: 540)
    )

    XCTAssertEqual(size.width, 720, accuracy: 0.001)
    XCTAssertEqual(size.height, 405, accuracy: 0.001)
  }

  func testPracticePortraitVideoStaysWithinHeightBound() {
    let size = VideoPlayerLayout.adaptiveCardSize(
      forAvailableSize: CGSize(width: 720, height: 540),
      contentAspectRatio: 9 / 16,
      maximumSize: CGSize(width: 720, height: 540)
    )

    XCTAssertEqual(size.width, 303.75, accuracy: 0.001)
    XCTAssertEqual(size.height, 540, accuracy: 0.001)
  }

  func testShortViewportLimitsVideoBeforeMaximumSize() {
    let size = VideoPlayerLayout.adaptiveCardSize(
      forAvailableSize: CGSize(width: 720, height: 240),
      contentAspectRatio: 16 / 9,
      maximumSize: CGSize(width: 720, height: 540)
    )
    XCTAssertEqual(size.width, 240 * 16 / 9, accuracy: 0.001)
    XCTAssertEqual(size.height, 240, accuracy: 0.001)
  }
}
