import AVFoundation
import XCTest
@testable import VideoPlayback

@MainActor
final class PlaybackTransportTests: XCTestCase {
  func testSameSourceLoadAppliesLatestRateToPlayingAndHoldingTransport() async throws {
    let url = try temporaryPlayableAudioURL()
    let source = PlaybackSource(identity: url, load: { AVURLAsset(url: url) })
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

  private func temporaryPlayableAudioURL() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(UUID().uuidString).caf")
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }

    let sampleRate = 44_100.0
    let format = try XCTUnwrap(
      AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
    )
    let frameCount = AVAudioFrameCount(sampleRate)
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
    transportSeek: @escaping PlaybackSession.TransportSeek = PlaybackSession.seekTransport
  ) async throws -> PlaybackSession {
    let url = try temporaryPlayableAudioURL()
    let session = PlaybackSession(transportSeek: transportSeek)
    addTeardownBlock { @MainActor in session.cleanup() }
    session.load(source: PlaybackSource(identity: UUID(), load: { AVURLAsset(url: url) }),
      playbackRate: 1, isLooping: false, autoplayWhenReady: false)
    try await waitUntil { session.isPlayerReady && session.durationSeconds > 0 }
    return session
  }
}

private struct PlaybackTestFailure: Error, CustomStringConvertible {
  let description: String
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
