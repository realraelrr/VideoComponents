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
