import AVFoundation
import XCTest
@testable import VideoFramePicker

@MainActor
final class VideoFramePickerOwnerTests: XCTestCase {
  func testInitialPreviewNeverConsumesAndPreservesActualFrameTime() async throws {
    let fixture = PickerFixture()
    defer { fixture.stop() }
    try await fixture.ready()
    XCTAssertFalse(fixture.owner.hasPendingSelection)
    XCTAssertFalse(fixture.owner.isSliderDisabled)
    XCTAssertEqual(fixture.owner.selectedSeconds, 1)
    XCTAssertEqual(fixture.owner.preview?.requestedSeconds, 1)
    XCTAssertEqual(fixture.owner.preview?.actualTime.seconds ?? -1, 0.9, accuracy: 0.001)
    XCTAssertTrue(fixture.selections.isEmpty)
    XCTAssertTrue(fixture.owner.player?.isMuted == true)
    XCTAssertEqual(fixture.owner.player?.rate, 0)
  }

  func testScrubbingDoesNotExtractUntilReleaseAndConsumesLatestValueOnce() async throws {
    let fixture = PickerFixture()
    defer { fixture.stop() }
    try await fixture.ready()
    fixture.owner.beginScrubbing()
    for value in [2.0, 3, 4] { fixture.owner.changeSeconds(value, callbacks: fixture.callbacks) }
    await Task.yield()
    XCTAssertEqual(fixture.frames.requests.count, 1)
    XCTAssertTrue(fixture.owner.hasPendingSelection)
    XCTAssertTrue(fixture.owner.isShowingPlayerPreview)
    fixture.owner.endScrubbing(onFailure: fixture.callbacks.onFailure)
    try await waitForPicker { fixture.frames.requests.count == 2 }
    XCTAssertEqual(fixture.frames.requests[1].seconds, 4)
    fixture.frames.succeed(1)
    try await waitForPicker { fixture.selections.count == 1 }
    XCTAssertEqual(fixture.selections[0].requestedSeconds, 4)
    XCTAssertFalse(fixture.owner.hasPendingSelection)
  }

  func testTouchWithoutValueChangeDoesNotConsume() async throws {
    let fixture = PickerFixture()
    defer { fixture.stop() }
    try await fixture.ready()
    fixture.owner.beginScrubbing()
    fixture.owner.changeSeconds(1, callbacks: fixture.callbacks)
    fixture.owner.endScrubbing(onFailure: fixture.callbacks.onFailure)
    try await waitForPicker { fixture.frames.requests.count == 2 }
    fixture.frames.succeed(1)
    try await waitForPicker { !fixture.owner.isShowingPlayerPreview }
    XCTAssertTrue(fixture.selections.isEmpty)
    XCTAssertFalse(fixture.owner.hasPendingSelection)
  }

  func testPendingRetouchWithoutChangeKeepsIntentAndOriginalCallbacks() async throws {
    let fixture = PickerFixture()
    defer { fixture.stop() }
    try await fixture.ready()
    fixture.owner.changeSeconds(4, callbacks: fixture.callbacks)
    try await waitForPicker { fixture.frames.requests.count == 2 }
    fixture.owner.beginScrubbing()
    XCTAssertTrue(fixture.owner.hasPendingSelection)
    fixture.owner.endScrubbing(onFailure: { _ in XCTFail("Retouch must keep the pending handler") })
    XCTAssertTrue(fixture.owner.hasPendingSelection)
    try await waitForPicker { fixture.frames.requests.count == 3 }
    fixture.frames.fail(1)
    await Task.yield()
    XCTAssertTrue(fixture.owner.hasPendingSelection)
    XCTAssertTrue(fixture.failures.isEmpty)
    fixture.frames.succeed(2)
    try await waitForPicker { fixture.selections.count == 1 }
    XCTAssertEqual(fixture.selections.first?.requestedSeconds, 4)
    XCTAssertFalse(fixture.owner.hasPendingSelection)
  }

  func testNonScrubbingValueChangeUsesExactPipeline() async throws {
    let fixture = PickerFixture()
    defer { fixture.stop() }
    try await fixture.ready()
    fixture.owner.changeSeconds(2.5, callbacks: fixture.callbacks)
    XCTAssertTrue(fixture.owner.hasPendingSelection)
    try await waitForPicker { fixture.frames.requests.count == 2 }
    XCTAssertEqual(fixture.frames.requests[1].seconds, 2.5)
    fixture.frames.succeed(1, actualSeconds: 2.4)
    try await waitForPicker { fixture.selections.count == 1 }
    XCTAssertEqual(fixture.selections[0].actualTime.seconds, 2.4, accuracy: 0.001)
  }

  func testNewUserChangeUsesLatestCallbacksWhilePendingRetainsSnapshot() async throws {
    let fixture = PickerFixture()
    defer { fixture.stop() }
    try await fixture.ready()
    let player = fixture.owner.player
    var updatedCalls = 0
    fixture.owner.changeSeconds(2, callbacks: fixture.callbacks)
    try await waitForPicker { fixture.frames.requests.count == 2 }
    fixture.owner.start(
      source: VideoFramePickerSource(identity: "video", load: { XCTFail("Same identity reloaded"); return fixture.asset }),
      initialTime: 8, maximumFrameSize: CGSize(width: 64, height: 64), onFailure: { _ in }
    )
    fixture.frames.succeed(1)
    try await waitForPicker { fixture.selections.count == 1 }
    fixture.owner.changeSeconds(3, callbacks: VideoFramePickerCallbacks(
      onFailure: { _ in }, onSelection: { _ in updatedCalls += 1 }
    ))
    try await waitForPicker { fixture.frames.requests.count == 3 }
    XCTAssertEqual(fixture.frames.requests[2].maximumSize, CGSize(width: 1280, height: 1280))
    fixture.frames.succeed(2)
    try await waitForPicker { updatedCalls == 1 }
    XCTAssertEqual(fixture.selections.count, 1)
    XCTAssertTrue(fixture.owner.player === player)
  }

  func testSameTimeReplacementRejectsLateFrameAndLateFailure() async throws {
    let fixture = PickerFixture()
    defer { fixture.stop() }
    try await fixture.ready()
    fixture.owner.changeSeconds(4, callbacks: fixture.callbacks)
    try await waitForPicker { fixture.frames.requests.count == 2 }
    fixture.owner.beginScrubbing()
    fixture.owner.endScrubbing(onFailure: fixture.callbacks.onFailure)
    try await waitForPicker { fixture.frames.requests.count == 3 }
    fixture.frames.succeed(1, actualSeconds: 3.5)
    await Task.yield()
    XCTAssertEqual(fixture.owner.preview?.actualTime.seconds ?? -1, 0.9, accuracy: 0.001)
    XCTAssertTrue(fixture.selections.isEmpty)
    XCTAssertTrue(fixture.owner.hasPendingSelection)
    fixture.owner.beginScrubbing()
    fixture.owner.endScrubbing(onFailure: fixture.callbacks.onFailure)
    try await waitForPicker { fixture.frames.requests.count == 4 }
    fixture.frames.fail(2)
    await Task.yield()
    XCTAssertTrue(fixture.owner.hasPendingSelection)
    XCTAssertTrue(fixture.failures.isEmpty)
    fixture.frames.succeed(3)
    try await waitForPicker { fixture.selections.count == 1 }
  }

  func testHostAwaitLocksSliderAndFailureKeepsExactPreview() async throws {
    let fixture = PickerFixture()
    let consumer = PickerGate<Void>()
    defer { fixture.stop(); consumer.finish(.success(())) }
    try await fixture.ready()
    var failures: [VideoFramePickerFailure] = []
    fixture.owner.changeSeconds(4, callbacks: VideoFramePickerCallbacks(
      onFailure: { failures.append($0) }, onSelection: { _ in try await consumer.run() }
    ))
    try await waitForPicker { fixture.frames.requests.count == 2 }
    XCTAssertFalse(fixture.owner.isSliderDisabled, "Extraction must allow a new drag")
    fixture.frames.succeed(1)
    try await waitForPicker { consumer.started }
    XCTAssertTrue(fixture.owner.hasPendingSelection)
    XCTAssertTrue(fixture.owner.isProcessingSelection)
    XCTAssertTrue(fixture.owner.isSliderDisabled)
    fixture.owner.changeSeconds(5, callbacks: fixture.callbacks)
    fixture.owner.beginScrubbing()
    XCTAssertEqual(fixture.owner.selectedSeconds, 4)
    XCTAssertFalse(fixture.owner.isScrubbing)
    consumer.finish(.failure(PickerTestError.failed))
    try await waitForPicker { failures.count == 1 }
    guard case .selectionProcessing = failures[0] else { return XCTFail("Wrong failure stage") }
    XCTAssertFalse(fixture.owner.hasPendingSelection)
    XCTAssertFalse(fixture.owner.isSliderDisabled)
    XCTAssertEqual(fixture.owner.preview?.requestedSeconds, 4)
    XCTAssertFalse(fixture.owner.isShowingPlayerPreview)
  }

  func testHostAwaitSuccessEndsActivityOnlyWhenConsumerReturns() async throws {
    let fixture = PickerFixture()
    let consumer = PickerGate<Void>()
    defer { fixture.stop(); consumer.finish(.success(())) }
    try await fixture.ready()
    fixture.owner.changeSeconds(4, callbacks: VideoFramePickerCallbacks(
      onFailure: { _ in XCTFail("Unexpected failure") }, onSelection: { _ in try await consumer.run() }
    ))
    try await waitForPicker { fixture.frames.requests.count == 2 }
    fixture.frames.succeed(1)
    try await waitForPicker { consumer.started }
    XCTAssertTrue(fixture.owner.hasPendingSelection)
    consumer.finish(.success(()))
    try await waitForPicker { !fixture.owner.hasPendingSelection }
    XCTAssertFalse(fixture.owner.isProcessingSelection)
  }

  func testActiveCancellationErrorFromFrameAndConsumerIsFailure() async throws {
    let fixture = PickerFixture()
    defer { fixture.stop() }
    try await fixture.ready()
    fixture.owner.changeSeconds(2, callbacks: fixture.callbacks)
    try await waitForPicker { fixture.frames.requests.count == 2 }
    fixture.frames.fail(1, error: CancellationError())
    try await waitForPicker { fixture.failures.count == 1 }
    guard case .frame(let cause) = fixture.failures[0] else { return XCTFail("Wrong failure stage") }
    XCTAssertTrue(cause is CancellationError)
    XCTAssertFalse(fixture.owner.hasPendingSelection)
    var consumerFailure: VideoFramePickerFailure?
    fixture.owner.changeSeconds(3, callbacks: VideoFramePickerCallbacks(
      onFailure: { consumerFailure = $0 }, onSelection: { _ in throw CancellationError() }
    ))
    try await waitForPicker { fixture.frames.requests.count == 3 }
    fixture.frames.succeed(2)
    try await waitForPicker { consumerFailure != nil }
    guard case .selectionProcessing(let cause) = consumerFailure else {
      return XCTFail("Wrong failure stage")
    }
    XCTAssertTrue(cause is CancellationError)
    XCTAssertFalse(fixture.owner.hasPendingSelection)
  }

  func testSourceAToBToARejectsOriginalLoaderEvenWhenIdentityMatchesAgain() async throws {
    let fixture = PickerFixture()
    let loader = PickerGate<AVAsset>()
    defer { fixture.stop(); loader.finish(.success(fixture.asset)) }
    fixture.owner.start(
      source: VideoFramePickerSource(identity: "A", load: loader.run),
      initialTime: nil, maximumFrameSize: CGSize(width: 1280, height: 1280),
      onFailure: { _ in XCTFail("Original A cannot publish") }
    )
    try await waitForPicker { loader.started }
    fixture.start(identity: "B", initialTime: 2)
    try await waitForPicker { fixture.frames.requests.count == 1 }
    fixture.start(identity: "A", initialTime: 3)
    try await waitForPicker { fixture.frames.requests.count == 2 }
    fixture.frames.succeed(1)
    try await waitForPicker { fixture.owner.preview?.requestedSeconds == 3 }
    let currentPlayer = fixture.owner.player
    loader.finish(.success(fixture.asset))
    fixture.frames.fail(0)
    try await waitForPicker { loader.cancelled }
    await Task.yield()
    XCTAssertTrue(fixture.owner.player === currentPlayer)
    XCTAssertEqual(fixture.owner.preview?.requestedSeconds, 3)
    XCTAssertEqual(fixture.frames.requests.count, 2)
    XCTAssertTrue(fixture.failures.isEmpty)
  }

  func testSourceSwitchDuringConsumerCannotUnlockNewPendingSelection() async throws {
    let fixture = PickerFixture()
    let consumer = PickerGate<Void>()
    defer { fixture.stop(); consumer.finish(.success(())) }
    try await fixture.ready()
    fixture.owner.changeSeconds(2, callbacks: VideoFramePickerCallbacks(
      onFailure: { _ in XCTFail("Old consumer cannot publish") },
      onSelection: { _ in try await consumer.run() }
    ))
    try await waitForPicker { fixture.frames.requests.count == 2 }
    fixture.frames.succeed(1)
    try await waitForPicker { consumer.started }
    fixture.start(identity: "B")
    XCTAssertFalse(fixture.owner.hasPendingSelection)
    try await waitForPicker { fixture.frames.requests.count == 3 }
    fixture.frames.succeed(2)
    try await waitForPicker { fixture.owner.preview != nil }
    fixture.owner.changeSeconds(5, callbacks: fixture.callbacks)
    try await waitForPicker { fixture.frames.requests.count == 4 }
    consumer.finish(.failure(PickerTestError.failed))
    try await waitForPicker { consumer.cancelled }
    XCTAssertTrue(fixture.owner.hasPendingSelection)
    XCTAssertNil(fixture.owner.failure)
    fixture.frames.succeed(3)
    try await waitForPicker { fixture.selections.count == 1 }
  }

  func testStopSynchronouslyDetachesPlayerAndRejectsLateFrame() async throws {
    let fixture = PickerFixture()
    defer { fixture.stop() }
    try await fixture.ready()
    fixture.owner.changeSeconds(4, callbacks: fixture.callbacks)
    try await waitForPicker { fixture.frames.requests.count == 2 }
    let player = fixture.owner.player
    fixture.owner.stop()
    XCTAssertNil(player?.currentItem)
    XCTAssertNil(fixture.owner.player)
    XCTAssertFalse(fixture.owner.hasPendingSelection)
    fixture.frames.succeed(1)
    try await waitForPicker { fixture.frames.requests[1].gate.cancelled }
    XCTAssertNil(fixture.owner.preview)
    XCTAssertTrue(fixture.selections.isEmpty)
    XCTAssertTrue(fixture.failures.isEmpty)
  }
}
