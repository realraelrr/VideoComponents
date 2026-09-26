import AVFoundation
import XCTest
@testable import VideoFramePicker

@MainActor
final class VideoFramePickerLifecycleTests: XCTestCase {
  func testSuspendedLoaderDoesNotRetainOwnerAndReceivesCancellation() async throws {
    let loader = PickerGate<AVAsset>()
    let asset = AVMutableComposition()
    var owner: VideoFramePickerOwner? = VideoFramePickerOwner()
    weak var weakOwner = owner
    defer { loader.finish(.success(asset)) }
    owner?.start(
      source: VideoFramePickerSource(identity: "video", load: loader.run),
      initialTime: nil, maximumFrameSize: CGSize(width: 1280, height: 1280),
      onFailure: { _ in XCTFail("Released owner cannot publish") }
    )
    try await waitForPicker { loader.started }
    owner = nil
    try await waitForPicker { weakOwner == nil && loader.cancelled }
    loader.finish(.success(asset))
    await Task.yield()
    XCTAssertNil(weakOwner)
  }

  func testSuspendedMetadataInspectionDoesNotRetainOwnerOrCancelBorrowedAsset() async throws {
    let metadata = PickerGate<CMTime>()
    let asset = CancellationTrackingAsset()
    var owner: VideoFramePickerOwner? = VideoFramePickerOwner(inspectAsset: { _ in try await metadata.run() })
    weak var weakOwner = owner
    defer { metadata.finish(.success(CMTime(seconds: 10, preferredTimescale: 600))) }
    owner?.start(
      source: VideoFramePickerSource(identity: "video", load: { asset }),
      initialTime: nil, maximumFrameSize: CGSize(width: 1280, height: 1280),
      onFailure: { _ in XCTFail("Released owner cannot publish") }
    )
    try await waitForPicker { metadata.started }
    owner = nil
    try await waitForPicker { weakOwner == nil && metadata.cancelled }
    XCTAssertFalse(asset.wasLoadingCancelled)
  }

  func testSuspendedFrameExtractionDoesNotRetainOwnerAndDetachesItsItem() async throws {
    let frames = PickerFrames()
    let asset = AVMutableComposition()
    var owner: VideoFramePickerOwner? = VideoFramePickerOwner(
      inspectAsset: { _ in CMTime(seconds: 10, preferredTimescale: 600) },
      extractFrame: frames.extract
    )
    weak var weakOwner = owner
    defer { frames.finishOutstanding() }
    owner?.start(
      source: VideoFramePickerSource(identity: "video", load: { asset }),
      initialTime: nil, maximumFrameSize: CGSize(width: 1280, height: 1280),
      onFailure: { _ in XCTFail("Released owner cannot publish") }
    )
    try await waitForPicker { frames.requests.count == 1 }
    let player = try XCTUnwrap(owner?.player)
    owner = nil
    try await waitForPicker { weakOwner == nil && frames.requests[0].gate.cancelled }
    XCTAssertNil(player.currentItem)
    frames.succeed(0)
    await Task.yield()
    XCTAssertNil(weakOwner)
  }

  func testSuspendedConsumerDoesNotRetainOwnerAndReceivesCancellation() async throws {
    let frames = PickerFrames()
    let consumer = PickerGate<Void>()
    let asset = AVMutableComposition()
    var owner: VideoFramePickerOwner? = VideoFramePickerOwner(
      inspectAsset: { _ in CMTime(seconds: 10, preferredTimescale: 600) },
      extractFrame: frames.extract
    )
    weak var weakOwner = owner
    defer { frames.finishOutstanding(); consumer.finish(.success(())) }
    owner?.start(
      source: VideoFramePickerSource(identity: "video", load: { asset }),
      initialTime: nil, maximumFrameSize: CGSize(width: 1280, height: 1280), onFailure: { _ in }
    )
    try await waitForPicker { frames.requests.count == 1 }
    frames.succeed(0)
    try await waitForPicker { owner?.preview != nil }
    owner?.changeSeconds(2, callbacks: VideoFramePickerCallbacks(
      onFailure: { _ in XCTFail("Released owner cannot publish") },
      onSelection: { _ in try await consumer.run() }
    ))
    try await waitForPicker { frames.requests.count == 2 }
    frames.succeed(1)
    try await waitForPicker { consumer.started }
    owner = nil
    try await waitForPicker { weakOwner == nil && consumer.cancelled }
    consumer.finish(.failure(PickerTestError.failed))
    await Task.yield()
    XCTAssertNil(weakOwner)
  }

  func testActiveLoaderCancellationErrorIsSourceFailure() async throws {
    let owner = VideoFramePickerOwner()
    defer { owner.stop() }
    var failure: VideoFramePickerFailure?
    owner.start(
      source: VideoFramePickerSource(identity: "video", load: { throw CancellationError() }),
      initialTime: nil, maximumFrameSize: CGSize(width: 1280, height: 1280),
      onFailure: { failure = $0 }
    )
    try await waitForPicker { failure != nil }
    guard case .source(.unavailable, let cause) = failure else { return XCTFail("Wrong failure") }
    XCTAssertTrue(cause is CancellationError)
    XCTAssertFalse(owner.hasPendingSelection)
    XCTAssertTrue(owner.isSliderDisabled)
  }

  func testStoppedLoaderIgnoresLateErrorWithoutPublishing() async throws {
    let loader = PickerGate<AVAsset>()
    let owner = VideoFramePickerOwner()
    defer { owner.stop(); loader.finish(.failure(PickerTestError.failed)) }
    var failureCount = 0
    owner.start(
      source: VideoFramePickerSource(identity: "video", load: loader.run),
      initialTime: nil, maximumFrameSize: CGSize(width: 1280, height: 1280),
      onFailure: { _ in failureCount += 1 }
    )
    try await waitForPicker { loader.started }
    owner.stop()
    loader.finish(.failure(PickerTestError.failed))
    try await waitForPicker { loader.cancelled }
    await Task.yield()
    XCTAssertEqual(failureCount, 0)
    XCTAssertNil(owner.failure)
  }
}

private final class CancellationTrackingAsset: AVMutableComposition {
  private(set) var wasLoadingCancelled = false

  override func cancelLoading() {
    wasLoadingCancelled = true
    super.cancelLoading()
  }
}
