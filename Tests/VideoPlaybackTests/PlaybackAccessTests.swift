import AVFoundation
import XCTest
@testable import VideoPlayback

@MainActor
final class PlaybackAccessTests: XCTestCase {
  func testPlayBeforeAcquisitionCanBeCancelledAndRequestedAgain() async throws {
    let asset = try audioAsset()
    let loader = SuspendedAssetOperation()
    let session = PlaybackSession()
    defer { session.cleanup(); loader.finish(asset) }
    session.load(source: PlaybackSource(identity: UUID(), load: loader.load),
      playbackRate: 1, isLooping: false, autoplayWhenReady: false)
    try await wait { loader.started }
    XCTAssertNil(session.player.currentItem)
    XCTAssertFalse(session.isPlaybackRequested)
    XCTAssertTrue(session.canTogglePlayback)
    XCTAssertFalse(session.isWaitingForPlayback)

    session.togglePlayback()
    XCTAssertTrue(session.isPlaybackRequested, "Play must be accepted while acquiring the source")
    XCTAssertTrue(session.isWaitingForPlayback)
    XCTAssertEqual(session.player.rate, 0)
    session.togglePlayback()
    XCTAssertFalse(session.isPlaybackRequested, "A second tap cancels the waiting playback")
    XCTAssertFalse(session.isWaitingForPlayback)
    session.togglePlayback()
    XCTAssertTrue(session.isPlaybackRequested)
    loader.finish(asset)
    try await wait { session.isPlayerReady }
    XCTAssertTrue(session.isPlaybackRequested)
    XCTAssertGreaterThan(session.player.rate, 0)
  }

  func testCancelledAcquisitionPlayKeepsPreparingWithoutLateAutoplay() async throws {
    let asset = try audioAsset()
    let loader = SuspendedAssetOperation()
    let session = PlaybackSession()
    defer { session.cleanup(); loader.finish(asset) }
    session.load(source: PlaybackSource(identity: UUID(), load: loader.load),
      playbackRate: 1, isLooping: false, autoplayWhenReady: false)
    try await wait { loader.started }
    session.togglePlayback()
    XCTAssertTrue(session.isPlaybackRequested)
    session.togglePlayback()
    loader.finish(asset)
    try await wait { session.isPlayerReady }
    XCTAssertFalse(session.isPlaybackRequested)
    XCTAssertEqual(session.player.rate, 0)
    XCTAssertNil(session.failure)
    XCTAssertFalse(loader.cancelled, "Cancelling Play must not discard background preparation")
  }

  func testWaitingPlayCleanupRejectsLateAcquisition() async throws {
    let asset = try audioAsset()
    let loader = SuspendedAssetOperation()
    let session = PlaybackSession()
    defer { session.cleanup(); loader.finish(asset) }
    session.load(source: PlaybackSource(identity: UUID(), load: loader.load),
      playbackRate: 1, isLooping: false, autoplayWhenReady: false)
    try await wait { loader.started }
    session.togglePlayback()
    XCTAssertTrue(session.isPlaybackRequested)
    session.cleanup()
    try await wait { loader.cancelled }
    loader.finish(asset)
    await Task { @MainActor in }.value
    XCTAssertNil(session.currentSourceIdentity)
    XCTAssertNil(session.player.currentItem)
    XCTAssertFalse(session.isPlaybackRequested)
    XCTAssertFalse(session.canTogglePlayback)
    XCTAssertFalse(session.isWaitingForPlayback)
    XCTAssertNil(session.failure)
  }

  func testWaitingPlaySourceSwitchDropsIntentAndRejectsOldAcquisition() async throws {
    let asset = try audioAsset()
    let first = SuspendedAssetOperation()
    let next = SuspendedAssetOperation()
    let session = PlaybackSession()
    defer { session.cleanup(); first.finish(asset); next.finish(asset) }
    session.load(source: PlaybackSource(identity: UUID(), load: first.load),
      playbackRate: 1, isLooping: false, autoplayWhenReady: false)
    try await wait { first.started }
    session.togglePlayback()
    XCTAssertTrue(session.isPlaybackRequested)
    let nextIdentity = UUID()
    session.load(source: PlaybackSource(identity: nextIdentity, load: next.load),
      playbackRate: 1, isLooping: false, autoplayWhenReady: false)
    try await wait { next.started && first.cancelled }
    first.finish(asset)
    await Task { @MainActor in }.value
    XCTAssertTrue(session.isCurrentSource(nextIdentity))
    XCTAssertNil(session.player.currentItem)
    XCTAssertFalse(session.isPlaybackRequested)
    XCTAssertFalse(session.isWaitingForPlayback)
    next.finish(asset)
    try await wait { session.isPlayerReady }
    XCTAssertFalse(session.isPlaybackRequested)
    XCTAssertEqual(session.player.rate, 0)
    XCTAssertNil(session.failure)
  }

  func testAutoplayRequestAtEndWhileAccessIsPendingRestartsPlayback() async throws {
    let (session, source, asset) = try await readySession()
    let validator = SuspendedAssetOperation()
    defer { session.cleanup(); validator.finish(asset) }
    try await wait { session.durationSeconds > 0 }
    let original = try XCTUnwrap(session.player.currentItem)
    session.handleScrubEditingChanged(true)
    session.setScrubProgress(1)
    session.handleScrubEditingChanged(false)
    try await wait { abs(session.player.currentTime().seconds - session.durationSeconds) < 0.01 }
    session.revalidateAccess(source: source, refreshID: 1) { .validate(validator.load) }
    try await wait { validator.started }

    session.load(source: source, playbackRate: 1, isLooping: false, autoplayWhenReady: true)
    validator.finish(asset)
    try await wait {
      session.isPlayerReady && (session.player.rate > 0 || !session.isPlaybackRequested)
    }
    XCTAssertTrue(session.player.currentItem === original)
    XCTAssertTrue(session.isPlaybackRequested)
    XCTAssertLessThan(session.player.currentTime().seconds, 0.5)
    XCTAssertGreaterThan(session.player.rate, 0)
  }

  func testSameSourceLoadDuringResolutionKeepsOriginalLoaderAndPlaybackIntent() async throws {
    let asset = try audioAsset()
    for (initialAutoplay, nextAutoplay) in [(true, false), (false, true)] {
      let loader = SuspendedAssetOperation()
      let session = PlaybackSession()
      defer { session.cleanup(); loader.finish(asset) }
      let identity = UUID()
      var replacementLoads = 0
      session.load(source: PlaybackSource(identity: identity, load: loader.load),
        playbackRate: 1, isLooping: false, autoplayWhenReady: initialAutoplay)
      try await wait { loader.started }

      session.load(source: PlaybackSource(identity: identity, load: {
        replacementLoads += 1
        return asset
      }), playbackRate: 0.5, isLooping: true, autoplayWhenReady: nextAutoplay)
      XCTAssertTrue(session.isPlaybackRequested)
      await Task.yield()
      XCTAssertFalse(loader.cancelled)
      XCTAssertEqual(replacementLoads, 0)

      loader.finish(asset)
      try await wait { session.isPlayerReady }
      XCTAssertTrue(session.isPlaybackRequested)
      XCTAssertEqual(session.playbackConfig.playbackRate, 0.5)
      XCTAssertTrue(session.playbackConfig.isLooping)
    }
  }

  func testSameSourceLoadDuringRevalidationKeepsItemPositionAndPlaybackIntent() async throws {
    let asset = try audioAsset()
    var sourceLoads = 0
    let source = PlaybackSource(identity: UUID(), load: {
      sourceLoads += 1
      return asset
    })
    let validator = SuspendedAssetOperation()
    let session = PlaybackSession()
    defer { session.cleanup(); validator.finish(asset) }
    session.load(source: source, playbackRate: 1, isLooping: false, autoplayWhenReady: false)
    try await wait { session.isPlayerReady && session.durationSeconds > 0 }
    let original = try XCTUnwrap(session.player.currentItem)
    session.handleScrubEditingChanged(true)
    session.setScrubProgress(0.4)
    session.handleScrubEditingChanged(false)
    try await wait { abs(session.player.currentTime().seconds - 0.4) < 0.01 }
    session.togglePlayback()
    session.revalidateAccess(source: source, refreshID: 1) { .validate(validator.load) }
    try await wait { validator.started }

    session.load(source: source, playbackRate: 0.5, isLooping: true, autoplayWhenReady: false)
    XCTAssertFalse(session.hasCurrentItem)
    XCTAssertTrue(session.isPlaybackRequested)
    XCTAssertEqual(session.status, .loading)
    await Task.yield()
    XCTAssertFalse(validator.cancelled)
    XCTAssertEqual(sourceLoads, 1)

    validator.finish(asset)
    try await wait { session.isPlayerReady && session.player.rate > 0 }
    XCTAssertTrue(session.player.currentItem === original)
    XCTAssertEqual(session.currentTimeSeconds, 0.4, accuracy: 0.05)
    XCTAssertEqual(session.player.rate, 0.5, accuracy: 0.01)
    XCTAssertTrue(session.isPlaybackRequested)
  }

  func testSameSourceLoadDoesNotSupersedePendingAccessDenial() async throws {
    let (session, source, asset) = try await readySession()
    let validator = SuspendedAssetOperation()
    defer { session.cleanup(); validator.finish(asset) }
    session.revalidateAccess(source: source, refreshID: 1) {
      .validate {
        _ = try await validator.load()
        throw TestError.denied
      }
    }
    try await wait { validator.started }
    session.load(source: source, playbackRate: 1, isLooping: false, autoplayWhenReady: true)
    validator.finish(asset)

    try await wait { session.status == .unavailable || session.hasCurrentItem }
    XCTAssertEqual(session.status, .unavailable)
    XCTAssertFalse(session.hasCurrentItem)
    guard case .source(let error) = session.failure else { return XCTFail("Expected access denial") }
    XCTAssertTrue(error is TestError)
  }

  func testDeniedRefreshFactoryRunsOncePerIdentityAndIsSynchronous() async throws {
    let asset = try audioAsset()
    let session = PlaybackSession()
    defer { session.cleanup() }
    var invalidations = 0
    for identity in ["first", "second"] {
      let source = PlaybackSource(identity: identity, load: { asset })
      session.load(source: source, playbackRate: 0.75, isLooping: true, autoplayWhenReady: false)
      try await wait { session.hasCurrentItem }
      for _ in 0..<2 {
        session.revalidateAccess(source: source, refreshID: 1) {
          invalidations += 1
          return .unavailable(TestError.denied)
        }
        XCTAssertFalse(session.hasCurrentItem)
        XCTAssertEqual(session.status, .unavailable)
      }
    }
    XCTAssertEqual(invalidations, 2)
    XCTAssertEqual(session.playbackConfig.playbackRate, 0.75)
    XCTAssertTrue(session.playbackConfig.isLooping)
  }

  func testNoItemRefreshCancelsOldLoadAndPreservesAutoplayIntent() async throws {
    let asset = try audioAsset()
    let suspended = SuspendedAssetOperation()
    let session = PlaybackSession()
    defer { session.cleanup(); suspended.finish(asset) }
    let source = PlaybackSource(identity: "media", load: suspended.load)
    session.load(source: source, playbackRate: 0.75, isLooping: true, autoplayWhenReady: true)
    try await wait { suspended.started }
    session.revalidateAccess(source: source, refreshID: 1) { .validate { asset } }
    XCTAssertTrue(session.isPlaybackRequested)
    try await wait { suspended.cancelled && session.isPlayerReady }
    let item = try XCTUnwrap(session.player.currentItem)
    suspended.finish(asset)
    await Task.yield()
    XCTAssertTrue(session.player.currentItem === item)
    XCTAssertTrue(session.isPlaybackRequested)
    XCTAssertEqual(session.playbackConfig.playbackRate, 0.75)
  }

  func testRevalidationRestoresSameItemAndLatestConfiguration() async throws {
    let asset = try audioAsset()
    let source = PlaybackSource(identity: "same", load: { asset })
    let session = PlaybackSession()
    defer { session.cleanup() }
    session.load(source: source, playbackRate: 1, isLooping: false, autoplayWhenReady: false)
    try await wait { session.isPlayerReady }
    let original = try XCTUnwrap(session.player.currentItem)
    let validator = SuspendedAssetOperation()
    session.revalidateAccess(source: source, refreshID: 4) { .validate(validator.load) }
    XCTAssertFalse(session.hasCurrentItem)
    try await wait { validator.started }
    session.updatePlaybackRate(0.5)
    session.updateLooping(true)
    validator.finish(asset)
    try await wait { session.isPlayerReady }
    XCTAssertTrue(session.player.currentItem === original)
    XCTAssertEqual(session.playbackConfig.playbackRate, 0.5)
    XCTAssertTrue(session.playbackConfig.isLooping)
    XCTAssertFalse(session.isPlaybackRequested)
  }

  func testCleanupCancelsSuspendedValidatorAndDiscardsLateSuccess() async throws {
    let (session, source, asset) = try await readySession()
    let validator = SuspendedAssetOperation()
    session.revalidateAccess(source: source, refreshID: 1) { .validate(validator.load) }
    try await wait { validator.started }
    session.cleanup()
    try await wait { validator.cancelled }
    validator.finish(asset)
    await Task.yield()
    XCTAssertFalse(session.hasCurrentItem)
    XCTAssertFalse(session.hasActivePlayerObservers)
    XCTAssertEqual(session.status, .none)
  }

  func testReplacementCancelsSuspendedValidatorAndKeepsNewItem() async throws {
    let (session, source, asset) = try await readySession()
    defer { session.cleanup() }
    let validator = SuspendedAssetOperation()
    session.revalidateAccess(source: source, refreshID: 1) { .validate(validator.load) }
    try await wait { validator.started }
    session.load(source: PlaybackSource(identity: "replacement", load: { asset }),
      playbackRate: 0.75, isLooping: false, autoplayWhenReady: false)
    try await wait { validator.cancelled && session.isPlayerReady }
    let newItem = try XCTUnwrap(session.player.currentItem)
    validator.finish(asset)
    await Task.yield()
    XCTAssertTrue(session.player.currentItem === newItem)
    XCTAssertTrue(session.isCurrentSource("replacement"))
  }

  func testSuspendedValidatorDoesNotRetainOwnerAndReceivesCancellation() async throws {
    let asset = try audioAsset()
    let source = PlaybackSource(identity: "owner", load: { asset })
    var owner: PlaybackSession? = PlaybackSession()
    weak var weakOwner = owner
    owner?.load(source: source, playbackRate: 1, isLooping: false, autoplayWhenReady: false)
    try await wait { owner?.isPlayerReady == true }
    let validator = SuspendedAssetOperation()
    owner?.revalidateAccess(source: source, refreshID: 1) { .validate(validator.load) }
    try await wait { validator.started }
    owner = nil
    try await wait { weakOwner == nil && validator.cancelled }
    validator.finish(asset)
    await Task.yield()
    XCTAssertNil(weakOwner)
  }

  func testSuspendedLoaderDoesNotRetainOwnerAndReceivesCancellation() async throws {
    let asset = try audioAsset()
    let loader = SuspendedAssetOperation()
    var owner: PlaybackSession? = PlaybackSession()
    weak var weakOwner = owner
    owner?.load(source: PlaybackSource(identity: "owner", load: loader.load),
      playbackRate: 1, isLooping: false, autoplayWhenReady: true)
    try await wait { loader.started }
    owner = nil
    try await wait { weakOwner == nil && loader.cancelled }
    loader.finish(asset)
    await Task.yield()
    XCTAssertNil(weakOwner)
  }

  func testFrameworkCancellationIsFailureAndLaterRefreshCanLoadWithoutOldIntent() async throws {
    let (session, source, asset) = try await readySession()
    defer { session.cleanup() }
    session.togglePlayback()
    XCTAssertTrue(session.isPlaybackRequested)
    session.revalidateAccess(source: source, refreshID: 1) { .validate { throw CancellationError() } }
    try await wait { session.status == .unavailable }
    guard case .source(let error) = session.failure else { return XCTFail("Expected source failure") }
    XCTAssertTrue(error is CancellationError)
    XCTAssertFalse(session.isPlaybackRequested)
    session.revalidateAccess(source: source, refreshID: 2) { .validate { asset } }
    try await wait { session.isPlayerReady }
    XCTAssertFalse(session.isPlaybackRequested)
  }

  func testInvalidSeekInputIsRejectedWithoutChangingPlayerOrScheduling() throws {
    let player = AVPlayer()
    let coordinator = VideoSeekCoordinator(player: player)
    for invalid in [Double.nan, .infinity, -.infinity] {
      XCTAssertFalse(coordinator.seek(to: invalid, duration: 1, precision: .exact))
      XCTAssertFalse(coordinator.seek(to: 0, duration: invalid, precision: .interactive))
    }
    XCTAssertFalse(coordinator.seek(to: 0, duration: -1, precision: .exact))
    XCTAssertTrue(coordinator.seek(to: -2, duration: 1, precision: .interactive))
    coordinator.reset()
    XCTAssertNil(player.currentItem)
  }

  private func readySession() async throws -> (PlaybackSession, PlaybackSource, AVAsset) {
    let asset = try audioAsset()
    let source = PlaybackSource(identity: UUID(), load: { asset })
    let session = PlaybackSession()
    session.load(source: source, playbackRate: 1, isLooping: false, autoplayWhenReady: false)
    try await wait { session.isPlayerReady }
    return (session, source, asset)
  }

  private func wait(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<500 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw TestError.timeout
  }

  private func audioAsset() throws -> AVAsset {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("playback-\(UUID()).caf")
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100))
    buffer.frameLength = 44_100
    buffer.floatChannelData?[0].update(repeating: 0, count: 44_100)
    try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
    return AVURLAsset(url: url)
  }
}

private enum TestError: Error { case denied, timeout }

@MainActor private final class SuspendedAssetOperation {
  private var continuation: CheckedContinuation<Void, Never>?
  private var asset: AVAsset?
  private(set) var started = false
  private(set) var cancelled = false

  func load() async throws -> AVAsset {
    started = true
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation = $0 }
    } onCancel: {
      Task { @MainActor [weak self] in self?.cancelled = true }
    }
    return try XCTUnwrap(asset)
  }

  func finish(_ asset: AVAsset) {
    self.asset = asset
    continuation?.resume()
    continuation = nil
  }
}

@MainActor
final class PlaybackSeekCancellationTests: XCTestCase {
  func testResetRejectsOldCompletionWhenNewRequestHasSameTimeAndPrecision() async throws {
    let player = DeferredSeekPlayer()
    let coordinator = VideoSeekCoordinator(player: player)
    coordinator.seek(to: 2, duration: 10, precision: .interactive)
    coordinator.reset()
    coordinator.seek(to: 2, duration: 10, precision: .interactive)
    coordinator.seek(to: 3, duration: 10, precision: .exact)
    XCTAssertEqual(player.requestCount, 2)

    player.complete(0)
    try await Task.sleep(for: .milliseconds(10))
    XCTAssertEqual(player.requestCount, 2, "A completion from before reset must not advance the new request queue")

    player.complete(1)
    for _ in 0..<100 where player.requestCount != 3 { await Task.yield() }
    XCTAssertEqual(player.requestCount, 3)
    XCTAssertEqual(player.lastTarget?.seconds, 3)
    coordinator.reset()
  }
}

private final class DeferredSeekPlayer: AVPlayer {
  private var requests: [(CMTime, @Sendable (Bool) -> Void)] = []

  override func seek(to time: CMTime, toleranceBefore: CMTime, toleranceAfter: CMTime,
                     completionHandler: @escaping @Sendable (Bool) -> Void) {
    // The coordinator invokes this override synchronously on MainActor.
    MainActor.assumeIsolated { requests.append((time, completionHandler)) }
  }

  var requestCount: Int { requests.count }
  var lastTarget: CMTime? { requests.last?.0 }
  func complete(_ index: Int) {
    let completion = requests[index].1
    completion(true)
  }
}
