import Foundation
import VideoPlayback
import XCTest

final class VideoPlaybackRuntimeResourcesTests: XCTestCase {
  func testEnglishResourcesResolveFromTheConsumedPackage() {
    let labels = VideoPlaybackLabels(locale: Locale(identifier: "en"))
    XCTAssertEqual(labels.play, "Play")
    XCTAssertEqual(labels.pause, "Pause")
    XCTAssertEqual(labels.fullscreen, "Play fullscreen")
    XCTAssertEqual(labels.progress, "Playback progress")
    XCTAssertEqual(labels.resetZoom, "Reset zoom")
    XCTAssertEqual(labels.close, "Close")
  }

  func testSimplifiedChineseResourcesResolveFromTheConsumedPackage() {
    let labels = VideoPlaybackLabels(locale: Locale(identifier: "zh-Hans"))
    XCTAssertEqual(labels.play, "播放")
    XCTAssertEqual(labels.pause, "暂停")
    XCTAssertEqual(labels.fullscreen, "全屏播放")
    XCTAssertEqual(labels.progress, "播放进度")
    XCTAssertEqual(labels.resetZoom, "重置缩放")
    XCTAssertEqual(labels.close, "关闭")
  }

  func testRegionalLocalesResolveFromTheConsumedPackage() {
    XCTAssertEqual(VideoPlaybackLabels(locale: Locale(identifier: "zh_CN")).play, "播放")
    XCTAssertEqual(VideoPlaybackLabels(locale: Locale(identifier: "es_MX")).play, "Reproducir")
  }
}
