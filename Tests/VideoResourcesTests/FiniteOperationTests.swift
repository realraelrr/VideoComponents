import AVFoundation
import Foundation
import Observation
import VideoResources
import XCTest

@MainActor
final class FiniteOperationTests: XCTestCase {
  func testSynchronousShareSurvivesImmediateParentCancellation() async throws {
    let probe = FiniteLoaderProbe()
    defer { probe.finishOutstanding() }
    let resources = probe.makeResources()
    let source = resources.photosSource(serializedCloudIdentifier: "submitted")
    let parent = source.prepare()
    await fulfillment(of: [probe.started(0)], timeout: 1)

    let submitted = parent.share()
    parent.cancel()

    await assertNoCancellation(probe, protected: [0])
    let asset = AVMutableComposition()
    probe.finish(0, with: .success(VideoRepresentation(asset: asset)))
    let receipt = try await submitted.value()
    XCTAssertTrue(receipt.asset === asset)
    XCTAssertEqual(probe.invocations.count, 1)
    assertCancelled(await result { try await parent.value() })
  }

  func testLastShareCancellationStopsNativeWorkOnceAndEndsItsWaiters() async {
    let probe = FiniteLoaderProbe()
    defer { probe.finishOutstanding() }
    let source = probe.makeResources().photosSource(serializedCloudIdentifier: "shared")
    let first = source.prepare()
    let second = first.share()
    await fulfillment(of: [probe.started(0)], timeout: 1)
    let entered = expectation(description: "Both share waiters enter")
    entered.expectedFulfillmentCount = 2
    let firstFinished = expectation(description: "First cancelled share exits")
    let secondFinished = expectation(description: "Last cancelled share exits")
    let firstWait = Task { @MainActor in
      entered.fulfill()
      let outcome = await result { try await first.value() }
      firstFinished.fulfill()
      return outcome
    }
    let secondWait = Task { @MainActor in
      entered.fulfill()
      let outcome = await result { try await second.value() }
      secondFinished.fulfill()
      return outcome
    }
    await fulfillment(of: [entered], timeout: 1)

    first.cancel()
    await fulfillment(of: [firstFinished], timeout: 1)
    await assertNoCancellation(probe, protected: [0])
    second.cancel()
    first.cancel()
    second.cancel()
    await fulfillment(of: [probe.cancelled(0), secondFinished], timeout: 1)

    // The loader deliberately stays suspended after cancellation. Finish it only
    // after checking that each public wait has ended independently of native work.
    probe.finish(0, with: .success(VideoRepresentation(asset: AVMutableComposition())))
    assertCancelled(await firstWait.value)
    assertCancelled(await secondWait.value)
    XCTAssertEqual(probe.cancellationIndices, [0])
  }

  func testCancelledHandleAndItsShareStayCancelledAfterSurvivorSucceeds() async throws {
    let probe = FiniteLoaderProbe()
    defer { probe.finishOutstanding() }
    let source = probe.makeResources().photosSource(serializedCloudIdentifier: "cancelled-handle")
    let abandoned = source.prepare()
    let survivor = abandoned.share()
    await fulfillment(of: [probe.started(0)], timeout: 1)
    abandoned.cancel()
    let inheritedCancellation = abandoned.share()
    assertCancelled(await result { try await abandoned.value() })
    assertCancelled(await result { try await inheritedCancellation.value() })

    let asset = AVMutableComposition()
    probe.finish(0, with: .success(VideoRepresentation(asset: asset)))
    let receipt = try await survivor.value()
    XCTAssertTrue(receipt.asset === asset)
    assertCancelled(await result { try await abandoned.value() })
    assertCancelled(await result { try await abandoned.share().value() })
    XCTAssertEqual(probe.invocations.count, 1)
    XCTAssertTrue(probe.cancellationIndices.isEmpty)
  }

  func testCancellingOneValueTaskEndsOnlyThatWaitAndKeepsTheHandleUsable() async throws {
    let probe = FiniteLoaderProbe()
    defer { probe.finishOutstanding() }
    let source = probe.makeResources().photosSource(serializedCloudIdentifier: "two-waits-one-share")
    let handle = source.prepare()
    await fulfillment(of: [probe.started(0)], timeout: 1)
    let entered = expectation(description: "Both value tasks enter")
    entered.expectedFulfillmentCount = 2
    let cancelledWaitFinished = expectation(description: "Cancelled value task exits promptly")
    let cancelledWait = Task { @MainActor in
      entered.fulfill()
      let outcome = await result { try await handle.value() }
      cancelledWaitFinished.fulfill()
      return outcome
    }
    let survivingWait = Task { @MainActor in
      entered.fulfill()
      return await result { try await handle.value() }
    }
    await fulfillment(of: [entered], timeout: 1)

    cancelledWait.cancel()
    await fulfillment(of: [cancelledWaitFinished], timeout: 1)
    await assertNoCancellation(probe, protected: [0])
    let asset = AVMutableComposition()
    probe.finish(0, with: .success(VideoRepresentation(asset: asset)))

    assertCancelled(await cancelledWait.value)
    let survived = try await survivingWait.value.get()
    let repeated = try await handle.value()
    XCTAssertTrue(survived.asset === asset)
    XCTAssertEqual(repeated.representationID, survived.representationID)
    XCTAssertEqual(probe.invocations.count, 1)
  }

  func testValueTaskCancelledDuringSuccessPublicationRejectsTheResumedReceipt() async throws {
    let probe = FiniteLoaderProbe()
    defer { probe.finishOutstanding() }
    let source = probe.makeResources().photosSource(serializedCloudIdentifier: "success-cancel-race")
    let retainedPreparation = source.prepare()
    await fulfillment(of: [probe.started(0)], timeout: 1)
    let entered = expectation(description: "Value task enters the pending operation")
    let finished = expectation(description: "Value task exits after success and cancellation race")
    let waiterTask = Task { @MainActor in
      entered.fulfill()
      let outcome = await result { try await retainedPreparation.value() }
      finished.fulfill()
      return outcome
    }
    await fulfillment(of: [entered], timeout: 1)
    let cancelledDuringPublication = expectation(description: "Terminal state publication cancels the value task")
    withObservationTracking {
      _ = source.state
    } onChange: {
      // The provider never reports progress, so this callback runs synchronously
      // on the MainActor when successful completion publishes terminal state.
      MainActor.assumeIsolated {
        waiterTask.cancel()
        cancelledDuringPublication.fulfill()
      }
    }
    let asset = AVMutableComposition()
    probe.finish(0, with: .success(VideoRepresentation(asset: asset)))
    await fulfillment(of: [cancelledDuringPublication, finished], timeout: 1)

    assertCancelled(await waiterTask.value)
    let independentlyRead = try await retainedPreparation.value()
    XCTAssertTrue(independentlyRead.asset === asset)
    XCTAssertEqual(source.preferred?.representationID, independentlyRead.representationID)
    await assertNoCancellation(probe, protected: [0])
    XCTAssertEqual(probe.invocations.count, 1)
  }

  func testValueTaskCancelledDuringFailurePublicationRejectsTheResumedFailure() async {
    let probe = FiniteLoaderProbe()
    defer { probe.finishOutstanding() }
    let source = probe.makeResources().photosSource(serializedCloudIdentifier: "failure-cancel-race")
    let retainedPreparation = source.prepare()
    await fulfillment(of: [probe.started(0)], timeout: 1)
    let entered = expectation(description: "Value task enters before failed completion")
    let finished = expectation(description: "Value task exits after failure and cancellation race")
    let waiterTask = Task { @MainActor in
      entered.fulfill()
      let outcome = await result { try await retainedPreparation.value() }
      finished.fulfill()
      return outcome
    }
    await fulfillment(of: [entered], timeout: 1)
    let cancelledDuringPublication = expectation(description: "Failed terminal state cancels the value task")
    withObservationTracking {
      _ = source.state
    } onChange: {
      MainActor.assumeIsolated {
        waiterTask.cancel()
        cancelledDuringPublication.fulfill()
      }
    }
    probe.finish(0, with: .failure(VideoResourceFailure.networkRequired))
    await fulfillment(of: [cancelledDuringPublication, finished], timeout: 1)

    assertCancelled(await waiterTask.value)
    for handle in [retainedPreparation, retainedPreparation.share()] {
      switch await result({ try await handle.value() }) {
      case .success: XCTFail("The independent handle must retain the native terminal failure")
      case .failure(let error): XCTAssertEqual(error as? VideoResourceFailure, .networkRequired)
      }
    }
    XCTAssertEqual(source.state, .unavailable(.networkRequired))
    XCTAssertEqual(probe.invocations.count, 1)
  }

  func testAuthorityChangeEndsAllOldRequestsAndLateHQCannotAffectNewAuthority() async throws {
    let probe = FiniteLoaderProbe()
    defer { probe.finishOutstanding() }
    let facts = FiniteAuthorityFacts()
    let resources = probe.makeResources(authority: { _ in facts.revision })
    let source = resources.photosSource(serializedCloudIdentifier: "authority-change")
    let automatic = source.prepare()
    let highQuality = source.prepare(VideoRequest(quality: .highest))
    await fulfillment(of: [probe.started(0), probe.started(1)], timeout: 1)
    let entered = expectation(description: "Both old authority wait tasks enter")
    entered.expectedFulfillmentCount = 2
    let finished = expectation(description: "Both old authority wait tasks end promptly")
    finished.expectedFulfillmentCount = 2
    let automaticWait = Task { @MainActor in
      entered.fulfill()
      let outcome = await result { try await automatic.value() }
      facts.finishedWaits += 1
      finished.fulfill()
      return outcome
    }
    let highQualityWait = Task { @MainActor in
      entered.fulfill()
      let outcome = await result { try await highQuality.value() }
      facts.finishedWaits += 1
      finished.fulfill()
      return outcome
    }
    await fulfillment(of: [entered], timeout: 1)
    let automaticIndex = try XCTUnwrap(probe.invocations.firstIndex { $0.request.quality == .automatic })
    let highQualityIndex = try XCTUnwrap(probe.invocations.firstIndex { $0.request.quality == .highest })

    facts.revision = "B"
    probe.finish(automaticIndex, with: .success(VideoRepresentation(asset: AVMutableComposition())))
    await fulfillment(of: [finished], timeout: 1)
    XCTAssertEqual(facts.finishedWaits, 2, "Both old waits must end before the old HQ loader completes")
    await fulfillment(of: [probe.cancelled(highQualityIndex)], timeout: 1)

    let newAuthority = source.prepare()
    await fulfillment(of: [probe.started(2)], timeout: 1)
    let newAsset = AVMutableComposition()
    // The old HQ loader deliberately ignores cancellation and succeeds after B
    // has started. Its result must not finish, cancel, or replace B's operation.
    if probe.invocations[highQualityIndex].continuation != nil {
      probe.finish(highQualityIndex, with: .success(VideoRepresentation(asset: AVMutableComposition())))
      await fulfillment(of: [probe.returned(highQualityIndex)], timeout: 1)
    }
    if probe.invocations.indices.contains(2) {
      probe.finish(2, with: .success(VideoRepresentation(asset: newAsset)))
    }
    // Cleanup precedes awaiting outcomes so a broken invalidation fails through
    // the bounded expectations above instead of leaving either old wait hung.
    probe.finishOutstanding()

    assertSourceChanged(await automaticWait.value)
    assertSourceChanged(await highQualityWait.value)
    let current = try await newAuthority.value()
    XCTAssertTrue(current.asset === newAsset)
    XCTAssertTrue(current.isCurrent)
    XCTAssertEqual(source.preferred?.representationID, current.representationID)
    XCTAssertEqual(probe.invocations.count, 3)
    XCTAssertEqual(probe.cancellationIndices, [highQualityIndex],
      "Only the still-pending HQ native request needs cancellation")
  }

  func testInvalidationDuringAcquiringPublicationPreventsNativeStartup() async throws {
    let probe = FiniteLoaderProbe()
    defer { probe.finishOutstanding() }
    let source = probe.makeResources().photosSource(serializedCloudIdentifier: "reentrant-invalidation")
    let initialAcquire = Task { @MainActor in try await source.acquire() }
    await fulfillment(of: [probe.started(0)], timeout: 1)
    let automaticAsset = AVMutableComposition()
    probe.finish(0, with: .success(VideoRepresentation(asset: automaticAsset)))
    let initialReceipt = try await initialAcquire.value
    XCTAssertTrue(initialReceipt.asset === automaticAsset)
    let unexpectedHQStart = probe.started(1)
    unexpectedHQStart.isInverted = true
    let invalidatedDuringPublication = expectation(description: "Acquiring publication invalidates the new operation")
    let observation = FiniteInvalidationObservation()
    withObservationTracking {
      _ = source.state
    } onChange: {
      MainActor.assumeIsolated {
        guard !observation.fired else { return }
        observation.fired = true
        source.invalidate()
        invalidatedDuringPublication.fulfill()
      }
    }

    let highQuality = source.prepare(VideoRequest(quality: .highest))
    assertSourceChanged(await result { try await highQuality.value() })
    await fulfillment(of: [invalidatedDuringPublication], timeout: 1)
    await fulfillment(of: [unexpectedHQStart], timeout: 0.25)

    XCTAssertEqual(probe.invocations.count, 1,
      "An operation invalidated synchronously before start must not launch native work")
    XCTAssertEqual(source.state, .idle)
  }

  func testCancellingAcquireReleasesItsTemporaryShareAndStopsTheOnlyRequest() async {
    let probe = FiniteLoaderProbe()
    defer { probe.finishOutstanding() }
    let source = probe.makeResources().photosSource(serializedCloudIdentifier: "acquire-only")
    let finished = expectation(description: "Cancelled acquire exits promptly")
    let acquiring = Task { @MainActor in
      let outcome = await result { try await source.acquire() }
      finished.fulfill()
      return outcome
    }
    await fulfillment(of: [probe.started(0)], timeout: 1)

    acquiring.cancel()
    await fulfillment(of: [probe.cancelled(0), finished], timeout: 1)
    probe.finish(0, with: .success(VideoRepresentation(asset: AVMutableComposition())))

    assertCancelled(await acquiring.value)
    XCTAssertEqual(probe.invocations.count, 1)
    XCTAssertEqual(probe.cancellationIndices, [0])
  }

  func testCancellingAcquireDoesNotCancelAnExplicitPreparationShare() async throws {
    let probe = FiniteLoaderProbe()
    defer { probe.finishOutstanding() }
    let source = probe.makeResources().photosSource(serializedCloudIdentifier: "acquire-and-prepare")
    let preparation = source.prepare()
    await fulfillment(of: [probe.started(0)], timeout: 1)
    let entered = expectation(description: "Acquire enters the shared operation")
    let finished = expectation(description: "Cancelled acquire exits")
    let acquiring = Task { @MainActor in
      entered.fulfill()
      let outcome = await result { try await source.acquire() }
      finished.fulfill()
      return outcome
    }
    await fulfillment(of: [entered], timeout: 1)
    acquiring.cancel()
    await fulfillment(of: [finished], timeout: 1)
    await assertNoCancellation(probe, protected: [0])

    let asset = AVMutableComposition()
    probe.finish(0, with: .success(VideoRepresentation(asset: asset)))
    let receipt = try await preparation.value()
    assertCancelled(await acquiring.value)
    XCTAssertTrue(receipt.asset === asset)
    XCTAssertEqual(probe.invocations.count, 1)
  }

  func testSavedShareIsRegisteredBeforeSubmittedShareIsReleased() async throws {
    let probe = FiniteLoaderProbe()
    defer { probe.finishOutstanding() }
    let source = probe.makeResources().photosSource(serializedCloudIdentifier: "handoff")
    let draft = source.prepare()
    await fulfillment(of: [probe.started(0)], timeout: 1)

    let submitted = draft.share()
    draft.cancel()
    let saved = submitted.share()
    submitted.cancel()

    await assertNoCancellation(probe, protected: [0])
    let asset = AVMutableComposition()
    probe.finish(0, with: .success(VideoRepresentation(asset: asset)))
    let receipt = try await saved.value()
    XCTAssertTrue(receipt.asset === asset)
    XCTAssertEqual(probe.invocations.count, 1)
  }

  // These A/B tests exercise only the finite share primitive. They do not stand
  // in for the App's real makeDraft/makeChanges or submitted callback wiring.
  func testSubmittedASurvivesDraftRemovalWhileLaterUnsubmittedBStops() async throws {
    let probe = FiniteLoaderProbe()
    defer { probe.finishOutstanding() }
    let resources = probe.makeResources()
    let sourceA = resources.photosSource(serializedCloudIdentifier: "submitted-A")
    let sourceB = resources.photosSource(serializedCloudIdentifier: "later-B")
    let draftA = sourceA.prepare()
    await fulfillment(of: [probe.started(0)], timeout: 1)
    let submittedA = draftA.share()
    draftA.cancel()
    let draftB = sourceB.prepare()
    await fulfillment(of: [probe.started(1)], timeout: 1)

    draftB.cancel()
    await fulfillment(of: [probe.cancelled(1)], timeout: 1)
    await assertNoCancellation(probe, protected: [0])
    let assetA = AVMutableComposition()
    probe.finish(0, with: .success(VideoRepresentation(asset: assetA)))

    let submitted = try await submittedA.value()
    XCTAssertTrue(submitted.asset === assetA)
    assertCancelled(await result { try await draftB.value() })
    XCTAssertEqual(probe.invocations.map(\.identifier), ["submitted-A", "later-B"])
    XCTAssertEqual(probe.cancellationIndices, [1])
  }

  func testFailedSaveReleasePreservesExistingAndLaterDraftShares() async throws {
    let probe = FiniteLoaderProbe()
    defer { probe.finishOutstanding() }
    let resources = probe.makeResources()
    let draftA = resources.photosSource(serializedCloudIdentifier: "draft-A").prepare()
    await fulfillment(of: [probe.started(0)], timeout: 1)
    let submittedA = draftA.share()
    let draftB = resources.photosSource(serializedCloudIdentifier: "draft-B").prepare()
    await fulfillment(of: [probe.started(1)], timeout: 1)

    submittedA.cancel()

    await assertNoCancellation(probe, protected: [0, 1])
    let assetA = AVMutableComposition()
    let assetB = AVMutableComposition()
    probe.finish(0, with: .success(VideoRepresentation(asset: assetA)))
    probe.finish(1, with: .success(VideoRepresentation(asset: assetB)))
    let receiptA = try await draftA.value()
    let receiptB = try await draftB.value()
    XCTAssertTrue(receiptA.asset === assetA)
    XCTAssertTrue(receiptB.asset === assetB)
    XCTAssertEqual(probe.invocations.count, 2)
  }

  func testLateOldSuccessFailureAndCancellationCannotRetireNewOperation() async throws {
    for oldResult in FiniteLateResult.allCases {
      let probe = FiniteLoaderProbe()
      defer { probe.finishOutstanding() }
      let source = probe.makeResources().photosSource(serializedCloudIdentifier: "restarted")
      let old = source.prepare()
      await fulfillment(of: [probe.started(0)], timeout: 1)
      old.cancel()
      let fresh = source.prepare()
      await fulfillment(of: [probe.started(1), probe.cancelled(0)], timeout: 1)

      probe.finish(0, with: oldResult.result)
      await fulfillment(of: [probe.returned(0)], timeout: 1)
      old.cancel()
      assertCancelled(await result { try await old.share().value() })
      let freshShare = fresh.share()
      await assertNoCancellation(probe, protected: [1])
      let currentAsset = AVMutableComposition()
      probe.finish(1, with: .success(VideoRepresentation(asset: currentAsset)))

      let firstReceipt = try await fresh.value()
      let secondReceipt = try await freshShare.value()
      XCTAssertTrue(firstReceipt.asset === currentAsset)
      XCTAssertEqual(secondReceipt.representationID, firstReceipt.representationID)
      XCTAssertTrue(source.preferred?.asset === currentAsset)
      XCTAssertEqual(probe.invocations.count, 2)
      XCTAssertEqual(probe.cancellationIndices, [0])
    }
  }

  func testFailedTerminalSharesDoNotRetryAndExplicitPreparationCanRetry() async throws {
    let probe = FiniteLoaderProbe()
    defer { probe.finishOutstanding() }
    let source = probe.makeResources().photosSource(serializedCloudIdentifier: "failed-then-retry")
    let failed = source.prepare()
    await fulfillment(of: [probe.started(0)], timeout: 1)
    probe.finish(0, with: .failure(VideoResourceFailure.acquisitionFailed))
    assertAcquisitionFailure(await result { try await failed.value() })
    assertAcquisitionFailure(await result { try await failed.share().value() })
    source.invalidate()
    assertAcquisitionFailure(await result { try await failed.value() })
    XCTAssertEqual(probe.invocations.count, 1)

    let retry = source.prepare()
    await fulfillment(of: [probe.started(1)], timeout: 1)
    failed.cancel()
    assertAcquisitionFailure(await result { try await failed.share().value() })
    await assertNoCancellation(probe, protected: [1])
    let asset = AVMutableComposition()
    probe.finish(1, with: .success(VideoRepresentation(asset: asset)))

    let receipt = try await retry.value()
    XCTAssertTrue(receipt.asset === asset)
    XCTAssertEqual(probe.invocations.count, 2)
  }

  func testCancelledTerminalSharesDoNotRestartOrCancelExplicitRetry() async throws {
    let probe = FiniteLoaderProbe()
    defer { probe.finishOutstanding() }
    let source = probe.makeResources().photosSource(serializedCloudIdentifier: "cancelled-then-retry")
    let cancelled = source.prepare()
    await fulfillment(of: [probe.started(0)], timeout: 1)
    cancelled.cancel()
    await fulfillment(of: [probe.cancelled(0)], timeout: 1)
    assertCancelled(await result { try await cancelled.share().value() })
    source.invalidate()
    XCTAssertEqual(probe.invocations.count, 1)

    let retry = source.prepare()
    await fulfillment(of: [probe.started(1)], timeout: 1)
    cancelled.cancel()
    assertCancelled(await result { try await cancelled.value() })
    await assertNoCancellation(probe, protected: [1])
    let asset = AVMutableComposition()
    probe.finish(1, with: .success(VideoRepresentation(asset: asset)))
    let receipt = try await retry.value()
    XCTAssertTrue(receipt.asset === asset)
    XCTAssertEqual(probe.invocations.count, 2)
  }

  func testSuccessfulTerminalShareReplaysItsReceiptWithoutNewWork() async throws {
    let probe = FiniteLoaderProbe()
    defer { probe.finishOutstanding() }
    let source = probe.makeResources().photosSource(serializedCloudIdentifier: "completed")
    let preparation = source.prepare()
    await fulfillment(of: [probe.started(0)], timeout: 1)
    let asset = AVMutableComposition()
    probe.finish(0, with: .success(VideoRepresentation(asset: asset)))
    let first = try await preparation.value()
    let repeated = try await preparation.share().value()
    XCTAssertTrue(repeated.asset === asset)
    XCTAssertEqual(repeated.representationID, first.representationID)
    XCTAssertEqual(probe.invocations.count, 1)
    XCTAssertTrue(probe.cancellationIndices.isEmpty)
  }

  func testDroppingOneHandleDoesNotCancelItsSurvivingShare() async throws {
    let probe = FiniteLoaderProbe()
    defer { probe.finishOutstanding() }
    let source = probe.makeResources().photosSource(serializedCloudIdentifier: "deinit-one-share")
    var parent: VideoPreparation? = source.prepare()
    weak let releasedParent = parent
    let survivor = parent!.share()
    await fulfillment(of: [probe.started(0)], timeout: 1)

    parent = nil
    XCTAssertNil(releasedParent)
    await assertNoCancellation(probe, protected: [0])
    let asset = AVMutableComposition()
    probe.finish(0, with: .success(VideoRepresentation(asset: asset)))
    let receipt = try await survivor.value()
    XCTAssertTrue(receipt.asset === asset)
    XCTAssertEqual(probe.invocations.count, 1)
  }

  func testDroppingLastHandleCancelsAndDoesNotRetainSourceDespiteUnresponsiveLoader() async {
    let probe = FiniteLoaderProbe()
    defer { probe.finishOutstanding() }
    let resources = probe.makeResources()
    var source: VideoSource? = resources.photosSource(serializedCloudIdentifier: "deinit-last-share")
    weak let releasedSource = source
    var preparation: VideoPreparation? = source!.prepare()
    weak let releasedPreparation = preparation
    await fulfillment(of: [probe.started(0)], timeout: 1)
    source = nil
    XCTAssertNotNil(releasedSource, "The live handle keeps its source available")

    preparation = nil
    await fulfillment(of: [probe.cancelled(0)], timeout: 1)

    XCTAssertNil(releasedPreparation)
    XCTAssertNil(releasedSource, "A loader that ignores cancellation must not retain the old source")
    XCTAssertEqual(probe.cancellationIndices, [0])
  }

  private func assertNoCancellation(_ probe: FiniteLoaderProbe, protected: Set<Int>) async {
    let unexpected = expectation(description: "Protected native acquisition stays active")
    unexpected.isInverted = true
    probe.onCancellation = { if protected.contains($0) { unexpected.fulfill() } }
    await fulfillment(of: [unexpected], timeout: 0.05)
    probe.onCancellation = nil
    XCTAssertTrue(protected.isDisjoint(with: probe.cancellationIndices))
  }

  private func result(_ operation: () async throws -> VideoReceipt) async -> Result<VideoReceipt, Error> {
    do { return .success(try await operation()) }
    catch { return .failure(error) }
  }

  private func assertCancelled(
    _ result: Result<VideoReceipt, Error>,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    switch result {
    case .success: XCTFail("Cancelled wait or handle must not receive a receipt", file: file, line: line)
    case .failure(let error): XCTAssertTrue(error is CancellationError, file: file, line: line)
    }
  }

  private func assertSourceChanged(
    _ result: Result<VideoReceipt, Error>,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    switch result {
    case .success: XCTFail("An old authority must not return a receipt", file: file, line: line)
    case .failure(let error):
      XCTAssertEqual(error as? VideoResourceFailure, .sourceChanged, file: file, line: line)
    }
  }

  private func assertAcquisitionFailure(
    _ result: Result<VideoReceipt, Error>,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    switch result {
    case .success: XCTFail("Failed operation must retain its terminal failure", file: file, line: line)
    case .failure(let error):
      XCTAssertEqual(error as? VideoResourceFailure, .acquisitionFailed, file: file, line: line)
    }
  }
}

@MainActor
private final class FiniteInvalidationObservation {
  var fired = false
}

@MainActor
private final class FiniteAuthorityFacts {
  var revision = "A"
  var finishedWaits = 0
}

@MainActor
private enum FiniteLateResult: CaseIterable {
  case success, failure, cancellation

  var result: Result<VideoRepresentation, Error> {
    switch self {
    case .success: .success(VideoRepresentation(asset: AVMutableComposition()))
    case .failure: .failure(VideoResourceFailure.acquisitionFailed)
    case .cancellation: .failure(CancellationError())
    }
  }
}

private extension FiniteLoaderProbe {
  func makeResources(authority: @escaping (String) throws -> String) -> VideoResources {
    VideoResources(photos: PhotosVideoProvider(
      authority: authority,
      load: { [self] identifier, request, progress in
        try await load(identifier: identifier, request: request, progress: progress)
      }
    ))
  }
}

/// Deliberately records cancellation without completing the native request, so
/// tests can deliver the old callback after a new same-source request has begun.
@MainActor
private final class FiniteLoaderProbe {
  struct Invocation {
    let identifier: String
    let request: VideoRequest
    let progress: PhotosVideoProvider.Progress
    var continuation: CheckedContinuation<VideoRepresentation, Error>?
  }

  private(set) var invocations: [Invocation] = []
  private(set) var cancellationIndices: [Int] = []
  var onCancellation: ((Int) -> Void)?
  private var returnedIndices: Set<Int> = []
  private var startObservers: [Int: [XCTestExpectation]] = [:]
  private var cancelObservers: [Int: [XCTestExpectation]] = [:]
  private var returnObservers: [Int: [XCTestExpectation]] = [:]
  private var timeoutTasks: [Int: Task<Void, Never>] = [:]
  private enum ProbeFailure: Error { case nativeTimeout }

  func makeResources() -> VideoResources {
    VideoResources(photos: PhotosVideoProvider(
      authority: { "authority:\($0)" },
      load: { [self] identifier, request, progress in
        try await load(identifier: identifier, request: request, progress: progress)
      }
    ))
  }

  func started(_ index: Int) -> XCTestExpectation {
    let event = XCTestExpectation(description: "Native request \(index) starts")
    if invocations.indices.contains(index) { event.fulfill() }
    else { startObservers[index, default: []].append(event) }
    return event
  }

  func cancelled(_ index: Int) -> XCTestExpectation {
    let event = XCTestExpectation(description: "Native request \(index) receives cancellation")
    if cancellationIndices.contains(index) { event.fulfill() }
    else { cancelObservers[index, default: []].append(event) }
    return event
  }

  func returned(_ index: Int) -> XCTestExpectation {
    let event = XCTestExpectation(description: "Native request \(index) returns its delayed result")
    if returnedIndices.contains(index) { event.fulfill() }
    else { returnObservers[index, default: []].append(event) }
    return event
  }

  func finish(
    _ index: Int,
    with result: Result<VideoRepresentation, Error>,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    guard invocations.indices.contains(index), let continuation = invocations[index].continuation else {
      XCTFail("Expected an unfinished native request at index \(index)", file: file, line: line)
      return
    }
    invocations[index].continuation = nil
    timeoutTasks.removeValue(forKey: index)?.cancel()
    continuation.resume(with: result)
  }

  func finishOutstanding() {
    for task in timeoutTasks.values { task.cancel() }
    timeoutTasks.removeAll()
    for index in invocations.indices {
      guard let continuation = invocations[index].continuation else { continue }
      invocations[index].continuation = nil
      continuation.resume(throwing: CancellationError())
    }
  }

  private func load(
    identifier: String,
    request: VideoRequest,
    progress: @escaping PhotosVideoProvider.Progress
  ) async throws -> VideoRepresentation {
    let index = invocations.count
    defer {
      timeoutTasks.removeValue(forKey: index)?.cancel()
      returnedIndices.insert(index)
      for observer in returnObservers.removeValue(forKey: index) ?? [] { observer.fulfill() }
    }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        invocations.append(Invocation(
          identifier: identifier, request: request, progress: progress, continuation: continuation
        ))
        // A broken public wait must fail within a bound instead of hanging the
        // test process. Prompt cancellation is still checked separately at 1 s.
        timeoutTasks[index] = Task { @MainActor [weak self] in
          do { try await Task.sleep(for: .seconds(5)) }
          catch { return }
          guard let self, invocations.indices.contains(index),
            invocations[index].continuation != nil
          else { return }
          finish(index, with: .failure(ProbeFailure.nativeTimeout))
        }
        for observer in startObservers.removeValue(forKey: index) ?? [] { observer.fulfill() }
      }
    } onCancel: {
      Task { @MainActor [self] in
        cancellationIndices.append(index)
        for observer in cancelObservers.removeValue(forKey: index) ?? [] { observer.fulfill() }
        onCancellation?(index)
      }
    }
  }
}

extension FiniteOperationTests {
  func testPreferredOnlyObservationTracksAcceptanceUpgradeAndInvalidation() async throws {
    let probe = FiniteLoaderProbe()
    defer { probe.finishOutstanding() }
    let source = probe.makeResources().photosSource(serializedCloudIdentifier: "preferred-events")
    let changes = PreparedPreferredEvents()
    preparedWatchPreferred(source) { changes.count += 1 }
    let first = source.prepare()
    await fulfillment(of: [probe.started(0)], timeout: 1)
    probe.finish(0, with: .success(VideoRepresentation(asset: AVMutableComposition())))
    let initial = try await first.value()
    XCTAssertEqual(changes.count, 1)

    preparedWatchPreferred(source) { changes.count += 1 }
    let high = source.prepare(.init(quality: .highest, network: .forbidden))
    await fulfillment(of: [probe.started(1)], timeout: 1)
    probe.finish(1, with: .success(VideoRepresentation(asset: AVMutableComposition())))
    let upgraded = try await high.value()
    XCTAssertNotEqual(initial.representationID, upgraded.representationID)
    XCTAssertEqual(changes.count, 2)

    preparedWatchPreferred(source) { changes.count += 1 }
    source.invalidate()
    XCTAssertNil(source.preferred)
    XCTAssertEqual(changes.count, 3)
  }

  func testPreferredAcceptanceNotifiesWhilePeerKeepsStateAcquiring() async throws {
    let probe = FiniteLoaderProbe()
    defer { probe.finishOutstanding() }
    let source = probe.makeResources().photosSource(serializedCloudIdentifier: "preferred-pending-peer")
    let automatic = source.prepare()
    let high = source.prepare(.init(quality: .highest, network: .forbidden))
    defer { high.cancel() }
    await fulfillment(of: [probe.started(0), probe.started(1)], timeout: 1)
    let changes = PreparedPreferredEvents()
    let previousState = source.state
    preparedWatchPreferred(source) { changes.count += 1 }
    probe.finish(0, with: .success(VideoRepresentation(asset: AVMutableComposition())))
    _ = try await automatic.value()
    XCTAssertEqual(previousState, .acquiring(0))
    XCTAssertEqual(source.state, previousState)
    XCTAssertEqual(changes.count, 1, "Receipt publication must not depend on terminal state publication")
  }

  func testSameActualAssetEvidenceUpgradeNotifiesButCacheHitDoesNot() async throws {
    let probe = FiniteLoaderProbe()
    defer { probe.finishOutstanding() }
    let source = probe.makeResources().photosSource(serializedCloudIdentifier: "preferred-evidence")
    let asset = AVMutableComposition()
    let first = source.prepare()
    await fulfillment(of: [probe.started(0)], timeout: 1)
    probe.finish(0, with: .success(VideoRepresentation(asset: asset)))
    let original = try await first.value()
    let changes = PreparedPreferredEvents()
    preparedWatchPreferred(source) { changes.count += 1 }
    let request = VideoRequest(quality: .highest, network: .forbidden)
    let high = source.prepare(request)
    await fulfillment(of: [probe.started(1)], timeout: 1)
    probe.finish(1, with: .success(VideoRepresentation(asset: asset)))
    let upgraded = try await high.value()
    XCTAssertEqual(upgraded.representationID, original.representationID)
    XCTAssertEqual(source.preferred?.evidence, request)
    XCTAssertEqual(changes.count, 1)

    preparedWatchPreferred(source) { changes.count += 1 }
    let repeated = try await source.prepare(request).value()
    XCTAssertEqual(repeated.representationID, original.representationID)
    XCTAssertEqual(probe.invocations.count, 2)
    XCTAssertEqual(changes.count, 1, "An unchanged receipt cannot create a refresh loop")
  }

  func testPreferredAcceptanceCallbackInvalidationCannotReturnOrRecacheOldReceipt() async {
    let probe = FiniteLoaderProbe()
    defer { probe.finishOutstanding() }
    let source = probe.makeResources().photosSource(serializedCloudIdentifier: "preferred-invalidated-on-accept")
    let handle = source.prepare()
    await fulfillment(of: [probe.started(0)], timeout: 1)
    let changes = PreparedPreferredEvents()
    preparedWatchPreferred(source) {
      // Observation can reenter this callback for the invalidation performed
      // inside it. The fixture withdraws authority only once.
      guard changes.count == 0 else { return }
      changes.count += 1
      source.invalidate()
    }
    probe.finish(0, with: .success(VideoRepresentation(asset: AVMutableComposition())))
    assertSourceChanged(await result { try await handle.value() })
    XCTAssertEqual(changes.count, 1)
    XCTAssertNil(source.preferred)
    XCTAssertEqual(source.state, .idle)
  }

  func testPreferredInvalidationCallbackFreshPreparationSurvivesOldPendingBatch() async throws {
    let probe = FiniteLoaderProbe()
    defer { probe.finishOutstanding() }
    let source = probe.makeResources().photosSource(serializedCloudIdentifier: "preferred-restart-on-invalidate")
    let initial = source.prepare()
    await fulfillment(of: [probe.started(0)], timeout: 1)
    probe.finish(0, with: .success(VideoRepresentation(asset: AVMutableComposition())))
    _ = try await initial.value()
    let oldHigh = source.prepare(.init(quality: .highest, network: .forbidden))
    await fulfillment(of: [probe.started(1)], timeout: 1)
    let events = PreparedPreferredEvents()
    preparedWatchPreferred(source) { events.fresh = source.prepare() }
    source.invalidate()
    assertSourceChanged(await result { try await oldHigh.value() })
    let fresh = try XCTUnwrap(events.fresh)
    await fulfillment(of: [probe.started(2)], timeout: 1)
    let currentAsset = AVMutableComposition()
    probe.finish(2, with: .success(VideoRepresentation(asset: currentAsset)))
    let current = try await fresh.value()
    XCTAssertTrue(current.asset === currentAsset)
    XCTAssertTrue(current.isCurrent)
    XCTAssertEqual(source.preferred?.representationID, current.representationID)
  }

  func testPreferredAcceptanceCallbackLastShareCancellationKeepsTerminalCancellation() async {
    let probe = FiniteLoaderProbe()
    defer { probe.finishOutstanding() }
    let source = probe.makeResources().photosSource(serializedCloudIdentifier: "preferred-cancel-on-accept")
    let handle = source.prepare()
    await fulfillment(of: [probe.started(0)], timeout: 1)
    let events = PreparedPreferredEvents()
    preparedWatchPreferred(source) {
      events.count += 1
      handle.cancel()
    }
    probe.finish(0, with: .success(VideoRepresentation(asset: AVMutableComposition())))
    assertCancelled(await result { try await handle.value() })
    XCTAssertEqual(events.count, 1)
  }

  func testFailedHighQualityAndWeakerSuccessDoNotRepublishPreferred() async throws {
    let probe = FiniteLoaderProbe()
    defer { probe.finishOutstanding() }
    let source = probe.makeResources().photosSource(serializedCloudIdentifier: "preferred-retained")
    let weaker = source.prepare()
    let highestRequest = VideoRequest(quality: .highest, network: .allowed)
    let highest = source.prepare(highestRequest)
    await fulfillment(of: [probe.started(0), probe.started(1)], timeout: 1)
    probe.finish(1, with: .success(VideoRepresentation(asset: AVMutableComposition())))
    let best = try await highest.value()
    let events = PreparedPreferredEvents()
    preparedWatchPreferred(source) { events.count += 1 }
    probe.finish(0, with: .success(VideoRepresentation(asset: AVMutableComposition())))
    _ = try await weaker.value()
    XCTAssertEqual(source.preferred?.representationID, best.representationID)
    XCTAssertEqual(events.count, 0)

    let forbidden = source.prepare(.init(quality: .highest, network: .forbidden))
    await fulfillment(of: [probe.started(2)], timeout: 1)
    probe.finish(2, with: .failure(VideoResourceFailure.networkRequired))
    switch await result({ try await forbidden.value() }) {
    case .success: XCTFail("The failed probe retains its own failure")
    case .failure(let error): XCTAssertEqual(error as? VideoResourceFailure, .networkRequired)
    }
    XCTAssertEqual(source.preferred?.representationID, best.representationID)
    XCTAssertEqual(source.state, .available)
    XCTAssertEqual(events.count, 0)
  }
}

@MainActor
private final class PreparedPreferredEvents {
  var count = 0
  var fresh: VideoPreparation?
}

@MainActor
private func preparedWatchPreferred(_ source: VideoSource, change: @escaping @MainActor () -> Void) {
  withObservationTracking { _ = source.preferred } onChange: {
    MainActor.assumeIsolated { change() }
  }
}

extension FiniteOperationTests {
  func testColdPhotosForbiddenProbeFailureKeepsOwnErrorWithoutGlobalUnavailable() async {
    for quality in [VideoRequest.Quality.automatic, .highest] {
      for failure in [VideoResourceFailure.networkRequired, .networkFailed, .acquisitionFailed] {
        let probe = FiniteLoaderProbe()
        defer { probe.finishOutstanding() }
        let source = probe.makeResources().photosSource(serializedCloudIdentifier: "cold-local-probe")
        let request = VideoRequest(quality: quality, network: .forbidden)
        let handle = source.prepare(request)
        await fulfillment(of: [probe.started(0)], timeout: 1)
        probe.finish(0, with: .failure(failure))
        switch await result({ try await handle.value() }) {
        case .success: XCTFail("A failed probe must keep its finite failure")
        case .failure(let error): XCTAssertEqual(error as? VideoResourceFailure, failure)
        }
        XCTAssertNil(source.preferred)
        XCTAssertEqual(source.state, .idle)
        XCTAssertEqual(probe.invocations.map(\.request), [request], "No automatic retry")
      }
    }
  }

  func testPhotosForbiddenProbeDoesNotSuppressAuthorityOrFileFailures() async {
    for failure in [VideoResourceFailure.photosAccessRequired, .sourceUnavailable, .sourceChanged,
      .fileUnavailable, .fileChanged]
    {
      let probe = FiniteLoaderProbe()
      defer { probe.finishOutstanding() }
      let source = probe.makeResources().photosSource(serializedCloudIdentifier: "probe-authority-failure")
      let handle = source.prepare(.init(quality: .automatic, network: .forbidden))
      await fulfillment(of: [probe.started(0)], timeout: 1)
      probe.finish(0, with: .failure(failure))
      switch await result({ try await handle.value() }) {
      case .success: XCTFail("The failure must not be replaced with success")
      case .failure(let error): XCTAssertEqual(error as? VideoResourceFailure, failure)
      }
      XCTAssertEqual(source.state, .unavailable(failure))
    }
  }

  func testAllowedPhotosFailuresKeepExistingGlobalUnavailableProjection() async {
    for quality in [VideoRequest.Quality.automatic, .highest] {
      for failure in [VideoResourceFailure.networkRequired, .networkFailed, .acquisitionFailed] {
        let probe = FiniteLoaderProbe()
        defer { probe.finishOutstanding() }
        let source = probe.makeResources().photosSource(serializedCloudIdentifier: "allowed-failure")
        let handle = source.prepare(.init(quality: quality, network: .allowed))
        await fulfillment(of: [probe.started(0)], timeout: 1)
        probe.finish(0, with: .failure(failure))
        switch await result({ try await handle.value() }) {
        case .success: XCTFail("The allowed acquisition remains failed")
        case .failure(let error): XCTAssertEqual(error as? VideoResourceFailure, failure)
        }
        XCTAssertEqual(source.state, .unavailable(failure))
      }
    }
  }

  func testFileAcquisitionFailuresAreNotPhotosProbeFailures() async {
    for failure in [VideoResourceFailure.fileUnavailable, .fileChanged, .networkRequired,
      .networkFailed, .acquisitionFailed]
    {
      let resources = VideoResources(verifiedFile: { _ in throw failure })
      let source = resources.fileSource(identity: "local-file-failure")
      let handle = source.prepare()
      switch await result({ try await handle.value() }) {
      case .success: XCTFail("A file verification failure remains failed")
      case .failure(let error): XCTAssertEqual(error as? VideoResourceFailure, failure)
      }
      XCTAssertEqual(source.state, .unavailable(failure))
    }
  }
}


extension FiniteOperationTests {
  func testAuthorityChangesDuringPreferredComparisonCannotPublishOldCandidate() async throws {
    let probe = FiniteLoaderProbe()
    defer { probe.finishOutstanding() }
    let facts = PreparedPreferredAuthorityChange()
    let source = probe.makeResources(authority: { _ in
      if facts.armed {
        facts.reads += 1
        if facts.reads == 2 {
          facts.revision = "B"
          facts.armed = false
        }
      }
      return facts.revision
    }).photosSource(serializedCloudIdentifier: "preferred-comparison-authority")
    let initial = source.prepare()
    await fulfillment(of: [probe.started(0)], timeout: 1)
    probe.finish(0, with: .success(VideoRepresentation(asset: AVMutableComposition())))
    _ = try await initial.value()
    let high = source.prepare(.init(quality: .highest, network: .forbidden))
    await fulfillment(of: [probe.started(1)], timeout: 1)
    let events = PreparedPreferredEvents()
    func watch() {
      preparedWatchPreferred(source) {
        events.count += 1
        if events.fresh == nil {
          events.fresh = source.prepare()
          watch()
        }
      }
    }
    watch()
    // The initial incoming receipt check still sees A. Revalidating the cached
    // preferred candidate then sees B and synchronously invalidates the old work.
    facts.armed = true
    probe.finish(1, with: .success(VideoRepresentation(asset: AVMutableComposition())))
    assertSourceChanged(await result { try await high.value() })
    let fresh = try XCTUnwrap(events.fresh)
    await fulfillment(of: [probe.started(2)], timeout: 1)
    XCTAssertEqual(events.count, 1, "Only invalidation is published before fresh acceptance")
    XCTAssertNil(source.preferred, "The A candidate cannot reappear in epoch B")
    let currentAsset = AVMutableComposition()
    probe.finish(2, with: .success(VideoRepresentation(asset: currentAsset)))
    let current = try await fresh.value()
    XCTAssertTrue(current.isCurrent)
    XCTAssertTrue(source.preferred?.asset === currentAsset)
    XCTAssertEqual(events.count, 2)
  }
}

@MainActor
private final class PreparedPreferredAuthorityChange {
  var revision = "A"
  var reads = 0
  var armed = false
}


extension FiniteOperationTests {
  func testLateForbiddenProbeCannotEraseOrdinaryAcquisitionFailure() async {
    let probe = FiniteLoaderProbe()
    defer { probe.finishOutstanding() }
    let source = probe.makeResources().photosSource(serializedCloudIdentifier: "ordinary-then-probe")
    let ordinary = source.prepare(.init(quality: .automatic, network: .allowed))
    let local = source.prepare(.init(quality: .highest, network: .forbidden))
    await fulfillment(of: [probe.started(0), probe.started(1)], timeout: 1)
    probe.finish(0, with: .failure(VideoResourceFailure.acquisitionFailed))
    switch await result({ try await ordinary.value() }) {
    case .success: XCTFail("The ordinary acquisition must fail")
    case .failure(let error): XCTAssertEqual(error as? VideoResourceFailure, .acquisitionFailed)
    }
    XCTAssertEqual(source.state, .unavailable(.acquisitionFailed))
    probe.finish(1, with: .failure(VideoResourceFailure.networkRequired))
    switch await result({ try await local.value() }) {
    case .success: XCTFail("The local probe must keep its own failure")
    case .failure(let error): XCTAssertEqual(error as? VideoResourceFailure, .networkRequired)
    }
    XCTAssertEqual(source.state, .unavailable(.acquisitionFailed))
    XCTAssertNil(source.preferred)
    XCTAssertEqual(probe.invocations.count, 2)
  }
}


extension FiniteOperationTests {
  func testProbeDuringOrdinaryFailurePublicationCannotSuppressFailureButRetryCan() async {
    for network in [VideoRequest.Network.forbidden, .allowed] {
      let probe = FiniteLoaderProbe()
      defer { probe.finishOutstanding() }
      let source = probe.makeResources().photosSource(serializedCloudIdentifier: "failure-publication")
      let ordinary = source.prepare()
      await fulfillment(of: [probe.started(0)], timeout: 1)
      let events = PreparedPreferredEvents()
      withObservationTracking { _ = source.state } onChange: {
        MainActor.assumeIsolated {
          guard events.fresh == nil else { return }
          events.fresh = source.prepare(.init(quality: .highest, network: network))
        }
      }
      probe.finish(0, with: .failure(VideoResourceFailure.acquisitionFailed))
      _ = await result { try await ordinary.value() }
      let fresh = try? XCTUnwrap(events.fresh)
      guard let fresh else { continue }
      await fulfillment(of: [probe.started(1)], timeout: 1)
      XCTAssertEqual(source.state, network == .forbidden ? .unavailable(.acquisitionFailed) : .acquiring(0))
      probe.finish(1, with: .failure(VideoResourceFailure.networkRequired))
      _ = await result { try await fresh.value() }
      XCTAssertEqual(source.state, .unavailable(network == .forbidden ? .acquisitionFailed : .networkRequired))
    }
  }
}


extension FiniteOperationTests {
  func testLocalProbeProgressAndQuietCompletionPreserveOrdinaryFailure() async throws {
    for alreadyPending in [false, true] {
      for ordinaryFailure in [VideoResourceFailure.networkRequired, .networkFailed, .acquisitionFailed,
        .photosAccessRequired, .sourceUnavailable, .sourceChanged, .fileUnavailable, .fileChanged]
      {
        for probeFailure in [VideoResourceFailure.networkRequired, .networkFailed, .acquisitionFailed, nil] {
          let probe = FiniteLoaderProbe()
          defer { probe.finishOutstanding() }
          let source = probe.makeResources().photosSource(serializedCloudIdentifier: "probe-preserves-error")
          let ordinary = source.prepare()
          var local: VideoPreparation?
          if alreadyPending { local = source.prepare(.init(quality: .highest, network: .forbidden)) }
          await fulfillment(of: [probe.started(0)], timeout: 1)
          probe.finish(0, with: .failure(ordinaryFailure))
          _ = await result { try await ordinary.value() }
          XCTAssertEqual(source.state, .unavailable(ordinaryFailure))
          if local == nil { local = source.prepare(.init(quality: .highest, network: .forbidden)) }
          let handle = try XCTUnwrap(local)
          await fulfillment(of: [probe.started(1)], timeout: 1)
          XCTAssertEqual(source.state, .unavailable(ordinaryFailure))
          let progress = expectation(description: "Local probe publishes its own progress")
          withObservationTracking { _ = handle.progress } onChange: { progress.fulfill() }
          probe.invocations[1].progress(0.4)
          await fulfillment(of: [progress], timeout: 1)
          XCTAssertEqual(handle.progress, 0.4)
          XCTAssertEqual(source.state, .unavailable(ordinaryFailure))
          probe.finish(1, with: .failure(probeFailure.map { $0 as Error } ?? CancellationError()))
          switch await result({ try await handle.value() }) {
          case .success: XCTFail("The local probe must retain its failure")
          case .failure(let error):
            if let probeFailure { XCTAssertEqual(error as? VideoResourceFailure, probeFailure) }
            else { XCTAssertTrue(error is CancellationError) }
          }
          XCTAssertEqual(source.state, .unavailable(ordinaryFailure))
          XCTAssertEqual(probe.invocations.count, 2)
          let retry = source.prepare()
          await fulfillment(of: [probe.started(2)], timeout: 1)
          XCTAssertEqual(source.state, .acquiring(0), "An explicit ordinary retry resets the failure")
          probe.finish(2, with: .success(VideoRepresentation(asset: AVMutableComposition())))
          _ = try await retry.value()
          XCTAssertEqual(source.state, .available)
          XCTAssertEqual(probe.invocations.count, 3)
        }
      }
    }
  }

  func testLocalProbeSuccessRestoresAvailabilityAfterOrdinaryFailure() async throws {
    let probe = FiniteLoaderProbe()
    defer { probe.finishOutstanding() }
    let source = probe.makeResources().photosSource(serializedCloudIdentifier: "probe-recovers")
    let ordinary = source.prepare()
    await fulfillment(of: [probe.started(0)], timeout: 1)
    probe.finish(0, with: .failure(VideoResourceFailure.networkFailed))
    _ = await result { try await ordinary.value() }
    let local = source.prepare(.init(quality: .automatic, network: .forbidden))
    await fulfillment(of: [probe.started(1)], timeout: 1)
    XCTAssertEqual(source.state, .unavailable(.networkFailed))
    let asset = AVMutableComposition()
    probe.finish(1, with: .success(VideoRepresentation(asset: asset)))
    let receipt = try await local.value()
    XCTAssertTrue(receipt.isCurrent)
    XCTAssertTrue(source.preferred?.asset === asset)
    XCTAssertEqual(source.state, .available)
    XCTAssertEqual(probe.invocations.count, 2)
  }
}
