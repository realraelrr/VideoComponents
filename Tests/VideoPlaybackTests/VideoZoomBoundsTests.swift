import XCTest
@testable import VideoPlayback

final class VideoZoomBoundsTests: XCTestCase {
  func testLandscapeVideoInPortraitWindowLimitsPanAndCentersShortAxis() {
    let size = CGSize(width: 320, height: 450)
    XCTAssertEqual(bound(CGSize(width: 9_000, height: 9_000), size: size),
      CGSize(width: 160, height: 0))
    XCTAssertEqual(bound(CGSize(width: -9_000, height: -9_000), size: size),
      CGSize(width: -160, height: 0))
  }

  func testPortraitVideoInLandscapeWindowCentersShortAxisAndLimitsVerticalPan() {
    let size = CGSize(width: 450, height: 320)
    XCTAssertEqual(bound(CGSize(width: 9_000, height: 9_000), size: size, ratio: 9 / 16),
      CGSize(width: 0, height: 160))
    XCTAssertEqual(bound(CGSize(width: -9_000, height: -9_000), size: size, ratio: 9 / 16),
      CGSize(width: 0, height: -160))
  }

  func testUnzoomedVideoCannotMoveAndUnknownAspectRatioUsesViewport() {
    XCTAssertEqual(bound(CGSize(width: 90, height: -90), size: CGSize(width: 320, height: 450), scale: 1), .zero)
    XCTAssertEqual(bound(CGSize(width: 9_000, height: 9_000), size: CGSize(width: 320, height: 450), ratio: nil),
      CGSize(width: 160, height: 225))
  }

  func testResizeAndZoomOutRecomputeSmallerBounds() {
    let previousOffset = CGSize(width: 160, height: 0)
    XCTAssertEqual(bound(previousOffset, size: CGSize(width: 200, height: 400)), CGSize(width: 100, height: 0))
    XCTAssertEqual(bound(previousOffset, size: CGSize(width: 320, height: 450), scale: 1.5), CGSize(width: 80, height: 0))
  }

  func testInvalidGeometryDoesNotProduceNonfiniteOffsets() {
    XCTAssertEqual(bound(.zero, size: CGSize(width: CGFloat.infinity, height: 400)), .zero)
    XCTAssertEqual(bound(.zero, size: .zero), .zero)
    XCTAssertEqual(bound(CGSize(width: CGFloat.nan, height: CGFloat.infinity), size: CGSize(width: 320, height: 450)), .zero)
  }

  private func bound(
    _ offset: CGSize, size: CGSize, scale: CGFloat = 2,
    ratio: CGFloat? = 16 / 9
  ) -> CGSize {
    VideoZoomBounds.clampedOffset(offset, scale: scale,
      containerSize: size, contentAspectRatio: ratio)
  }
}
