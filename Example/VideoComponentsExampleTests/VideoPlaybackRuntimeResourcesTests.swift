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
  func testSecondPinchKeepsTheCurrentFingerFocusAfterPanning() async throws {
    let probe = PinchFocusProbe()
    let host = UIHostingController(rootView: MountedZoomProbe(probe: probe))
    let window = mount(host, size: CGSize(width: 320, height: 450))
    defer { window.isHidden = true; window.rootViewController = nil }
    try await Task.sleep(for: .milliseconds(100))
    let surface = try XCTUnwrap(findGestureSurface(host.view))
    let coordinator = try XCTUnwrap(surface.gestureRecognizers?.first?.delegate as? VideoGestureSurface.Coordinator)
    func pinch(at point: CGPoint, scale: CGFloat) async throws {
      coordinator.onPinchUpdate(.init(scale: 1, location: point, state: .began, numberOfTouches: 2))
      coordinator.onPinchUpdate(.init(scale: scale, location: point, state: .changed, numberOfTouches: 2))
      coordinator.onPinchUpdate(.init(scale: scale, location: point, state: .ended, numberOfTouches: 2))
      try await Task.sleep(for: .milliseconds(50))
    }
    try await pinch(at: CGPoint(x: 160, y: 225), scale: 2)
    coordinator.onPanUpdate(.init(translation: .zero, state: .began, numberOfTouches: 1))
    coordinator.onPanUpdate(.init(translation: CGSize(width: 20, height: 0), state: .changed, numberOfTouches: 1))
    coordinator.onPanUpdate(.init(translation: CGSize(width: 20, height: 0), state: .ended, numberOfTouches: 1))
    try await Task.sleep(for: .milliseconds(50))
    // This source point is under the second pinch's fingers after the first zoom and pan.
    let before = try XCTUnwrap(renderedPixels(in: host.view, matching: { $0 > 200 && $1 < 60 && $2 > 200 }))
    let focusBefore = CGPoint(x: before.midX, y: before.midY)
    XCTAssertEqual(focusBefore.x, 260, accuracy: 1)
    try await pinch(at: focusBefore, scale: 1.5)
    let after = try XCTUnwrap(renderedPixels(in: host.view, matching: { $0 > 200 && $1 < 60 && $2 > 200 }))
    let focusAfter = CGPoint(x: after.midX, y: after.midY)
    XCTAssertEqual(focusAfter.x, focusBefore.x, accuracy: 1, "The video point beneath the fingers must remain there on a second pinch")
    XCTAssertEqual(focusAfter.y, focusBefore.y, accuracy: 1)
  }

  func testBlockingStatusCannotCoverOrInterceptFullscreenClose() async throws {
    let session = PlaybackSession()
    let source = PlaybackSource(identity: "unavailable", load: { throw NSError(domain: "fixture", code: 1) })
    session.load(source: source, playbackRate: 1, isLooping: false, autoplayWhenReady: false)
    for _ in 0..<300 where session.status != .unavailable { try await Task.sleep(for: .milliseconds(5)) }
    XCTAssertEqual(session.status, .unavailable)
    let host = UIHostingController(rootView: FullscreenPlaybackView(
      playbackSession: session, onClose: {}, trailingAccessory: { EmptyView() },
      statusOverlay: { Color.red.ignoresSafeArea().contentShape(Rectangle()).onTapGesture {} }
    ).environment(\.scenePhase, .active))
    let window = mount(host, size: CGSize(width: 390, height: 700))
    defer { window.isHidden = true; window.rootViewController = nil; session.cleanup() }
    try await Task.sleep(for: .milliseconds(100))
    let closePixels = try XCTUnwrap(renderedPixels(in: host.view, matching: { $0 > 230 && $1 > 230 && $2 > 230 }),
      "The white close icon must remain rendered above the opaque, interactive status layer")
    XCTAssertLessThan(closePixels.maxX, 60)
    XCTAssertLessThan(closePixels.maxY, 120)
  }

  private func renderedPixels(in view: UIView, matching: (UInt8, UInt8, UInt8) -> Bool) -> CGRect? {
    view.layoutIfNeeded()
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let image = UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { _ in
      XCTAssertTrue(view.drawHierarchy(in: view.bounds, afterScreenUpdates: true))
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
        if matching(pixels[index], pixels[index + 1], pixels[index + 2]) {
          minX = min(minX, x); maxX = max(maxX, x)
          minY = min(minY, y); maxY = max(maxY, y)
        }
      }
    }
    guard maxX >= minX, maxY >= minY else { return nil }
    return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
  }

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
    session.load(source: PlaybackSource(identity: url, load: { PlaybackLoadedMedia(asset: AVURLAsset(url: url)) }),
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

private final class PinchFocusProbe: UIView {
  override func draw(_ rect: CGRect) {
    UIColor.yellow.setFill()
    UIRectFill(bounds)
    UIColor.magenta.setFill()
    UIRectFill(CGRect(x: bounds.width * 0.625 - 3, y: bounds.midY - 3, width: 6, height: 6))
  }
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

/// Uses external simctl screen captures: unit-host XCTest is not authorized to use XCUIScreen.
/// drawHierarchy/layer.render can omit AVPlayerLayer's video.
/// Every handoff must positively reach green video; black or an isHidden assertion cannot pass.
@MainActor
final class VideoPlaybackPosterHandoffTests: XCTestCase {
  private typealias NativeView = InlineVideoPlayerLayer.PlayerLayerView
  private enum Presentation: String, CaseIterable { case inline, fullscreen }
  private enum PixelColor: String { case red, green, blue, black, other }
  private struct ScreenFrame {
    let image: UIImage
    let color: PixelColor
    let description: String
  }
  private struct CaptureRect: Codable {
    let x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat
    init(_ rect: CGRect) { x = rect.minX; y = rect.minY; width = rect.width; height = rect.height }
  }
  private struct NativeFacts: Codable {
    let hasPlayer: Bool
    let hasCurrentItem: Bool
    let itemStatus: String
    let isReadyForDisplay: Bool
  }
  private struct CaptureDriver: Decodable {
    let protocolVersion: Int
    let simulatorUDID: String
    let runToken: String
    let state: String
    let failure: String?
  }
  private struct CaptureRequest: Encodable {
    let protocolVersion = 1
    let token: String
    let runToken: String
    let simulatorUDID: String
    let processID: Int32
    let test: String
    let stage: String
    let createdAt: Double
    let expiresAt: Double
    let mediaROI: CaptureRect
    let screenBounds: CaptureRect
    let nativeFacts: NativeFacts
  }
  private struct CaptureResponse: Decodable {
    let protocolVersion: Int
    let token: String
    let runToken: String
    let simulatorUDID: String
    let success: Bool
    let failure: String?
    let png: String?
    let byteCount: Int?
    let captureStartedAt: Double?
  }
  private struct CaptureError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
  }
  private enum FixtureError: Error { case timeout(String), writerFailed }
  private var previousKeyWindow: UIWindow?


  func testApprovedIntentRuleBackgroundReadyRetainsSavedPoster() async throws {
    let asset = try await greenVideo()
    let poster = image(.red)
    let session = PlaybackSession()
    let identity = AnyHashable(UUID())
    defer { session.cleanup() }
    session.load(source: PlaybackSource(identity: identity, load: { PlaybackLoadedMedia(asset: asset) }),
      playbackRate: 1, isLooping: true, autoplayWhenReady: false)
    let host = UIHostingController(rootView: sharedView(.inline, session: session,
      provider: { poster }, sourceIdentity: identity))
    let window = try mount(host)
    defer { unmount(window) }
    let media = try await mountedMedia(in: host.view)
    try await poll("background resource/item/native layer ready without Play") {
      session.isPlayerReady && media.playerLayer.isReadyForDisplay
    }
    XCTAssertFalse(session.isPlaybackRequested)
    XCTAssertEqual(session.player.rate, 0)
    let evidence = XCTAttachment(string: "userPlay=false; sessionRequested=\(session.isPlaybackRequested); playerRate=\(session.player.rate); itemReady=\(session.isPlayerReady); layerReady=\(media.playerLayer.isReadyForDisplay)")
    evidence.name = "approved-background-ready-state"
    evidence.lifetime = .keepAlways
    add(evidence)
    try await assertColor(.red, in: media, name: "approved-background-ready-must-still-be-saved-red-poster")
  }

  func testApprovedIntentRuleHeldResourceOffersPlayAndAcceptsIntent() async throws {
    let asset = try await greenVideo()
    let poster = image(.red)
    let session = PlaybackSession()
    let identity = AnyHashable(UUID())
    let gate = PosterHandoffAssetGate(asset: asset)
    defer { gate.release(); session.cleanup() }
    session.load(source: PlaybackSource(identity: identity, load: { PlaybackLoadedMedia(asset: try await gate.load()) }),
      playbackRate: 1, isLooping: true, autoplayWhenReady: false)
    let host = UIHostingController(rootView: sharedView(.inline, session: session,
      provider: { poster }, sourceIdentity: identity))
    let window = try mount(host)
    defer { unmount(window) }
    let media = try await mountedMedia(in: host.view)
    try await poll("resource acquisition held") { gate.started }
    XCTAssertFalse(session.hasCurrentItem)
    try await assertColor(.red, in: media, name: "approved-resource-held-saved-poster-and-play-entry")
    XCTAssertTrue(session.canTogglePlayback, "Saved poster must offer the Play action while background acquisition is pending")
    session.togglePlayback()
    let evidence = XCTAttachment(string: "userPlay=true; hasItem=\(session.hasCurrentItem); controlsAvailable=\(session.canTogglePlayback); requested=\(session.isPlaybackRequested)")
    evidence.name = "approved-held-resource-play-state"
    evidence.lifetime = .keepAlways
    add(evidence)
    XCTAssertTrue(session.isPlaybackRequested, "A Play action before item acquisition must register pending intent")
    try await assertColor(.red, in: media, name: "approved-resource-held-after-play-saved-poster")
  }



  func testApprovedPendingPlayCancellationAndPauseKeepTheCorrectPicture() async throws {
    let asset = try await greenVideo()
    let poster = image(.red)
    let session = PlaybackSession()
    let identity = AnyHashable(UUID())
    let gate = PosterHandoffAssetGate(asset: asset)
    defer { gate.release(); session.cleanup() }
    session.load(source: PlaybackSource(identity: identity, load: { PlaybackLoadedMedia(asset: try await gate.load()) }),
      playbackRate: 1, isLooping: true, autoplayWhenReady: false)
    let host = UIHostingController(rootView: sharedView(.inline, session: session,
      provider: { poster }, sourceIdentity: identity))
    let window = try mount(host)
    defer { unmount(window) }
    let media = try await mountedMedia(in: host.view)
    try await poll("pending fixture acquisition held") { gate.started }
    XCTAssertFalse(session.isWaitingForPlayback)
    session.togglePlayback()
    XCTAssertTrue(session.isWaitingForPlayback)
    try await assertColor(.red, in: media, name: "intent-pending-play-retains-red")
    session.togglePlayback() // The same Play/Pause control cancels pending intent.
    XCTAssertFalse(session.isPlaybackRequested)
    XCTAssertFalse(session.isWaitingForPlayback)
    try await assertColor(.red, in: media, name: "intent-pending-cancel-retains-red")
    session.togglePlayback()
    session.togglePlayback()
    XCTAssertFalse(session.isPlaybackRequested, "Repeated taps cannot leave a queued Play after the final cancellation")
    gate.release()
    try await poll("cancelled acquisition completes in background") { session.isPlayerReady }
    try await assertColor(.red, in: media, name: "intent-cancelled-background-ready-still-red")
    XCTAssertEqual(session.player.rate, 0)
    XCTAssertFalse(session.hasPresentedVideo)
    session.togglePlayback()
    try await waitForGreen(in: media, name: "intent-first-actual-play-green")
    XCTAssertTrue(session.hasPresentedVideo)
    XCTAssertFalse(session.isWaitingForPlayback)
    session.pausePlayback()
    try await assertColor(.green, in: media, name: "intent-first-pause-keeps-green")
    XCTAssertTrue(session.hasPresentedVideo)
    session.togglePlayback()
    try await poll("native resume playing") { session.player.timeControlStatus == .playing }
    try await assertColor(.green, in: media, name: "intent-resume-keeps-green")
    session.pausePlayback()
    try await assertColor(.green, in: media, name: "intent-second-pause-keeps-green")
  }

  func testApprovedPendingPlayCleanupRejectsLateAcquisitionPicture() async throws {
    let asset = try await greenVideo()
    let poster = image(.red)
    let gate = PosterHandoffAssetGate(asset: asset)
    let session = PlaybackSession()
    defer { gate.release(); session.cleanup() }
    session.load(source: PlaybackSource(identity: UUID(), load: { PlaybackLoadedMedia(asset: try await gate.load()) }),
      playbackRate: 1, isLooping: true, autoplayWhenReady: false)
    let host = UIHostingController(rootView: sharedView(.inline, session: session, provider: { poster }))
    let window = try mount(host)
    defer { unmount(window) }
    let media = try await mountedMedia(in: host.view)
    try await poll("cleanup acquisition held") { gate.started }
    session.togglePlayback()
    XCTAssertTrue(session.isWaitingForPlayback)
    session.cleanup() // The host invokes this when the playback owner leaves.
    gate.release()
    for _ in 0..<3 { try await nextRenderFrame() }
    XCTAssertNil(session.currentSourceIdentity)
    XCTAssertNil(session.player.currentItem)
    XCTAssertFalse(session.isPlaybackRequested)
    XCTAssertFalse(session.hasPresentedVideo)
    XCTAssertFalse(session.isWaitingForPlayback)
    XCTAssertEqual(session.player.rate, 0)
    try await assertColor(.red, in: media, name: "intent-leave-rejects-late-green")
  }

  func testApprovedSourceSwitchRejectsOldPendingPlayAndPoster() async throws {
    let assetA = try await greenVideo()
    let assetB = try await solidVideo(red: 255, green: 0, blue: 0)
    let gateA = PosterHandoffAssetGate(asset: assetA)
    let session = PlaybackSession()
    let identityA = AnyHashable(UUID()), identityB = AnyHashable(UUID())
    let posterA = image(.red), posterB = image(.blue)
    defer { gateA.release(); session.cleanup() }
    session.load(source: PlaybackSource(identity: identityA, load: { PlaybackLoadedMedia(asset: try await gateA.load()) }),
      playbackRate: 1, isLooping: true, autoplayWhenReady: false)
    let host = UIHostingController(rootView: sharedView(.inline, session: session,
      provider: { posterA }, sourceIdentity: identityA))
    let window = try mount(host)
    defer { unmount(window) }
    try await poll("source A held before pending Play") { gateA.started }
    session.togglePlayback()
    XCTAssertTrue(session.isWaitingForPlayback)
    host.rootView = sharedView(.inline, session: session, provider: { posterB }, sourceIdentity: identityB)
    session.load(source: PlaybackSource(identity: identityB, load: { PlaybackLoadedMedia(asset: assetB) }),
      playbackRate: 1, isLooping: true, autoplayWhenReady: false)
    let media = try await mountedMedia(in: host.view)
    gateA.release()
    try await poll("B ready after obsolete A completion") { session.isPlayerReady }
    XCTAssertEqual(session.currentSourceIdentity, identityB)
    XCTAssertFalse(session.isPlaybackRequested)
    XCTAssertFalse(session.hasPresentedVideo)
    XCTAssertEqual(session.player.rate, 0)
    try await assertColor(.blue, in: media, name: "intent-new-source-ready-stays-blue-no-obsolete-green")
    session.togglePlayback()
    try await waitForRedVideo(in: media, name: "intent-new-source-user-play-real-red")
    XCTAssertTrue(session.hasPresentedVideo)
    session.pausePlayback()
    try await assertColor(.red, in: media, name: "intent-new-source-pause-keeps-red-video")
  }

  func testApprovedPreparationFailureKeepsPosterUntilExplicitRetryPlays() async throws {
    let asset = try await greenVideo()
    let poster = image(.red)
    let session = PlaybackSession()
    let source = PlaybackSource(identity: UUID(), load: { PlaybackLoadedMedia(asset: asset) })
    var attempts = 0
    let retryPreparation = PosterHandoffAssetGate(asset: asset)
    session.preparation = PlaybackPreparation(prepare: { _ in
      attempts += 1
      if attempts == 1 { throw NSError(domain: "NativePreparationFixture", code: 1) }
      _ = try await retryPreparation.load()
    }, release: { _ in })
    defer { retryPreparation.release(); session.cleanup() }
    session.load(source: source, playbackRate: 1, isLooping: true, autoplayWhenReady: false)
    let host = UIHostingController(rootView: sharedView(.inline, session: session, provider: { poster }))
    let window = try mount(host)
    defer { unmount(window) }
    let media = try await mountedMedia(in: host.view)
    try await poll("audio fixture native item ready") { session.isPlayerReady }
    let item = try XCTUnwrap(session.player.currentItem)
    session.togglePlayback()
    try await poll("host preparation failure explicit state") { session.failure != nil }
    XCTAssertEqual(attempts, 1)
    XCTAssertFalse(session.isPlaybackRequested)
    XCTAssertFalse(session.hasPresentedVideo)
    XCTAssertFalse(session.isWaitingForPlayback)
    XCTAssertEqual(session.player.rate, 0)
    try await assertColor(.red, in: media, name: "intent-audio-failure-retains-red-not-first-frame")
    session.togglePlayback()
    for _ in 0..<3 { try await nextRenderFrame() }
    XCTAssertEqual(attempts, 1, "Ordinary Play cannot silently retry failed host preparation")
    XCTAssertTrue(session.player.currentItem === item)
    session.retryPlaybackPreparation() // This is the App's explicit Retry route for audio preparation failure.
    try await poll("retry audio preparation awaiting host") { retryPreparation.started }
    XCTAssertTrue(session.isWaitingForPlayback)
    XCTAssertTrue(session.isPlayerReady)
    XCTAssertTrue(media.playerLayer.isReadyForDisplay)
    XCTAssertFalse(session.hasPresentedVideo)
    XCTAssertEqual(session.player.rate, 0)
    try await assertColor(.red, in: media, name: "intent-audio-retry-native-ready-but-not-playing-stays-red")
    retryPreparation.release()
    try await waitForGreen(in: media, name: "intent-explicit-audio-retry-actual-green")
    XCTAssertEqual(attempts, 2)
    XCTAssertTrue(session.player.currentItem === item, "Audio retry preserves the prepared media")
    XCTAssertTrue(session.hasPresentedVideo)
    session.pausePlayback()
    try await assertColor(.green, in: media, name: "intent-audio-retry-pause-keeps-green")
  }


  func testApprovedNeverPlayedInlineFullscreenRoundTripKeepsSavedPoster() async throws {
    let asset = try await greenVideo()
    let poster = image(.red)
    let session = PlaybackSession()
    defer { session.cleanup() }
    session.load(source: PlaybackSource(identity: UUID(), load: { PlaybackLoadedMedia(asset: asset) }),
      playbackRate: 1, isLooping: true, autoplayWhenReady: false)
    let host = UIHostingController(rootView: sharedView(.inline, session: session, provider: { poster }))
    let window = try mount(host)
    defer { unmount(window) }
    let inline = try await mountedMedia(in: host.view)
    try await poll("never-played inline native ready") {
      session.isPlayerReady && inline.playerLayer.isReadyForDisplay
    }
    try await assertColor(.red, in: inline, name: "intent-never-played-inline-ready-red")
    host.rootView = sharedView(.fullscreen, session: session, provider: { poster })
    let fullscreen = try await mountedMedia(in: host.view)
    try await poll("never-played fullscreen native ready") { fullscreen.playerLayer.isReadyForDisplay }
    try await assertColor(.red, in: fullscreen, name: "intent-never-played-fullscreen-ready-red")
    XCTAssertFalse(session.isPlaybackRequested)
    XCTAssertFalse(session.isWaitingForPlayback)
    XCTAssertFalse(session.hasPresentedVideo)
    host.rootView = sharedView(.inline, session: session, provider: { poster })
    let returned = try await mountedMedia(in: host.view)
    try await poll("never-played return inline native ready") { returned.playerLayer.isReadyForDisplay }
    try await assertColor(.red, in: returned, name: "intent-never-played-return-inline-red")
    session.togglePlayback()
    try await waitForGreen(in: returned, name: "intent-after-roundtrip-first-play-green")
    XCTAssertTrue(session.hasPresentedVideo)
  }


  func testApprovedFastPauseBeforeDeferredHandoffStillSurvivesFullscreenTransfer() async throws {
    let asset = try await greenVideo()
    let poster = image(.red)
    let session = PlaybackSession()
    defer { session.cleanup() }
    session.load(source: PlaybackSource(identity: UUID(), load: { PlaybackLoadedMedia(asset: asset) }),
      playbackRate: 1, isLooping: true, autoplayWhenReady: false)
    let host = UIHostingController(rootView: sharedView(.inline, session: session, provider: { poster }))
    let window = try mount(host)
    defer { unmount(window) }
    let inline = try await mountedMedia(in: host.view)
    try await poll("fast-pause item and native layer ready") {
      session.isPlayerReady && inline.playerLayer.isReadyForDisplay
    }
    let nativePoster = try XCTUnwrap(inline.subviews.compactMap { $0 as? UIImageView }
      .first { $0.image === poster })
    let observation = nativePoster.observe(\.isHidden, options: [.new]) { [weak session] _, change in
      guard change.newValue == true, Thread.isMainThread else { return }
      MainActor.assumeIsolated {
        guard let session, session.isPlaybackRequested else { return }
        // Native handoff has happened, but its deferred session publication has not.
        session.pausePlayback()
      }
    }
    defer { observation.invalidate() }
    session.togglePlayback()
    try await poll("native handoff followed by immediate pause and deferred publication") {
      !session.isPlaybackRequested && session.hasPresentedVideo
    }
    XCTAssertEqual(session.player.rate, 0)
    try await assertColor(.green, in: inline, name: "intent-fast-pause-before-deferred-publication-green")
    host.rootView = sharedView(.fullscreen, session: session, provider: { poster })
    let fullscreen = try await mountedMedia(in: host.view)
    try await waitForGreen(in: fullscreen, name: "intent-fast-pause-fullscreen-no-red", allowing: [.green])
    XCTAssertTrue(session.hasPresentedVideo)
    XCTAssertFalse(session.isPlaybackRequested)
  }


  func testApprovedCleanupReloadOfSameIdentityRejectsOldDeferredHandoff() async throws {
    let asset = try await greenVideo()
    let poster = image(.red)
    let identity = AnyHashable(UUID())
    let reloadGate = PosterHandoffAssetGate(asset: asset)
    let session = PlaybackSession()
    let reloadSource = PlaybackSource(identity: identity, load: { PlaybackLoadedMedia(asset: try await reloadGate.load()) })
    defer { reloadGate.release(); session.cleanup() }
    session.load(source: PlaybackSource(identity: identity, load: { PlaybackLoadedMedia(asset: asset) }),
      playbackRate: 1, isLooping: true, autoplayWhenReady: false)
    let host = UIHostingController(rootView: sharedView(.inline, session: session,
      provider: { poster }, sourceIdentity: identity))
    let window = try mount(host)
    defer { unmount(window) }
    let media = try await mountedMedia(in: host.view)
    try await poll("old source native ready before ABA handoff") {
      session.isPlayerReady && media.playerLayer.isReadyForDisplay
    }
    let nativePoster = try XCTUnwrap(media.subviews.compactMap { $0 as? UIImageView }
      .first { $0.image === poster })
    let observation = nativePoster.observe(\.isHidden, options: [.new]) { [weak session] _, change in
      guard change.newValue == true, Thread.isMainThread else { return }
      MainActor.assumeIsolated {
        guard let session, session.isPlaybackRequested else { return }
        // The prior visit's display report is queued but has not been published.
        session.cleanup()
        session.load(source: reloadSource, playbackRate: 1, isLooping: true, autoplayWhenReady: false)
      }
    }
    defer { observation.invalidate() }
    session.togglePlayback()
    try await poll("same identity reload held after prior visit's native handoff") { reloadGate.started }
    for _ in 0..<3 { try await nextRenderFrame() }
    XCTAssertFalse(session.hasPresentedVideo, "A matching identity cannot adopt an old visit's queued display fact")
    XCTAssertFalse(session.isPlaybackRequested)
    try await assertColor(.red, in: media, name: "intent-same-identity-new-visit-rejects-old-deferred-green")
    reloadGate.release()
    try await poll("new visit becomes ready in background") { session.isPlayerReady }
    try await assertColor(.red, in: media, name: "intent-same-identity-new-visit-ready-still-red")
    observation.invalidate()
    session.togglePlayback()
    try await waitForGreen(in: media, name: "intent-same-identity-new-visit-user-play-green")
    XCTAssertTrue(session.hasPresentedVideo)
  }

  func testSharedInlineExpectedSourceChangeMasksReadyPreviousVideoUntilNewSourceReady() async throws {
    try await assertExpectedSourceChange(.inline)
  }

  func testSharedFullscreenExpectedSourceChangeMasksReadyPreviousVideoUntilNewSourceReady() async throws {
    try await assertExpectedSourceChange(.fullscreen)
  }

  func testSharedInlineCleanupThenHeldReloadOfSameSourceRestoresPoster() async throws {
    try await assertCleanupThenSameSourceReload(.inline)
  }

  func testSharedFullscreenCleanupThenHeldReloadOfSameSourceRestoresPoster() async throws {
    try await assertCleanupThenSameSourceReload(.fullscreen)
  }

  func testRawSourceIdentityNilItemResetsHandoffBeforeHeldReloadOnSamePlayer() async throws {
    let asset = try await greenVideo()
    let poster = image(.red)
    let session = PlaybackSession()
    let identity = AnyHashable(UUID())
    let gate = PosterHandoffAssetGate(asset: asset)
    defer { gate.release(); session.cleanup() }
    session.load(source: PlaybackSource(identity: identity, load: { PlaybackLoadedMedia(asset: asset) }),
      playbackRate: 1, isLooping: true, autoplayWhenReady: false)
    let host = UIHostingController(rootView: PosterHandoffRawSessionView(
      session: session, identity: identity, poster: poster))
    let window = try mount(host)
    defer { unmount(window) }
    let media = try await mountedMedia(in: host.view)
    try await waitForGreen(in: media, name: "raw-identity-before-nil-item-real-green")
    let player = session.player
    session.cleanup()
    XCTAssertNil(player.currentItem)
    XCTAssertNil(session.currentSourceIdentity)
    try await assertColor(.red, in: media, name: "raw-same-player-nil-item-resets-source-handoff-red")
    XCTAssertTrue(media.playerLayer.player === player,
      "Raw rendering keeps this player bound: this reset is nil-item, not nil-player")
    session.load(source: PlaybackSource(identity: identity, load: { PlaybackLoadedMedia(asset: try await gate.load()) }),
      playbackRate: 1, isLooping: true, autoplayWhenReady: false)
    try await poll("raw same-identity reload held") { gate.started }
    try await assertColor(.red, in: media, name: "raw-same-identity-held-reload-red")
    XCTAssertTrue(media.playerLayer.player === player)
    XCTAssertNil(player.currentItem)
    gate.release()
    try await waitForGreen(in: media, name: "raw-same-player-same-identity-reload-real-green")
    XCTAssertTrue(session.isPlayerReady)
    XCTAssertTrue(media.playerLayer.isReadyForDisplay)
  }

  func testRawSourceIdentityLatePosterDuringRealReplacementDoesNotCoverAlreadyShownVideo() async throws {
    let asset = try await greenVideo()
    let latePoster = image(.blue)
    let session = PlaybackSession()
    let identity = AnyHashable(UUID())
    defer { session.cleanup() }
    session.load(source: PlaybackSource(identity: identity, load: { PlaybackLoadedMedia(asset: asset) }),
      playbackRate: 1, isLooping: true, autoplayWhenReady: false)
    let host = UIHostingController(rootView: PosterHandoffRawSessionView(
      session: session, identity: identity, poster: nil))
    let window = try mount(host)
    defer { unmount(window) }
    let media = try await mountedMedia(in: host.view)
    try await waitForGreen(in: media, name: "raw-identity-no-poster-first-real-green", allowing: [.blue, .green])
    let original = try XCTUnwrap(session.player.currentItem)
    var publishedLatePoster = false
    // Published sends before storing. Use its incoming value; never set readiness or hold native transport.
    let readinessObservation = session.$isPlayerReady.sink { ready in
      guard !ready, !publishedLatePoster else { return }
      publishedLatePoster = true
      let evidence = XCTAttachment(string: "event=late-poster-published-on-production-readiness-false; "
        + "wallTime=\(Date().timeIntervalSince1970); monotonicTime=\(CACurrentMediaTime()); "
        + "originalItemStillInstalled=\(session.player.currentItem === original)")
      evidence.name = "raw-late-poster-production-phase"
      evidence.lifetime = .keepAlways
      self.add(evidence)
      host.rootView = PosterHandoffRawSessionView(session: session, identity: identity, poster: latePoster)
    }
    defer { readinessObservation.cancel() }
    try await assertRealReplacementKeepsVideo(session: session, media: media,
      asset: AVURLAsset(url: asset.url), identity: identity, color: .green, name: "raw-late-blue-poster")
    XCTAssertTrue(publishedLatePoster, "The late poster must arrive on the real production replacement transition")
    let mountedPoster = try XCTUnwrap(media.subviews.compactMap { $0 as? UIImageView }
      .first { $0.image === latePoster }, "The actual late poster must reach the native view")
    XCTAssertTrue(mountedPoster.isHidden)
  }

  private func assertExpectedSourceChange(_ mode: Presentation) async throws {
    let greenAsset = try await greenVideo()
    let redAsset = try await solidVideo(red: 255, green: 0, blue: 0)
    let posterA = image(.red), posterB = image(.blue)
    let session = PlaybackSession()
    let sourceA = PlaybackSource(identity: UUID(), load: { PlaybackLoadedMedia(asset: greenAsset) })
    let gateB = PosterHandoffAssetGate(asset: redAsset)
    let sourceB = PlaybackSource(identity: UUID(), load: { PlaybackLoadedMedia(asset: try await gateB.load()) }, thumbnail: { _ in posterB })
    defer { gateB.release(); session.cleanup() }
    session.load(source: sourceA, playbackRate: 1, isLooping: true, autoplayWhenReady: false)
    let host = UIHostingController(rootView: sharedView(mode, session: session,
      provider: { posterA }, sourceIdentity: sourceA.identity))
    let window = try mount(host)
    defer { unmount(window) }
    let mediaA = try await mountedMedia(in: host.view)
    let stage = mode.rawValue + "-expected-source-A-to-B"
    session.togglePlayback()
    try await waitForGreen(in: mediaA, name: stage + "-A-ready-real-green")
    session.pausePlayback()
    let itemA = try XCTUnwrap(session.player.currentItem)
    XCTAssertTrue(session.isPlayerReady)
    // Host metadata changes first. The session is deliberately still ready for A.
    host.rootView = sharedView(mode, session: session, provider: { posterB }, sourceIdentity: sourceB.identity)
    let mediaB = try await mountedMedia(in: host.view)
    try await assertColor(.blue, in: mediaB, name: stage + "-B-published-before-session-load-blue")
    XCTAssertNil(mediaB.playerLayer.player, "Expected B must not bind A's ready player")
    XCTAssertTrue(session.isCurrentSource(sourceA.identity))
    XCTAssertEqual(session.currentSourceIdentity, sourceA.identity)
    XCTAssertTrue(session.isPlayerReady)
    XCTAssertTrue(session.player.currentItem === itemA, "Publishing B must not mutate the still-current A session")
    let nativePoster = try XCTUnwrap(mediaB.subviews.compactMap { $0 as? UIImageView }
      .first { $0.image === posterB })
    let trace = PosterHandoffReplacementTrace(media: mediaB, poster: nativePoster,
      session: session, identity: sourceB.identity, test: name)
    trace.start()
    defer { retainReplacementTrace(trace, name: stage) }
    trace.mark("expected-B-published-session-still-A")
    session.load(source: sourceB, playbackRate: 1, isLooping: true, autoplayWhenReady: false)
    try await poll("source B production acquisition held") { gateB.started }
    trace.mark("source-B-load-held")
    try await assertColor(.blue, in: mediaB, name: stage + "-B-held-blue-no-A")
    XCTAssertTrue(session.isCurrentSource(sourceB.identity))
    XCTAssertEqual(session.currentSourceIdentity, sourceB.identity)
    XCTAssertFalse(session.isPlayerReady)
    XCTAssertNil(session.player.currentItem)
    XCTAssertNil(mediaB.playerLayer.player)
    gateB.release()
    try await poll("B acquired in background before explicit Play") { session.isPlayerReady }
    try await assertColor(.blue, in: mediaB, name: stage + "-B-ready-before-play-still-blue")
    session.togglePlayback()
    try await waitForRedVideo(in: mediaB, name: stage + "-B-ready-real-red")
    session.pausePlayback()
    XCTAssertTrue(session.isPlayerReady)
    XCTAssertTrue(mediaB.playerLayer.isReadyForDisplay)
    XCTAssertTrue(mediaB.playerLayer.player === session.player)
    XCTAssertFalse(session.player.currentItem === itemA)
    try await poll("B's natural blue-poster handoff witnessed by native KVO") { trace.sawInitialPosterHide }
    trace.mark("B-warm-real-red-confirmed")
    // Same red bytes/source B, different item. Blue is the distinguishable saved poster.
    try await assertRealReplacementKeepsVideo(session: session, media: mediaB,
      asset: AVURLAsset(url: redAsset.url), identity: sourceB.identity, color: .red,
      name: stage + "-B-HQ", trace: trace)
  }

  private func assertCleanupThenSameSourceReload(_ mode: Presentation) async throws {
    let asset = try await greenVideo()
    let poster = image(.red)
    let session = PlaybackSession()
    let identity = AnyHashable(UUID())
    let reloadGate = PosterHandoffAssetGate(asset: asset)
    defer { reloadGate.release(); session.cleanup() }
    session.load(source: PlaybackSource(identity: identity, load: { PlaybackLoadedMedia(asset: asset) }),
      playbackRate: 1, isLooping: true, autoplayWhenReady: false)
    let host = UIHostingController(rootView: sharedView(mode, session: session,
      provider: { poster }, sourceIdentity: identity))
    let window = try mount(host)
    defer { unmount(window) }
    let media = try await mountedMedia(in: host.view)
    let stage = mode.rawValue + "-cleanup-same-source-reload"
    session.togglePlayback()
    try await waitForGreen(in: media, name: stage + "-before-cleanup-real-green")
    let original = try XCTUnwrap(session.player.currentItem)
    session.cleanup()
    XCTAssertNil(session.currentSourceIdentity)
    XCTAssertNil(session.player.currentItem)
    try await assertColor(.red, in: media, name: stage + "-cleanup-restores-red-poster")
    XCTAssertNil(media.playerLayer.player, "Shared views must detach the cleaned-up session")
    session.load(source: PlaybackSource(identity: identity, load: { PlaybackLoadedMedia(asset: try await reloadGate.load()) }),
      playbackRate: 1, isLooping: true, autoplayWhenReady: false)
    try await poll("same resource reload acquisition held") { reloadGate.started }
    try await assertColor(.red, in: media, name: stage + "-held-same-resource-red-poster")
    XCTAssertTrue(session.isCurrentSource(identity))
    XCTAssertNil(session.player.currentItem)
    XCTAssertNil(media.playerLayer.player)
    reloadGate.release()
    try await poll("same source background reload ready") { session.isPlayerReady }
    try await assertColor(.red, in: media, name: stage + "-reloaded-ready-before-play-red")
    session.togglePlayback()
    try await waitForGreen(in: media, name: stage + "-reloaded-same-resource-real-green")
    XCTAssertTrue(session.isPlayerReady)
    XCTAssertTrue(media.playerLayer.isReadyForDisplay)
    XCTAssertTrue(media.playerLayer.player === session.player)
    XCTAssertFalse(session.player.currentItem === original)
  }

  private func assertRealReplacementKeepsVideo(
    session: PlaybackSession, media: NativeView, asset: AVAsset, identity: AnyHashable,
    color: PixelColor, name: String, trace: PosterHandoffReplacementTrace? = nil
  ) async throws {
    let original = try XCTUnwrap(session.player.currentItem)
    XCTAssertTrue(session.isPlayerReady)
    XCTAssertTrue(session.isCurrentSource(identity))
    trace?.beginReplacement(after: color.rawValue)
    var finished = false
    let replacement = Task {
      defer { finished = true }
      try await session.replaceAsset(PlaybackLoadedMedia(asset: asset), for: identity)
    }
    defer { replacement.cancel() }
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(8))
    var previous: PixelColor?
    repeat {
      try await nextRenderFrame()
      let frame = try await screenFrame(in: media, stage: name + "-real-replaceAsset")
      if frame.color != previous || finished { retain(frame, name: name + "-replacement-" + frame.color.rawValue) }
      XCTAssertEqual(frame.color, color, "Same-source video must remain visible, with no saved poster/black: \(frame.description)")
      previous = frame.color
    } while !finished && clock.now < deadline
    guard finished else {
      XCTFail("Production replaceAsset did not finish")
      throw FixtureError.timeout(name)
    }
    try await replacement.value
    trace?.mark("replaceAsset-returned")
    let candidate = try XCTUnwrap(session.player.currentItem)
    XCTAssertFalse(candidate === original)
    XCTAssertTrue(session.isCurrentSource(identity))
    try await poll("replacement item ready with real paused transport and native display") {
      session.isPlayerReady && candidate.status == .readyToPlay && media.playerLayer.isReadyForDisplay
        && session.player.timeControlStatus == .paused && session.player.rate == 0
    }
    try await assertColor(color, in: media, name: name + "-warm-ready-final-video")
    trace?.mark("warm-ready-final-video-confirmed")
    try await assertColor(color, in: media, name: name + "-final-video-still-visible")
    XCTAssertFalse(session.isPlaybackRequested)
    XCTAssertTrue(media.playerLayer.player === session.player)
    if let trace {
      XCTAssertGreaterThan(trace.replacementDisplayTicks, 0)
      XCTAssertTrue(trace.replacementItemIDs.contains(String(describing: ObjectIdentifier(candidate))))
      XCTAssertFalse(trace.posterResurfaced, "The current source's saved poster returned during a real HQ replacement")
    }
  }

  func testSharedInlinePlayingHQReplacementShowsAdvancingNativeGreenBrightness() async throws {
    try await assertPlayingHQBrightnessAdvances(.inline)
  }

  func testSharedFullscreenPlayingHQReplacementShowsAdvancingNativeGreenBrightness() async throws {
    try await assertPlayingHQBrightnessAdvances(.fullscreen)
  }

  private func assertPlayingHQBrightnessAdvances(_ mode: Presentation) async throws {
    let initialAsset = try await greenVideo() // Constant green 255 cannot satisfy the advancing-picture oracle.
    let hqAsset = try await solidVideo(red: 0, green: 255, blue: 0, alternatingGreenBrightness: true)
    let poster = image(.red)
    let session = PlaybackSession()
    let source = PlaybackSource(identity: UUID(), load: { PlaybackLoadedMedia(asset: initialAsset) })
    defer { session.cleanup() }
    session.load(source: source, playbackRate: 1, isLooping: true, autoplayWhenReady: true)
    let host = UIHostingController(rootView: sharedView(mode, session: session, provider: { poster },
      sourceIdentity: source.identity))
    let window = try mount(host)
    defer { unmount(window) }
    let media = try await mountedMedia(in: host.view)
    let stage = mode.rawValue + "-playing-HQ-brightness"
    try await waitForGreen(in: media, name: stage + "-constant-original-real-green")
    try await poll("original source native playback") {
      session.isPlayerReady && session.player.timeControlStatus == .playing && session.player.rate == 1
    }
    let originalFrame = try await screenFrame(in: media, stage: stage + "-constant-original-RGB-calibration")
    retain(originalFrame, name: stage + "-constant-original-RGB-calibration")
    XCTAssertEqual(originalFrame.color, .green)
    let originalRGB = try sampledScreenRGB(originalFrame, in: media)
    XCTAssertGreaterThan(originalRGB.green, 235)
    let nativePoster = try XCTUnwrap(media.subviews.compactMap { $0 as? UIImageView }.first { $0.image === poster })
    let trace = PosterHandoffReplacementTrace(media: media, poster: nativePoster,
      session: session, identity: source.identity, test: name)
    trace.start()
    defer { retainReplacementTrace(trace, name: stage) }
    let original = try XCTUnwrap(session.player.currentItem)
    trace.beginReplacement()
    var finished = false
    let replacement = Task {
      defer { finished = true }
      try await session.replaceAsset(PlaybackLoadedMedia(asset: hqAsset), for: source.identity)
    }
    defer { replacement.cancel() }
    let clock = ContinuousClock()
    let replacementDeadline = clock.now.advanced(by: .seconds(8))
    repeat {
      try await nextRenderFrame()
      let frame = try await screenFrame(in: media, stage: stage + "-real-replaceAsset")
      if frame.color != .green || finished { retain(frame, name: stage + "-replacement-" + frame.color.rawValue) }
      XCTAssertEqual(frame.color, .green, "HQ replacement must not expose poster/black: \(frame.description)")
    } while !finished && clock.now < replacementDeadline
    guard finished else { throw FixtureError.timeout(stage + " replacement") }
    try await replacement.value
    let candidate = try XCTUnwrap(session.player.currentItem)
    XCTAssertFalse(candidate === original)
    XCTAssertTrue(session.isCurrentSource(source.identity))
    try await poll("HQ native playback and display ready") {
      session.isPlayerReady && candidate.status == .readyToPlay && media.playerLayer.isReadyForDisplay
        && session.player.timeControlStatus == .playing && session.player.rate == 1
    }
    trace.mark("HQ-returned-playing-brightness-observation")
    var samples: [String] = []
    defer {
      let attachment = XCTAttachment(string: samples.joined(separator: "\n") + "\n")
      attachment.name = stage + "-compositor-rgb-samples.jsonl"
      attachment.lifetime = .keepAlways
      add(attachment)
    }
    var sawLow = false, sawHigh = false, transitions = 0
    var previousLevel: String?
    let deadline = clock.now.advanced(by: .seconds(6))
    while clock.now < deadline && !(sawLow && sawHigh && transitions >= 2) {
      try await nextRenderFrame()
      let frame = try await screenFrame(in: media, stage: stage + "-HQ-playing-RGB")
      let rgb = try sampledScreenRGB(frame, in: media)
      // Saved compositor PNGs and independent ROI decoding agree: input 190 -> G223,
      // while input 250 clips to the original's G255. Keep both HQ tiers below that ceiling.
      let level = rgb.green >= 175 && rgb.green <= 205 ? "low-input-160"
        : rgb.green >= 213 && rgb.green <= 235 && rgb.green <= originalRGB.green - 10
          ? "high-input-190" : "transition"
      let facts: [String: Any] = ["wallTime": Date().timeIntervalSince1970,
        "monotonicTime": CACurrentMediaTime(), "phase": "HQ-playing-RGB", "level": level,
        "red": rgb.red, "green": rgb.green, "blue": rgb.blue,
        "originalGreen": originalRGB.green, "capture": frame.description]
      samples.append(String(decoding: try JSONSerialization.data(withJSONObject: facts, options: [.sortedKeys]), as: UTF8.self))
      XCTAssertEqual(frame.color, .green, "Only real green HQ pixels count; poster/black fails: \(frame.description)")
      XCTAssertTrue(session.player.currentItem === candidate, "Brightness changes must belong to the installed HQ item")
      if frame.color != .green || level != previousLevel {
        retain(frame, name: stage + "-RGB-" + level)
      }
      if frame.color == .green && level != "transition" {
        sawLow = sawLow || level == "low-input-160"
        sawHigh = sawHigh || level == "high-input-190"
        if let previousLevel, level != previousLevel { transitions += 1 }
        previousLevel = level
      }
    }
    XCTAssertTrue(sawLow && sawHigh && transitions >= 2,
      "Actual compositor ROI must cross both green bands 175...205 and 213...235 twice after HQ returns; old G255 and native time/readiness alone cannot pass")
    trace.mark("HQ-brightness-observation-ended-low-\(sawLow)-high-\(sawHigh)-transitions-\(transitions)")
    try await assertColor(.green, in: media, name: stage + "-warm-ready-final-green")
    XCTAssertTrue(session.isPlaybackRequested)
    XCTAssertFalse(trace.posterResurfaced)
    XCTAssertGreaterThan(trace.replacementDisplayTicks, 0)
    XCTAssertTrue(trace.replacementItemIDs.contains(String(describing: ObjectIdentifier(candidate))))
  }

  private func sampledScreenRGB(_ frame: ScreenFrame, in view: UIView) throws -> (red: Double, green: Double, blue: Double) {
    let window = try XCTUnwrap(view.window)
    let bounds = window.screen.coordinateSpace.bounds
    let roi = view.bounds.insetBy(dx: view.bounds.width * 0.4, dy: view.bounds.height * 0.4)
    let screenROI = window.convert(view.convert(roi, to: window), to: window.screen.coordinateSpace)
    let image = try XCTUnwrap(frame.image.cgImage)
    let sx = CGFloat(image.width) / bounds.width, sy = CGFloat(image.height) / bounds.height
    let crop = try XCTUnwrap(image.cropping(to: CGRect(x: (screenROI.minX - bounds.minX) * sx,
      y: (screenROI.minY - bounds.minY) * sy, width: screenROI.width * sx, height: screenROI.height * sy).integral))
    let context = try XCTUnwrap(CGContext(data: nil, width: 12, height: 12, bitsPerComponent: 8, bytesPerRow: 48,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(crop, in: CGRect(x: 0, y: 0, width: 12, height: 12))
    let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
    var red = 0, green = 0, blue = 0, black = 0
    for pixel in 0..<144 { red += Int(bytes[pixel * 4]); green += Int(bytes[pixel * 4 + 1]); blue += Int(bytes[pixel * 4 + 2]) }
    return (Double(red) / 144, Double(green) / 144, Double(blue) / 144)
  }

  func testSharedInlineSameSourceReplacementDoesNotReshowSavedPosterWhilePaused() async throws {
    try await assertSameSourceReplacement(.inline, playing: false)
  }

  func testSharedInlineSameSourceReplacementDoesNotReshowSavedPosterWhilePlaying() async throws {
    try await assertSameSourceReplacement(.inline, playing: true)
  }

  func testSharedFullscreenSameSourceReplacementDoesNotReshowSavedPosterWhilePaused() async throws {
    try await assertSameSourceReplacement(.fullscreen, playing: false)
  }

  func testSharedFullscreenSameSourceReplacementDoesNotReshowSavedPosterWhilePlaying() async throws {
    try await assertSameSourceReplacement(.fullscreen, playing: true)
  }

  private func assertSameSourceReplacement(_ mode: Presentation, playing: Bool) async throws {
    let asset = try await greenVideo()
    let posterURL = FileManager.default.temporaryDirectory.appendingPathComponent("saved-poster-\(UUID()).png")
    addTeardownBlock { try? FileManager.default.removeItem(at: posterURL) }
    try XCTUnwrap(image(.red).pngData()).write(to: posterURL)
    let savedPoster = try XCTUnwrap(UIImage(contentsOfFile: posterURL.path))
    let gate = PosterHandoffAssetGate(asset: asset)
    let session = PlaybackSession() // Production preparation, native readiness and restoring seek.
    defer { gate.release(); session.cleanup() }
    let source = PlaybackSource(identity: UUID(), load: { PlaybackLoadedMedia(asset: try await gate.load()) }, thumbnail: { _ in savedPoster })
    session.load(source: source, playbackRate: 0.75, isLooping: true, autoplayWhenReady: false)
    try await poll("same-source initial acquisition held") { gate.started }
    let host = UIHostingController(rootView: sharedView(mode, session: session, provider: { savedPoster }))
    let window = try mount(host)
    defer { unmount(window) }
    let media = try await mountedMedia(in: host.view)
    let nativePoster = try XCTUnwrap(media.subviews.compactMap { $0 as? UIImageView }
      .first { $0.image === savedPoster }, "Observe the actual native saved-poster view")
    let stage = "\(mode.rawValue)-\(playing ? "playing" : "paused")-same-source"
    try await assertColor(.red, in: media, name: stage + "-saved-red-poster-calibration")
    let trace = PosterHandoffReplacementTrace(media: media, poster: nativePoster,
      session: session, identity: source.identity, test: name)
    trace.start()
    defer { retainReplacementTrace(trace, name: stage) }
    gate.release()
    try await poll("production source ready for real scrub") {
      session.canUsePlaybackControls && session.durationSeconds > 0
    }
    // Paused after actual playback differs from a source that has merely become ready.
    session.togglePlayback()
    try await waitForGreen(in: media, name: stage + "-first-actual-play-before-paused-HQ")
    session.pausePlayback()
    let pausedPosition = session.durationSeconds * 0.25
    session.handleScrubEditingChanged(true)
    session.setScrubProgress(0.25)
    session.handleScrubEditingChanged(false)
    try await poll("native nonzero paused position") {
      abs(session.player.currentTime().seconds - pausedPosition) < 0.05
    }
    if playing {
      session.togglePlayback()
      try await poll("native playback before representation replacement") {
        session.player.timeControlStatus == .playing && abs(session.player.rate - 0.75) < 0.01
      }
    }
    try await waitForGreen(in: media, name: stage + "-warm-ready-green-calibration")
    XCTAssertTrue(session.isPlayerReady)
    XCTAssertTrue(media.playerLayer.isReadyForDisplay)
    XCTAssertEqual(session.isPlaybackRequested, playing)
    try await poll("poster KVO independently calibrated by natural first handoff") { trace.sawInitialPosterHide }
    let player = session.player
    let originalItem = try XCTUnwrap(player.currentItem)
    // A new AVAsset/AVPlayerItem for the same bytes and identity, not a source A-to-B change.
    let replacementAsset = AVURLAsset(url: asset.url)
    trace.beginReplacement()
    var finished = false
    let replacement = Task {
      defer { finished = true }
      try await session.replaceAsset(PlaybackLoadedMedia(asset: replacementAsset), for: source.identity)
    }
    defer { replacement.cancel() }
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(8))
    var previous: PixelColor?
    repeat {
      try await nextRenderFrame()
      let frame = try await screenFrame(in: media, stage: stage + "-real-replaceAsset")
      if frame.color != previous || finished { retain(frame, name: stage + "-replacement-" + frame.color.rawValue) }
      // Keep collecting after a failure so the old implementation also supplies final-green evidence.
      XCTAssertEqual(frame.color, .green,
        "Same-source replacement must not reshow the saved red poster or expose black: \(frame.description)")
      previous = frame.color
    } while !finished && clock.now < deadline
    guard finished else {
      XCTFail("Production replaceAsset did not finish; native facts are retained")
      throw FixtureError.timeout(stage + " replacement")
    }
    try await replacement.value
    trace.mark("replaceAsset-returned")
    let candidate = try XCTUnwrap(player.currentItem)
    XCTAssertFalse(candidate === originalItem, "The real production call must install a different item")
    XCTAssertTrue(candidate.asset === replacementAsset)
    XCTAssertTrue(session.player === player)
    XCTAssertTrue(media.playerLayer.player === player)
    XCTAssertTrue(session.isCurrentSource(source.identity), "Item replacement must preserve source identity")
    try await poll("warm replacement item, display and restored native transport") {
      session.isPlayerReady && candidate.status == .readyToPlay && media.playerLayer.isReadyForDisplay
        && (playing ? player.timeControlStatus == .playing && abs(player.rate - 0.75) < 0.01
          : player.timeControlStatus == .paused && player.rate == 0)
    }
    // Actual compositor pixels are mandatory even when every native readiness flag is true.
    try await assertColor(.green, in: media, name: stage + "-warm-ready-final-green")
    trace.mark("warm-ready-final-green-confirmed")
    try await assertColor(.green, in: media, name: stage + "-warm-ready-final-green-still-visible")
    XCTAssertEqual(session.isPlaybackRequested, playing)
    XCTAssertEqual(session.playbackConfig.playbackRate, 0.75)
    XCTAssertTrue(session.playbackConfig.isLooping)
    if !playing { XCTAssertEqual(player.currentTime().seconds, pausedPosition, accuracy: 0.05) }
    XCTAssertGreaterThan(trace.replacementDisplayTicks, 0, "Continuous native evidence must span replacement")
    XCTAssertTrue(trace.replacementItemIDs.contains(String(describing: ObjectIdentifier(candidate))),
      "Independent native currentItem KVO must witness the new item")
    XCTAssertFalse(trace.posterResurfaced,
      "The saved poster returned after calibrated green video during production replaceAsset; inspect framefacts")
  }

  private func retainReplacementTrace(_ trace: PosterHandoffReplacementTrace, name: String) {
    trace.stop()
    let facts = trace.lines.joined(separator: "\n") + "\n"
    let attachment = XCTAttachment(string: facts)
    attachment.name = name + "-framefacts.jsonl"
    attachment.lifetime = .keepAlways
    add(attachment)
    if let directory = ProcessInfo.processInfo.environment["VIDEO_COMPONENTS_CAPTURE_DIRECTORY"] {
      let url = URL(fileURLWithPath: directory, isDirectory: true)
        .appendingPathComponent(name + "-" + UUID().uuidString + ".framefacts.jsonl")
      do { try Data(facts.utf8).write(to: url, options: .atomic) }
      catch { XCTFail("Cannot retain replacement facts beside compositor screenshots: \(error)") }
    }
  }

  func testScreenCaptureCalibratesRealGreenVideoAgainstRedPoster() async throws {
    let asset = try await greenVideo()
    let surface = UIView()
    let controller = UIViewController()
    let window = try mount(controller)
    defer { unmount(window) }
    place(surface, in: controller.view)
    let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
    let layer = AVPlayerLayer(player: player)
    layer.videoGravity = .resizeAspect
    layer.frame = surface.bounds
    surface.layer.addSublayer(layer)
    defer { layer.player = nil; player.replaceCurrentItem(with: nil) }
    let poster = UIImageView(image: image(.red))
    poster.frame = surface.bounds
    poster.contentMode = .scaleAspectFit
    surface.addSubview(poster)
    try await assertColor(.red, in: surface, name: "calibration-opaque-red-poster")
    try await poll("real calibration layer readiness") { layer.isReadyForDisplay }
    // Calibration is independent of the component's placeholder implementation.
    poster.removeFromSuperview()
    try await waitForGreen(in: surface, name: "calibration-real-video", allowing: [.red, .green])
    XCTAssertTrue(layer.isReadyForDisplay)
  }

  func testItemReadinessFalseKeepsRedAfterNativeLayerIsReady() async throws {
    let asset = try await greenVideo()
    let view = NativeView()
    let controller = UIViewController()
    let window = try mount(controller)
    defer { view.detach(); unmount(window) }
    place(view, in: controller.view)
    let poster = image(.red)
    let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
    configure(view, player: player, poster: poster, ready: false)
    try await assertColor(.red, in: view, name: "item-not-ready-before-native-ready")
    try await poll("native layer ready while host item readiness remains false") {
      view.playerLayer.isReadyForDisplay
    }
    XCTAssertEqual(player.currentItem?.status, .readyToPlay)
    try await assertColor(.red, in: view, name: "native-ready-item-not-ready-red")
    XCTAssertTrue(view.playerLayer.player === player, "The video must remain attached beneath the poster")
    configure(view, player: player, poster: poster, ready: true)
    try await waitForGreen(in: view, name: "both-ready-reveals-real-green")
  }

  func testHostReadyBeforeNativeLayerKeepsRedUntilRealGreen() async throws {
    let asset = try await greenVideo()
    let view = NativeView()
    let controller = UIViewController()
    let window = try mount(controller)
    defer { view.detach(); unmount(window) }
    place(view, in: controller.view)
    let poster = image(.red)
    let player = AVPlayer()
    configure(view, player: player, poster: poster, ready: true)
    XCTAssertFalse(view.playerLayer.isReadyForDisplay)
    try await assertColor(.red, in: view, name: "host-ready-layer-not-ready-red")
    player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
    // No configure call follows replacement: native KVO must complete the handoff.
    try await waitForGreen(in: view, name: "host-first-native-readiness-handoff")
    XCTAssertTrue(view.playerLayer.isReadyForDisplay)
  }

  func testNewNativeFullscreenLayerAndReturnInlineKeepCurrentPoster() async throws {
    let asset = try await greenVideo()
    let controller = UIViewController()
    let window = try mount(controller)
    defer { unmount(window) }
    let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
    let poster = image(.red)
    let inline = NativeView()
    place(inline, in: controller.view)
    configure(inline, player: player, poster: poster, ready: false)
    try await assertColor(.red, in: inline, name: "inline-preparing-red")
    configure(inline, player: player, poster: poster, ready: true)
    try await waitForGreen(in: inline, name: "inline-real-green")

    inline.detach()
    inline.removeFromSuperview()
    let fullscreen = NativeView()
    place(fullscreen, in: controller.view)
    configure(fullscreen, player: player, poster: poster, ready: false)
    try await poll("new fullscreen layer readiness") { fullscreen.playerLayer.isReadyForDisplay }
    try await assertColor(.red, in: fullscreen, name: "new-fullscreen-layer-preparing-current-red")
    XCTAssertNil(inline.playerLayer.player)
    XCTAssertTrue(fullscreen.playerLayer.player === player)
    configure(fullscreen, player: player, poster: poster, ready: true)
    try await waitForGreen(in: fullscreen, name: "fullscreen-real-green")

    fullscreen.detach()
    fullscreen.removeFromSuperview()
    let returnedInline = NativeView()
    defer { returnedInline.detach() }
    place(returnedInline, in: controller.view)
    configure(returnedInline, player: player, poster: poster, ready: false)
    try await poll("new return-inline layer readiness") { returnedInline.playerLayer.isReadyForDisplay }
    try await assertColor(.red, in: returnedInline, name: "new-return-inline-preparing-current-red")
    XCTAssertNil(fullscreen.playerLayer.player)
    XCTAssertTrue(returnedInline.playerLayer.player === player)
    configure(returnedInline, player: player, poster: poster, ready: true)
    try await waitForGreen(in: returnedInline, name: "return-inline-real-green")
  }

  func testNilPlayerAndNilItemKeepRedPoster() async throws {
    let asset = try await greenVideo()
    let view = NativeView()
    let controller = UIViewController()
    let window = try mount(controller)
    defer { view.detach(); unmount(window) }
    place(view, in: controller.view)
    let poster = image(.red)
    configure(view, player: nil, poster: poster, ready: true)
    try await assertColor(.red, in: view, name: "nil-player-red")
    let player = AVPlayer()
    configure(view, player: player, poster: poster, ready: true)
    try await assertColor(.red, in: view, name: "nil-current-item-red")
    player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
    try await waitForGreen(in: view, name: "nil-item-to-real-green")
    player.replaceCurrentItem(with: nil)
    try await assertColor(.red, in: view, name: "removed-item-restores-red-without-configure")
    configure(view, player: nil, poster: poster, ready: true)
    try await assertColor(.red, in: view, name: "removed-player-keeps-red")
  }

  func testPlayerAndItemReplacementRejectObsoleteReadiness() async throws {
    let asset = try await greenVideo()
    let view = NativeView()
    let controller = UIViewController()
    let window = try mount(controller)
    defer { view.detach(); unmount(window) }
    place(view, in: controller.view)
    let oldPlayer = AVPlayer(playerItem: AVPlayerItem(asset: asset))
    configure(view, player: oldPlayer, poster: image(.red), ready: true)
    try await waitForGreen(in: view, name: "old-player-real-green")

    // Queue real currentItem changes, then supersede the observed player before yielding.
    oldPlayer.replaceCurrentItem(with: nil)
    oldPlayer.replaceCurrentItem(with: AVPlayerItem(asset: asset))
    let currentPlayer = AVPlayer()
    let currentPoster = image(.blue)
    configure(view, player: currentPlayer, poster: currentPoster, ready: true)
    let obsoleteSurface = UIView(frame: CGRect(x: 12, y: 80, width: 80, height: 60))
    controller.view.addSubview(obsoleteSurface)
    let obsoleteLayer = AVPlayerLayer(player: oldPlayer)
    obsoleteLayer.frame = obsoleteSurface.bounds
    obsoleteSurface.layer.addSublayer(obsoleteLayer)
    defer { obsoleteLayer.player = nil }
    // The obsolete item's readiness really advances; it cannot reveal the current empty layer.
    try await poll("obsolete player renders on another layer") { obsoleteLayer.isReadyForDisplay }
    try await waitForGreen(in: obsoleteSurface, name: "obsolete-player-positive-green", allowing: [.blue, .green])
    try await assertColor(.blue, in: view, name: "replacement-rejects-obsolete-ready-and-old-red")
    XCTAssertTrue(view.playerLayer.player === currentPlayer)
    XCTAssertNil(currentPlayer.currentItem)
    currentPlayer.replaceCurrentItem(with: AVPlayerItem(asset: asset))
    try await waitForGreen(in: view, name: "replacement-current-video-green", allowing: [.blue, .green])

    // Replacement on the same player must rebind the observed item, without a view update.
    currentPlayer.replaceCurrentItem(with: nil)
    try await assertColor(.blue, in: view, name: "same-player-nil-item-current-poster")
    currentPlayer.replaceCurrentItem(with: AVPlayerItem(asset: asset))
    try await waitForGreen(in: view, name: "same-player-new-item-green", allowing: [.blue, .green])
  }

  func testDetachAndDismantleRejectLateReadinessAndReleaseView() async throws {
    let asset = try await greenVideo()
    let controller = UIViewController()
    let window = try mount(controller)
    defer { unmount(window) }
    let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
    var mounted: NativeView? = NativeView()
    weak var releasedView = mounted
    do {
      let view = try XCTUnwrap(mounted)
      place(view, in: controller.view)
      configure(view, player: player, poster: image(.red), ready: true)
      try await waitForGreen(in: view, name: "before-detach-real-green")
      view.detach()
      XCTAssertNil(view.playerLayer.player)
      configure(view, player: nil, poster: image(.red), ready: true)
      // Exercise late currentItem notifications after detach, while a new nil-player binding is mounted.
      player.replaceCurrentItem(with: nil)
      player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
      try await assertColor(.red, in: view, name: "detached-old-player-cannot-reveal-new-binding")
      XCTAssertNil(view.playerLayer.player)
      InlineVideoPlayerLayer.dismantleUIView(view, coordinator: ())
      XCTAssertNil(view.playerLayer.player)
      view.removeFromSuperview()
    }
    mounted = nil
    player.replaceCurrentItem(with: nil)
    try await poll("dismantled native view released despite obsolete observers") { releasedView == nil }
  }

  func testNativeNoPosterDoesNotSynthesizeRed() async throws {
    let asset = try await greenVideo()
    let view = NativeView()
    let controller = UIViewController()
    let window = try mount(controller)
    defer { view.detach(); unmount(window) }
    place(view, in: controller.view)
    // A known blue substrate makes absence observable without accepting black as evidence.
    view.backgroundColor = .blue
    configure(view, player: nil, poster: nil, ready: false)
    try await assertColor(.blue, in: view, name: "no-poster-positive-blue-substrate")
    let player = AVPlayer()
    configure(view, player: player, poster: nil, ready: true)
    try await assertColor(.blue, in: view, name: "no-poster-no-item-positive-blue")
    player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
    try await waitForGreen(in: view, name: "no-poster-real-green", allowing: [.blue, .green])
  }

  func testSharedInlineAndFullscreenDefaultPosterSurvivesHeldAccessValidation() async throws {
    let asset = try await greenVideo()
    for mode in Presentation.allCases {
      let poster = image(.red)
      let gate = PosterHandoffAssetGate(asset: asset)
      let validationGate = PosterHandoffAssetGate(asset: asset)
      let session = PlaybackSession()
      defer { gate.release(); validationGate.release(); session.cleanup() }
      let source = PlaybackSource(identity: UUID(), load: { PlaybackLoadedMedia(asset: try await gate.load()) }, thumbnail: { _ in poster })
      session.load(source: source, playbackRate: 1, isLooping: false, autoplayWhenReady: false)
      try await poll("initial source acquisition started") { gate.started }
      XCTAssertNil(session.thumbnailImage, "The source thumbnail starts only after source acquisition returns")
      gate.release()
      try await poll("source thumbnail and item ready after acquisition") {
        session.thumbnailImage === poster && session.isPlayerReady
      }
      // Existing access revalidation retains the thumbnail while detaching the item.
      // Hold this separate operation, not the source loader that supplies the thumbnail.
      session.revalidateAccess(source: source, refreshID: 1) { .validate { PlaybackLoadedMedia(asset: try await validationGate.load()) } }
      try await poll("access validation held with retained source thumbnail") { validationGate.started }
      let host = UIHostingController(rootView: sharedView(mode, session: session))
      let window = try mount(host)
      defer { unmount(window) }
      let media = try await mountedMedia(in: host.view)
      XCTAssertFalse(session.hasCurrentItem)
      XCTAssertFalse(session.isPlayerReady)
      XCTAssertTrue(session.thumbnailImage === poster)
      try await assertColor(.red, in: media, name: "\(mode.rawValue)-held-validation-default-red")
      validationGate.release()
      try await poll("validated source ready without Play") { session.isPlayerReady }
      try await assertColor(.red, in: media, name: "\(mode.rawValue)-validated-ready-before-play-red")
      session.togglePlayback()
      try await waitForGreen(in: media, name: "\(mode.rawValue)-default-poster-to-real-green")
      XCTAssertTrue(session.isPlayerReady)
      XCTAssertTrue(media.playerLayer.isReadyForDisplay)
      XCTAssertTrue(media.playerLayer.player === session.player)
    }
  }

  func testSharedInlineAndFullscreenAuthoritativeNilSuppressesSessionThumbnail() async throws {
    let asset = try await greenVideo()
    for mode in Presentation.allCases {
      let obsoletePoster = image(.red)
      let gate = PosterHandoffAssetGate(asset: asset)
      let validationGate = PosterHandoffAssetGate(asset: asset)
      let session = PlaybackSession()
      defer { gate.release(); validationGate.release(); session.cleanup() }
      let source = PlaybackSource(identity: UUID(), load: { PlaybackLoadedMedia(asset: try await gate.load()) }, thumbnail: { _ in obsoletePoster })
      session.load(source: source, playbackRate: 1, isLooping: false, autoplayWhenReady: false)
      try await poll("initial source acquisition started") { gate.started }
      gate.release()
      try await poll("obsolete session thumbnail available after acquisition") {
        session.thumbnailImage === obsoletePoster && session.isPlayerReady
      }
      session.revalidateAccess(source: source, refreshID: 1) { .validate { PlaybackLoadedMedia(asset: try await validationGate.load()) } }
      try await poll("access validation held with obsolete session thumbnail") { validationGate.started }
      let host = UIHostingController(rootView: sharedView(mode, session: session))
      let window = try mount(host)
      defer { unmount(window) }
      let oldMedia = try await mountedMedia(in: host.view)
      XCTAssertFalse(session.hasCurrentItem)
      XCTAssertFalse(session.isPlayerReady)
      try await assertColor(.red, in: oldMedia, name: "\(mode.rawValue)-calibrate-obsolete-session-red")
      host.rootView = sharedView(mode, session: session, provider: { nil })
      let media = try await mountedMedia(in: host.view)
      media.backgroundColor = .blue
      try await assertColor(.black, in: media, name: "\(mode.rawValue)-authoritative-nil-neutral-black-before-play")
      XCTAssertTrue(session.thumbnailImage === obsoletePoster, "The obsolete thumbnail still exists in the session")
      validationGate.release()
      try await poll("authoritative nil source ready without user Play") {
        session.isPlayerReady && media.playerLayer.isReadyForDisplay
      }
      try await assertColor(.black, in: media, name: "\(mode.rawValue)-authoritative-nil-native-ready-still-black")
      XCTAssertFalse(session.hasPresentedVideo)
      session.togglePlayback()
      try await waitForGreen(in: media, name: "\(mode.rawValue)-authoritative-nil-real-green", allowing: [.black, .green])
    }
  }

  func testSharedViewsTransferSamePlayerToFullscreenAndBack() async throws {
    let asset = try await greenVideo()
    let poster = image(.red)
    let gate = PosterHandoffAssetGate(asset: asset)
    let session = PlaybackSession()
    defer { gate.release(); session.cleanup() }
    session.load(source: PlaybackSource(identity: UUID(), load: { PlaybackLoadedMedia(asset: try await gate.load()) }),
      playbackRate: 1, isLooping: false, autoplayWhenReady: false)
    try await poll("held shared source") { gate.started }
    let host = UIHostingController(rootView: sharedView(.inline, session: session, provider: { poster }))
    let window = try mount(host)
    defer { unmount(window) }
    let inline = try await mountedMedia(in: host.view)
    try await assertColor(.red, in: inline, name: "shared-inline-current-provider-red-while-preparing")
    gate.release()
    session.togglePlayback()
    try await waitForGreen(in: inline, name: "shared-inline-before-transfer-green")
    session.pausePlayback()
    XCTAssertTrue(session.hasPresentedVideo)
    let item = try XCTUnwrap(session.player.currentItem)
    host.rootView = sharedView(.fullscreen, session: session, provider: { poster })
    let fullscreen = try await mountedMedia(in: host.view)
    XCTAssertFalse(fullscreen === inline, "Fullscreen owns a newly mounted native layer")
    try await waitForGreen(in: fullscreen, name: "shared-new-fullscreen-handoff", allowing: [.green])
    XCTAssertNil(inline.playerLayer.player, "SwiftUI dismantle must detach the previous inline layer")
    XCTAssertTrue(fullscreen.playerLayer.player === session.player)
    XCTAssertTrue(session.player.currentItem === item)
    host.rootView = sharedView(.inline, session: session, provider: { poster })
    let returnedInline = try await mountedMedia(in: host.view)
    XCTAssertFalse(returnedInline === inline)
    XCTAssertFalse(returnedInline === fullscreen)
    try await waitForGreen(in: returnedInline, name: "shared-new-return-inline-handoff", allowing: [.green])
    XCTAssertNil(fullscreen.playerLayer.player)
    XCTAssertTrue(returnedInline.playerLayer.player === session.player)
    XCTAssertTrue(session.player.currentItem === item)
  }

  func testSharedProviderRefreshUsesCurrentPosterWhileAcquisitionIsHeld() async throws {
    let asset = try await greenVideo()
    for mode in Presentation.allCases {
      let obsoletePoster = image(.red)
      let currentPoster = image(.blue)
      let gate = PosterHandoffAssetGate(asset: asset)
      let session = PlaybackSession()
      var sourceThumbnailRequests = 0
      defer { gate.release(); session.cleanup() }
      session.load(source: PlaybackSource(identity: UUID(), load: { PlaybackLoadedMedia(asset: try await gate.load()) },
        thumbnail: { _ in sourceThumbnailRequests += 1; return obsoletePoster }),
        playbackRate: 1, isLooping: false, autoplayWhenReady: false)
      try await poll("held initial source acquisition") { gate.started }
      XCTAssertNil(session.thumbnailImage)
      XCTAssertEqual(sourceThumbnailRequests, 0, "The host provider is independent of source thumbnail acquisition")
      let host = UIHostingController(rootView: sharedView(mode, session: session, provider: { obsoletePoster }))
      let window = try mount(host)
      defer { unmount(window) }
      let media = try await mountedMedia(in: host.view)
      try await assertColor(.red, in: media, name: "\(mode.rawValue)-provider-before-refresh-red")
      host.rootView = sharedView(mode, session: session, provider: { currentPoster })
      try await assertColor(.blue, in: media, name: "\(mode.rawValue)-current-provider-replaces-obsolete-red")
      XCTAssertNil(session.thumbnailImage)
      XCTAssertEqual(sourceThumbnailRequests, 0)
      XCTAssertFalse(session.hasCurrentItem)
      gate.release()
      try await poll("current provider's source ready before Play") { session.isPlayerReady }
      try await assertColor(.blue, in: media, name: "\(mode.rawValue)-current-provider-ready-before-play-blue")
      session.togglePlayback()
      try await waitForGreen(in: media, name: "\(mode.rawValue)-current-provider-to-real-green", allowing: [.blue, .green])
      try await poll("obsolete source thumbnail delivered after acquisition") { session.thumbnailImage === obsoletePoster }
    }
  }

  func testAspectFillOversizedPosterKeepsOutsideFixtureBlueWhileHostNotReady() async throws {
    let asset = try await greenVideo()
    let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
    let view = NativeView()
    let controller = UIViewController()
    let window = try mount(controller)
    defer { view.detach(); unmount(window) }
    place(view, in: controller.view)
    // Transparent siblings sample actual pixels outside the media; they cannot hide a leaking poster.
    let outsideRects = [
      CGRect(x: view.frame.minX - 24, y: view.frame.midY - 8, width: 16, height: 16),
      CGRect(x: view.frame.maxX + 8, y: view.frame.midY - 8, width: 16, height: 16),
      CGRect(x: view.frame.midX - 8, y: view.frame.minY - 24, width: 16, height: 16),
      CGRect(x: view.frame.midX - 8, y: view.frame.maxY + 8, width: 16, height: 16)
    ]
    let outside = outsideRects.map { rect in
      let probe = UIView(frame: rect)
      probe.backgroundColor = .clear
      controller.view.addSubview(probe)
      XCTAssertTrue(controller.view.bounds.contains(rect), "Outside samples must remain on screen")
      XCTAssertFalse(view.frame.intersects(rect), "Outside samples must exclude the media bounds")
      return probe
    }
    for (ratio, size) in [
      ("wide", CGSize(width: 600, height: 60)),
      ("tall", CGSize(width: 60, height: 600))
    ] {
      let poster = UIGraphicsImageRenderer(size: size).image { context in
        UIColor.red.setFill()
        context.fill(CGRect(origin: .zero, size: size))
      }
      view.configure(player: player, videoGravity: .resizeAspectFill,
        placeholderImage: poster, isPlayerReady: false)
      try await poll("aspect-fill native video ready beneath the held poster") { view.playerLayer.isReadyForDisplay }
      XCTAssertEqual(player.currentItem?.status, .readyToPlay)
      try await assertColor(.red, in: view, name: "aspect-fill-\(ratio)-held-red-poster")
      for (edge, probe) in zip(["left", "right", "top", "bottom"], outside) {
        try await assertColor(.blue, in: probe, name: "aspect-fill-\(ratio)-outside-\(edge)-blue")
      }
    }
  }

  func testQueuedBackgroundCurrentItemCallbackCannotOverrideReboundPlayer() async throws {
    let greenAsset = try await greenVideo()
    let redAsset = try await solidVideo(red: 255, green: 0, blue: 0)
    let oldPlayer = AVPlayer(playerItem: AVPlayerItem(asset: greenAsset))
    let view = NativeView()
    let controller = UIViewController()
    let window = try mount(controller)
    defer { view.detach(); unmount(window) }
    place(view, in: controller.view)
    configure(view, player: oldPlayer, poster: image(.red), ready: true)
    try await waitForGreen(in: view, name: "queued-rebind-original-real-green")

    let currentPlayer = AVPlayer(playerItem: AVPlayerItem(asset: redAsset))
    let currentPoster = image(.blue)
    // This call blocks MainActor until the background setter and native KVO have returned.
    // Do not await between this call and rebind: the component's old Task must still be queued.
    try replaceCurrentItemOnBackgroundWhileMainActorIsBlocked(
      oldPlayer, with: AVPlayerItem(asset: greenAsset))
    configure(view, player: currentPlayer, poster: currentPoster, ready: false)
    try await poll("rebound native red layer ready under the held blue poster") { view.playerLayer.isReadyForDisplay }
    try await assertColor(.blue, in: view, name: "queued-old-callback-rebound-held-blue")
    XCTAssertTrue(view.playerLayer.player === currentPlayer)
    XCTAssertEqual(currentPlayer.currentItem?.status, .readyToPlay)
    configure(view, player: currentPlayer, poster: currentPoster, ready: true)
    try await waitForRedVideo(in: view, name: "queued-rebind-current-real-red-rejects-old-green")
  }

  func testMountedViewReleaseCalibrationWithoutQueuedBackgroundKVO() async throws {
    let asset = try await greenVideo()
    let controller = UIViewController()
    let window = try mount(controller)
    defer { unmount(window) }
    let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
    var mounted: NativeView? = NativeView()
    weak var releasedView = mounted
    do {
      let view = try XCTUnwrap(mounted)
      place(view, in: controller.view)
      configure(view, player: player, poster: image(.red), ready: true)
      try await waitForGreen(in: view, name: "release-control-real-green-without-background-kvo")
      view.detach()
      view.removeFromSuperview()
    }
    mounted = nil
    let attachment = XCTAttachment(string: "No background item replacement: alive before render tick=\(releasedView != nil)")
    attachment.name = "mounted-release-control-before-render-tick"
    attachment.lifetime = .keepAlways
    add(attachment)
    print("POSTER_RELEASE_CONTROL aliveBeforeRenderTick=\(releasedView != nil)")
    try await nextRenderFrame()
    XCTAssertNil(releasedView, "The control must release after the native render transaction settles")
    player.replaceCurrentItem(with: nil)
  }

  func testQueuedBackgroundCurrentItemCallbackDoesNotRetainDetachedOrDismantledView() async throws {
    let asset = try await greenVideo()
    let controller = UIViewController()
    let window = try mount(controller)
    defer { unmount(window) }
    for teardown in ["detach", "dismantle"] {
      let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
      var mounted: NativeView? = NativeView()
      defer { mounted?.detach(); mounted?.removeFromSuperview() }
      weak var releasedView = mounted
      do {
        let view = try XCTUnwrap(mounted)
        place(view, in: controller.view)
        configure(view, player: player, poster: image(.red), ready: true)
        try await waitForGreen(in: view, name: "queued-\(teardown)-original-real-green")
        try replaceCurrentItemOnBackgroundWhileMainActorIsBlocked(
          player, with: AVPlayerItem(asset: asset))
        // Teardown and release both happen before any queued MainActor callback can run.
        if teardown == "detach" {
          view.detach()
        } else {
          InlineVideoPlayerLayer.dismantleUIView(view, coordinator: ())
        }
        XCTAssertNil(view.playerLayer.player)
        view.removeFromSuperview()
      }
      mounted = nil
      // The no-background-KVO control also retains a mounted view until this render tick.
      // Immediate weak ownership is covered separately without UIKit's mounted transaction.
      try await nextRenderFrame()
      XCTAssertNil(releasedView, "\(teardown): obsolete KVO must not restore or retain the dismantled view")
      player.replaceCurrentItem(with: nil)
    }
  }

  func testQueuedBackgroundKVOHoldsAnUnmountedViewWeaklyBeforeMainActorCanRun() async throws {
    let asset = try await greenVideo()
    for teardown in ["detach", "dismantle"] {
      let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
      weak var releasedView: NativeView?
      try autoreleasepool {
        var view: NativeView? = NativeView()
        releasedView = view
        let native = try XCTUnwrap(view)
        configure(native, player: player, poster: image(.red), ready: false)
        try replaceCurrentItemOnBackgroundWhileMainActorIsBlocked(
          player, with: AVPlayerItem(asset: asset))
        if teardown == "detach" {
          native.detach()
        } else {
          InlineVideoPlayerLayer.dismantleUIView(native, coordinator: ())
        }
        XCTAssertNil(native.playerLayer.player)
        view = nil
      }
      // There was no await or run-loop pumping after queuing the old native callback.
      XCTAssertNil(releasedView, "\(teardown): queued delivery must not strongly own the unmounted view")
      try await nextRenderFrame()
      XCTAssertNil(releasedView, "\(teardown): obsolete callbacks must not recreate or retain the released view")
      player.replaceCurrentItem(with: nil)
    }
  }

  func testDirectSamePlayerItemReplacementKeepsBluePosterUntilRealRedVideo() async throws {
    let greenAsset = try await greenVideo()
    let redAsset = try await solidVideo(red: 255, green: 0, blue: 0)
    let firstItem = AVPlayerItem(asset: greenAsset)
    let secondItem = AVPlayerItem(asset: redAsset)
    let player = AVPlayer(playerItem: firstItem)
    let view = NativeView()
    let controller = UIViewController()
    let window = try mount(controller)
    defer { view.detach(); unmount(window) }
    place(view, in: controller.view)
    configure(view, player: player, poster: image(.red), ready: true)
    try await waitForGreen(in: view, name: "direct-replacement-A-real-green")
    let poster = image(.blue)
    configure(view, player: player, poster: poster, ready: false)
    let evidence = PosterHandoffBackgroundItemReplacement(player: player, item: secondItem)
    let observation = player.observe(\.currentItem, options: [.new]) { @Sendable player, _ in
      evidence.recordCallback(from: player)
    }
    defer { observation.invalidate() }
    player.replaceCurrentItem(with: secondItem)
    XCTAssertTrue(player.currentItem === secondItem)
    XCTAssertTrue(view.playerLayer.player === player, "Direct replacement must keep the same player attached")
    let facts = evidence.snapshot()
    XCTAssertGreaterThan(facts.callbackCount, 0, "Direct A-to-B replacement must emit native currentItem KVO")
    XCTAssertTrue(facts.sawExpectedItem)
    XCTAssertFalse(facts.sawNilItem, "Direct replacement has no intermediate nil item")
    try await assertColor(.blue, in: view, name: "direct-replacement-B-held-blue-rejects-old-green")
    try await poll("direct replacement B native readiness") {
      secondItem.status == .readyToPlay && view.playerLayer.isReadyForDisplay
    }
    try await assertColor(.blue, in: view, name: "direct-replacement-B-native-ready-still-held-blue")
    configure(view, player: player, poster: poster, ready: true)
    try await waitForRedVideo(in: view, name: "direct-replacement-B-real-red-rejects-old-green")
    XCTAssertTrue(player.currentItem === secondItem)
    XCTAssertTrue(view.playerLayer.isReadyForDisplay)
  }

  private func replaceCurrentItemOnBackgroundWhileMainActorIsBlocked(
    _ player: AVPlayer, with item: AVPlayerItem
  ) throws {
    XCTAssertTrue(Thread.isMainThread, "This bounded barrier must occupy the MainActor's main thread")
    let evidence = PosterHandoffBackgroundItemReplacement(player: player, item: item)
    let observation = player.observe(\.currentItem, options: [.new]) { @Sendable player, _ in
      evidence.recordCallback(from: player)
    }
    defer { observation.invalidate() }
    DispatchQueue.global(qos: .userInitiated).async {
      autoreleasepool { evidence.replace() }
      // Drain bridge temporaries before unblocking MainActor; only its queued Task remains.
      evidence.setterReturned.signal()
    }
    // No run-loop pumping or actor suspension: the component's off-main KVO Task cannot execute yet.
    let result = evidence.setterReturned.wait(timeout: .now() + 2)
    XCTAssertEqual(result, .success, "Background currentItem setter must return while MainActor remains blocked")
    guard result == .success else { throw FixtureError.timeout("background currentItem setter") }
    let facts = evidence.snapshot()
    let attachment = XCTAttachment(string: "setterReturned=true; setterOffMain=\(facts.setterWasOffMain); "
      + "callbackCount=\(facts.callbackCount); callbacksOffMain=\(facts.allCallbacksOffMain); "
      + "sawExpectedItem=\(facts.sawExpectedItem); sawNilItem=\(facts.sawNilItem)")
    attachment.name = "background-current-item-kvo-before-main-actor-yield"
    attachment.lifetime = .keepAlways
    add(attachment)
    XCTAssertTrue(facts.setterWasOffMain)
    XCTAssertGreaterThan(facts.callbackCount, 0, "Independent native KVO must actually fire before rebind/teardown")
    XCTAssertTrue(facts.allCallbacksOffMain, "The test must exercise queued delivery, not inline main-thread KVO")
    XCTAssertTrue(facts.sawExpectedItem)
    XCTAssertFalse(facts.sawNilItem)
    guard facts.setterWasOffMain, facts.callbackCount > 0, facts.allCallbacksOffMain,
      facts.sawExpectedItem, !facts.sawNilItem else {
      throw FixtureError.timeout("off-main native currentItem KVO evidence")
    }
  }

  private func waitForRedVideo(in view: UIView, name: String) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(8))
    var previous: PixelColor?
    while clock.now < deadline {
      try await nextRenderFrame()
      let frame = try await screenFrame(in: view, stage: name)
      if frame.color != previous || frame.color == .red {
        retain(frame, name: "\(name)-\(frame.color.rawValue)")
      }
      XCTAssertTrue(frame.color == .blue || frame.color == .red,
        "\(name) must show the current blue poster or real red video; old green/black is forbidden: \(frame.description)")
      guard frame.color == .blue || frame.color == .red else { throw FixtureError.timeout(name) }
      if frame.color == .red { return }
      previous = frame.color
    }
    XCTFail("\(name) never displayed real red video; remaining on the blue poster is not success")
    throw FixtureError.timeout(name)
  }

  private func sharedView(
    _ mode: Presentation, session: PlaybackSession,
    provider: (@MainActor () -> UIImage?)? = nil, sourceIdentity: AnyHashable? = nil
  ) -> AnyView {
    switch mode {
    case .inline:
      AnyView(InlinePlaybackView(playbackSession: session, topTrailingAccessory: { EmptyView() },
        placeholderImage: provider, sourceIdentity: sourceIdentity, statusOverlay: { EmptyView() })
        .frame(maxWidth: .infinity, maxHeight: .infinity).id(mode.rawValue))
    case .fullscreen:
      AnyView(FullscreenPlaybackView(playbackSession: session, onClose: {}, placeholderImage: provider,
        sourceIdentity: sourceIdentity, trailingAccessory: { EmptyView() }, statusOverlay: { EmptyView() })
        .environment(\.scenePhase, .active).id(mode.rawValue))
    }
  }

  private func configure(_ view: NativeView, player: AVPlayer?, poster: UIImage?, ready: Bool) {
    view.configure(player: player, videoGravity: .resizeAspect, placeholderImage: poster, isPlayerReady: ready)
  }

  private func image(_ color: UIColor) -> UIImage {
    UIGraphicsImageRenderer(size: CGSize(width: 160, height: 120)).image { context in
      color.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 160, height: 120))
    }
  }

  private func mount(_ controller: UIViewController) throws -> UIWindow {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
      .first { $0.activationState == .foregroundActive }, "A visible host app scene is required for screen capture")
    previousKeyWindow = scene.windows.first { $0.isKeyWindow }
    let window = UIWindow(windowScene: scene)
    window.frame = scene.coordinateSpace.bounds
    window.windowLevel = .alert + 1
    window.rootViewController = controller
    window.makeKeyAndVisible()
    controller.view.frame = window.bounds
    controller.view.layoutIfNeeded()
    XCTAssertFalse(window.isHidden)
    XCTAssertTrue(window.isKeyWindow)
    return window
  }

  private func unmount(_ window: UIWindow) {
    window.isHidden = true
    window.rootViewController = nil
    previousKeyWindow?.makeKey()
    previousKeyWindow = nil
  }

  private func place(_ view: UIView, in root: UIView) {
    root.backgroundColor = .blue
    let width = min(CGFloat(320), root.bounds.width - 64)
    let height = width * 0.75
    view.frame = CGRect(x: (root.bounds.width - width) / 2,
      y: (root.bounds.height - height) / 2, width: width, height: height)
    root.addSubview(view)
    view.layoutIfNeeded()
  }

  private func mountedMedia(in root: UIView) async throws -> NativeView {
    try await poll("mounted shared native media view") {
      root.layoutIfNeeded()
      return self.findMedia(in: root) != nil
    }
    try await nextRenderFrame()
    return try XCTUnwrap(findMedia(in: root))
  }

  private func findMedia(in view: UIView) -> NativeView? {
    if let media = view as? NativeView { return media }
    for child in view.subviews {
      if let media = findMedia(in: child) { return media }
    }
    return nil
  }

  private func assertColor(_ color: PixelColor, in view: UIView, name: String) async throws {
    try await nextRenderFrame()
    let frame = try await screenFrame(in: view, stage: name)
    retain(frame, name: name)
    XCTAssertEqual(frame.color, color, "\(name): \(frame.description)")
    guard frame.color == color else { throw FixtureError.timeout(name) }
  }

  private func waitForGreen(
    in view: UIView, name: String, allowing: Set<PixelColor> = [.red, .green]
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(8))
    var previous: PixelColor?
    while clock.now < deadline {
      try await nextRenderFrame()
      let frame = try await screenFrame(in: view, stage: name)
      if frame.color != previous || frame.color == .green {
        retain(frame, name: "\(name)-\(frame.color.rawValue)")
      }
      XCTAssertTrue(allowing.contains(frame.color),
        "\(name) leaked a non-poster/non-video frame: \(frame.description)")
      guard allowing.contains(frame.color) else { throw FixtureError.timeout(name) }
      if frame.color == .green { return }
      previous = frame.color
    }
    XCTFail("\(name) never displayed real green video; a poster or black frame is not success")
    throw FixtureError.timeout(name)
  }

  private func screenFrame(in view: UIView, stage: String) async throws -> ScreenFrame {
    view.layoutIfNeeded()
    let window = try XCTUnwrap(view.window)
    XCTAssertFalse(window.isHidden)
    XCTAssertTrue(window.screen === UIScreen.main, "External capture must sample this Simulator's main screen")
    // The center avoids letterboxing, rounded corners, and playback/chrome controls.
    let mediaRect = view.bounds.insetBy(dx: view.bounds.width * 0.4, dy: view.bounds.height * 0.4)
    let windowRect = view.convert(mediaRect, to: window)
    let screenRect = window.convert(windowRect, to: window.screen.coordinateSpace)
    let screenBounds = window.screen.coordinateSpace.bounds
    let (screenshot, captureEvidence) = try await externalScreenCapture(
      in: view, roi: screenRect, screenBounds: screenBounds, stage: stage)
    let format = UIGraphicsImageRendererFormat()
    format.scale = screenshot.scale
    format.opaque = true
    let normalized = UIGraphicsImageRenderer(size: screenshot.size, format: format).image { _ in
      screenshot.draw(in: CGRect(origin: .zero, size: screenshot.size))
    }
    let cgImage = try XCTUnwrap(normalized.cgImage)
    XCTAssertEqual(normalized.size.width / normalized.size.height,
      screenBounds.width / screenBounds.height, accuracy: 0.01, "Capture orientation must match screen coordinates")
    let scaleX = CGFloat(cgImage.width) / screenBounds.width
    let scaleY = CGFloat(cgImage.height) / screenBounds.height
    let pixelsRect = CGRect(x: (screenRect.minX - screenBounds.minX) * scaleX,
      y: (screenRect.minY - screenBounds.minY) * scaleY,
      width: screenRect.width * scaleX, height: screenRect.height * scaleY).integral
    XCTAssertGreaterThan(pixelsRect.width, 4)
    XCTAssertGreaterThan(pixelsRect.height, 4)
    XCTAssertTrue(CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height).contains(pixelsRect),
      "The media sampling region must be on screen: \(pixelsRect)")
    let crop = try XCTUnwrap(cgImage.cropping(to: pixelsRect))
    let context = try XCTUnwrap(CGContext(data: nil, width: 12, height: 12,
      bitsPerComponent: 8, bytesPerRow: 48, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(crop, in: CGRect(x: 0, y: 0, width: 12, height: 12))
    let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
    var red = 0, green = 0, blue = 0, black = 0
    for pixel in 0..<144 {
      let r = bytes[pixel * 4], g = bytes[pixel * 4 + 1], b = bytes[pixel * 4 + 2]
      if r > 200 && g < 70 && b < 70 { red += 1 }
      if g > 170 && r < 80 && b < 80 { green += 1 }
      if b > 200 && r < 70 && g < 70 { blue += 1 }
      if r < 35 && g < 35 && b < 35 { black += 1 }
    }
    let color: PixelColor = red >= 137 ? .red : green >= 137 ? .green : blue >= 137 ? .blue : black >= 137 ? .black : .other
    return ScreenFrame(image: normalized, color: color,
      description: "ROI=\(screenRect); red=\(red)/144 green=\(green)/144 blue=\(blue)/144 black=\(black)/144\n\(captureEvidence)")
  }

  private func nativeFacts(in view: UIView) -> NativeFacts {
    let layer = (view.layer as? AVPlayerLayer)
      ?? view.layer.sublayers?.compactMap { $0 as? AVPlayerLayer }.first
    let itemStatus: String
    switch layer?.player?.currentItem?.status {
    case .readyToPlay?: itemStatus = "readyToPlay"
    case .failed?: itemStatus = "failed"
    case .unknown?: itemStatus = "unknown"
    default: itemStatus = "noItem"
    }
    return NativeFacts(hasPlayer: layer?.player != nil, hasCurrentItem: layer?.player?.currentItem != nil,
      itemStatus: itemStatus, isReadyForDisplay: layer?.isReadyForDisplay ?? false)
  }

  private func externalScreenCapture(
    in view: UIView, roi: CGRect, screenBounds: CGRect, stage: String
  ) async throws -> (UIImage, String) {
    let environment = ProcessInfo.processInfo.environment
    guard let path = environment["VIDEO_COMPONENTS_CAPTURE_DIRECTORY"], path.hasPrefix("/") else {
      throw CaptureError("External screen capture is required. Start Scripts/capture-player-screen.py and pass "
        + "TEST_RUNNER_VIDEO_COMPONENTS_CAPTURE_DIRECTORY to the consumer test run; no screenshot fallback or skip is allowed.")
    }
    guard let simulatorUDID = environment["SIMULATOR_UDID"] else {
      throw CaptureError("External screen capture requires an explicit Simulator UDID in the test host environment.")
    }
    let directory = URL(fileURLWithPath: path, isDirectory: true)
    let decoder = JSONDecoder()
    let driverURL = directory.appendingPathComponent("driver.json")
    guard FileManager.default.fileExists(atPath: driverURL.path) else {
      throw CaptureError("Capture driver is not ready at \(path); stage=\(stage)")
    }
    let driver = try decoder.decode(CaptureDriver.self, from: Data(contentsOf: driverURL))
    guard driver.protocolVersion == 1, driver.simulatorUDID == simulatorUDID, driver.state == "ready" else {
      throw CaptureError("Capture driver mismatch/unavailable: state=\(driver.state), UDID=\(driver.simulatorUDID), "
        + "failure=\(driver.failure ?? "none"); stage=\(stage)")
    }
    let token = UUID().uuidString
    let createdAt = Date().timeIntervalSince1970
    let request = CaptureRequest(token: token, runToken: driver.runToken, simulatorUDID: simulatorUDID,
      processID: ProcessInfo.processInfo.processIdentifier, test: name, stage: stage,
      createdAt: createdAt, expiresAt: createdAt + 20, mediaROI: CaptureRect(roi),
      screenBounds: CaptureRect(screenBounds), nativeFacts: nativeFacts(in: view))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let requestData = try encoder.encode(request)
    try requestData.write(to: directory.appendingPathComponent(token + ".request.json"), options: .atomic)
    let responseURL = directory.appendingPathComponent(token + ".response.json")
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(20))
    while clock.now < deadline {
      try Task.checkCancellation()
      if FileManager.default.fileExists(atPath: responseURL.path) {
        let responseData = try Data(contentsOf: responseURL)
        let response = try decoder.decode(CaptureResponse.self, from: responseData)
        guard response.protocolVersion == 1, response.token == token, response.runToken == driver.runToken,
          response.simulatorUDID == simulatorUDID else {
          throw CaptureError("Rejected stale/mismatched capture response; token=\(token), stage=\(stage)")
        }
        guard response.success else {
          // Preserve the driver's original error, including simctl timeout/exit evidence.
          throw CaptureError("Capture failed: \(response.failure ?? "unspecified driver error"); token=\(token), stage=\(stage)")
        }
        guard response.png == token + ".png", let startedAt = response.captureStartedAt,
          startedAt >= request.createdAt else {
          throw CaptureError("Rejected non-current capture PNG; token=\(token), stage=\(stage)")
        }
        let pngData = try Data(contentsOf: directory.appendingPathComponent(token + ".png"))
        guard pngData.count == response.byteCount, pngData.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
          let screenshot = UIImage(data: pngData) else {
          throw CaptureError("Capture response has an invalid PNG; token=\(token), stage=\(stage)")
        }
        let after = try encoder.encode(nativeFacts(in: view))
        return (screenshot, "request=\(String(decoding: requestData, as: UTF8.self))\n"
          + "response=\(String(decoding: responseData, as: UTF8.self))\n"
          + "nativeFactsAfterCapture=\(String(decoding: after, as: UTF8.self))")
      }
      let currentDriver = try decoder.decode(CaptureDriver.self, from: Data(contentsOf: driverURL))
      guard currentDriver.runToken == driver.runToken, currentDriver.state == "ready" else {
        throw CaptureError("Capture driver stopped: \(currentDriver.failure ?? currentDriver.state); token=\(token), stage=\(stage)")
      }
      // This bounds a test-only external operation; it never changes product loading/transport timing.
      try await Task.sleep(for: .milliseconds(10))
    }
    throw CaptureError("Timed out after 20 seconds waiting for external capture; token=\(token), stage=\(stage). "
      + "Request/native facts and any capture output are retained in \(path).")
  }

  private func retain(_ frame: ScreenFrame, name: String) {
    let screenshot = XCTAttachment(image: frame.image)
    screenshot.name = name
    screenshot.lifetime = .keepAlways
    add(screenshot)
    let sample = XCTAttachment(string: frame.description)
    sample.name = name + "-media-sample"
    sample.lifetime = .keepAlways
    add(sample)
  }

  private func poll(_ name: String, until condition: @MainActor () -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(8))
    while clock.now < deadline {
      try Task.checkCancellation()
      if condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Timed out waiting for \(name)")
    throw FixtureError.timeout(name)
  }

  private func nextRenderFrame() async throws {
    CATransaction.flush()
    try await PosterHandoffDisplayTick().wait()
  }

  private func greenVideo() async throws -> AVURLAsset {
    try await solidVideo(red: 0, green: 255, blue: 0)
  }

  private func solidVideo(
    red: UInt8, green: UInt8, blue: UInt8, alternatingGreenBrightness: Bool = false
  ) async throws -> AVURLAsset {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("poster-handoff-\(UUID()).mov")
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    var completed = false
    defer { if !completed { writer.cancelWriting() } }
    let width = 160, height = 120, frameCount = 60
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height
    ])
    XCTAssertTrue(writer.canAdd(input))
    writer.add(input)
    guard writer.startWriting() else { throw writer.error ?? FixtureError.writerFailed }
    writer.startSession(atSourceTime: .zero)
    for frame in 0..<frameCount {
      try await poll("solid-color fixture writer input") { input.isReadyForMoreMediaData || writer.status != .writing }
      guard writer.status == .writing else { throw writer.error ?? FixtureError.writerFailed }
      var buffer: CVPixelBuffer?
      XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &buffer),
        kCVReturnSuccess)
      let pixel = try XCTUnwrap(buffer)
      XCTAssertEqual(CVPixelBufferLockBaseAddress(pixel, []), kCVReturnSuccess)
      let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixel)).assumingMemoryBound(to: UInt8.self)
      let stride = CVPixelBufferGetBytesPerRow(pixel)
      // Input 190 measured G223 in saved screenshots; 250 clipped to G255. Use a lower
      // 160 tier and the measured 190 tier, each lasting half a second across looping.
      let frameGreen: UInt8 = alternatingGreenBrightness ? (frame / 15 % 2 == 0 ? 160 : 190) : green
      for y in 0..<height {
        for x in 0..<width {
          let offset = y * stride + x * 4
          bytes[offset] = blue; bytes[offset + 1] = frameGreen; bytes[offset + 2] = red; bytes[offset + 3] = 255
        }
      }
      XCTAssertEqual(CVPixelBufferUnlockBaseAddress(pixel, []), kCVReturnSuccess)
      guard adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else {
        throw writer.error ?? FixtureError.writerFailed
      }
    }
    writer.endSession(atSourceTime: CMTime(value: Int64(frameCount), timescale: 30))
    input.markAsFinished()
    await writer.finishWriting()
    XCTAssertEqual(writer.status, .completed)
    guard writer.status == .completed else { throw writer.error ?? FixtureError.writerFailed }
    completed = true
    return AVURLAsset(url: url)
  }
}

/// Feeds only production session readiness while keeping the raw layer's player bound through nil-item reset.
@MainActor
private struct PosterHandoffRawSessionView: View {
  @ObservedObject var session: PlaybackSession
  let identity: AnyHashable
  let poster: UIImage?

  var body: some View {
    InlineVideoPlayerLayer(player: session.player, placeholderImage: poster,
      isPlayerReady: session.isPlayerReady, sourceIdentity: identity)
      .frame(width: 320, height: 240)
      .background(.blue)
  }
}

/// Passive native facts only. Existing protocol-v1 simctl captures remain the pixel oracle;
/// wall/monotonic timestamps and screen-point ROI also align the main agent's continuous movie.
@MainActor
private final class PosterHandoffReplacementTrace: NSObject {
  private let media: InlineVideoPlayerLayer.PlayerLayerView
  private let poster: UIImageView
  private let session: PlaybackSession
  private let identity: AnyHashable
  private let test: String
  private var displayLink: CADisplayLink?
  private var observations: [NSKeyValueObservation] = []
  private var isRunning = false
  private var isReplacing = false
  private var phase = "initial-handoff-calibration"
  private(set) var lines: [String] = []
  private(set) var sawInitialPosterHide = false
  private(set) var posterResurfaced = false
  private(set) var replacementDisplayTicks = 0
  private(set) var replacementItemIDs: [String] = []

  init(media: InlineVideoPlayerLayer.PlayerLayerView, poster: UIImageView,
    session: PlaybackSession, identity: AnyHashable, test: String) {
    self.media = media; self.poster = poster; self.session = session; self.identity = identity; self.test = test
    super.init()
  }

  func start() {
    isRunning = true
    observations = [
      poster.observe(\.isHidden, options: [.new]) { [weak self] _, change in
        Self.deliver(to: self, event: "poster-hidden-kvo", changedHidden: change.newValue)
      },
      media.playerLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] _, change in
        Self.deliver(to: self, event: "display-ready-kvo", changedReady: change.newValue)
      },
      session.player.observe(\.currentItem, options: [.new]) { [weak self] _, change in
        let item = change.newValue ?? nil
        Self.deliver(to: self, event: "current-item-kvo",
          changedItemID: item.map { String(describing: ObjectIdentifier($0)) } ?? "nil")
      }
    ]
    let link = CADisplayLink(target: self, selector: #selector(tick))
    displayLink = link
    link.add(to: .main, forMode: .common)
    record("trace-start")
  }

  func beginReplacement(after color: String = "green") {
    isReplacing = true
    mark("replaceAsset-begin-after-compositor-" + color)
  }

  func mark(_ phase: String) {
    self.phase = phase
    record("phase")
  }

  func stop() {
    record("trace-stop")
    isRunning = false
    displayLink?.invalidate()
    displayLink = nil
    observations.forEach { $0.invalidate() }
    observations.removeAll()
  }

  @objc private func tick(_ link: CADisplayLink) {
    if isReplacing { replacementDisplayTicks += 1 }
    record("display-link", displayTimestamp: link.timestamp)
  }

  private nonisolated static func deliver(to trace: PosterHandoffReplacementTrace?, event: String,
    changedHidden: Bool? = nil, changedReady: Bool? = nil, changedItemID: String? = nil) {
    let callbackTime = Date().timeIntervalSince1970
    let callbackOnMain = Thread.isMainThread
    if callbackOnMain {
      MainActor.assumeIsolated {
        trace?.record(event, changedHidden: changedHidden, changedReady: changedReady,
          changedItemID: changedItemID, callbackTime: callbackTime, callbackOnMain: callbackOnMain)
      }
    } else {
      Task { @MainActor [weak trace] in
        trace?.record(event, changedHidden: changedHidden, changedReady: changedReady,
          changedItemID: changedItemID, callbackTime: callbackTime, callbackOnMain: callbackOnMain)
      }
    }
  }

  private func record(_ event: String, changedHidden: Bool? = nil, changedReady: Bool? = nil,
    changedItemID: String? = nil, callbackTime: Double? = nil, callbackOnMain: Bool? = nil,
    displayTimestamp: Double? = nil) {
    guard isRunning else { return }
    if !isReplacing && event == "poster-hidden-kvo" && changedHidden == true { sawInitialPosterHide = true }
    let attached = poster.window != nil && poster.superview === media
    let presentation = poster.layer.presentation()
    let visible = attached && !poster.isHidden && poster.alpha > 0
    let presented = attached && presentation?.isHidden == false && (presentation?.opacity ?? 0) > 0
    if isReplacing {
      // KVO catches a cover that returns and disappears entirely between display ticks/captures.
      posterResurfaced = posterResurfaced || visible || (attached && changedHidden == false)
      if let changedItemID { replacementItemIDs.append(changedItemID) }
    }
    let player = session.player
    let item = player.currentItem
    let seconds = player.currentTime().seconds
    var facts: [String: Any] = [
      "test": test, "sequence": lines.count, "event": event, "phase": phase,
      "wallTime": Date().timeIntervalSince1970, "monotonicTime": CACurrentMediaTime(),
      "sourceIdentity": String(describing: identity), "sourceIsCurrent": session.isCurrentSource(identity),
      "itemID": item.map { String(describing: ObjectIdentifier($0)) } ?? "nil",
      "itemStatus": item.map { String(describing: $0.status) } ?? "noItem",
      "sessionReady": session.isPlayerReady, "layerReady": media.playerLayer.isReadyForDisplay,
      "posterAttached": attached, "posterHidden": poster.isHidden, "posterVisible": visible,
      "posterPresented": presented, "playbackRequested": session.isPlaybackRequested,
      "playerRate": player.rate, "timeControlStatus": String(describing: player.timeControlStatus)
    ]
    facts["posterPresentationHidden"] = presentation?.isHidden
    facts["posterPresentationOpacity"] = presentation?.opacity
    facts["timeSeconds"] = seconds.isFinite ? seconds : nil
    facts["changedHidden"] = changedHidden
    facts["changedReady"] = changedReady
    facts["changedItemID"] = changedItemID
    facts["callbackWallTime"] = callbackTime
    facts["callbackOnMain"] = callbackOnMain
    facts["displayTimestamp"] = displayTimestamp
    if let window = media.window {
      let roi = media.bounds.insetBy(dx: media.bounds.width * 0.4, dy: media.bounds.height * 0.4)
      let screenROI = window.convert(media.convert(roi, to: window), to: window.screen.coordinateSpace)
      func rect(_ value: CGRect) -> [String: Double] {
        ["x": Double(value.minX), "y": Double(value.minY), "width": Double(value.width), "height": Double(value.height)]
      }
      facts["mediaROI"] = rect(screenROI)
      facts["screenBounds"] = rect(window.screen.coordinateSpace.bounds)
    }
    do {
      let data = try JSONSerialization.data(withJSONObject: facts, options: [.sortedKeys])
      lines.append(String(decoding: data, as: UTF8.self))
    } catch { XCTFail("Cannot encode continuous native replacement evidence: \(error)") }
  }
}

/// Only this test fixture crosses threads; its mutable evidence is protected by the lock.
private final class PosterHandoffBackgroundItemReplacement: @unchecked Sendable {
  struct Facts {
    var setterWasOffMain = false
    var callbackCount = 0
    var allCallbacksOffMain = true
    var sawExpectedItem = false
    var sawNilItem = false
  }
  let setterReturned = DispatchSemaphore(value: 0)
  private let player: AVPlayer
  private let item: AVPlayerItem
  private let lock = NSLock()
  private var facts = Facts()

  init(player: AVPlayer, item: AVPlayerItem) { self.player = player; self.item = item }

  func replace() {
    lock.lock()
    facts.setterWasOffMain = !Thread.isMainThread
    lock.unlock()
    player.replaceCurrentItem(with: item)
  }

  func recordCallback(from observedPlayer: AVPlayer) {
    let currentItem = observedPlayer.currentItem
    lock.lock()
    defer { lock.unlock() }
    facts.callbackCount += 1
    facts.allCallbacksOffMain = facts.allCallbacksOffMain && !Thread.isMainThread
    facts.sawExpectedItem = facts.sawExpectedItem || currentItem === item
    facts.sawNilItem = facts.sawNilItem || currentItem == nil
  }

  func snapshot() -> Facts {
    lock.lock()
    defer { lock.unlock() }
    return facts
  }
}

@MainActor
private final class PosterHandoffAssetGate {
  private let asset: AVAsset
  private var continuation: CheckedContinuation<Void, Never>?
  private var isReleased = false
  private(set) var started = false

  init(asset: AVAsset) { self.asset = asset }

  func load() async throws -> AVAsset {
    started = true
    if !isReleased { await withCheckedContinuation { continuation = $0 } }
    try Task.checkCancellation()
    return asset
  }

  func release() {
    isReleased = true
    continuation?.resume()
    continuation = nil
  }
}

@MainActor
private final class PosterHandoffDisplayTick: NSObject {
  private var continuation: CheckedContinuation<Void, any Error>?
  private var displayLink: CADisplayLink?
  private enum TickError: Error { case timeout }

  func wait() async throws {
    try await withCheckedThrowingContinuation { continuation in
      self.continuation = continuation
      let link = CADisplayLink(target: self, selector: #selector(tick))
      displayLink = link
      link.add(to: .main, forMode: .common)
      DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
        self?.finish(.failure(TickError.timeout))
      }
    }
  }

  @objc private func tick() { finish(.success(())) }

  private func finish(_ result: Result<Void, any Error>) {
    displayLink?.invalidate()
    displayLink = nil
    continuation?.resume(with: result)
    continuation = nil
  }
}

extension VideoPlaybackRuntimeResourcesTests {
  func testHighQualityLabelsResolveFromThePlaybackPackage() {
    for (locale, title, accessibility) in [
      ("en", "HQ", "High-quality playback"),
      ("es", "HD", "Reproducción de alta calidad"),
      ("ja", "高画質", "高画質で再生"),
      ("ko", "고화질", "고화질 재생"),
      ("zh-Hans", "高清", "高清播放"),
      ("zh-Hant", "高畫質", "高畫質播放")
    ] {
      let labels = VideoPlaybackLabels(locale: Locale(identifier: locale))
      XCTAssertEqual(labels.highQuality, title)
      XCTAssertEqual(labels.highQualityAccessibility, accessibility)
    }
  }
}

extension VideoPlaybackMountedTests {
  func testFullscreenHighQualityAndRateStayAtTopRightBesideTheAccessory() async throws {
    try await requireNativeControlAccessibilityRuntime()
    for (width, typeSize) in [(CGFloat(390), DynamicTypeSize.large), (320, .accessibility3)] {
      let session = try await readySession()
      session.updatePlaybackRate(1.5)
      let labels = VideoPlaybackLabels(locale: Locale(identifier: "en"))
      let host = UIHostingController(rootView: FullscreenPlaybackView(
        playbackSession: session, onClose: {}, labels: labels,
        highQualityControl: .available {},
        trailingAccessory: {
          Button {} label: {
            Image(systemName: "square.and.arrow.up").frame(width: 44, height: 44)
          }.accessibilityLabel("Fixture export")
        }, statusOverlay: { EmptyView() }
      ).environment(\.scenePhase, .active).environment(\.dynamicTypeSize, typeSize))
      let window = try mountHighQualityHost(host, size: CGSize(width: width, height: 700))
      defer { window.isHidden = true; window.rootViewController = nil; session.cleanup() }
      try await Task.sleep(for: .milliseconds(100))
      let bounds = UIAccessibility.convertToScreenCoordinates(host.view.bounds, in: host.view)
      let elements = fullscreenAccessibilityElements(in: host.view)
      let rate = try XCTUnwrap(elements.first { $0.accessibilityLabel == session.playbackRateIndicatorText })
      let hq = try XCTUnwrap(highQualityButton(in: host.view, label: labels.highQualityAccessibility))
      let accessory = try XCTUnwrap(highQualityButton(in: host.view, label: "Fixture export"))
      let close = try XCTUnwrap(highQualityButton(in: host.view, label: labels.close))
      let play = try XCTUnwrap(highQualityButton(in: host.view, label: labels.play))
      for element in [rate, hq, accessory] {
        XCTAssertTrue(bounds.contains(element.accessibilityFrame), "Top controls must fit at \(width)pt \(typeSize)")
        XCTAssertLessThan(element.accessibilityFrame.maxY, bounds.minY + 100,
          "HQ and rate must stay at the top with the original accessory")
      }
      XCTAssertLessThanOrEqual(rate.accessibilityFrame.height, hq.accessibilityFrame.height + 12,
        "The rate badge must keep its numeric value on one line at large text sizes")
      XCTAssertGreaterThan(rate.accessibilityFrame.minX, close.accessibilityFrame.maxX)
      XCTAssertLessThanOrEqual(rate.accessibilityFrame.maxX, hq.accessibilityFrame.minX)
      XCTAssertLessThanOrEqual(hq.accessibilityFrame.maxX, accessory.accessibilityFrame.minX)
      XCTAssertGreaterThan(hq.accessibilityFrame.midX, bounds.midX)
      XCTAssertGreaterThan(play.accessibilityFrame.minY, bounds.midY, "Play must remain in the bottom console")
      XCTAssertGreaterThanOrEqual(hq.accessibilityFrame.width, 44)
      XCTAssertGreaterThanOrEqual(hq.accessibilityFrame.height, 44)
      let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
        host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
      }
      let attachment = XCTAttachment(image: image)
      attachment.name = "Top right controls \(Int(width))pt \(typeSize)"
      attachment.lifetime = .keepAlways
      add(attachment)
    }
  }

  func testFullscreenHighQualityUsesChromeIdleAndSingleTapVisibility() async throws {
    try await requireNativeControlAccessibilityRuntime()
    let session = try await readySession()
    var requests = 0
    let labels = VideoPlaybackLabels(locale: Locale(identifier: "en"))
    let host = UIHostingController(rootView: FullscreenPlaybackView(
      playbackSession: session, onClose: {}, labels: labels,
      highQualityControl: .available { requests += 1 },
      trailingAccessory: { EmptyView() }, statusOverlay: { EmptyView() }
    ).environment(\.scenePhase, .active))
    let window = try mountHighQualityHost(host, size: CGSize(width: 390, height: 700))
    defer { window.isHidden = true; window.rootViewController = nil; session.cleanup() }
    try await Task.sleep(for: .milliseconds(100))
    let region = try highQualityRegion(in: host.view)
    XCTAssertTrue(hasHighQualityPixels(in: host.view, region: region))
    let button = try XCTUnwrap(highQualityButton(in: host.view, label: labels.highQualityAccessibility))
    XCTAssertTrue(button.accessibilityActivate())
    XCTAssertEqual(requests, 1)
    try await Task.sleep(for: .milliseconds(3_400))
    XCTAssertFalse(hasHighQualityPixels(in: host.view, region: region), "HQ must disappear with the existing chrome timeout")

    let surface = try XCTUnwrap(findGestureSurface(host.view))
    let coordinator = try XCTUnwrap(surface.gestureRecognizers?.first?.delegate as? VideoGestureSurface.Coordinator)
    let tap = MountedTap()
    surface.addGestureRecognizer(tap)
    coordinator.handleSingleTap(tap)
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertTrue(hasHighQualityPixels(in: host.view, region: region))
    let restored = try XCTUnwrap(highQualityButton(in: host.view, label: labels.highQualityAccessibility))
    XCTAssertTrue(restored.accessibilityActivate())
    XCTAssertEqual(requests, 2)
    XCTAssertFalse(session.isPlaybackRequested, "Showing or requesting HQ must not change playback intent")
  }

  func testOptionalFullscreenHighQualityLoadingAndVoiceOverPresentation() async throws {
    try await requireNativeControlAccessibilityRuntime()
    let session = try await readySession()
    defer { session.cleanup() }
    let labels = VideoPlaybackLabels(locale: Locale(identifier: "en"))
    for (control, expectedValue) in [
      (nil, nil),
      (VideoHighQualityControl.loading(nil), ""),
      (VideoHighQualityControl.loading(0.42), 0.42.formatted(.percent.precision(.fractionLength(0))))
    ] as [(VideoHighQualityControl?, String?)] {
      let host = UIHostingController(rootView: FullscreenPlaybackView(
        playbackSession: session, onClose: {}, labels: labels, highQualityControl: control,
        trailingAccessory: { EmptyView() }, statusOverlay: { EmptyView() }
      ).environment(\.scenePhase, .active))
      let window = try mountHighQualityHost(host, size: CGSize(width: 390, height: 700))
      defer { window.isHidden = true; window.rootViewController = nil }
      try await Task.sleep(for: .milliseconds(100))
      guard let expectedValue else {
        XCTAssertNil(highQualityButton(in: host.view, label: labels.highQualityAccessibility))
        XCTAssertNotNil(highQualityButton(in: host.view, label: labels.play))
        continue
      }
      let region = try highQualityRegion(in: host.view)
      let loading = try XCTUnwrap(highQualityButton(in: host.view, label: labels.highQualityAccessibility))
      XCTAssertTrue(loading.accessibilityTraits.contains(.notEnabled))
      XCTAssertEqual(loading.accessibilityValue, expectedValue)
      XCTAssertGreaterThanOrEqual(loading.accessibilityFrame.width, 44)
      XCTAssertGreaterThanOrEqual(loading.accessibilityFrame.height, 44)
      try await Task.sleep(for: .milliseconds(3_400))
      XCTAssertFalse(hasHighQualityPixels(in: host.view, region: region), "Busy HQ follows the existing chrome timeout")
    }
  }

  func testFullscreenHighQualityAndPlaybackControlsHideDuringUnzoomedMultiTouch() async throws {
    try await requireNativeControlAccessibilityRuntime()
    for (width, typeSize) in [(CGFloat(390), DynamicTypeSize.large), (320, .accessibility3)] {
      let session = try await readySession()
      session.updatePlaybackRate(1.5)
      let labels = VideoPlaybackLabels(locale: Locale(identifier: "en"))
      var closes = 0
      var accessoryActivations = 0
      let host = UIHostingController(rootView: FullscreenPlaybackView(
        playbackSession: session, onClose: { closes += 1 }, labels: labels,
        highQualityControl: .available {},
        trailingAccessory: { Button("Fixture accessory") { accessoryActivations += 1 } },
        statusOverlay: { EmptyView() }
      ).environment(\.scenePhase, .active).environment(\.dynamicTypeSize, typeSize))
      let window = try mountHighQualityHost(host, size: CGSize(width: width, height: 700))
      defer { window.isHidden = true; window.rootViewController = nil; session.cleanup() }
      try await Task.sleep(for: .milliseconds(100))
      let region = try highQualityRegion(in: host.view)
      assertFullscreenPlaybackControls(in: host.view, session: session, labels: labels, region: region, visible: true)

      let surface = try XCTUnwrap(findGestureSurface(host.view))
      let coordinator = try XCTUnwrap(surface.gestureRecognizers?.first?.delegate as? VideoGestureSurface.Coordinator)
      // Drive the mounted production gesture callback, without changing the view's private state.
      coordinator.onPinchUpdate(.init(scale: 1, location: CGPoint(x: width / 2, y: 350),
        state: .began, numberOfTouches: 2))
      try await Task.sleep(for: .milliseconds(50))
      assertFullscreenPlaybackControls(in: host.view, session: session, labels: labels, region: region, visible: false)
      let close = try XCTUnwrap(highQualityButton(in: host.view, label: labels.close))
      XCTAssertTrue(close.accessibilityActivate())
      XCTAssertEqual(closes, 1)
      let accessory = try XCTUnwrap(highQualityButton(in: host.view, label: "Fixture accessory"))
      XCTAssertTrue(accessory.accessibilityActivate())
      XCTAssertEqual(accessoryActivations, 1)

      coordinator.onPinchUpdate(.init(scale: 1, location: CGPoint(x: width / 2, y: 350),
        state: .ended, numberOfTouches: 2))
      try await Task.sleep(for: .milliseconds(50))
      assertFullscreenPlaybackControls(in: host.view, session: session, labels: labels, region: region, visible: true)
      XCTAssertTrue(session.canUsePlaybackControls)
    }
  }

  func testFullscreenHighQualityAndPlaybackControlsHideWhileZoomedUntilReset() async throws {
    try await requireNativeControlAccessibilityRuntime()
    let session = try await readySession()
    session.updatePlaybackRate(1.5)
    let labels = VideoPlaybackLabels(locale: Locale(identifier: "en"))
    var closes = 0
    let host = UIHostingController(rootView: FullscreenPlaybackView(
      playbackSession: session, onClose: { closes += 1 }, labels: labels,
      highQualityControl: .available {},
      trailingAccessory: { Button("Fixture accessory") {} }, statusOverlay: { EmptyView() }
    ).environment(\.scenePhase, .active))
    let window = try mountHighQualityHost(host, size: CGSize(width: 390, height: 700))
    defer { window.isHidden = true; window.rootViewController = nil; session.cleanup() }
    try await Task.sleep(for: .milliseconds(100))
    let region = try highQualityRegion(in: host.view)
    assertFullscreenPlaybackControls(in: host.view, session: session, labels: labels, region: region, visible: true)
    let surface = try XCTUnwrap(findGestureSurface(host.view))
    let coordinator = try XCTUnwrap(surface.gestureRecognizers?.first?.delegate as? VideoGestureSurface.Coordinator)
    for (state, scale) in [(UIGestureRecognizer.State.began, CGFloat(1)), (.changed, 2), (.ended, 2)] {
      coordinator.onPinchUpdate(.init(scale: scale, location: CGPoint(x: 195, y: 350),
        state: state, numberOfTouches: 2))
    }
    try await Task.sleep(for: .milliseconds(50))
    assertFullscreenPlaybackControls(in: host.view, session: session, labels: labels, region: region, visible: false)
    let close = try XCTUnwrap(highQualityButton(in: host.view, label: labels.close))
    XCTAssertTrue(close.accessibilityActivate())
    XCTAssertEqual(closes, 1)
    XCTAssertNotNil(highQualityButton(in: host.view, label: "Fixture accessory"))
    let reset = try XCTUnwrap(highQualityButton(in: host.view, label: labels.resetZoom))
    XCTAssertTrue(reset.accessibilityActivate())
    try await Task.sleep(for: .milliseconds(50))
    assertFullscreenPlaybackControls(in: host.view, session: session, labels: labels, region: region, visible: true)
    XCTAssertNil(highQualityButton(in: host.view, label: labels.resetZoom))
    XCTAssertTrue(session.canUsePlaybackControls)
  }

  func testFullscreenHighQualityCannotAppearWithoutThePlaybackControls() async throws {
    try await requireNativeControlAccessibilityRuntime()
    let session = PlaybackSession()
    session.updatePlaybackRate(1.5)
    defer { session.cleanup() }
    let labels = VideoPlaybackLabels(locale: Locale(identifier: "en"))
    XCTAssertFalse(session.hasCurrentItem)
    XCTAssertFalse(session.canTogglePlayback)
    for control in [VideoHighQualityControl.available {}, .loading(nil), .loading(0.42)] {
      var closes = 0
      let host = UIHostingController(rootView: FullscreenPlaybackView(
        playbackSession: session, onClose: { closes += 1 }, labels: labels, highQualityControl: control,
        trailingAccessory: { Button("Fixture accessory") {} }, statusOverlay: { EmptyView() }
      ).environment(\.scenePhase, .active))
      let window = try mountHighQualityHost(host, size: CGSize(width: 390, height: 700))
      defer { window.isHidden = true; window.rootViewController = nil }
      try await Task.sleep(for: .milliseconds(100))
      assertFullscreenPlaybackControls(in: host.view, session: session, labels: labels, region: nil, visible: false)
      let close = try XCTUnwrap(highQualityButton(in: host.view, label: labels.close))
      XCTAssertTrue(close.accessibilityActivate())
      XCTAssertEqual(closes, 1)
      XCTAssertNotNil(highQualityButton(in: host.view, label: "Fixture accessory"))
    }
  }

  func testRenderedFullscreenControlsHideDuringUnzoomedMultiTouch() async throws {
    for (width, typeSize) in [(CGFloat(390), DynamicTypeSize.large), (320, .accessibility3)] {
      let session = try await readySession()
      session.updatePlaybackRate(1.5)
      let host = UIHostingController(rootView: FullscreenPlaybackView(
        playbackSession: session, onClose: {},
        highQualityControl: .available {},
        trailingAccessory: { EmptyView() }, statusOverlay: { EmptyView() }
      ).environment(\.scenePhase, .active).environment(\.dynamicTypeSize, typeSize))
      let window = try mountHighQualityHost(host, size: CGSize(width: width, height: 700))
      defer { window.isHidden = true; window.rootViewController = nil; session.cleanup() }
      try await Task.sleep(for: .milliseconds(100))
      assertRenderedFullscreenControls(in: host.view, visible: true, name: "\(width)pt controls before multitouch")
      let surface = try XCTUnwrap(findGestureSurface(host.view))
      let coordinator = try XCTUnwrap(surface.gestureRecognizers?.first?.delegate as? VideoGestureSurface.Coordinator)
      coordinator.onPinchUpdate(.init(scale: 1, location: CGPoint(x: width / 2, y: 350),
        state: .began, numberOfTouches: 2))
      try await Task.sleep(for: .milliseconds(50))
      assertRenderedFullscreenControls(in: host.view, visible: false, name: "\(width)pt unzoomed multitouch")
      coordinator.onPinchUpdate(.init(scale: 1, location: CGPoint(x: width / 2, y: 350),
        state: .ended, numberOfTouches: 2))
      try await Task.sleep(for: .milliseconds(50))
      assertRenderedFullscreenControls(in: host.view, visible: true, name: "\(width)pt controls after multitouch")
      XCTAssertFalse(session.isPlaybackRequested)
    }
  }

  func testRenderedFullscreenControlsStayHiddenWhileZoomed() async throws {
    let session = try await readySession()
    session.updatePlaybackRate(1.5)
    let host = UIHostingController(rootView: FullscreenPlaybackView(
      playbackSession: session, onClose: {}, highQualityControl: .available {},
      trailingAccessory: { EmptyView() }, statusOverlay: { EmptyView() }
    ).environment(\.scenePhase, .active))
    let window = try mountHighQualityHost(host, size: CGSize(width: 390, height: 700))
    defer { window.isHidden = true; window.rootViewController = nil; session.cleanup() }
    try await Task.sleep(for: .milliseconds(100))
    assertRenderedFullscreenControls(in: host.view, visible: true, name: "Controls before zoom")
    let surface = try XCTUnwrap(findGestureSurface(host.view))
    let coordinator = try XCTUnwrap(surface.gestureRecognizers?.first?.delegate as? VideoGestureSurface.Coordinator)
    for (state, scale) in [(UIGestureRecognizer.State.began, CGFloat(1)), (.changed, 2), (.ended, 2)] {
      coordinator.onPinchUpdate(.init(scale: scale, location: CGPoint(x: 195, y: 350),
        state: state, numberOfTouches: 2))
    }
    try await Task.sleep(for: .milliseconds(50))
    assertRenderedFullscreenControls(in: host.view, visible: false, name: "Zoom ended with playback controls hidden")
    XCTAssertFalse(session.isPlaybackRequested)
  }

  func testRenderedFullscreenCannotShowHQWithoutPlaybackItem() async throws {
    let session = PlaybackSession()
    session.updatePlaybackRate(1.5)
    defer { session.cleanup() }
    XCTAssertFalse(session.hasCurrentItem)
    for (index, control) in [VideoHighQualityControl.available {}, .loading(nil), .loading(0.42)].enumerated() {
      let host = UIHostingController(rootView: FullscreenPlaybackView(
        playbackSession: session, onClose: {}, highQualityControl: control,
        trailingAccessory: { EmptyView() }, statusOverlay: { EmptyView() }
      ).environment(\.scenePhase, .active))
      let window = try mountHighQualityHost(host, size: CGSize(width: 390, height: 700))
      defer { window.isHidden = true; window.rootViewController = nil }
      try await Task.sleep(for: .milliseconds(100))
      assertRenderedFullscreenControls(in: host.view, visible: false, name: "No playback item, HQ presentation \(index)")
    }
  }

  func testRenderedFullscreenHQUsesIdleTimeoutAndSingleTapWithoutPlaying() async throws {
    let session = try await readySession()
    session.updatePlaybackRate(1.5)
    let host = UIHostingController(rootView: FullscreenPlaybackView(
      playbackSession: session, onClose: {}, highQualityControl: .available {},
      trailingAccessory: { EmptyView() }, statusOverlay: { EmptyView() }
    ).environment(\.scenePhase, .active))
    let window = try mountHighQualityHost(host, size: CGSize(width: 390, height: 700))
    defer { window.isHidden = true; window.rootViewController = nil; session.cleanup() }
    try await Task.sleep(for: .milliseconds(100))
    assertRenderedFullscreenControls(in: host.view, visible: true, name: "Paused controls initially visible")
    try await Task.sleep(for: .milliseconds(3_400))
    // Idle hides navigation too, so this image has no white pixels anywhere.
    let hidden = try fullscreenRenderedControlPixelCounts(in: host.view, name: "Paused controls after idle timeout")
    XCTAssertEqual(hidden.playback, 0)
    XCTAssertEqual(hidden.navigation, 0)
    let surface = try XCTUnwrap(findGestureSurface(host.view))
    let coordinator = try XCTUnwrap(surface.gestureRecognizers?.first?.delegate as? VideoGestureSurface.Coordinator)
    let tap = MountedTap()
    surface.addGestureRecognizer(tap)
    coordinator.handleSingleTap(tap)
    try await Task.sleep(for: .milliseconds(50))
    assertRenderedFullscreenControls(in: host.view, visible: true, name: "Single tap restores paused controls")
    XCTAssertFalse(session.isPlaybackRequested)
  }

  private func assertRenderedFullscreenControls(
    in view: UIView, visible: Bool, name: String,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    do {
      let counts = try fullscreenRenderedControlPixelCounts(in: view, name: name)
      XCTAssertGreaterThan(counts.navigation, 0, "Close/reset navigation must stay rendered", file: file, line: line)
      if visible {
        XCTAssertGreaterThan(counts.playback, 50, "The actual playback controls must render", file: file, line: line)
      } else {
        XCTAssertEqual(counts.playback, 0, "No playback control, rate badge or isolated HQ may remain rendered", file: file, line: line)
      }
    } catch {
      XCTFail("The mounted fullscreen image must be readable: \(error)", file: file, line: line)
    }
  }

  private func fullscreenRenderedControlPixelCounts(
    in view: UIView, name: String
  ) throws -> (navigation: Int, playback: Int) {
    // The fixture has black media, no status overlay and no trailing accessory.
    // Exclude only the two navigation targets; detect rate/HQ ink at the top right too.
    view.layoutIfNeeded()
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let image = UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { _ in
      XCTAssertTrue(view.drawHierarchy(in: view.bounds, afterScreenUpdates: true))
    }
    let screenshot = XCTAttachment(image: image)
    screenshot.name = name
    screenshot.lifetime = .keepAlways
    add(screenshot)
    let cgImage = try XCTUnwrap(image.cgImage)
    let context = try XCTUnwrap(CGContext(data: nil, width: cgImage.width, height: cgImage.height,
      bitsPerComponent: 8, bytesPerRow: cgImage.width * 4,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let data = try XCTUnwrap(context.data)
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
    let bytes = data.assumingMemoryBound(to: UInt8.self)
    var navigation = 0
    var playback = 0
    for y in 0..<cgImage.height {
      for x in 0..<cgImage.width {
        let offset = (y * cgImage.width + x) * 4
        guard bytes[offset] > 200 && bytes[offset + 1] > 200 && bytes[offset + 2] > 200 else { continue }
        if x < 112 && y < 120 { navigation += 1 }
        else { playback += 1 }
      }
    }
    let diagnostic = XCTAttachment(string: "Navigation white pixels: \(navigation); playback/HQ white pixels: \(playback)")
    diagnostic.name = "\(name) pixel counts"
    diagnostic.lifetime = .keepAlways
    add(diagnostic)
    return (navigation, playback)
  }

  private func assertFullscreenPlaybackControls(
    in root: UIView, session: PlaybackSession, labels: VideoPlaybackLabels, region: CGRect?, visible: Bool,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    let elements = fullscreenAccessibilityElements(in: root)
    let rate = session.playbackRateIndicatorText
    XCTAssertNotNil(rate, file: file, line: line)
    for label in [labels.play, labels.progress, labels.highQualityAccessibility, rate ?? ""] {
      XCTAssertEqual(elements.contains { $0.accessibilityLabel == label }, visible,
        "The actual fullscreen control \(label) must share the group's visibility", file: file, line: line)
    }
    if let region {
      XCTAssertEqual(hasHighQualityPixels(in: root, region: region), visible,
        "HQ must share both rendered and accessibility visibility", file: file, line: line)
    }
    if visible {
      let bounds = UIAccessibility.convertToScreenCoordinates(root.bounds, in: root)
      for label in [labels.play, labels.progress, labels.highQualityAccessibility] {
        guard let element = elements.first(where: { $0.accessibilityLabel == label }) else { continue }
        let frame = element.accessibilityFrame
        if label == labels.play {
          // Play's natural AX frame describes the SF Symbol, not its 44-point label.
          // Verify the ordinary-touch area with coordinate touches, not this AX metric.
          XCTAssertTrue(element.accessibilityTraits.contains(.button),
            "Play must retain its natural button semantics", file: file, line: line)
          XCTAssertGreaterThan(frame.width, 0, "Play must retain a nonempty AX frame", file: file, line: line)
          XCTAssertGreaterThan(frame.height, 0, "Play must retain a nonempty AX frame", file: file, line: line)
        } else {
          XCTAssertGreaterThanOrEqual(frame.width, 44, "\(label) must retain its action target", file: file, line: line)
          XCTAssertGreaterThanOrEqual(frame.height, 44, "\(label) must retain its action target", file: file, line: line)
        }
        XCTAssertTrue(bounds.contains(frame), "\(label) must fit the mounted window", file: file, line: line)
      }
    }
  }

  private func mountHighQualityHost<V: View>(_ host: UIHostingController<V>, size: CGSize) throws -> UIWindow {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(origin: .zero, size: size)
    window.rootViewController = host
    host.safeAreaRegions = []
    window.makeKeyAndVisible()
    host.view.frame = window.bounds
    host.view.layoutIfNeeded()
    return window
  }

  private func highQualityButton(in root: UIView, label: String) -> NSObject? {
    fullscreenAccessibilityElements(in: root).first {
      $0.accessibilityTraits.contains(.button) && $0.accessibilityLabel == label
    }
  }

  private func fullscreenAccessibilityElements(in root: UIView) -> [NSObject] {
    var visited: Set<ObjectIdentifier> = []
    var elements: [NSObject] = []
    func collect(_ object: NSObject) {
      guard visited.insert(ObjectIdentifier(object)).inserted else { return }
      if object.isAccessibilityElement { elements.append(object) }
      (object.accessibilityElements as? [NSObject] ?? []).forEach(collect)
      (object.automationElements as? [NSObject] ?? []).forEach(collect)
      let count = object.accessibilityElementCount()
      if count > 0 && count < 500 {
        for index in 0..<count {
          if let child = object.accessibilityElement(at: index) as? NSObject { collect(child) }
        }
      }
      if let view = object as? UIView { view.subviews.forEach(collect) }
    }
    if let window = root.window { collect(window) }
    collect(root)
    return elements
  }

  private func highQualityRegion(in view: UIView) throws -> CGRect {
    let labels = VideoPlaybackLabels(locale: Locale(identifier: "en"))
    let button = try XCTUnwrap(highQualityButton(in: view, label: labels.highQualityAccessibility))
    view.layoutIfNeeded()
    let screenBounds = UIAccessibility.convertToScreenCoordinates(view.bounds, in: view)
    let region = button.accessibilityFrame.offsetBy(dx: -screenBounds.minX, dy: -screenBounds.minY)
      .intersection(view.bounds).integral
    guard !region.isNull, !region.isEmpty else {
      XCTFail("The mounted HQ control must have an on-screen frame")
      throw CocoaError(.coderInvalidValue)
    }
    return region
  }

  private func hasHighQualityPixels(in view: UIView, region: CGRect) -> Bool {
    // Keep the visible baseline's region even after AX hides the control.
    view.layoutIfNeeded()
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let image = UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { _ in
      XCTAssertTrue(view.drawHierarchy(in: view.bounds, afterScreenUpdates: true))
    }
    guard let crop = image.cgImage?.cropping(to: region),
      let context = CGContext(data: nil, width: crop.width, height: crop.height,
        bitsPerComponent: 8, bytesPerRow: crop.width * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
      let data = context.data else {
      XCTFail("The fullscreen HQ region must be readable")
      return false
    }
    context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
    let bytes = data.assumingMemoryBound(to: UInt8.self)
    return (0..<(crop.width * crop.height)).contains { pixel in
      let offset = pixel * 4
      return bytes[offset] > 200 && bytes[offset + 1] > 200 && bytes[offset + 2] > 200
    }
  }
}

@MainActor
private func requireNativeControlAccessibilityRuntime() async throws {
  let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
  let previousKeyWindow = scene.keyWindow
  let controller = UIViewController()
  controller.view.backgroundColor = .systemBackground
  let nativeTitle = "UIKit accessibility probe"
  let native = UIButton(type: .system)
  native.setTitle(nativeTitle, for: .normal)
  native.frame = CGRect(x: 40, y: 80, width: 260, height: 44)
  controller.view.addSubview(native)

  let swiftUITitle = "SwiftUI accessibility probe"
  let hosted = UIHostingController(rootView: Button(swiftUITitle) {})
  controller.addChild(hosted)
  controller.view.addSubview(hosted.view)
  hosted.didMove(toParent: controller)
  hosted.view.frame = CGRect(x: 40, y: 180, width: 260, height: 44)

  let window = UIWindow(windowScene: scene)
  window.rootViewController = controller
  window.makeKeyAndVisible()
  defer {
    window.isHidden = true
    window.rootViewController = nil
    previousKeyWindow?.makeKey()
  }
  try await Task.sleep(for: .milliseconds(450))
  controller.view.layoutIfNeeded()
  var visited: Set<ObjectIdentifier> = []
  var nodeDetails: [String] = []
  var swiftUIProvidesSemantics = false
  var hasAnyMetadata = false
  func collect(_ object: NSObject) {
    guard visited.insert(ObjectIdentifier(object)).inserted else { return }
    let automation = object.automationElements as? [NSObject] ?? []
    let assistive = object.accessibilityElements as? [NSObject] ?? []
    let count = object.accessibilityElementCount()
    if object.isAccessibilityElement || object.accessibilityLabel != nil
      || !object.accessibilityTraits.isEmpty || !automation.isEmpty || !assistive.isEmpty || count != 0 {
      hasAnyMetadata = true
    }
    nodeDetails.append("\(type(of: object)): element=\(object.isAccessibilityElement), label=\(object.accessibilityLabel ?? "nil"), automation=\(automation.count), assistive=\(assistive.count), indexed=\(count)")
    if object.isAccessibilityElement, object.accessibilityLabel == swiftUITitle {
      swiftUIProvidesSemantics = true
    }
    automation.forEach(collect)
    assistive.forEach(collect)
    if count > 0 && count < 500 {
      for index in 0..<count {
        if let child = object.accessibilityElement(at: index) as? NSObject { collect(child) }
      }
    }
    if let view = object as? UIView { view.subviews.forEach(collect) }
  }
  collect(window)
  collect(hosted.view)
  let isMounted = window.isKeyWindow && !window.isHidden
    && native.window === window && hosted.view.window === window
  let providesExpectedSemantics = native.isAccessibilityElement
    && native.accessibilityLabel == nativeTitle && swiftUIProvidesSemantics
  if !isMounted || !providesExpectedSemantics {
    XCTContext.runActivity(named: "Independent native-control accessibility preflight") { activity in
      let diagnostic = XCTAttachment(string:
        "No accessibility properties were assigned to either standard control. keyWindow=\(window.isKeyWindow), nativeMounted=\(native.window === window), SwiftUIMounted=\(hosted.view.window === window), nativeTitle=\(native.currentTitle ?? "nil"), nativeTraits=\(native.accessibilityTraits.rawValue), VoiceOver=\(UIAccessibility.isVoiceOverRunning)\n" + nodeDetails.prefix(60).joined(separator: "\n"))
      diagnostic.name = "Independent UIKit and SwiftUI accessibility runtime preflight"
      diagnostic.lifetime = .keepAlways
      activity.add(diagnostic)
      let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
        controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
      }
      let screenshot = XCTAttachment(image: image)
      screenshot.name = "Independent system controls with no product views"
      screenshot.lifetime = .keepAlways
      activity.add(screenshot)
    }
  }
  guard isMounted else {
    XCTFail("The independent native-control accessibility preflight did not mount correctly")
    throw CocoaError(.coderInvalidValue)
  }
  if !hasAnyMetadata {
    throw XCTSkip("The test host's public accessibility runtime is unavailable: independently mounted system UIButton and SwiftUI Button both provide no natural element, label, traits, automation, assistive, or indexed metadata. No product accessibility assertions ran; see the preflight diagnostic.")
  }
  guard providesExpectedSemantics else {
    XCTFail("Independent standard controls returned partial accessibility metadata; this is not the verified wholly unavailable-runtime condition")
    throw CocoaError(.coderInvalidValue)
  }
}

extension VideoPlaybackMountedTests {
  func testFullscreenControlCoordinatesDoNotRouteToPlaybackGestureSurface() async throws {
    for (width, typeSize) in [(CGFloat(390), DynamicTypeSize.large), (320, .accessibility3)] {
      let session = try await readySession()
      session.updatePlaybackRate(1.5)
      let host = UIHostingController(rootView: FullscreenPlaybackView(
        playbackSession: session, onClose: {},
        labels: VideoPlaybackLabels(locale: Locale(identifier: "en")),
        highQualityControl: .available {},
        trailingAccessory: { EmptyView() }, statusOverlay: { EmptyView() }
      ).environment(\.scenePhase, .active).environment(\.dynamicTypeSize, typeSize))
      let window = try mountHighQualityHost(host, size: CGSize(width: width, height: 700))
      defer { window.isHidden = true; window.rootViewController = nil; session.cleanup() }
      try await Task.sleep(for: .milliseconds(100))
      host.view.layoutIfNeeded()

      let surface = try XCTUnwrap(findGestureSurface(host.view))
      let targets = try routingRenderedTargets(in: host.view,
        name: "HQ routing \(Int(width)) \(typeSize)")
      let points: [(String, CGPoint)] = [
        ("HQ glyph center", CGPoint(x: targets.hq.midX, y: targets.hq.midY)),
        ("HQ glyph upper interior", CGPoint(x: targets.hq.midX, y: targets.hq.minY + 0.5)),
        ("play glyph center", CGPoint(x: targets.play.midX, y: targets.play.midY)),
        ("progress rendered track center", CGPoint(x: targets.progress.midX, y: targets.progress.midY))
      ]
      var routes: [String] = []
      for (name, point) in points {
        let windowPoint = host.view.convert(point, to: window)
        let hit = try XCTUnwrap(window.hitTest(windowPoint, with: nil),
          "\(name) must have a natural UIKit hit")
        XCTAssertFalse(hit === surface || hit.isDescendant(of: surface),
          "\(name) must not route to the playback gesture UIView; hit=\(type(of: hit))")
        var path: [String] = []
        var ancestor: UIView? = hit
        while let view = ancestor {
          path.append(String(describing: type(of: view)))
          ancestor = view.superview
        }
        routes.append("\(name): root=\(point), window=\(windowPoint), route=\(path.joined(separator: " -> "))")
      }

      // A positive control rules out an entirely disabled/misidentified surface.
      let videoCenter = CGPoint(x: host.view.bounds.midX, y: host.view.bounds.midY)
      let videoHit = try XCTUnwrap(window.hitTest(host.view.convert(videoCenter, to: window), with: nil))
      XCTAssertTrue(videoHit === surface || videoHit.isDescendant(of: surface),
        "The unobstructed video center must route to the actual playback gesture UIView")
      routes.append("video center: root=\(videoCenter), hit=\(type(of: videoHit))")
      let diagnostic = XCTAttachment(string: routes.joined(separator: "\n"))
      diagnostic.name = "Natural UIKit control routing \(Int(width)) \(typeSize)"
      diagnostic.lifetime = .keepAlways
      add(diagnostic)
    }
  }

  private func routingRenderedTargets(
    in root: UIView, name: String
  ) throws -> (hq: CGRect, play: CGRect, progress: CGRect) {
    // Use the top-right HQ target and the bottom console's fixed padding.
    // Actual HQ/play ink and the progress track are then found in the render.
    // Glyph/track bounds are coordinates, never proof of a 44-point hit target.
    XCTAssertEqual(root.bounds.origin, .zero)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let image = UIGraphicsImageRenderer(size: root.bounds.size, format: format).image { _ in
      XCTAssertTrue(root.drawHierarchy(in: root.bounds, afterScreenUpdates: true))
    }
    let screenshot = XCTAttachment(image: image)
    screenshot.name = name
    screenshot.lifetime = .keepAlways
    add(screenshot)
    let cgImage = try XCTUnwrap(image.cgImage)
    let context = try XCTUnwrap(CGContext(data: nil, width: cgImage.width, height: cgImage.height,
      bitsPerComponent: 8, bytesPerRow: cgImage.width * 4,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let data = try XCTUnwrap(context.data)
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
    let bytes = data.assumingMemoryBound(to: UInt8.self)
    func isNeutralInk(x: Int, y: Int, threshold: Int) -> Bool {
      let offset = (y * cgImage.width + x) * 4
      let red = Int(bytes[offset]), green = Int(bytes[offset + 1]), blue = Int(bytes[offset + 2])
      return red > threshold && abs(red - green) < 8 && abs(red - blue) < 8
    }
    func whiteBounds(in region: CGRect) throws -> CGRect {
      let region = region.intersection(root.bounds).integral
      guard !region.isNull, !region.isEmpty else { throw CocoaError(.coderInvalidValue) }
      var left = cgImage.width, top = cgImage.height, right = -1, bottom = -1
      for y in Int(region.minY)..<Int(region.maxY) {
        for x in Int(region.minX)..<Int(region.maxX) where isNeutralInk(x: x, y: y, threshold: 200) {
          left = min(left, x); right = max(right, x)
          top = min(top, y); bottom = max(bottom, y)
        }
      }
      guard right >= left, bottom >= top else {
        XCTFail("The expected control must have actual rendered glyphs in \(region)")
        throw CocoaError(.coderInvalidValue)
      }
      return CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
    }

    let playY = root.bounds.maxY - 20 - 10 - 44
    let play = try whiteBounds(in: CGRect(x: 28, y: playY, width: 44, height: 44))
    let hq = try whiteBounds(in: CGRect(x: root.bounds.maxX - 56,
      y: 12, width: 44, height: 84))

    // Find the longest continuous neutral run starting beside the play button.
    // This selects the real gray/white progress track, stops at the time-label
    // gap, and tolerates its row moving vertically with Dynamic Type.
    let search = CGRect(x: 84, y: playY, width: root.bounds.width - 112, height: 44)
      .intersection(root.bounds).integral
    var progress: CGRect?
    for y in Int(search.minY)..<Int(search.maxY) {
      let first = (Int(search.minX)..<min(Int(search.minX) + 24, Int(search.maxX)))
        .first { isNeutralInk(x: $0, y: y, threshold: 50) }
      guard let first else { continue }
      var last = first
      while last + 1 < Int(search.maxX), isNeutralInk(x: last + 1, y: y, threshold: 50) { last += 1 }
      let run = CGRect(x: first, y: y, width: last - first + 1, height: 1)
      if run.width > (progress?.width ?? 0) { progress = run }
    }
    return (hq, play, try XCTUnwrap(progress, "The actual progress track must be rendered"))
  }
}


extension VideoPlaybackMountedTests {
  func testHighQualityStatesKeepFortyPointVisual() async throws {
    for (typeSize, locale) in [
      (DynamicTypeSize.large, "en"), (.accessibility3, "en"),
      (.accessibility3, "zh-Hant"), (.accessibility3, "ja"), (.accessibility3, "ko"),
      (.accessibility5, "zh-Hant"), (.accessibility5, "ja"), (.accessibility5, "ko")
    ] {
      let labels = VideoPlaybackLabels(locale: Locale(identifier: locale))
      for (name, control) in [
        ("available", VideoHighQualityControl.available {}),
        ("loading", .loading(nil)), ("progress", .loading(0.42))
      ] {
        let host = UIHostingController(rootView: ZStack {
          Color.white.ignoresSafeArea()
          VideoHighQualityButton(control: control, labels: labels)
        }.environment(\.dynamicTypeSize, typeSize))
        let window = try mountHighQualityHost(host, size: CGSize(width: 100, height: 100))
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(100))
        let ink = try XCTUnwrap(renderedPixels(in: host.view, matching: { $0 < 240 && $1 < 240 && $2 < 240 }))
        XCTAssertEqual(ink.width, 40, accuracy: 1, "\(name) \(locale) \(typeSize)")
        XCTAssertEqual(ink.height, 40, accuracy: 1, "\(name) \(locale) \(typeSize)")
        XCTAssertEqual(ink.midX, 50, accuracy: 1)
        XCTAssertEqual(ink.midY, 50, accuracy: 1)
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
          XCTAssertTrue(host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true))
        }
        let screenshot = XCTAttachment(image: image)
        screenshot.name = "HQ shell \(name) \(locale) \(typeSize)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
      }
    }
  }

  func testFullscreenHighQualityStatesKeepTheSameTopRightFrame() async throws {
    try await requireNativeControlAccessibilityRuntime()
    for (width, typeSize) in [
      (CGFloat(390), DynamicTypeSize.large), (320, .large), (320, .accessibility3)
    ] {
      let session = try await readySession()
      defer { session.cleanup() }
      session.updatePlaybackRate(1.5)
      let labels = VideoPlaybackLabels(locale: Locale(identifier: "en"))
      var baseline: CGRect?
      for (name, control) in [
        ("available", VideoHighQualityControl.available {}),
        ("loading", .loading(nil)), ("progress", .loading(0.42))
      ] {
        let host = UIHostingController(rootView: FullscreenPlaybackView(
          playbackSession: session, onClose: {}, labels: labels, highQualityControl: control,
          trailingAccessory: {
            Button {} label: {
              Image(systemName: "square.and.arrow.down")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(.black.opacity(0.62), in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Fixture export")
          }, statusOverlay: { EmptyView() }
        ).environment(\.scenePhase, .active).environment(\.dynamicTypeSize, typeSize))
        let window = try mountHighQualityHost(host, size: CGSize(width: width, height: 700))
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(100))
        let hq = try XCTUnwrap(highQualityButton(in: host.view, label: labels.highQualityAccessibility))
        let accessory = try XCTUnwrap(highQualityButton(in: host.view, label: "Fixture export"))
        let rate = try XCTUnwrap(fullscreenAccessibilityElements(in: host.view).first {
          $0.accessibilityLabel == session.playbackRateIndicatorText
        })
        let bounds = UIAccessibility.convertToScreenCoordinates(host.view.bounds, in: host.view)
        XCTAssertEqual(hq.accessibilityFrame.width, 44, accuracy: 0.5)
        XCTAssertEqual(hq.accessibilityFrame.height, 44, accuracy: 0.5)
        XCTAssertTrue(bounds.contains(hq.accessibilityFrame))
        XCTAssertLessThan(hq.accessibilityFrame.maxY, bounds.minY + 100)
        XCTAssertLessThanOrEqual(rate.accessibilityFrame.maxX, hq.accessibilityFrame.minX)
        XCTAssertLessThanOrEqual(hq.accessibilityFrame.maxX, accessory.accessibilityFrame.minX)
        if let baseline { XCTAssertEqual(hq.accessibilityFrame, baseline) }
        else { baseline = hq.accessibilityFrame }
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
          XCTAssertTrue(host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true))
        }
        let screenshot = XCTAttachment(image: image)
        screenshot.name = "HQ top right \(name) \(Int(width))pt \(typeSize)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
      }
    }
  }
}
