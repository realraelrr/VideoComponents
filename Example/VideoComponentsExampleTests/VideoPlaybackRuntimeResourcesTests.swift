import Foundation
import AVFoundation
import SwiftUI
import UIKit
import VideoFramePicker
@testable import VideoPlayback
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

@MainActor
final class VideoPlaybackMountedTests: XCTestCase {
  func testContactDefersTimeoutAndSingleTapRestoresHiddenChrome() async throws {
    let session = try await readySession()
    let probe = UIView()
    probe.backgroundColor = .magenta
    let host = UIHostingController(rootView: FullscreenPlaybackView(
      playbackSession: session, onClose: {},
      trailingAccessory: { PlaybackProbe(view: probe).frame(width: 44, height: 44) },
      statusOverlay: { EmptyView() }
    ).environment(\.scenePhase, .active))
    let window = mount(host, size: CGSize(width: 390, height: 700))
    defer { window.isHidden = true; window.rootViewController = nil; session.cleanup() }
    try await Task.sleep(for: .milliseconds(100))
    let observer = try XCTUnwrap(window.gestureRecognizers?.first {
      String(describing: type(of: $0)).contains("ContactRecognizer")
    })
    let surface = try XCTUnwrap(findGestureSurface(host.view))
    let coordinator = try XCTUnwrap(surface.gestureRecognizers?.first?.delegate as? VideoGestureSurface.Coordinator)
    for gesture in surface.gestureRecognizers ?? [] {
      XCTAssertFalse(observer.canPrevent(gesture))
      XCTAssertFalse(observer.canBePrevented(by: gesture))
    }
    XCTAssertFalse(observer.cancelsTouchesInView)
    XCTAssertFalse(observer.delaysTouchesBegan)
    XCTAssertFalse(observer.delaysTouchesEnded)
    let first = UITouch(), second = UITouch(), event = UIEvent()
    observer.touchesBegan([first, second], with: event)
    observer.touchesEnded([first], with: event)
    try await Task.sleep(for: .milliseconds(3_400))
    XCTAssertTrue(isMagenta(at: probe, in: host.view), "Remaining contact keeps controls visible")
    observer.touchesCancelled([second], with: event)
    try await Task.sleep(for: .milliseconds(3_400))
    XCTAssertFalse(isMagenta(at: probe, in: host.view))
    let tap = MountedTap()
    surface.addGestureRecognizer(tap)
    coordinator.handleSingleTap(tap)
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertTrue(isMagenta(at: probe, in: host.view))
    XCTAssertFalse(session.isPlaybackRequested, "A single tap only restores controls")
    coordinator.handleDoubleTap(tap)
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertTrue(session.isPlaybackRequested)
    XCTAssertTrue(isMagenta(at: probe, in: host.view))
  }

  func testFullscreenChromeHidesAfterThreeIdleSeconds() async throws {
    let session = try await readySession()
    let probe = UIView()
    probe.backgroundColor = .magenta
    let host = UIHostingController(rootView: FullscreenPlaybackView(
      playbackSession: session, onClose: {},
      trailingAccessory: { PlaybackProbe(view: probe).frame(width: 44, height: 44) },
      statusOverlay: { EmptyView() }
    ).environment(\.scenePhase, .active))
    let window = mount(host, size: CGSize(width: 390, height: 700))
    defer { window.isHidden = true; window.rootViewController = nil; session.cleanup() }
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertTrue(isMagenta(at: probe, in: host.view), "Chrome starts visible")
    try await Task.sleep(for: .milliseconds(3_400))
    XCTAssertFalse(isMagenta(at: probe, in: host.view), "Idle chrome must disappear")
  }

  func testZoomedPanKeepsActualAspectFitVideoInsideViewportAfterResize() async throws {
    let probe = UIView()
    probe.backgroundColor = .yellow
    let host = UIHostingController(rootView: MountedZoomProbe(probe: probe))
    let window = mount(host, size: CGSize(width: 320, height: 450))
    defer { window.isHidden = true; window.rootViewController = nil }
    try await Task.sleep(for: .milliseconds(100))
    let surface = try XCTUnwrap(findGestureSurface(host.view))
    let coordinator = try XCTUnwrap(surface.gestureRecognizers?.first?.delegate as? VideoGestureSurface.Coordinator)
    for (state, scale) in [(UIGestureRecognizer.State.began, CGFloat(1)), (.changed, 2), (.ended, 2)] {
      coordinator.onPinchUpdate(SupplementPinchGestureValue(scale: scale,
        location: CGPoint(x: 160, y: 225), state: state, numberOfTouches: 2))
    }
    try await Task.sleep(for: .milliseconds(50))
    let zoomedRect = try XCTUnwrap(renderedYellowRect(in: host.view))
    // Screen rendering can antialias one pixel at each fitted edge.
    XCTAssertEqual(zoomedRect.height, 360, accuracy: 3, "Pinch actually doubles the fitted video height")
    for translation in [CGSize(width: 2_000, height: 2_000), CGSize(width: -2_000, height: -2_000)] {
      coordinator.onPanUpdate(SupplementPanGestureValue(translation: .zero, state: .began, numberOfTouches: 1))
      coordinator.onPanUpdate(SupplementPanGestureValue(translation: translation, state: .changed, numberOfTouches: 1))
      coordinator.onPanUpdate(SupplementPanGestureValue(translation: translation, state: .ended, numberOfTouches: 1))
      try await Task.sleep(for: .milliseconds(50))
      let rect = try XCTUnwrap(renderedYellowRect(in: host.view), "Panning must leave the video visible")
      XCTAssertLessThanOrEqual(rect.minX, 2)
      XCTAssertGreaterThanOrEqual(rect.maxX, 318)
      XCTAssertEqual(rect.midY, 225, accuracy: 1, "Letterboxed axis stays centered")
    }
    window.frame.size = CGSize(width: 200, height: 400)
    host.view.frame = window.bounds
    host.view.setNeedsLayout()
    host.view.layoutIfNeeded()
    try await Task.sleep(for: .milliseconds(100))
    let rect = try XCTUnwrap(renderedYellowRect(in: host.view))
    XCTAssertLessThanOrEqual(rect.minX, 2)
    XCTAssertGreaterThanOrEqual(rect.maxX, 198)
    XCTAssertEqual(rect.midY, 200, accuracy: 1)
  }

  private func renderedYellowRect(in view: UIView) -> CGRect? {
    view.layoutIfNeeded()
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let image = UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { _ in
      XCTAssertTrue(view.drawHierarchy(in: view.bounds, afterScreenUpdates: true), "Screen rendering must succeed")
    }
    guard let cgImage = image.cgImage,
      let context = CGContext(data: nil, width: cgImage.width, height: cgImage.height,
        bitsPerComponent: 8, bytesPerRow: cgImage.width * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
      let data = context.data else { return nil }
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
    let pixels = data.assumingMemoryBound(to: UInt8.self)
    var minX = cgImage.width, minY = cgImage.height, maxX = -1, maxY = -1
    for y in 0..<cgImage.height {
      for x in 0..<cgImage.width {
        let index = (y * cgImage.width + x) * 4
        if pixels[index] > 200 && pixels[index + 1] > 200 && pixels[index + 2] < 60 {
          minX = min(minX, x); maxX = max(maxX, x)
          minY = min(minY, y); maxY = max(maxY, y)
        }
      }
    }
    guard maxX >= minX, maxY >= minY else { return nil }
    return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
  }

  private func readySession() async throws -> PlaybackSession {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("chrome-\(UUID()).caf")
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100))
    buffer.frameLength = 44_100
    buffer.floatChannelData?[0].update(repeating: 0, count: 44_100)
    do {
      let file = try AVAudioFile(forWriting: url, settings: format.settings)
      try file.write(from: buffer)
    }
    let session = PlaybackSession()
    session.load(source: PlaybackSource(identity: url, load: { AVURLAsset(url: url) }),
      playbackRate: 1, isLooping: true, autoplayWhenReady: false)
    for _ in 0..<400 {
      if session.canUsePlaybackControls { return session }
      try await Task.sleep(for: .milliseconds(5))
    }
    session.cleanup()
    throw NSError(domain: "PlaybackFixtureNotReady", code: 1)
  }

  private func mount<V: View>(_ host: UIHostingController<V>, size: CGSize) -> UIWindow {
    let window = UIWindow(frame: CGRect(origin: .zero, size: size))
    window.rootViewController = host
    window.makeKeyAndVisible()
    host.view.frame = window.bounds
    host.view.layoutIfNeeded()
    return window
  }

  private func findGestureSurface(_ view: UIView) -> UIView? {
    if view.gestureRecognizers?.contains(where: { $0 is UIPinchGestureRecognizer }) == true { return view }
    return view.subviews.lazy.compactMap(findGestureSurface).first
  }

  private func isMagenta(at probe: UIView, in view: UIView) -> Bool {
    view.layoutIfNeeded()
    let point = probe.convert(CGPoint(x: 22, y: 22), to: view)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let image = UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { _ in
      XCTAssertTrue(view.drawHierarchy(in: view.bounds, afterScreenUpdates: true), "Screen rendering must succeed")
    }
    guard let cgImage = image.cgImage, let crop = cgImage.cropping(to: CGRect(x: point.x, y: point.y, width: 1, height: 1)),
      let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
      let data = context.data else {
      XCTFail("Chrome snapshot must have a readable pixel at the accessory")
      return false
    }
    context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    let bytes = data.assumingMemoryBound(to: UInt8.self)
    return bytes[0] > 200 && bytes[1] < 60 && bytes[2] > 200
  }
}

private struct PlaybackProbe: UIViewRepresentable {
  let view: UIView
  func makeUIView(context: Context) -> UIView { view }
  func updateUIView(_ view: UIView, context: Context) {}
}

private struct MountedZoomProbe: View {
  let probe: UIView
  @State private var zoomed = false
  @State private var multiTouch = false
  var body: some View {
    ZoomableVideoContainer(contentAspectRatio: 16 / 9, isZooming: $zoomed,
      isMultiTouchGestureActive: $multiTouch, isGestureEnabled: true, cornerRadius: 0,
      shouldReceivePlaybackTouch: nil, onLongPressStateChanged: { _ in }, onDoubleTap: {}) {
      PlaybackProbe(view: probe).aspectRatio(16 / 9, contentMode: .fit)
    }
    .ignoresSafeArea()
  }
}

private final class MountedTap: UITapGestureRecognizer {
  override var state: UIGestureRecognizer.State { get { .ended } set {} }
}
