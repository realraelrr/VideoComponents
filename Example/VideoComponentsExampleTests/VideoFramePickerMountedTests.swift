import AVFoundation
import Observation
import SwiftUI
import UIKit
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
