import Foundation
import VideoFramePicker
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

final class VideoFramePickerRuntimeResourcesTests: XCTestCase {
  func testEnglishResourcesResolveFromTheConsumedPackage() {
    let labels = VideoFramePickerLabels(locale: Locale(identifier: "en"))
    XCTAssertEqual(labels.preview, "Frame preview")
    XCTAssertEqual(labels.time, "Frame time")
    XCTAssertEqual(labels.processing, "Processing selection")
    XCTAssertEqual(labels.sourceUnavailable, "The video is unavailable.")
    XCTAssertEqual(labels.frameUnavailable, "Unable to read this video frame.")
    XCTAssertEqual(labels.selectionFailed, "Unable to process the selected frame. Try again.")
  }

  func testSimplifiedChineseResourcesResolveFromTheConsumedPackage() {
    let labels = VideoFramePickerLabels(locale: Locale(identifier: "zh-Hans"))
    XCTAssertEqual(labels.preview, "画面预览")
    XCTAssertEqual(labels.time, "画面时间")
    XCTAssertEqual(labels.processing, "正在处理所选画面")
    XCTAssertEqual(labels.sourceUnavailable, "暂时无法读取视频")
    XCTAssertEqual(labels.frameUnavailable, "暂时无法读取视频帧")
    XCTAssertEqual(labels.selectionFailed, "所选画面处理失败，请重试")
  }

  func testRegionalLocalesResolveFromTheConsumedPackage() {
    XCTAssertEqual(VideoFramePickerLabels(locale: Locale(identifier: "zh_CN")).preview, "画面预览")
    XCTAssertEqual(VideoFramePickerLabels(locale: Locale(identifier: "es_MX")).preview, "Vista previa del fotograma")
  }
}
