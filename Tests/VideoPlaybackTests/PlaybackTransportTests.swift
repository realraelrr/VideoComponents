import AVFoundation
import XCTest
@testable import VideoPlayback

@MainActor
final class PlaybackTransportTests: XCTestCase {
  func testPreparationWaitsBeforeNativePlayAndUsesLatestHoldRate() async throws {
    let preparation = ControlledPlaybackPreparation()
    let session = try await makeReadyPlaybackSession(
      preparation: preparation.hook, audioSeconds: 8
    )
    preparation.observe(session)
    defer { session.cleanup(); preparation.resumeAll() }
    let item = try XCTUnwrap(session.player.currentItem)
    let identity = try XCTUnwrap(session.currentSourceIdentity)
    let source = PlaybackSource(identity: identity, load: { PlaybackLoadedMedia(asset: item.asset) })

    session.togglePlayback()
    XCTAssertTrue(session.isPlaybackRequested)
    XCTAssertEqual(session.player.rate, 0, "Native play must await host preparation")
    try await waitUntil { preparation.preparedOwners.count == 1 }
    let owner = try XCTUnwrap(preparation.preparedOwners.first)

    session.load(source: source, playbackRate: 0.5, isLooping: true, autoplayWhenReady: true)
    session.load(source: source, playbackRate: 0.75, isLooping: true, autoplayWhenReady: false)
    session.handleHoldGestureStateChanged(.began, allowsHoldBoost: true)
    session.updatePlaybackRate(1.25)
    XCTAssertTrue(session.player.currentItem === item)
    XCTAssertEqual(session.player.rate, 0)
    XCTAssertTrue(session.isPlaybackRequested)
    XCTAssertEqual(preparation.history, [.prepared(owner)])

    try await finishPreparation(preparation, owner: owner)
    XCTAssertEqual(session.player.rate, 2.5, accuracy: 0.01)
    session.cancelHold()
    XCTAssertEqual(session.player.rate, 1.25, accuracy: 0.01)
    XCTAssertEqual(preparation.history, [.prepared(owner)])
    session.pausePlayback()
    XCTAssertEqual(preparation.history, [.prepared(owner), .released(owner)])
    assertPreparationReleasedAfterPause(preparation)
  }

  func testPreparationPendingPauseCancelsAndRejectsStaleCompletion() async throws {
    for result: Result<Void, any Error> in [.success(()), .failure(PreparationTestError.denied)] {
      let preparation = ControlledPlaybackPreparation()
      let session = try await makeReadyPlaybackSession(
        preparation: preparation.hook, audioSeconds: 8
      )
      preparation.observe(session)
      defer { session.cleanup(); preparation.resumeAll() }
      let item = try XCTUnwrap(session.player.currentItem)
      let identity = session.currentSourceIdentity

      session.togglePlayback()
      XCTAssertEqual(session.player.rate, 0)
      try await waitUntil { preparation.preparedOwners.count == 1 }
      let owner = try XCTUnwrap(preparation.preparedOwners.first)
      session.handleHoldGestureStateChanged(.began, allowsHoldBoost: true)
      session.pausePlayback()
      XCTAssertFalse(session.isPlaybackRequested)
      XCTAssertNil(session.playbackRateIndicatorText)
      XCTAssertEqual(session.player.rate, 0)
      XCTAssertEqual(preparation.history, [.prepared(owner), .released(owner)])
      assertPreparationReleasedAfterPause(preparation)
      try await waitUntil { preparation.cancelledOwners == [owner] }

      try await finishPreparation(preparation, owner: owner, result: result)
      XCTAssertTrue(session.player.currentItem === item)
      XCTAssertEqual(session.currentSourceIdentity, identity)
      XCTAssertTrue(session.isPlayerReady)
      XCTAssertFalse(session.isPlaybackRequested)
      XCTAssertEqual(session.player.rate, 0)
      XCTAssertNil(session.failure)
      XCTAssertEqual(session.status, .none)
      XCTAssertEqual(preparation.history, [.prepared(owner), .released(owner)])
    }
  }

  func testPreparationPauseBeforeTaskRunsDoesNotInvokeCancelledHook() async throws {
    let preparation = ControlledPlaybackPreparation()
    let session = try await makeReadyPlaybackSession(
      preparation: preparation.hook, audioSeconds: 8
    )
    preparation.observe(session)
    defer { session.cleanup(); preparation.resumeAll() }

    // No actor suspension between demand and pause: the preparation task cannot enter yet.
    session.togglePlayback()
    session.pausePlayback()
    XCTAssertEqual(session.player.rate, 0)
    XCTAssertFalse(session.isPlaybackRequested)
    XCTAssertTrue(preparation.preparedOwners.isEmpty)
    let cancelledOwner = try XCTUnwrap(preparation.releases.first?.owner)
    XCTAssertEqual(preparation.history, [.released(cancelledOwner)])
    assertPreparationReleasedAfterPause(preparation)

    session.togglePlayback()
    try await waitUntil { !preparation.preparedOwners.isEmpty }
    let currentOwner = try XCTUnwrap(preparation.preparedOwners.first)
    XCTAssertNotEqual(currentOwner, cancelledOwner)
    XCTAssertEqual(preparation.history, [.released(cancelledOwner), .prepared(currentOwner)])
    try await finishPreparation(preparation, owner: currentOwner)
    XCTAssertEqual(session.player.rate, 1, accuracy: 0.01)
    session.pausePlayback()
    XCTAssertEqual(preparation.history, [
      .released(cancelledOwner), .prepared(currentOwner), .released(currentOwner)
    ])
    assertPreparationReleasedAfterPause(preparation)
  }

  func testPreparationPausePlayRejectsOldSuccessAndErrorBeforeAndAfterNewSuccess() async throws {
    for oldResult: Result<Void, any Error> in [.success(()), .failure(PreparationTestError.denied)] {
      for completeCurrentFirst in [false, true] {
        let preparation = ControlledPlaybackPreparation()
        let session = try await makeReadyPlaybackSession(
          preparation: preparation.hook, audioSeconds: 8
        )
        preparation.observe(session)
        defer { session.cleanup(); preparation.resumeAll() }
        session.togglePlayback()
        try await waitUntil { preparation.preparedOwners.count == 1 }
        let oldOwner = preparation.preparedOwners[0]
        session.pausePlayback()
        session.updatePlaybackRate(0.75)
        session.togglePlayback()
        try await waitUntil { preparation.preparedOwners.count == 2 }
        let currentOwner = preparation.preparedOwners[1]
        XCTAssertNotEqual(oldOwner, currentOwner)
        try await waitUntil { preparation.cancelledOwners == [oldOwner] }
        XCTAssertEqual(session.player.rate, 0)

        if completeCurrentFirst {
          try await finishPreparation(preparation, owner: currentOwner)
          XCTAssertEqual(session.player.rate, 0.75, accuracy: 0.01)
        }
        try await finishPreparation(preparation, owner: oldOwner, result: oldResult)
        XCTAssertTrue(session.isPlaybackRequested)
        XCTAssertNil(session.failure)
        XCTAssertNotEqual(session.status, .unavailable)
        XCTAssertEqual(session.player.rate, completeCurrentFirst ? 0.75 : 0, accuracy: 0.01)
        if !completeCurrentFirst {
          try await finishPreparation(preparation, owner: currentOwner)
        }
        XCTAssertEqual(session.player.rate, 0.75, accuracy: 0.01)
        session.pausePlayback()
        XCTAssertEqual(preparation.history, [
          .prepared(oldOwner), .released(oldOwner), .prepared(currentOwner), .released(currentOwner)
        ])
        assertPreparationReleasedAfterPause(preparation)
      }
    }
  }

  func testPreparationCleanupAndSameIdentityReuseRejectsOldCompletion() async throws {
    for oldResult: Result<Void, any Error> in [.success(()), .failure(PreparationTestError.denied)] {
      for completeCurrentFirst in [false, true] {
        let preparation = ControlledPlaybackPreparation()
        let session = try await makeReadyPlaybackSession(
          preparation: preparation.hook, audioSeconds: 8
        )
        preparation.observe(session)
        defer { session.cleanup(); preparation.resumeAll() }
        let oldItem = try XCTUnwrap(session.player.currentItem)
        let identity = try XCTUnwrap(session.currentSourceIdentity)
        let source = PlaybackSource(identity: identity, load: { PlaybackLoadedMedia(asset: oldItem.asset) })
        session.togglePlayback()
        try await waitUntil { preparation.preparedOwners.count == 1 }
        let oldOwner = preparation.preparedOwners[0]

        session.cleanup()
        session.cleanup()
        XCTAssertFalse(session.hasCurrentItem)
        XCTAssertFalse(session.hasActivePlayerObservers)
        XCTAssertFalse(session.isPlayerReady)
        XCTAssertFalse(session.isPlaybackRequested)
        XCTAssertEqual(session.player.rate, 0)
        XCTAssertEqual(preparation.history, [.prepared(oldOwner), .released(oldOwner)])
        try await waitUntil { preparation.cancelledOwners == [oldOwner] }

        session.load(source: source, playbackRate: 1.25, isLooping: true, autoplayWhenReady: true)
        try await waitUntil { session.isPlayerReady && preparation.preparedOwners.count == 2 }
        let currentOwner = preparation.preparedOwners[1]
        let currentItem = try XCTUnwrap(session.player.currentItem)
        XCTAssertNotEqual(currentOwner, oldOwner)
        XCTAssertFalse(currentItem === oldItem)
        if completeCurrentFirst {
          try await finishPreparation(preparation, owner: currentOwner)
          XCTAssertEqual(session.player.rate, 1.25, accuracy: 0.01)
        }
        try await finishPreparation(preparation, owner: oldOwner, result: oldResult)
        XCTAssertTrue(session.player.currentItem === currentItem)
        XCTAssertTrue(session.isCurrentSource(identity))
        XCTAssertTrue(session.isPlaybackRequested)
        XCTAssertEqual(session.player.rate, completeCurrentFirst ? 1.25 : 0, accuracy: 0.01)
        XCTAssertNil(session.failure)
        XCTAssertNotEqual(session.status, .unavailable)
        if !completeCurrentFirst { try await finishPreparation(preparation, owner: currentOwner) }
        XCTAssertEqual(session.player.rate, 1.25, accuracy: 0.01)
        session.cleanup()
        XCTAssertEqual(preparation.history, [
          .prepared(oldOwner), .released(oldOwner), .prepared(currentOwner), .released(currentOwner)
        ])
        assertPreparationReleasedAfterPause(preparation)
      }
    }
  }

  func testPreparationSuccessResumedBeforeSynchronousPauseOrCleanupNeverPlays() async throws {
    for cleanup in [false, true] {
      let preparation = ControlledPlaybackPreparation()
      let session = try await makeReadyPlaybackSession(
        preparation: preparation.hook, audioSeconds: 8
      )
      preparation.observe(session)
      defer { session.cleanup(); preparation.resumeAll() }
      let item = try XCTUnwrap(session.player.currentItem)
      let identity = session.currentSourceIdentity
      var willPlayCount = 0
      session.onEvent = { event in
        if case .willPlay = event { willPlayCount += 1 }
      }
      session.togglePlayback()
      try await waitUntil { preparation.preparedOwners.count == 1 }
      let owner = preparation.preparedOwners[0]

      // Resuming queues the callback; this actor has not yielded to that callback yet.
      try preparation.resume(owner, with: .success(()))
      XCTAssertFalse(preparation.returnedOwners.contains(owner))
      if cleanup { session.cleanup() } else { session.pausePlayback() }
      XCTAssertFalse(preparation.returnedOwners.contains(owner))
      XCTAssertEqual(session.player.rate, 0)
      XCTAssertFalse(session.isPlaybackRequested)
      XCTAssertEqual(preparation.history, [.prepared(owner), .released(owner)])
      assertPreparationReleasedAfterPause(preparation)

      try await waitUntil { preparation.returnedOwners == [owner] && preparation.cancelledOwners == [owner] }
      XCTAssertEqual(willPlayCount, 0, "Invalidated success must not reach the native-play boundary")
      XCTAssertEqual(session.player.rate, 0)
      XCTAssertFalse(session.isPlaybackRequested)
      XCTAssertNil(session.failure)
      if cleanup {
        XCTAssertFalse(session.hasCurrentItem)
        XCTAssertFalse(session.hasActivePlayerObservers)
        XCTAssertFalse(session.isPlayerReady)
        XCTAssertNil(session.currentSourceIdentity)
      } else {
        XCTAssertTrue(session.player.currentItem === item)
        XCTAssertTrue(session.isPlayerReady)
        XCTAssertEqual(session.currentSourceIdentity, identity)
      }
      XCTAssertEqual(preparation.history, [.prepared(owner), .released(owner)])
    }
  }

  func testPreparationWillPlayCallbackCleanupPreventsNativePlayAndReleasesOnce() async throws {
    let preparation = ControlledPlaybackPreparation()
    let session = try await makeReadyPlaybackSession(
      preparation: preparation.hook, audioSeconds: 8
    )
    preparation.observe(session)
    defer { session.cleanup(); preparation.resumeAll() }
    var willPlayCount = 0
    session.onEvent = { [weak session] event in
      guard case .willPlay = event else { return }
      willPlayCount += 1
      session?.cleanup()
    }
    session.togglePlayback()
    try await waitUntil { preparation.preparedOwners.count == 1 }
    let owner = preparation.preparedOwners[0]
    try await finishPreparation(preparation, owner: owner)

    XCTAssertEqual(willPlayCount, 1)
    XCTAssertFalse(session.hasCurrentItem)
    XCTAssertFalse(session.hasActivePlayerObservers)
    XCTAssertFalse(session.isPlayerReady)
    XCTAssertFalse(session.isPlaybackRequested)
    XCTAssertNil(session.currentSourceIdentity)
    XCTAssertEqual(session.player.rate, 0, "Reentrant cleanup must prevent playImmediately")
    XCTAssertNil(session.failure)
    XCTAssertEqual(preparation.history, [.prepared(owner), .released(owner)])
    assertPreparationReleasedAfterPause(preparation)
    session.cleanup()
    XCTAssertEqual(preparation.history, [.prepared(owner), .released(owner)])
  }

  func testPreparationSourceAToBToAUsesDistinctOwnersAndRejectsBothOldResults() async throws {
    let preparation = ControlledPlaybackPreparation()
    let session = try await makeReadyPlaybackSession(
      preparation: preparation.hook, audioSeconds: 8
    )
    preparation.observe(session)
    defer { session.cleanup(); preparation.resumeAll() }
    let asset = try XCTUnwrap(session.player.currentItem?.asset)
    let identityA = try XCTUnwrap(session.currentSourceIdentity)
    let sourceA = PlaybackSource(identity: identityA, load: { PlaybackLoadedMedia(asset: asset) })
    let sourceB = PlaybackSource(identity: UUID(), load: { PlaybackLoadedMedia(asset: asset) })
    session.togglePlayback()
    try await waitUntil { preparation.preparedOwners.count == 1 }
    let firstA = preparation.preparedOwners[0]
    session.load(source: sourceB, playbackRate: 0.5, isLooping: true, autoplayWhenReady: true)
    try await waitUntil { session.isPlayerReady && preparation.preparedOwners.count == 2 }
    let ownerB = preparation.preparedOwners[1]
    session.load(source: sourceA, playbackRate: 1.25, isLooping: true, autoplayWhenReady: true)
    try await waitUntil { session.isPlayerReady && preparation.preparedOwners.count == 3 }
    let currentA = preparation.preparedOwners[2]
    let item = try XCTUnwrap(session.player.currentItem)
    XCTAssertEqual(Set(preparation.preparedOwners).count, 3)
    try await waitUntil { preparation.cancelledOwners == [firstA, ownerB] }

    try await finishPreparation(preparation, owner: ownerB, result: .failure(PreparationTestError.denied))
    try await finishPreparation(preparation, owner: firstA)
    XCTAssertTrue(session.player.currentItem === item)
    XCTAssertTrue(session.isCurrentSource(identityA))
    XCTAssertTrue(session.isPlaybackRequested)
    XCTAssertEqual(session.player.rate, 0)
    XCTAssertNil(session.failure)
    try await finishPreparation(preparation, owner: currentA)
    XCTAssertEqual(session.player.rate, 1.25, accuracy: 0.01)
    session.pausePlayback()
    XCTAssertEqual(preparation.history, [
      .prepared(firstA), .released(firstA), .prepared(ownerB), .released(ownerB),
      .prepared(currentA), .released(currentA)
    ])
    assertPreparationReleasedAfterPause(preparation)
  }

  func testPreparationCompletionWhileScrubbingWaitsForLatestSeek() async throws {
    let preparation = ControlledPlaybackPreparation()
    let transport = ControlledTransportSeek()
    let session = try await makeReadyPlaybackSession(
      transportSeek: transport.seek, preparation: preparation.hook, audioSeconds: 8
    )
    preparation.observe(session)
    defer { session.cleanup(); preparation.resumeAll() }
    session.togglePlayback()
    try await waitUntil { preparation.preparedOwners.count == 1 }
    let owner = preparation.preparedOwners[0]
    session.handleScrubEditingChanged(true)
    session.setScrubProgress(0.3)
    session.setScrubProgress(0.6)
    session.updatePlaybackRate(1.25)
    try await finishPreparation(preparation, owner: owner)
    XCTAssertTrue(session.isPlaybackRequested)
    XCTAssertEqual(session.player.rate, 0, "A prepared lease cannot play during scrubbing")
    XCTAssertEqual(session.displayedProgress, 0.6, accuracy: 0.001)
    XCTAssertEqual(preparation.history, [.prepared(owner)])

    session.handleScrubEditingChanged(false)
    try await waitUntil { transport.finished(0) == true }
    XCTAssertEqual(transport.requests[0].target.seconds, 4.8, accuracy: 0.001)
    XCTAssertEqual(session.player.currentTime().seconds, 4.8, accuracy: 0.01)
    XCTAssertEqual(session.player.rate, 0, "Playback also waits for the final seek acknowledgement")
    try transport.deliver(0)
    XCTAssertEqual(session.player.rate, 1.25, accuracy: 0.01)
    XCTAssertEqual(preparation.history, [.prepared(owner)])
    session.pausePlayback()
    XCTAssertEqual(preparation.history, [.prepared(owner), .released(owner)])
    assertPreparationReleasedAfterPause(preparation)
  }

  func testPreparationAndPendingSeekMustBothCompleteBeforeNativePlay() async throws {
    for prepareFirst in [false, true] {
      let preparation = ControlledPlaybackPreparation()
      let transport = ControlledTransportSeek()
      let session = try await makeReadyPlaybackSession(
        transportSeek: transport.seek, preparation: preparation.hook, audioSeconds: 8
      )
      preparation.observe(session)
      defer { session.cleanup(); preparation.resumeAll() }
      session.togglePlayback()
      try await waitUntil { preparation.preparedOwners.count == 1 }
      let owner = preparation.preparedOwners[0]
      session.handleScrubEditingChanged(true)
      session.setScrubProgress(0.4)
      session.handleScrubEditingChanged(false)
      try await waitUntil { transport.finished(0) == true }

      if prepareFirst { try await finishPreparation(preparation, owner: owner) }
      else { try transport.deliver(0) }
      XCTAssertEqual(session.player.rate, 0)
      XCTAssertTrue(session.isPlaybackRequested)
      XCTAssertEqual(preparation.history, [.prepared(owner)])
      if prepareFirst { try transport.deliver(0) }
      else { try await finishPreparation(preparation, owner: owner) }
      XCTAssertEqual(session.player.rate, 1, accuracy: 0.01)
      session.pausePlayback()
      XCTAssertEqual(preparation.history, [.prepared(owner), .released(owner)])
      assertPreparationReleasedAfterPause(preparation)
    }
  }

  func testPreparationPauseWhileScrubbingCommitsPositionWithoutResumingPendingSeek() async throws {
    let preparation = ControlledPlaybackPreparation()
    let transport = ControlledTransportSeek()
    let session = try await makeReadyPlaybackSession(
      transportSeek: transport.seek, preparation: preparation.hook, audioSeconds: 8
    )
    preparation.observe(session)
    defer { session.cleanup(); preparation.resumeAll() }
    let item = session.player.currentItem
    session.togglePlayback()
    try await waitUntil { preparation.preparedOwners.count == 1 }
    let owner = preparation.preparedOwners[0]
    session.handleScrubEditingChanged(true)
    session.setScrubProgress(0.4)
    session.pausePlayback()
    XCTAssertFalse(session.isPlaybackRequested)
    XCTAssertEqual(session.player.rate, 0)
    XCTAssertEqual(preparation.history, [.prepared(owner), .released(owner)])
    assertPreparationReleasedAfterPause(preparation)
    try await waitUntil { transport.finished(0) == true && preparation.cancelledOwners == [owner] }

    try await finishPreparation(preparation, owner: owner)
    try transport.deliver(0)
    XCTAssertTrue(session.player.currentItem === item)
    XCTAssertEqual(session.player.currentTime().seconds, 3.2, accuracy: 0.01)
    XCTAssertEqual(session.currentTimeSeconds, 3.2, accuracy: 0.01)
    XCTAssertEqual(session.displayedProgress, 0.4, accuracy: 0.001)
    XCTAssertFalse(session.isPlaybackRequested)
    XCTAssertEqual(session.player.rate, 0)
    XCTAssertNil(session.failure)
    XCTAssertEqual(preparation.history, [.prepared(owner), .released(owner)])
  }

  func testPreparationPausedOriginHoldEndsPendingAndReadyLeases() async throws {
    for completeFirst in [false, true] {
      let preparation = ControlledPlaybackPreparation()
      let session = try await makeReadyPlaybackSession(
        preparation: preparation.hook, audioSeconds: 8
      )
      preparation.observe(session)
      defer { session.cleanup(); preparation.resumeAll() }
      session.handleHoldGestureStateChanged(.began, allowsHoldBoost: true)
      XCTAssertTrue(session.isPlaybackRequested)
      XCTAssertEqual(session.player.rate, 0)
      try await waitUntil { preparation.preparedOwners.count == 1 }
      let owner = preparation.preparedOwners[0]
      if completeFirst {
        try await finishPreparation(preparation, owner: owner)
        XCTAssertEqual(session.player.rate, 2, accuracy: 0.01)
      }
      session.handleHoldGestureStateChanged(.ended, allowsHoldBoost: true)
      XCTAssertFalse(session.isPlaybackRequested)
      XCTAssertNil(session.playbackRateIndicatorText)
      XCTAssertEqual(session.player.rate, 0)
      XCTAssertEqual(preparation.history, [.prepared(owner), .released(owner)])
      assertPreparationReleasedAfterPause(preparation)
      if !completeFirst {
        try await waitUntil { preparation.cancelledOwners == [owner] }
        try await finishPreparation(preparation, owner: owner)
      }
      XCTAssertEqual(session.player.rate, 0)
      XCTAssertFalse(session.isPlaybackRequested)
      XCTAssertNil(session.failure)
      session.cancelHold()
      XCTAssertEqual(preparation.history, [.prepared(owner), .released(owner)])
    }
  }

  func testPreparationLeaseSurvivesScrubSeekAndHQReplacementWhilePendingAndReady() async throws {
    for completeFirst in [false, true] {
      let preparation = ControlledPlaybackPreparation()
      let transport = ControlledTransportSeek()
      let session = try await makeReadyPlaybackSession(
        transportSeek: transport.seek, preparation: preparation.hook, audioSeconds: 8
      )
      preparation.observe(session)
      defer { session.cleanup(); preparation.resumeAll() }
      let original = try XCTUnwrap(session.player.currentItem)
      let identity = try XCTUnwrap(session.currentSourceIdentity)
      session.updatePlaybackRate(0.75)
      session.togglePlayback()
      try await waitUntil { preparation.preparedOwners.count == 1 }
      let owner = preparation.preparedOwners[0]
      if completeFirst { try await finishPreparation(preparation, owner: owner) }
      session.handleScrubEditingChanged(true)
      session.setScrubProgress(0.4)
      session.handleScrubEditingChanged(false)
      try await waitUntil { transport.finished(0) == true }
      XCTAssertEqual(session.player.rate, 0)
      XCTAssertEqual(preparation.history, [.prepared(owner)])

      let hqURL = try temporaryPlayableAudioURL(seconds: 8)
      var replacementResult: Result<Void, any Error>?
      let replacement = Task {
        do {
          try await session.replaceAsset(PlaybackLoadedMedia(asset: AVURLAsset(url: hqURL)), for: identity)
          replacementResult = .success(())
        } catch { replacementResult = .failure(error) }
      }
      defer { replacement.cancel() }
      try await waitUntil { transport.finished(1) == true }
      let latestItem = try XCTUnwrap(session.player.currentItem)
      XCTAssertFalse(latestItem === original)
      XCTAssertEqual((latestItem.asset as? AVURLAsset)?.url, hqURL)
      XCTAssertEqual(transport.requests[1].target.seconds, 3.2, accuracy: 0.01)
      XCTAssertEqual(session.player.rate, 0)
      // Replacement adopts the pending target; the old item's late seek cannot resume it.
      try transport.deliver(0)
      XCTAssertTrue(session.player.currentItem === latestItem)
      XCTAssertEqual(session.player.rate, 0)
      session.updatePlaybackRate(1.25)
      try transport.deliver(1)
      try await waitUntil { replacementResult != nil }
      try XCTUnwrap(replacementResult).get()
      await replacement.value
      XCTAssertTrue(session.player.currentItem === latestItem)
      XCTAssertTrue(session.isCurrentSource(identity))
      XCTAssertTrue(session.isPlaybackRequested)
      XCTAssertEqual(preparation.history, [.prepared(owner)])
      XCTAssertEqual(session.player.rate, completeFirst ? 1.25 : 0, accuracy: 0.01)
      if !completeFirst { try await finishPreparation(preparation, owner: owner) }
      XCTAssertTrue(session.player.currentItem === latestItem)
      XCTAssertEqual(session.player.rate, 1.25, accuracy: 0.01)
      XCTAssertEqual(preparation.history, [.prepared(owner)])
      session.pausePlayback()
      XCTAssertEqual(preparation.history, [.prepared(owner), .released(owner)])
      assertPreparationReleasedAfterPause(preparation)
    }
  }

  func testPreparationFailureStopsHoldAndRequiresExplicitRetryWithoutReloadingOrSeeking() async throws {
    let preparation = ControlledPlaybackPreparation()
    let transport = ControlledTransportSeek()
    let session = try await makeReadyPlaybackSession(
      transportSeek: transport.seek, preparation: preparation.hook, audioSeconds: 8
    )
    preparation.observe(session)
    defer { session.cleanup(); preparation.resumeAll() }
    let item = try XCTUnwrap(session.player.currentItem)
    let identity = try XCTUnwrap(session.currentSourceIdentity)
    let source = PlaybackSource(identity: identity, load: { PlaybackLoadedMedia(asset: item.asset) })
    session.handleScrubEditingChanged(true)
    session.setScrubProgress(0.4)
    session.handleScrubEditingChanged(false)
    try await waitUntil { transport.finished(0) == true }
    try transport.deliver(0)
    session.togglePlayback()
    session.handleHoldGestureStateChanged(.began, allowsHoldBoost: true)
    try await waitUntil { preparation.preparedOwners.count == 1 }
    let failedOwner = preparation.preparedOwners[0]
    try await finishPreparation(preparation, owner: failedOwner, result: .failure(PreparationTestError.denied))

    assertDeniedPreparationFailure(session)
    XCTAssertTrue(session.player.currentItem === item)
    XCTAssertTrue(session.isPlayerReady)
    XCTAssertTrue(session.isCurrentSource(identity))
    XCTAssertEqual(session.player.currentTime().seconds, 3.2, accuracy: 0.01)
    XCTAssertEqual(session.currentTimeSeconds, 3.2, accuracy: 0.01)
    XCTAssertEqual(session.player.rate, 0)
    XCTAssertFalse(session.isPlaybackRequested)
    XCTAssertNil(session.playbackRateIndicatorText)
    XCTAssertEqual(preparation.history, [.prepared(failedOwner), .released(failedOwner)])
    assertPreparationReleasedAfterPause(preparation)

    session.load(source: source, playbackRate: 0.5, isLooping: true, autoplayWhenReady: true)
    session.updatePlaybackRate(1.25)
    session.togglePlayback()
    session.handleHoldGestureStateChanged(.began, allowsHoldBoost: true)
    session.handleHoldGestureStateChanged(.ended, allowsHoldBoost: true)
    session.handleScrubEditingChanged(true)
    session.setScrubProgress(0.7)
    session.handleScrubEditingChanged(false)
    // An actor turn also lets any wrongly scheduled retry enter the controlled hook.
    await Task { @MainActor in }.value
    assertDeniedPreparationFailure(session)
    XCTAssertFalse(session.isPlaybackRequested)
    XCTAssertEqual(session.player.rate, 0)
    XCTAssertTrue(session.player.currentItem === item)
    XCTAssertEqual(session.player.currentTime().seconds, 3.2, accuracy: 0.01)
    XCTAssertEqual(transport.requests.count, 1)
    XCTAssertEqual(preparation.history, [.prepared(failedOwner), .released(failedOwner)])

    session.retryPlaybackPreparation()
    session.retryPlaybackPreparation()
    XCTAssertEqual(session.player.rate, 0)
    try await waitUntil { preparation.preparedOwners.count == 2 }
    let retryOwner = preparation.preparedOwners[1]
    XCTAssertNotEqual(retryOwner, failedOwner)
    XCTAssertTrue(session.player.currentItem === item)
    XCTAssertTrue(session.isPlayerReady)
    XCTAssertTrue(session.isCurrentSource(identity))
    XCTAssertEqual(session.player.currentTime().seconds, 3.2, accuracy: 0.01)
    XCTAssertEqual(session.currentTimeSeconds, 3.2, accuracy: 0.01)
    XCTAssertEqual(transport.requests.count, 1, "Audio retry must not seek or reload media")
    try await finishPreparation(preparation, owner: retryOwner)
    XCTAssertNil(session.failure)
    XCTAssertNotEqual(session.status, .unavailable)
    XCTAssertTrue(session.isPlaybackRequested)
    XCTAssertTrue(session.player.currentItem === item)
    XCTAssertEqual(session.player.rate, 1.25, accuracy: 0.01, "Failure must clear the old hold boost")
    session.pausePlayback()
    XCTAssertEqual(preparation.history, [
      .prepared(failedOwner), .released(failedOwner), .prepared(retryOwner), .released(retryOwner)
    ])
    assertPreparationReleasedAfterPause(preparation)
  }

  func testPreparationFailureSurvivesSameSourceResourceRetryUntilExplicitPreparationRetry() async throws {
    let preparation = ControlledPlaybackPreparation()
    let session = try await makeReadyPlaybackSession(
      preparation: preparation.hook, audioSeconds: 8
    )
    preparation.observe(session)
    defer { session.cleanup(); preparation.resumeAll() }
    let original = try XCTUnwrap(session.player.currentItem)
    let identity = try XCTUnwrap(session.currentSourceIdentity)
    var loadCount = 0
    let source = PlaybackSource(identity: identity, load: {
      loadCount += 1
      return PlaybackLoadedMedia(asset: original.asset)
    })
    session.togglePlayback()
    try await waitUntil { preparation.preparedOwners.count == 1 }
    let failedOwner = preparation.preparedOwners[0]
    try await finishPreparation(preparation, owner: failedOwner, result: .failure(PreparationTestError.denied))
    assertDeniedPreparationFailure(session)

    session.retry(source: source, playbackRate: 0.75, isLooping: true, autoplayWhenReady: true)
    assertDeniedPreparationFailure(session)
    XCTAssertFalse(session.isPlaybackRequested)
    XCTAssertEqual(session.player.rate, 0)
    try await waitUntil { loadCount == 1 && session.isPlayerReady && session.player.currentItem !== original }
    let reloadedItem = try XCTUnwrap(session.player.currentItem)
    XCTAssertTrue(session.isCurrentSource(identity))
    XCTAssertEqual(reloadedItem.status, .readyToPlay)
    assertDeniedPreparationFailure(session)
    XCTAssertFalse(session.isPlaybackRequested)
    XCTAssertEqual(session.player.rate, 0)
    XCTAssertEqual(preparation.history, [.prepared(failedOwner), .released(failedOwner)])

    session.load(source: source, playbackRate: 1.25, isLooping: true, autoplayWhenReady: true)
    await Task { @MainActor in }.value
    XCTAssertEqual(loadCount, 1)
    XCTAssertTrue(session.player.currentItem === reloadedItem)
    assertDeniedPreparationFailure(session)
    XCTAssertFalse(session.isPlaybackRequested)
    XCTAssertEqual(session.player.rate, 0)
    XCTAssertEqual(preparation.history, [.prepared(failedOwner), .released(failedOwner)])

    session.retryPlaybackPreparation()
    try await waitUntil { preparation.preparedOwners.count == 2 }
    let retryOwner = preparation.preparedOwners[1]
    XCTAssertNotEqual(retryOwner, failedOwner)
    XCTAssertEqual(loadCount, 1, "Explicit preparation retry must reuse the reloaded ready item")
    XCTAssertTrue(session.player.currentItem === reloadedItem)
    XCTAssertEqual(session.player.rate, 0)
    try await finishPreparation(preparation, owner: retryOwner)
    XCTAssertNil(session.failure)
    XCTAssertNotEqual(session.status, .unavailable)
    XCTAssertTrue(session.isPlaybackRequested)
    XCTAssertEqual(session.player.rate, 1.25, accuracy: 0.01)
    session.pausePlayback()
    XCTAssertEqual(preparation.history, [
      .prepared(failedOwner), .released(failedOwner), .prepared(retryOwner), .released(retryOwner)
    ])
    assertPreparationReleasedAfterPause(preparation)
  }

  func testPreparationFailureReleaseReentryCannotOverwriteCleanupOrNewSource() async throws {
    for cleanup in [false, true] {
      let preparation = ControlledPlaybackPreparation()
      let session = try await makeReadyPlaybackSession(
        preparation: preparation.hook, audioSeconds: 8
      )
      preparation.observe(session)
      defer { session.cleanup(); preparation.resumeAll() }
      let original = try XCTUnwrap(session.player.currentItem)
      let sourceB = PlaybackSource(identity: UUID(), load: { PlaybackLoadedMedia(asset: original.asset) })
      var callbackOwners: [UUID] = []
      preparation.onRelease = { [weak session] owner in
        callbackOwners.append(owner)
        if let session {
          self.assertDeniedPreparationFailure(session)
          XCTAssertFalse(session.isPlaybackRequested)
          XCTAssertEqual(session.player.rate, 0)
          if cleanup { session.cleanup() }
          else {
            session.load(source: sourceB, playbackRate: 1.25, isLooping: true, autoplayWhenReady: true)
          }
        }
      }
      session.togglePlayback()
      try await waitUntil { preparation.preparedOwners.count == 1 }
      let failedOwner = preparation.preparedOwners[0]
      try await finishPreparation(preparation, owner: failedOwner, result: .failure(PreparationTestError.denied))
      XCTAssertEqual(callbackOwners, [failedOwner])
      XCTAssertNil(session.failure, "Old preparation failure must be published before the release callback")

      if cleanup {
        XCTAssertFalse(session.hasCurrentItem)
        XCTAssertFalse(session.hasActivePlayerObservers)
        XCTAssertFalse(session.isPlayerReady)
        XCTAssertFalse(session.isPlaybackRequested)
        XCTAssertNil(session.currentSourceIdentity)
        XCTAssertEqual(session.status, .none)
        XCTAssertEqual(session.player.rate, 0)
        XCTAssertEqual(preparation.history, [.prepared(failedOwner), .released(failedOwner)])
      } else {
        try await waitUntil { session.isPlayerReady && preparation.preparedOwners.count == 2 }
        let ownerB = preparation.preparedOwners[1]
        XCTAssertNotEqual(ownerB, failedOwner)
        XCTAssertTrue(session.isCurrentSource(sourceB.identity))
        XCTAssertFalse(session.player.currentItem === original)
        XCTAssertTrue(session.isPlaybackRequested)
        XCTAssertEqual(session.player.rate, 0)
        XCTAssertNil(session.failure)
        XCTAssertNotEqual(session.status, .unavailable)
        XCTAssertEqual(preparation.history, [.prepared(failedOwner), .released(failedOwner), .prepared(ownerB)])
        try await finishPreparation(preparation, owner: ownerB)
        XCTAssertEqual(session.player.rate, 1.25, accuracy: 0.01)
        XCTAssertNil(session.failure)
        session.pausePlayback()
        XCTAssertEqual(preparation.history, [
          .prepared(failedOwner), .released(failedOwner), .prepared(ownerB), .released(ownerB)
        ])
      }
      XCTAssertEqual(callbackOwners, [failedOwner], "The release reentry hook runs once")
      assertPreparationReleasedAfterPause(preparation)
    }
  }

  func testPreparationFailureSurvivesSuccessfulPhotosAccessRevalidationWithoutAutoplay() async throws {
    let preparation = ControlledPlaybackPreparation()
    let transport = ControlledTransportSeek()
    let session = try await makeReadyPlaybackSession(
      transportSeek: transport.seek, preparation: preparation.hook, audioSeconds: 8
    )
    preparation.observe(session)
    defer { session.cleanup(); preparation.resumeAll() }
    let item = try XCTUnwrap(session.player.currentItem)
    let identity = try XCTUnwrap(session.currentSourceIdentity)
    let source = PlaybackSource(identity: identity, load: { PlaybackLoadedMedia(asset: item.asset) })
    session.handleScrubEditingChanged(true)
    session.setScrubProgress(0.4)
    session.handleScrubEditingChanged(false)
    try await waitUntil { transport.finished(0) == true }
    try transport.deliver(0)
    session.togglePlayback()
    try await waitUntil { preparation.preparedOwners.count == 1 }
    let owner = preparation.preparedOwners[0]
    try await finishPreparation(preparation, owner: owner, result: .failure(PreparationTestError.denied))
    assertDeniedPreparationFailure(session)

    var validationContinuation: CheckedContinuation<AVAsset, any Error>?
    defer { validationContinuation?.resume(throwing: CancellationError()) }
    session.revalidateAccess(source: source, refreshID: 1) {
      .validate {
        PlaybackLoadedMedia(asset: try await withCheckedThrowingContinuation { validationContinuation = $0 })
      }
    }
    try await waitUntil { validationContinuation != nil }
    XCTAssertFalse(session.hasCurrentItem)
    XCTAssertFalse(session.isPlaybackRequested)
    XCTAssertEqual(session.player.rate, 0)
    assertDeniedPreparationFailure(session)
    let continuation = try XCTUnwrap(validationContinuation)
    validationContinuation = nil
    continuation.resume(returning: item.asset)
    try await waitUntil { transport.finished(1) == true }
    XCTAssertEqual(transport.requests[1].target.seconds, 3.2, accuracy: 0.01)
    try transport.deliver(1)
    try await waitUntil { session.isPlayerReady }

    XCTAssertTrue(session.player.currentItem === item)
    XCTAssertTrue(session.isCurrentSource(identity))
    XCTAssertEqual(session.player.currentTime().seconds, 3.2, accuracy: 0.01)
    XCTAssertEqual(session.currentTimeSeconds, 3.2, accuracy: 0.01)
    XCTAssertFalse(session.isPlaybackRequested)
    XCTAssertEqual(session.player.rate, 0)
    assertDeniedPreparationFailure(session)
    XCTAssertEqual(preparation.history, [.prepared(owner), .released(owner)])
    assertPreparationReleasedAfterPause(preparation)
  }

  func testPreparationPendingTaskDoesNotRetainOwnerAndDeinitCancelsAndReleases() async throws {
    let preparation = ControlledPlaybackPreparation()
    let url = try temporaryPlayableAudioURL(seconds: 8)
    // Do not use the ready-session helper: its teardown intentionally retains its session.
    var session: PlaybackSession? = PlaybackSession()
    weak var weakSession = session
    let player = try XCTUnwrap(session?.player)
    session?.preparation = preparation.hook
    preparation.observe(try XCTUnwrap(session))
    session?.load(source: PlaybackSource(identity: UUID(), load: { PlaybackLoadedMedia(asset: AVURLAsset(url: url)) }),
      playbackRate: 1, isLooping: true, autoplayWhenReady: false)
    defer { session?.cleanup(); preparation.resumeAll() }
    try await waitUntil { session?.isPlayerReady == true }
    session?.togglePlayback()
    try await waitUntil { preparation.preparedOwners.count == 1 }
    let owner = preparation.preparedOwners[0]
    XCTAssertEqual(player.rate, 0)

    session = nil
    XCTAssertNil(weakSession, "The preparation await must not strongly retain its owner")
    try await waitUntil { preparation.cancelledOwners == [owner] }
    XCTAssertNil(player.currentItem)
    XCTAssertEqual(player.rate, 0)
    XCTAssertEqual(preparation.history, [.prepared(owner), .released(owner)])
    let release = try XCTUnwrap(preparation.releases.first)
    XCTAssertEqual(release.rate, 0)
    // Weak references have already become nil inside deinit; no live owner can retain intent.
    XCTAssertNil(release.isPlaybackRequested)
    try await finishPreparation(preparation, owner: owner)
    XCTAssertNil(weakSession)
    XCTAssertNil(player.currentItem)
    XCTAssertEqual(player.rate, 0)
    XCTAssertEqual(preparation.history, [.prepared(owner), .released(owner)])
  }

  func testNilPreparationPreservesNativePlaybackAndPauseKeepsReadyMedia() async throws {
    let session = try await makeReadyPlaybackSession(audioSeconds: 8)
    let item = try XCTUnwrap(session.player.currentItem)
    let identity = session.currentSourceIdentity
    XCTAssertNil(session.preparation)
    session.togglePlayback()
    XCTAssertEqual(session.player.rate, 1, accuracy: 0.01)
    session.handleHoldGestureStateChanged(.began, allowsHoldBoost: true)
    XCTAssertEqual(session.player.rate, 2, accuracy: 0.01)
    session.pausePlayback()
    let time = session.player.currentTime().seconds
    XCTAssertFalse(session.isPlaybackRequested)
    XCTAssertEqual(session.player.rate, 0)
    XCTAssertNil(session.playbackRateIndicatorText)
    XCTAssertTrue(session.isPlayerReady)
    XCTAssertTrue(session.player.currentItem === item)
    XCTAssertEqual(session.currentSourceIdentity, identity)
    session.retryPlaybackPreparation()
    XCTAssertFalse(session.isPlaybackRequested)
    XCTAssertEqual(session.player.rate, 0)
    XCTAssertEqual(session.player.currentTime().seconds, time, accuracy: 0.01)
    XCTAssertNil(session.failure)
  }

  func testSameSourceLoadAppliesLatestRateToPlayingAndHoldingTransport() async throws {
    let url = try temporaryPlayableAudioURL()
    let source = PlaybackSource(identity: url, load: { PlaybackLoadedMedia(asset: AVURLAsset(url: url)) })
    let session = PlaybackSession()
    defer { session.cleanup() }
    session.load(source: source, playbackRate: 1, isLooping: true, autoplayWhenReady: true)
    try await waitUntil { session.isPlayerReady && session.player.rate > 0 }
    let original = try XCTUnwrap(session.player.currentItem)

    session.load(source: source, playbackRate: 0.5, isLooping: true, autoplayWhenReady: false)
    XCTAssertTrue(session.player.currentItem === original)
    XCTAssertTrue(session.isPlaybackRequested)
    XCTAssertEqual(session.player.rate, 0.5, accuracy: 0.01)

    session.handleHoldGestureStateChanged(.began, allowsHoldBoost: true)
    session.load(source: source, playbackRate: 1.25, isLooping: true, autoplayWhenReady: false)
    XCTAssertTrue(session.player.currentItem === original)
    XCTAssertEqual(session.player.rate, 2.5, accuracy: 0.01)
    session.cancelHold()
    XCTAssertEqual(session.player.rate, 1.25, accuracy: 0.01)
  }

  func testPlaybackControlIntentAndToggleAgreeDuringPendingRestart() async throws {
    let transport = ControlledTransportSeek()
    let session = try await makeReadyPlaybackSession(transportSeek: transport.seek)
    try await movePlaybackToEnd(session, transport: transport)
    session.togglePlayback()
    XCTAssertTrue(session.isPlaybackRequested)
    XCTAssertFalse(isPlaying(session))
    try await waitUntil { transport.finished(1) == true }
    session.togglePlayback()
    try transport.deliver(1)
    XCTAssertFalse(isPlaying(session))
    XCTAssertFalse(session.isPlaybackRequested)
  }

  func testPlaybackControlIntentAndToggleAgreeForPausedOriginHold() async throws {
    let session = try await makeReadyPlaybackSession()

    session.handleHoldGestureStateChanged(.began, allowsHoldBoost: true)
    try await waitUntil { isPlaying(session) }
    XCTAssertTrue(session.isPlaybackRequested)

    session.togglePlayback()
    try await waitUntil { !isPlaying(session) }

    XCTAssertFalse(session.isPlaybackRequested)
  }

  func testPlaybackEndSettlesSynchronouslyBeforeFollowingToggle() async throws {
    let session = try await makeReadyPlaybackSession()
    session.togglePlayback()
    try await waitUntil { isPlaying(session) }
    let item = try XCTUnwrap(session.player.currentItem)
    session.player.pause()
    try await seekPlayerToEnd(session)

    NotificationCenter.default.post(
      name: .AVPlayerItemDidPlayToEndTime,
      object: item
    )
    XCTAssertFalse(session.isPlaybackRequested)

    session.togglePlayback()

    XCTAssertTrue(session.isPlaybackRequested)
    try await waitUntil { isPlaying(session) }
  }

  func testStalePlaybackEndCannotOverrideCurrentRestart() async throws {
    let transport = ControlledTransportSeek()
    let session = try await makeReadyPlaybackSession(transportSeek: transport.seek)
    try await movePlaybackToEnd(session, transport: transport)
    let item = try XCTUnwrap(session.player.currentItem)
    session.togglePlayback()
    NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: item)
    XCTAssertTrue(session.isPlaybackRequested)
    try await waitUntil { transport.finished(1) == true }
    try transport.deliver(1)
    XCTAssertTrue(isPlaying(session))
    XCTAssertEqual(session.displayedProgress, 0)
  }

  func testPlaybackEndArrivingAfterRestartCompletionCannotOverrideRestart() async throws {
    let transport = ControlledTransportSeek()
    let session = try await makeReadyPlaybackSession(transportSeek: transport.seek)
    try await movePlaybackToEnd(session, transport: transport)
    let item = try XCTUnwrap(session.player.currentItem)
    session.togglePlayback()
    try await waitUntil { transport.finished(1) == true }
    try transport.deliver(1)
    NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: item)
    XCTAssertTrue(session.isPlaybackRequested)
    XCTAssertTrue(isPlaying(session))
    XCTAssertEqual(session.displayedProgress, 0)
  }

  func testLoopSettingChangeDoesNotRewriteCommittedRestart() async throws {
    let transport = ControlledTransportSeek()
    let session = try await makeReadyPlaybackSession(transportSeek: transport.seek)
    session.updateLooping(true)
    try await movePlaybackToEnd(session, transport: transport)
    session.togglePlayback()
    session.updateLooping(false)
    try await waitUntil { transport.finished(1) == true }
    try transport.deliver(1)
    XCTAssertTrue(isPlaying(session))
    XCTAssertEqual(session.displayedProgress, 0)
    let item = try XCTUnwrap(session.player.currentItem)
    session.player.pause()
    try await seekPlayerToEnd(session)
    NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: item)
    XCTAssertFalse(session.isPlaybackRequested)
    XCTAssertEqual(session.displayedProgress, 1, accuracy: 0.001)
  }

  func testPendingRestartTransfersToHoldAndUsesLatestRates() async throws {
    let transport = ControlledTransportSeek()
    let session = try await makeReadyPlaybackSession(transportSeek: transport.seek)
    try await movePlaybackToEnd(session, transport: transport)
    session.togglePlayback()
    session.handleHoldGestureStateChanged(.began, allowsHoldBoost: true)
    try await waitUntil { transport.finished(1) == true }
    XCTAssertFalse(isPlaying(session))
    try transport.deliver(1)
    XCTAssertEqual(session.player.rate, 2, accuracy: 0.01)
    session.updatePlaybackRate(1.25)
    XCTAssertEqual(session.player.rate, 2.5, accuracy: 0.01)
    session.handleHoldGestureStateChanged(.ended, allowsHoldBoost: true)
    XCTAssertEqual(session.player.rate, 1.25, accuracy: 0.01)
    XCTAssertTrue(session.isPlaybackRequested)
  }

  func testSecondScrubInheritsPlayingIntentAndSupersedesFirstTarget() async throws {
    let transport = ControlledTransportSeek()
    let session = try await makeReadyPlaybackSession(transportSeek: transport.seek)
    session.togglePlayback()
    try await waitUntil { isPlaying(session) }
    session.handleScrubEditingChanged(true)
    session.setScrubProgress(0.3)
    session.handleScrubEditingChanged(false)
    try await waitUntil { transport.finished(0) == true }
    session.handleScrubEditingChanged(true)
    session.setScrubProgress(0.7)
    session.handleScrubEditingChanged(false)
    try await waitUntil { transport.finished(1) == true }
    XCTAssertEqual(transport.requests[0].target.seconds, 0.3, accuracy: 0.001)
    XCTAssertEqual(transport.requests[1].target.seconds, 0.7, accuracy: 0.001)
    try transport.deliver(0)
    XCTAssertFalse(isPlaying(session))
    XCTAssertEqual(session.displayedProgress, 0.7, accuracy: 0.001)
    try transport.deliver(1)
    XCTAssertTrue(isPlaying(session))
    XCTAssertTrue(session.isPlaybackRequested)
    XCTAssertEqual(session.displayedProgress, 0.7, accuracy: 0.001)
  }

  func testPendingScrubTargetSettlesAtBoostRateWhenHoldBegins() async throws {
    let transport = ControlledTransportSeek()
    let session = try await makeReadyPlaybackSession(transportSeek: transport.seek)
    session.togglePlayback()
    try await waitUntil { isPlaying(session) }
    session.handleScrubEditingChanged(true)
    session.setScrubProgress(0.6)
    session.handleScrubEditingChanged(false)
    session.handleHoldGestureStateChanged(.began, allowsHoldBoost: true)
    try await waitUntil { transport.finished(0) == true }
    XCTAssertEqual(transport.requests[0].target.seconds, 0.6, accuracy: 0.001)
    XCTAssertFalse(isPlaying(session))
    try transport.deliver(0)
    XCTAssertEqual(session.displayedProgress, 0.6, accuracy: 0.001)
    XCTAssertEqual(session.player.rate, 2, accuracy: 0.01)
    session.handleHoldGestureStateChanged(.ended, allowsHoldBoost: true)
    XCTAssertEqual(session.player.rate, 1, accuracy: 0.01)
    XCTAssertTrue(session.isPlaybackRequested)
  }

  func testLoopRestartWhileHoldingKeepsBoostAndLatestRate() async throws {
    let transport = ControlledTransportSeek()
    let session = try await makeReadyPlaybackSession(transportSeek: transport.seek)
    session.updateLooping(true)
    session.togglePlayback()
    try await waitUntil { isPlaying(session) }
    session.handleHoldGestureStateChanged(.began, allowsHoldBoost: true)
    XCTAssertEqual(session.player.rate, 2, accuracy: 0.01)
    let item = try XCTUnwrap(session.player.currentItem)
    session.player.pause()
    try await seekPlayerToEnd(session)
    NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: item)
    try await waitUntil { transport.finished(0) == true }
    XCTAssertEqual(transport.requests[0].target, .zero)
    try transport.deliver(0)
    XCTAssertEqual(session.displayedProgress, 0)
    XCTAssertEqual(session.player.rate, 2, accuracy: 0.01)
    session.updatePlaybackRate(1.25)
    XCTAssertEqual(session.player.rate, 2.5, accuracy: 0.01)
    session.handleHoldGestureStateChanged(.ended, allowsHoldBoost: true)
    XCTAssertEqual(session.player.rate, 1.25, accuracy: 0.01)
    XCTAssertTrue(session.isPlaybackRequested)
  }

  func testCleanupInvalidatesPendingRestartCompletion() async throws {
    let transport = ControlledTransportSeek()
    let session = try await makeReadyPlaybackSession(transportSeek: transport.seek)
    try await movePlaybackToEnd(session, transport: transport)
    session.togglePlayback()
    try await waitUntil { transport.finished(1) == true }
    session.cleanup()
    try transport.deliver(1)
    XCTAssertFalse(session.hasCurrentItem)
    XCTAssertFalse(session.hasActivePlayerObservers)
    XCTAssertFalse(session.isPlaybackRequested)
    XCTAssertFalse(session.isPlayerReady)
    XCTAssertEqual(session.player.rate, 0)
    XCTAssertEqual(session.displayedProgress, 0)
    XCTAssertEqual(session.currentTimeSeconds, 0)
  }

  func testCleanupDoesNotPublishPositionFromLateSuccessfulScrub() async throws {
    let transport = ControlledTransportSeek()
    let session = try await makeReadyPlaybackSession(transportSeek: transport.seek)
    session.handleScrubEditingChanged(true)
    session.setScrubProgress(0.6)
    session.handleScrubEditingChanged(false)
    try await waitUntil { transport.finished(0) == true }
    session.cleanup()
    try transport.deliver(0)
    XCTAssertFalse(session.hasCurrentItem)
    XCTAssertFalse(session.isPlaybackRequested)
    XCTAssertEqual(session.currentTimeSeconds, 0)
    XCTAssertEqual(session.displayedProgress, 0)
    XCTAssertEqual(session.player.rate, 0)
  }

  func testVideoSeekUsesFiniteToleranceOnlyWhileScrubbing() {
    let interactiveTolerance = VideoSeekPrecision.interactive.tolerance.seconds

    XCTAssertTrue(interactiveTolerance.isFinite)
    XCTAssertGreaterThan(interactiveTolerance, 0)
    XCTAssertLessThanOrEqual(interactiveTolerance, 0.05)
    XCTAssertEqual(VideoSeekPrecision.exact.tolerance, .zero)
  }

  func testVideoSeekSchedulerKeepsOnlyLatestForwardTarget() {
    var scheduler = VideoSeekScheduler()
    let first = videoSeekRequest(seconds: 1)
    let superseded = videoSeekRequest(seconds: 2)
    let latest = videoSeekRequest(seconds: 3)

    XCTAssertEqual(scheduler.submit(first), first)
    XCTAssertNil(scheduler.submit(superseded))
    XCTAssertNil(scheduler.submit(latest))
    XCTAssertEqual(scheduler.pending, latest)
    XCTAssertEqual(scheduler.complete(first), latest)
    XCTAssertEqual(scheduler.inFlight, latest)
    XCTAssertNil(scheduler.pending)
  }

  func testVideoSeekSchedulerKeepsOnlyLatestReverseTarget() {
    var scheduler = VideoSeekScheduler()
    let first = videoSeekRequest(seconds: 3)
    let superseded = videoSeekRequest(seconds: 2)
    let latest = videoSeekRequest(seconds: 1)

    XCTAssertEqual(scheduler.submit(first), first)
    XCTAssertNil(scheduler.submit(superseded))
    XCTAssertNil(scheduler.submit(latest))
    XCTAssertEqual(scheduler.pending, latest)
    XCTAssertEqual(scheduler.complete(first), latest)
    XCTAssertEqual(scheduler.inFlight, latest)
    XCTAssertNil(scheduler.pending)
  }

  func testVideoSeekSchedulerExactReleaseSupersedesInteractiveTarget() {
    var scheduler = VideoSeekScheduler()
    let inFlight = videoSeekRequest(seconds: 1)
    let superseded = videoSeekRequest(seconds: 2)
    let exact = videoSeekRequest(seconds: 1, precision: .exact)

    XCTAssertEqual(scheduler.submit(inFlight), inFlight)
    XCTAssertNil(scheduler.submit(superseded))
    XCTAssertNil(scheduler.submit(exact))
    XCTAssertEqual(scheduler.complete(inFlight), exact)
  }

  func testVideoSeekSchedulerResetRejectsLateCompletion() {
    var scheduler = VideoSeekScheduler()
    let request = videoSeekRequest(seconds: 2)

    XCTAssertEqual(scheduler.submit(request), request)
    scheduler.reset()

    XCTAssertNil(scheduler.complete(request))
    XCTAssertNil(scheduler.inFlight)
    XCTAssertNil(scheduler.pending)
  }

  private func assertDeniedPreparationFailure(
    _ session: PlaybackSession,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertEqual(session.status, .unavailable, file: file, line: line)
    guard case .preparation(let error) = session.failure,
      let reason = error as? PreparationTestError, case .denied = reason
    else {
      return XCTFail("Expected the original typed preparation error", file: file, line: line)
    }
  }

  private func finishPreparation(
    _ preparation: ControlledPlaybackPreparation,
    owner: UUID,
    result: Result<Void, any Error> = .success(())
  ) async throws {
    try preparation.resume(owner, with: result)
    try await waitUntil { preparation.returnedOwners.contains(owner) }
  }

  private func assertPreparationReleasedAfterPause(
    _ preparation: ControlledPlaybackPreparation,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertFalse(preparation.releases.isEmpty, file: file, line: line)
    for release in preparation.releases {
      XCTAssertEqual(release.rate, 0, "Release must observe paused native transport", file: file, line: line)
      XCTAssertEqual(release.isPlaybackRequested, false, "Release must observe ended intent and hold", file: file, line: line)
    }
  }

  private func isPlaying(_ session: PlaybackSession) -> Bool {
    session.player.rate > 0
  }

  private func waitUntil(
    _ condition: @MainActor () -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async throws {
    for _ in 0..<400 {
      if condition() { return }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    throw PlaybackTestFailure(description: "Condition did not become true at \(file):\(line)")
  }

  private func videoSeekRequest(
    seconds: Double,
    precision: VideoSeekPrecision = .interactive
  ) -> VideoSeekRequest {
    VideoSeekRequest(
      time: CMTime(seconds: seconds, preferredTimescale: 600),
      precision: precision
    )
  }

  private func movePlaybackToEnd(
    _ session: PlaybackSession,
    transport: ControlledTransportSeek
  ) async throws {
    let index = transport.requests.count
    session.handleScrubEditingChanged(true)
    session.setScrubProgress(1)
    session.handleScrubEditingChanged(false)
    try await waitUntil { transport.finished(index) == true }
    try transport.deliver(index)
    XCTAssertFalse(isPlaying(session))
    XCTAssertEqual(session.displayedProgress, 1)
  }

  private func seekPlayerToEnd(_ session: PlaybackSession) async throws {
    let target = CMTime(
      seconds: session.durationSeconds,
      preferredTimescale: CMTimeScale(NSEC_PER_SEC)
    )
    let finished = await withCheckedContinuation { continuation in
      session.player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) {
        continuation.resume(returning: $0)
      }
    }
    guard finished else { throw PlaybackTestFailure(description: "Seek to end was cancelled") }
  }

  private func temporaryPlayableAudioURL(seconds: Double = 1) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(UUID().uuidString).caf")
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }

    let sampleRate = 44_100.0
    let format = try XCTUnwrap(
      AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
    )
    let frameCount = AVAudioFrameCount(sampleRate * seconds)
    let buffer = try XCTUnwrap(
      AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
    )
    buffer.frameLength = frameCount
    buffer.floatChannelData?[0].update(repeating: 0, count: Int(frameCount))

    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
    return url
  }

  private func makeReadyPlaybackSession(
    transportSeek: @escaping PlaybackSession.TransportSeek = PlaybackSession.seekTransport,
    preparation: PlaybackPreparation? = nil,
    audioSeconds: Double = 1
  ) async throws -> PlaybackSession {
    let url = try temporaryPlayableAudioURL(seconds: audioSeconds)
    let session = PlaybackSession(transportSeek: transportSeek)
    session.preparation = preparation
    addTeardownBlock { @MainActor in session.cleanup() }
    session.load(source: PlaybackSource(identity: UUID(), load: { PlaybackLoadedMedia(asset: AVURLAsset(url: url)) }),
      playbackRate: 1, isLooping: false, autoplayWhenReady: false)
    try await waitUntil { session.isPlayerReady && session.durationSeconds > 0 }
    return session
  }
}

private struct PlaybackTestFailure: Error, CustomStringConvertible {
  let description: String
}

private enum PreparationTestError: Error { case denied }

/// Cancellation is recorded but deliberately does not resume the continuation.
/// Tests choose when even a cancelled preparation returns, exposing stale-result bugs.
@MainActor
private final class ControlledPlaybackPreparation {
  enum Event: Equatable {
    case prepared(UUID)
    case released(UUID)
  }

  struct Release {
    let owner: UUID
    let rate: Float?
    let isPlaybackRequested: Bool?
  }

  private weak var session: PlaybackSession?
  private var player: AVPlayer?
  private var continuations: [UUID: CheckedContinuation<Void, any Error>] = [:]
  private(set) var preparedOwners: [UUID] = []
  private(set) var cancelledOwners: [UUID] = []
  private(set) var returnedOwners: [UUID] = []
  private(set) var releases: [Release] = []
  private(set) var history: [Event] = []
  var onRelease: (@MainActor (UUID) -> Void)?

  var hook: PlaybackPreparation {
    PlaybackPreparation(prepare: prepare, release: release)
  }

  func observe(_ session: PlaybackSession) {
    self.session = session
    player = session.player
  }

  private func prepare(_ owner: UUID) async throws {
    preparedOwners.append(owner)
    history.append(.prepared(owner))
    defer { returnedOwners.append(owner) }
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        guard continuations[owner] == nil else {
          XCTFail("One invocation per preparation owner")
          continuation.resume(throwing: PreparationTestError.denied)
          return
        }
        continuations[owner] = continuation
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.cancelledOwners.append(owner) }
    }
  }

  private func release(_ owner: UUID) {
    history.append(.released(owner))
    releases.append(Release(
      owner: owner, rate: player?.rate, isPlaybackRequested: session?.isPlaybackRequested
    ))
    let callback = onRelease
    onRelease = nil
    callback?(owner)
  }

  func resume(_ owner: UUID, with result: Result<Void, any Error>) throws {
    let continuation = try XCTUnwrap(continuations.removeValue(forKey: owner))
    continuation.resume(with: result)
  }

  func resumeAll() {
    let pending = continuations.values
    continuations.removeAll()
    for continuation in pending { continuation.resume(throwing: CancellationError()) }
  }
}

@MainActor
private final class ControlledTransportSeek {
  struct Request {
    let target: CMTime
    let completion: @MainActor (Bool) -> Void
    var finished: Bool?
  }

  private(set) var requests: [Request] = []

  func seek(player: AVPlayer, target: CMTime, completion: @escaping @MainActor (Bool) -> Void) {
    let index = requests.count
    requests.append(Request(target: target, completion: completion))
    PlaybackSession.seekTransport(player: player, target: target) { [weak self] finished in
      self?.requests[index].finished = finished
    }
  }

  func finished(_ index: Int) -> Bool? {
    guard requests.indices.contains(index) else { return nil }
    return requests[index].finished
  }

  func deliver(_ index: Int) throws {
    let request = try XCTUnwrap(requests.indices.contains(index) ? requests[index] : nil)
    let finished = try XCTUnwrap(request.finished)
    request.completion(finished)
  }
}
