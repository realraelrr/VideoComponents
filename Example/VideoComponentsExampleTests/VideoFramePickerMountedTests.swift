import AVFoundation
import Observation
import SwiftUI
import UIKit
import VideoPlayback
import XCTest
@testable import VideoFramePicker

@MainActor
final class VideoFramePickerMountedTests: XCTestCase {
  func testMountedSliderUsesUpdatedHandlerWithoutReloadingSameIdentity() async throws {
    let model = MountedPickerModel()
    let mounted = mount(model)
    defer { unmount(mounted); model.finish() }
    try await finishInitial(model)
    let player = model.owner.player
    let slider = try XCTUnwrap(findSlider(in: mounted.view))
    setSlider(slider, fraction: 0.3)
    try await waitForPicker { model.frames.requests.count == 2 && model.activity.last == true }
    model.revision = 1
    mounted.view.setNeedsLayout()
    mounted.view.layoutIfNeeded()
    try await Task.sleep(for: .milliseconds(50))
    model.frames.succeed(1)
    try await waitForPicker { model.selections.count == 1 && model.activity.last == false }
    XCTAssertEqual(model.selections[0].revision, 0, "Pending work owns its callback snapshot")
    setSlider(try XCTUnwrap(findSlider(in: mounted.view)), fraction: 0.5)
    try await waitForPicker { model.frames.requests.count == 3 }
    model.frames.succeed(2)
    try await waitForPicker { model.selections.count == 2 && model.activity.last == false }
    XCTAssertEqual(model.selections[1].revision, 1)
    XCTAssertEqual(model.loadCount, 1)
    XCTAssertTrue(model.owner.player === player)
    XCTAssertEqual(model.activity.first, false)
    XCTAssertEqual(model.activity, [false, true, false, true, false])
  }

  func testMountedConsumerKeepsNativeSliderDisabledAndUnmountUnlocksSynchronously() async throws {
    let model = MountedPickerModel()
    let consumer = PickerGate<Void>()
    model.consumer = consumer
    let mounted = mount(model)
    defer { unmount(mounted); model.finish(); consumer.finish(.success(())) }
    try await finishInitial(model)
    setSlider(try XCTUnwrap(findSlider(in: mounted.view)), fraction: 0.4)
    try await waitForPicker { model.frames.requests.count == 2 && model.activity.last == true }
    XCTAssertTrue(try XCTUnwrap(findSlider(in: mounted.view)).isEnabled)
    model.frames.succeed(1)
    try await waitForPicker {
      consumer.started && self.findSlider(in: mounted.view)?.isEnabled == false
    }
    XCTAssertEqual(model.activity.last, true)
    model.isVisible = false
    try await waitForPicker { model.owner.player == nil && model.activity.last == false }
    XCTAssertFalse(model.owner.hasPendingSelection)
    consumer.finish(.failure(PickerTestError.failed))
    try await waitForPicker { consumer.cancelled }
    XCTAssertTrue(model.failures.isEmpty)
  }

  func testAppearanceCycleRestartsStoppedSameIdentityWithoutRebuildingForRedraw() async throws {
    let model = MountedPickerModel()
    let mounted = mount(model)
    let window = try XCTUnwrap(mounted.view.window)
    defer {
      window.rootViewController = mounted
      unmount(mounted)
      model.finish()
    }
    try await finishInitial(model)
    model.revision = 1
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(model.loadCount, 1)
    // Detach the retained host so SwiftUI observes a real disappearance.
    window.rootViewController = UIViewController()
    XCTAssertNil(mounted.view.window)
    do {
      try await waitForPicker { model.owner.player == nil }
    } catch {
      XCTFail("Detached picker did not stop: loads=\(model.loadCount), frames=\(model.frames.requests.count), activity=\(model.activity)")
      throw error
    }
    XCTAssertEqual(model.activity.last, false)
    window.rootViewController = mounted
    mounted.view.layoutIfNeeded()
    XCTAssertTrue(mounted.view.window === window)
    do {
      try await waitForPicker { model.loadCount == 2 && model.frames.requests.count == 2 }
    } catch {
      XCTFail("Reattached picker did not restart once: loads=\(model.loadCount), frames=\(model.frames.requests.count), player=\(model.owner.player != nil), activity=\(model.activity)")
      throw error
    }
    model.frames.succeed(1)
    try await waitForPicker { model.owner.preview != nil }
    XCTAssertFalse(model.owner.hasPendingSelection)
    XCTAssertTrue(model.selections.isEmpty)
  }

  func testSeparateMountedInstancesSettleOnlyTheirOwnActivity() async throws {
    let first = MountedPickerModel()
    let firstHost = mount(first)
    defer { unmount(firstHost); first.finish() }
    try await finishInitial(first)
    setSlider(try XCTUnwrap(findSlider(in: firstHost.view)), fraction: 0.4)
    try await waitForPicker { first.frames.requests.count == 2 && first.activity.last == true }
    first.isVisible = false
    try await waitForPicker { first.activity.last == false && first.owner.player == nil }

    let second = MountedPickerModel()
    let secondHost = mount(second)
    defer { unmount(secondHost); second.finish() }
    try await finishInitial(second)
    XCTAssertEqual(second.activity, [false])
    setSlider(try XCTUnwrap(findSlider(in: secondHost.view)), fraction: 0.6)
    try await waitForPicker { second.frames.requests.count == 2 && second.activity.last == true }
    first.frames.fail(1)
    await Task.yield()
    XCTAssertEqual(first.activity.last, false)
    XCTAssertEqual(second.activity.last, true)
    second.frames.succeed(1)
    try await waitForPicker { second.activity.last == false }
    XCTAssertEqual(first.selections.count, 0)
    XCTAssertEqual(second.selections.count, 1)
  }

  private var windows: [UIWindow] = []

  private func mount(_ model: MountedPickerModel) -> UIHostingController<MountedPickerHost> {
    let host = UIHostingController(rootView: MountedPickerHost(model: model))
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
    window.rootViewController = host
    window.makeKeyAndVisible()
    host.view.layoutIfNeeded()
    windows.append(window)
    return host
  }

  private func unmount(_ host: UIHostingController<MountedPickerHost>) {
    for window in windows where window.rootViewController === host {
      window.isHidden = true
      window.rootViewController = nil
    }
    windows.removeAll { $0.rootViewController == nil }
  }

  private func finishInitial(_ model: MountedPickerModel) async throws {
    try await waitForPicker { model.frames.requests.count == 1 }
    model.frames.succeed(0)
    try await waitForPicker { model.owner.preview != nil && !model.activity.isEmpty }
  }

  private func findSlider(in view: UIView) -> UISlider? {
    if let slider = view as? UISlider { return slider }
    return view.subviews.lazy.compactMap { self.findSlider(in: $0) }.first
  }

  private func setSlider(_ slider: UISlider, fraction: Float) {
    slider.setValue(slider.minimumValue + fraction * (slider.maximumValue - slider.minimumValue), animated: false)
    slider.sendActions(for: .valueChanged)
  }
}

@MainActor
@Observable
private final class MountedPickerModel {
  let frames = PickerFrames()
  let owner: VideoFramePickerOwner
  let asset = AVMutableComposition()
  var revision = 0
  var isVisible = true
  var consumer: PickerGate<Void>?
  var loadCount = 0
  var selections: [(revision: Int, frame: VideoFrameSelection)] = []
  var activity: [Bool] = []
  var failures: [VideoFramePickerFailure] = []

  init() {
    let frames = frames
    owner = VideoFramePickerOwner(
      inspectAsset: { _ in CMTime(seconds: 10, preferredTimescale: 600) },
      extractFrame: frames.extract
    )
  }

  func finish() { owner.stop(); frames.finishOutstanding() }
}

@MainActor
private struct MountedPickerHost: View {
  let model: MountedPickerModel

  var body: some View {
    let revision = model.revision
    if model.isVisible {
      VideoFramePickerView(
        source: VideoFramePickerSource(identity: "mounted") { [weak model] in
          guard let model else { throw CancellationError() }
          model.loadCount += 1
          return model.asset
        },
        onSelectionActivityChanged: { [weak model] in model?.activity.append($0) },
        onFailure: { [weak model] in model?.failures.append($0) },
        onSelection: { [weak model] frame in
          model?.selections.append((revision, frame))
          if let consumer = model?.consumer { try await consumer.run() }
        },
        owner: model.owner
      )
      .padding(20)
    }
  }
}

@MainActor
final class VideoComponentStatusAndLayoutMountedTests: XCTestCase {
  func testSourceFailureStopsPickerLoadingIndicator() async throws {
    let loader = PickerGate<AVAsset>()
    var failures = 0
    let host = UIHostingController(rootView: VideoFramePickerView(
      source: VideoFramePickerSource(identity: "failed-source", load: loader.run),
      onFailure: { _ in failures += 1 }, onSelection: { _ in }
    ))
    let window = mount(host)
    defer { unmount(window); loader.finish(.failure(PickerTestError.failed)) }
    try await waitForPicker { loader.started }
    try await Task.sleep(for: .milliseconds(100))
    host.view.layoutIfNeeded()
    recordPickerState(in: host.view, phase: "Loading baseline", failures: failures)
    XCTAssertTrue(visibleIndicators(in: host.view).contains(where: \.isAnimating),
      "The suspended source must show a visible loading indicator")
    loader.finish(.failure(PickerTestError.failed))
    try await waitForPicker { failures == 1 }
    try await Task.sleep(for: .milliseconds(100))
    host.view.layoutIfNeeded()
    recordPickerState(in: host.view, phase: "Source failed", failures: failures)
    XCTAssertEqual(failures, 1)
    XCTAssertFalse(visibleIndicators(in: host.view).contains(where: \.isAnimating),
      "A terminal source failure has no loading operation to indicate")
  }

  func testSlowPreparingAndBufferingRetainLoadingIndication() async throws {
    for status in [PlaybackStatus.loading, .slowPreparing, .slowBuffering] {
      let host = UIHostingController(rootView: PlaybackStatusOverlay(status: status))
      let window = mount(host)
      defer { unmount(window) }
      try await Task.sleep(for: .milliseconds(100))
      XCTAssertTrue(indicators(in: host.view).contains(where: \.isAnimating),
        "A pending operation must keep its loading indication in \(status)")
    }
  }

  func testUnknownAspectHonorsExplicitMaximumSize() async throws {
    let probe = UIView()
    let host = UIHostingController(rootView:
      AdaptiveVideoCardLayout(contentAspectRatio: nil, maximumSize: CGSize(width: 160, height: 90)) {
        VideoCardSizeProbe(view: probe)
      }.frame(maxWidth: .infinity, maxHeight: .infinity).ignoresSafeArea()
    )
    let window = mount(host)
    defer { unmount(window) }
    try await waitForPicker { probe.bounds.width > 0 && probe.bounds.height > 0 }
    XCTAssertLessThanOrEqual(probe.bounds.width, 160,
      "The explicit width cap still applies while the aspect ratio is unknown")
    XCTAssertLessThanOrEqual(probe.bounds.height, 90,
      "The explicit height cap still applies while the aspect ratio is unknown")
  }

  private func indicators(in view: UIView) -> [UIActivityIndicatorView] {
    let current = (view as? UIActivityIndicatorView).map { [$0] } ?? []
    return current + view.subviews.flatMap { indicators(in: $0) }
  }

  private func visibleIndicators(in root: UIView) -> [UIActivityIndicatorView] {
    indicators(in: root).filter { isVisible($0, in: root) }
  }

  private func isVisible(_ view: UIView, in root: UIView) -> Bool {
    guard view.window != nil, view.window === root.window else { return false }
    var visibleRect = view.convert(view.bounds, to: root).intersection(root.bounds)
    var ancestor: UIView? = view
    while let current = ancestor {
      guard !current.isHidden, current.alpha > 0.01, current.layer.opacity > 0.01,
        !visibleRect.isEmpty else { return false }
      if current.clipsToBounds {
        visibleRect = visibleRect.intersection(current.convert(current.bounds, to: root))
      }
      if current === root { return !visibleRect.isEmpty }
      ancestor = current.superview
    }
    return false
  }

  private func recordPickerState(in view: UIView, phase: String, failures: Int) {
    let states = indicators(in: view).map {
      "animating=\($0.isAnimating), hidden=\($0.isHidden), alpha=\($0.alpha), "
        + "opacity=\($0.layer.opacity), frame=\($0.frame), visible=\(isVisible($0, in: view))"
    }
    print("Picker \(phase): failures=\(failures), indicators=\(states)")
    let screenshot = UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
      view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
    }
    let attachment = XCTAttachment(image: screenshot)
    attachment.name = "Picker \(phase)"
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  private func mount<V: View>(_ host: UIHostingController<V>) -> UIWindow {
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
    window.rootViewController = host
    window.makeKeyAndVisible()
    host.view.frame = window.bounds
    host.view.layoutIfNeeded()
    return window
  }

  private func unmount(_ window: UIWindow) {
    window.isHidden = true
    window.rootViewController = nil
  }
}

@MainActor
private struct VideoCardSizeProbe: UIViewRepresentable {
  let view: UIView
  func makeUIView(context: Context) -> UIView { view }
  func updateUIView(_ uiView: UIView, context: Context) {}
}
