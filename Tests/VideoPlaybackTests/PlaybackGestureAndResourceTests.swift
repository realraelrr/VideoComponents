import SwiftUI
import UIKit
import XCTest
@testable import VideoPlayback

@MainActor
final class PlaybackGestureTests: XCTestCase {
  func testPinchImmediatelyBlocksHoldDoubleTapAndPanBeforeSwiftUIRefresh() async {
    var doubleTaps = 0
    var holds: [UIGestureRecognizer.State] = []
    var pinches: [SupplementPinchGestureValue] = []
    let coordinator = VideoGestureSurface.Coordinator(isZoomed: true, isMultiTouchGestureActive: false,
      shouldReceivePlaybackTouch: nil, onPinchUpdate: { pinches.append($0) }, onPanUpdate: { _ in },
      onLongPressStateChanged: { holds.append($0) }, onDoubleTap: { doubleTaps += 1 })
    let view = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
    let pinch = TestPinch(); let pan = UIPanGestureRecognizer(); let hold = TestHold(); let tap = TestTap()
    for gesture in [pinch, pan, hold, tap] { view.addGestureRecognizer(gesture) }
    coordinator.pinchRecognizer = pinch; coordinator.panRecognizer = pan
    coordinator.longPressRecognizer = hold; coordinator.tapRecognizer = tap
    pinch.simulatedState = .began; hold.simulatedState = .began; tap.simulatedState = .ended
    coordinator.handlePinch(pinch)
    XCTAssertEqual(pinches.last?.state, .began)
    XCTAssertFalse(coordinator.gestureRecognizerShouldBegin(hold))
    XCTAssertFalse(coordinator.gestureRecognizerShouldBegin(tap))
    XCTAssertFalse(coordinator.gestureRecognizerShouldBegin(pan))
    coordinator.handleDoubleTap(tap)
    coordinator.handleLongPress(hold)
    await Task.yield()
    XCTAssertEqual(doubleTaps, 0)
    XCTAssertTrue(holds.allSatisfy { $0 == .cancelled })
    pinch.simulatedState = .ended
    coordinator.handlePinch(pinch)
    XCTAssertTrue(coordinator.gestureRecognizerShouldBegin(pan))
    XCTAssertTrue(coordinator.gestureRecognizerShouldBegin(tap))
    XCTAssertTrue(coordinator.gestureRecognizer(pinch, shouldRecognizeSimultaneouslyWith: pan))
    XCTAssertFalse(coordinator.gestureRecognizer(tap, shouldRecognizeSimultaneouslyWith: hold))
  }

  func testDismantleCancelsActivePinchHoldAndRemovesAllRecognizers() async {
    var pinches: [SupplementPinchGestureValue] = []
    var holds: [UIGestureRecognizer.State] = []
    let coordinator = VideoGestureSurface.Coordinator(isZoomed: true, isMultiTouchGestureActive: true,
      shouldReceivePlaybackTouch: nil, onPinchUpdate: { pinches.append($0) }, onPanUpdate: { _ in },
      onLongPressStateChanged: { holds.append($0) }, onDoubleTap: {})
    let view = UIView(); let pinch = TestPinch(); let hold = TestHold()
    let pan = UIPanGestureRecognizer(); let tap = UITapGestureRecognizer()
    for recognizer in [pinch, hold, pan, tap] { view.addGestureRecognizer(recognizer) }
    coordinator.pinchRecognizer = pinch; coordinator.longPressRecognizer = hold
    coordinator.panRecognizer = pan; coordinator.tapRecognizer = tap
    pinch.simulatedState = .changed; hold.simulatedState = .began
    coordinator.removeGestures()
    await Task.yield()
    XCTAssertEqual(pinches.last?.state, .cancelled)
    XCTAssertEqual(pinches.last?.numberOfTouches, 0)
    XCTAssertEqual(holds, [.cancelled])
    XCTAssertTrue(view.gestureRecognizers?.isEmpty ?? true)
    XCTAssertNil(coordinator.pinchRecognizer)
    XCTAssertNil(coordinator.longPressRecognizer)
  }

  func testAnchorClampAspectFitAndScaleBounds() {
    let size = CGSize(width: 320, height: 450)
    let rect = VideoZoomGeometry.contentRect(containerSize: size, contentAspectRatio: 16 / 9)
    XCTAssertEqual(rect, CGRect(x: 0, y: 135, width: 320, height: 180))
    XCTAssertEqual(VideoZoomConfig.scale(startScale: 2, gestureScale: 4), 3)
    XCTAssertEqual(VideoZoomConfig.clampedScale(.nan), 1)
    XCTAssertFalse(VideoGesturePolicy.allowsSingleFingerPan(isZoomed: false, isMultiTouchGestureActive: false))
    XCTAssertTrue(VideoOuterScrollLockPolicy.shouldDisableOuterScroll(isZoomed: false, isMultiTouchGestureActive: true))
  }

  func testPlaybackControlsProvideMinimumInteractiveHeightInBothPresentations() {
    let playback = PlaybackSession()
    defer { playback.cleanup() }
    for style in [VideoPlaybackControlsStyle.inline, .fullscreen] {
      let host = UIHostingController(rootView: VideoPlaybackControls(playbackSession: playback,
        style: style, labels: .init(), tint: .blue, fullscreenAction: {}).buttonStyle(.plain))
      XCTAssertGreaterThanOrEqual(host.sizeThatFits(in: CGSize(width: 400, height: 1_000)).height, 44)
    }
  }

  func testInlineVideoGestureIncludesFormerBottomControlRegion() {
    XCTAssertTrue(VideoGestureRegion.containsInlinePoint(y: 299, height: 300))
    XCTAssertFalse(VideoGestureRegion.containsInlinePoint(y: -1, height: 300))
    XCTAssertFalse(VideoGestureRegion.containsInlinePoint(y: 301, height: 300))
    XCTAssertFalse(VideoGestureRegion.containsInlinePoint(y: .nan, height: 300))
  }
}

private final class TestPinch: UIPinchGestureRecognizer {
  var simulatedState: UIGestureRecognizer.State = .possible
  override var state: UIGestureRecognizer.State { get { simulatedState } set { simulatedState = newValue } }
  override var numberOfTouches: Int { 2 }
  override func location(in view: UIView?) -> CGPoint { CGPoint(x: 160, y: 200) }
}
private final class TestHold: UILongPressGestureRecognizer {
  var simulatedState: UIGestureRecognizer.State = .possible
  override var state: UIGestureRecognizer.State { get { simulatedState } set { simulatedState = newValue } }
}
private final class TestTap: UITapGestureRecognizer {
  var simulatedState: UIGestureRecognizer.State = .possible
  override var state: UIGestureRecognizer.State { get { simulatedState } set { simulatedState = newValue } }
}

final class PlaybackLocalizationTests: XCTestCase {
  func testSixLanguagesResolveCompleteResourceKeys() {
    let expected = ["en": "Play", "zh-Hans": "播放", "zh-Hant": "播放", "ja": "再生", "ko": "재생", "es": "Reproducir"]
    for (locale, play) in expected {
      let labels = VideoPlaybackLabels(locale: Locale(identifier: locale))
      XCTAssertEqual(labels.play, play)
      for value in [labels.pause, labels.fullscreen, labels.progress, labels.resetZoom, labels.close] {
        XCTAssertFalse(value.isEmpty)
        XCTAssertFalse(value.hasPrefix("video."))
      }
    }
  }

  func testRegionLocalesSelectTheirLanguageResource() {
    XCTAssertEqual(VideoPlaybackLabels(locale: Locale(identifier: "zh_CN")).play, "播放")
    XCTAssertEqual(VideoPlaybackLabels(locale: Locale(identifier: "zh_Hans_CN")).progress, "播放进度")
    XCTAssertEqual(VideoPlaybackLabels(locale: Locale(identifier: "es_MX")).play, "Reproducir")
    XCTAssertEqual(VideoPlaybackLabels(locale: Locale(identifier: "ja_JP")).play, "再生")
  }
}
