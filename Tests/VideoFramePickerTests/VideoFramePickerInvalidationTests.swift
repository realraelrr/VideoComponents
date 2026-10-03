import AVFoundation
import CoreGraphics
import Foundation
import XCTest
@testable import VideoFramePicker

@MainActor
final class VideoFramePickerInvalidationTests: XCTestCase {
  func testSynchronousInvalidationWhileSubscribingCancelsReturnedResourceBeforeInspection() async throws {
    let signal = PickerInvalidationProbe()
    signal.invalidateDuringSubscribe = true
    var inspectionCount = 0
    var extractionCount = 0
    let asset = AVComposition()
    let owner = VideoFramePickerOwner(inspectAsset: { _ in
      inspectionCount += 1
      return CMTime(seconds: 2, preferredTimescale: 600)
    }, extractFrame: { _, seconds, _ in
      extractionCount += 1
      return try Self.selection(at: seconds)
    })
    defer { owner.stop() }
    owner.start(source: VideoFramePickerSource(identity: "subscribe-race",
      onInvalidation: signal.subscribe, load: { .init(asset: asset) }),
      initialTime: 0, maximumFrameSize: CGSize(width: 16, height: 16), onFailure: { _ in })
    try await wait { signal.registrations > 0 || owner.preview != nil || owner.failure != nil }

    XCTAssertEqual(signal.registrations, 1)
    XCTAssertEqual(signal.cancellations, 1,
      "A registration returned after synchronous invalidation still belongs to the retired mount")
    XCTAssertEqual(inspectionCount, 0)
    XCTAssertEqual(extractionCount, 0)
    XCTAssertNil(owner.player)
    XCTAssertNil(owner.preview)
    guard case .failed(.source) = owner.sourceStatus else {
      return XCTFail("A synchronously invalidated mount must remain source-failed")
    }
  }

  func testStopSwitchAndReleaseCancelRegistrationAndLateSignalCannotAffectCurrentMount() async throws {
    for end in PickerInvalidationMountEnd.allCases {
      let signal = PickerInvalidationProbe()
      let assetA = AVComposition()
      let assetB = AVComposition()
      var owner: VideoFramePickerOwner? = VideoFramePickerOwner(
        inspectAsset: { _ in CMTime(seconds: 2, preferredTimescale: 600) },
        extractFrame: { _, seconds, _ in try Self.selection(at: seconds) })
      weak var releasedOwner = owner
      defer { owner?.stop() }
      owner?.start(source: VideoFramePickerSource(identity: "A", onInvalidation: signal.subscribe,
        load: { .init(asset: assetA) }), initialTime: 0,
        maximumFrameSize: CGSize(width: 16, height: 16), onFailure: { _ in })
      try await wait { owner?.preview != nil || owner?.failure != nil }
      XCTAssertNil(owner?.failure)
      XCTAssertEqual(signal.registrations, 1)
      let escapedSelection = try XCTUnwrap(owner?.preview)
      let retiredPlayer = try XCTUnwrap(owner?.player)
      switch end {
      case .stop: owner?.stop()
      case .switchSource:
        owner?.start(source: VideoFramePickerSource(identity: "B", load: { .init(asset: assetB) }),
          initialTime: 0.5, maximumFrameSize: CGSize(width: 16, height: 16), onFailure: { _ in })
        try await wait { owner?.preview != nil || owner?.failure != nil }
      case .release: owner = nil
      }
      XCTAssertEqual(signal.cancellations, 1, "The ended mount releases its exact subscription")
      XCTAssertNil(retiredPlayer.currentItem)
      XCTAssertThrowsError(try escapedSelection.validate()) { XCTAssertTrue($0 is CancellationError) }
      if end == .release { XCTAssertNil(releasedOwner) }
      let currentPlayer = owner?.player
      let currentItem = currentPlayer?.currentItem
      signal.sendLateInvalidations()
      if end == .switchSource {
        XCTAssertTrue(owner?.player === currentPlayer)
        XCTAssertTrue(currentPlayer?.currentItem === currentItem)
        XCTAssertTrue(currentItem?.asset === assetB)
        XCTAssertNil(owner?.failure)
        try XCTUnwrap(owner?.preview).validate()
      } else {
        XCTAssertNil(owner?.player)
        XCTAssertNil(owner?.preview)
      }
      XCTAssertEqual(signal.cancellations, 1)
    }
  }

  private func wait(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<300 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw PickerInvalidationTestError.timeout
  }
  private static func selection(at seconds: Double) throws -> VideoFrameSelection {
    guard let context = CGContext(data: nil, width: 4, height: 4,
      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let image = context.makeImage() else {
      throw PickerInvalidationTestError.fixtureUnavailable
    }
    return VideoFrameSelection(image: image, requestedSeconds: seconds,
      actualTime: CMTime(seconds: seconds, preferredTimescale: 600))
  }
}

private enum PickerInvalidationTestError: Error { case timeout, fixtureUnavailable }
private enum PickerInvalidationMountEnd: CaseIterable { case stop, switchSource, release }

/// Retains callbacks after cancellation to model a previously captured Core notification batch.
@MainActor
private final class PickerInvalidationProbe {
  var invalidateDuringSubscribe = false
  private(set) var registrations = 0
  private(set) var cancellations = 0
  private var callbacks: [@MainActor () -> Void] = []
  func subscribe(_ callback: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
    registrations += 1
    callbacks.append(callback)
    if invalidateDuringSubscribe { callback() }
    var cancelled = false
    return { [weak self] in
      guard !cancelled else { return }
      cancelled = true
      self?.cancellations += 1
    }
  }
  func sendLateInvalidations() { for callback in callbacks { callback() } }
}
