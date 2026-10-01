import AVFoundation
import XCTest
@testable import VideoPlayback

@MainActor
final class PlaybackReplacementTests: XCTestCase {
  func testRestorationSeekFailureThrowsAndRestoresOldItemAndPlaybackIntent() async throws {
    let transport = ReplacementTransport()
    let (session, asset) = try await readySession(transport: transport.seek)
    defer { session.cleanup() }
    let original = try XCTUnwrap(session.player.currentItem)
    session.togglePlayback()
    session.updatePlaybackRate(0.5)
    session.updateLooping(true)
    session.handleScrubEditingChanged(true)
    session.setScrubProgress(0.4)
    session.handleScrubEditingChanged(false)
    try await waitUntil { transport.finished.first == true }
    transport.deliver(0)
    var result: Result<Void, any Error>?
    let replacement = Task {
      do { try await session.replaceAsset(asset, for: "A"); result = .success(()) }
      catch { result = .failure(error) }
    }
    defer { replacement.cancel() }
    try await waitUntil { transport.targets.count == 2 && transport.finished[1] == true }
    XCTAssertNil(result, "A ready item does not prove its restoring seek succeeded")
    transport.fail(1)
    try await waitUntil { result != nil }
    guard case .failure(let error) = result else { return XCTFail("Restoring seek failure must throw") }
    guard let failure = error as? PlaybackFailure, case .playerItemFailed = failure else {
      return XCTFail("Expected typed replacement failure: \(error)")
    }
    XCTAssertTrue(session.player.currentItem === original)
    XCTAssertTrue(session.isPlaybackRequested)
    XCTAssertEqual(session.playbackConfig.playbackRate, 0.5)
    XCTAssertTrue(session.playbackConfig.isLooping)
    XCTAssertEqual(transport.targets.last?.seconds ?? -1, 3.2, accuracy: 0.01)
    try await waitUntil { transport.finished.last == true }
    transport.deliverLast()
    XCTAssertEqual(session.player.rate, 0.5, accuracy: 0.01)
    XCTAssertNil(session.failure)
    await replacement.value
  }

  func testUnavailableAccessDoesNotRestoreOrSeekOldItemWhileReplacementIsPreparing() async throws {
    for waitingForSeek in [false, true] {
      let transport = ReplacementTransport()
      let (session, asset) = try await readySession(prepare: { asset in
        AVPlayerItem(asset: waitingForSeek ? asset : AVMutableComposition())
      }, transport: transport.seek)
      defer { session.cleanup() }
      let original = try XCTUnwrap(session.player.currentItem)
      let replacement = Task { try await session.replaceAsset(asset, for: "A") }
      defer { replacement.cancel() }
      try await waitUntil {
        waitingForSeek ? transport.finished.first == true
          : session.player.currentItem !== original && !session.isPlayerReady
      }
      let seekCount = transport.targets.count
      session.revalidateAccess(source: PlaybackSource(identity: "A", load: { asset }), refreshID: 1) {
        .unavailable(ReplacementTestError.timeout)
      }
      XCTAssertEqual(transport.targets.count, seekCount, "Revoked access must not first seek the old item")
      XCTAssertNil(session.player.currentItem)
      XCTAssertEqual(session.status, .unavailable)
      if waitingForSeek { transport.fail(0) }
      do { try await replacement.value; XCTFail("Revoked replacement must cancel") }
      catch is CancellationError {} catch { XCTFail("Expected cancellation: \(error)") }
    }
  }

  func testNewScrubRejectsLateRestorationFailureWithoutRestoringPreviousItem() async throws {
    let transport = ReplacementTransport()
    let (session, asset) = try await readySession(transport: transport.seek)
    defer { session.cleanup() }
    session.togglePlayback()
    let replacement = Task { try await session.replaceAsset(asset, for: "A") }
    defer { replacement.cancel() }
    try await waitUntil { transport.finished.first == true }
    let candidate = session.player.currentItem
    session.handleScrubEditingChanged(true)
    session.setScrubProgress(0.7)
    session.handleScrubEditingChanged(false)
    try await waitUntil { transport.targets.count == 2 && transport.finished[1] == true }
    transport.fail(0)
    XCTAssertTrue(session.player.currentItem === candidate)
    XCTAssertEqual(session.currentTimeSeconds, 5.6, accuracy: 0.01)
    XCTAssertTrue(session.isPlaybackRequested)
    transport.deliver(1)
    XCTAssertEqual(session.player.rate, 1, accuracy: 0.01)
    try await replacement.value
  }

  func testCleanupAndSourceReuseDuringRestorationRejectLateSeekFailure() async throws {
    for cleanup in [true, false] {
      let transport = ReplacementTransport()
      let (session, asset) = try await readySession(transport: transport.seek)
      defer { session.cleanup() }
      let replacement = Task { try await session.replaceAsset(asset, for: "A") }
      defer { replacement.cancel() }
      try await waitUntil { transport.finished.first == true }
      if cleanup {
        session.cleanup()
      } else {
        session.load(source: PlaybackSource(identity: "B", load: { asset }),
          playbackRate: 0.5, isLooping: false, autoplayWhenReady: false)
        try await waitUntil { session.isPlayerReady }
        session.load(source: PlaybackSource(identity: "A", load: { asset }),
          playbackRate: 0.75, isLooping: true, autoplayWhenReady: false)
        try await waitUntil { session.isPlayerReady }
      }
      let current = session.player.currentItem
      transport.fail(0)
      do { try await replacement.value; XCTFail("Invalidated restoration must cancel") }
      catch is CancellationError {} catch { XCTFail("Expected cancellation: \(error)") }
      XCTAssertTrue(session.player.currentItem === current)
      XCTAssertEqual(transport.targets.count, 1, "No late rollback seek may begin")
      XCTAssertFalse(session.isPlaybackRequested)
      XCTAssertEqual(session.player.rate, 0)
      if cleanup { XCTAssertNil(current) }
      else { XCTAssertEqual(session.playbackConfig.playbackRate, 0.75) }
    }
  }

  func testTaskCancellationDuringRestorationRestoresOriginalAndRejectsLateCandidateFailure() async throws {
    let transport = ReplacementTransport()
    let (session, asset) = try await readySession(transport: transport.seek)
    defer { session.cleanup() }
    let original = session.player.currentItem
    session.togglePlayback()
    let replacement = Task { try await session.replaceAsset(asset, for: "A") }
    try await waitUntil { transport.finished.first == true }
    replacement.cancel()
    try await waitUntil { transport.targets.count == 2 && transport.finished[1] == true }
    XCTAssertTrue(session.player.currentItem === original)
    transport.fail(0)
    transport.deliver(1)
    do { try await replacement.value; XCTFail("Cancelled restoration must cancel") }
    catch is CancellationError {} catch { XCTFail("Expected cancellation: \(error)") }
    XCTAssertTrue(session.player.currentItem === original)
    XCTAssertTrue(session.isPlayerReady)
    XCTAssertTrue(session.isPlaybackRequested)
    XCTAssertEqual(session.player.rate, 1, accuracy: 0.01)
  }

  func testNewReplacementDuringRestorationRejectsSupersededSeekFailure() async throws {
    let transport = ReplacementTransport()
    let (session, asset) = try await readySession(transport: transport.seek)
    defer { session.cleanup() }
    let previous = Task { try await session.replaceAsset(asset, for: "A") }
    defer { previous.cancel() }
    try await waitUntil { transport.finished.first == true }
    let replacement = Task { try await session.replaceAsset(asset, for: "A") }
    defer { replacement.cancel() }
    try await waitUntil { transport.targets.count == 3 && transport.finished[2] == true }
    let current = session.player.currentItem
    transport.fail(0)
    transport.fail(1)
    XCTAssertTrue(session.player.currentItem === current)
    transport.deliver(2)
    try await replacement.value
    do { try await previous.value; XCTFail("Superseded restoration must cancel") }
    catch is CancellationError {} catch { XCTFail("Expected cancellation: \(error)") }
    XCTAssertTrue(session.player.currentItem === current)
    XCTAssertTrue(session.isPlayerReady)
    XCTAssertEqual(transport.targets.count, 3)
  }

  func testReadyCandidateReplacesRepresentationOnSamePlayerAndRestoresPausedPosition() async throws {
    let (session, asset) = try await readySession()
    defer { session.cleanup() }
    let player = session.player
    let oldItem = try XCTUnwrap(player.currentItem)
    session.handleScrubEditingChanged(true)
    session.setScrubProgress(0.4)
    session.handleScrubEditingChanged(false)
    try await waitUntil { abs(session.currentTimeSeconds - 3.2) < 0.01 && player.currentTime().seconds > 3 }
    try await boundedReplace(session, asset)
    XCTAssertTrue(player === session.player)
    XCTAssertFalse(oldItem === player.currentItem)
    XCTAssertEqual(player.currentItem?.status, .readyToPlay)
    XCTAssertFalse(session.isPlaybackRequested)
    try await waitUntil { abs(player.currentTime().seconds - 3.2) < 0.01 }
    XCTAssertEqual(player.rate, 0)
    XCTAssertEqual(session.currentTimeSeconds, 3.2, accuracy: 0.01)
  }

  func testCandidatePreparationKeepsOldItemAndCapturesLatestScrubIntentAndConfiguration() async throws {
    let gate = ReplacementGate()
    let transport = ReplacementTransport()
    let (session, asset) = try await readySession(prepare: gate.prepare, transport: transport.seek)
    defer { session.cleanup(); gate.finish(.success(AVPlayerItem(asset: asset))) }
    let oldItem = try XCTUnwrap(session.player.currentItem)
    let replacement = Task { try await session.replaceAsset(asset, for: "A") }
    try await waitUntil { gate.started }
    XCTAssertTrue(session.player.currentItem === oldItem)
    XCTAssertTrue(session.canUsePlaybackControls)
    session.togglePlayback()
    session.updatePlaybackRate(1.25)
    session.updateLooping(true)
    session.handleScrubEditingChanged(true)
    session.setScrubProgress(0.6)
    XCTAssertTrue(session.player.currentItem === oldItem)
    let candidate = AVPlayerItem(asset: asset)
    gate.finish(.success(candidate))
    try await waitUntil { transport.targets.count == 1 }
    XCTAssertTrue(session.player.currentItem === candidate)
    XCTAssertEqual(transport.targets.last?.seconds ?? -1, 4.8, accuracy: 0.01)
    XCTAssertEqual(session.playbackConfig.playbackRate, 1.25)
    XCTAssertTrue(session.playbackConfig.isLooping)
    XCTAssertTrue(session.isPlaybackRequested)
    XCTAssertEqual(session.player.rate, 0, "Playback waits for the restoration seek")
    try await waitUntil { transport.finished.last == true }
    transport.deliverLast()
    try await replacement.value
    XCTAssertEqual(session.player.rate, 1.25, accuracy: 0.01)
  }

  func testReplacementPreservesPendingSeekTargetAndRejectsOldCompletion() async throws {
    let transport = ReplacementTransport()
    let (session, asset) = try await readySession(transport: transport.seek)
    defer { session.cleanup() }
    session.togglePlayback()
    session.handleScrubEditingChanged(true)
    session.setScrubProgress(0.7)
    session.handleScrubEditingChanged(false)
    try await waitUntil { transport.finished.first == true }
    let replacement = Task { try await session.replaceAsset(asset, for: "A") }
    defer { replacement.cancel() }
    try await waitUntil { transport.targets.count == 2 }
    XCTAssertEqual(transport.targets.last?.seconds ?? -1, 5.6, accuracy: 0.01)
    transport.deliver(0)
    XCTAssertEqual(session.player.rate, 0)
    try await waitUntil { transport.finished.last == true }
    transport.deliverLast()
    try await replacement.value
    XCTAssertEqual(session.player.rate, 1, accuracy: 0.01)
  }

  func testReplacementEndsPausedOriginHoldWithoutInheritingBoostOrPlaybackIntent() async throws {
    let transport = ReplacementTransport()
    let (session, asset) = try await readySession(transport: transport.seek)
    defer { session.cleanup() }
    session.updatePlaybackRate(1.25)
    session.handleHoldGestureStateChanged(.began, allowsHoldBoost: true)
    XCTAssertEqual(session.player.rate, 2.5, accuracy: 0.01)
    let replacement = Task { try await session.replaceAsset(asset, for: "A") }
    defer { replacement.cancel() }
    try await waitUntil { transport.finished.last == true }
    transport.deliverLast()
    try await replacement.value
    XCTAssertEqual(session.playbackConfig.playbackRate, 1.25)
    XCTAssertFalse(session.isPlaybackRequested)
    XCTAssertEqual(session.player.rate, 0)
  }

  func testNativeItemFailureRestoresOldItemPositionAndLatestIntent() async throws {
    let (session, asset) = try await readySession(prepare: { _ in
      AVPlayerItem(asset: AVURLAsset(url: URL(fileURLWithPath: "/native-missing-\(UUID()).mov")))
    })
    defer { session.cleanup() }
    let original = try XCTUnwrap(session.player.currentItem)
    session.togglePlayback()
    session.updatePlaybackRate(0.5)
    session.updateLooping(true)
    session.handleScrubEditingChanged(true)
    session.setScrubProgress(0.4)
    do { try await boundedReplace(session, asset); XCTFail("Invalid native item must fail") }
    catch {
      guard let failure = error as? PlaybackFailure, case .playerItemFailed = failure else {
        return XCTFail("Expected native item failure: \(error)")
      }
      try await waitUntil { session.isPlayerReady && session.player.rate > 0 }
      XCTAssertTrue(session.player.currentItem === original)
      XCTAssertEqual(session.currentTimeSeconds, 3.2, accuracy: 0.1)
      XCTAssertEqual(session.playbackConfig.playbackRate, 0.5)
      XCTAssertTrue(session.playbackConfig.isLooping)
      XCTAssertTrue(session.isPlaybackRequested)
      XCTAssertEqual(session.player.rate, 0.5, accuracy: 0.01)
      XCTAssertNil(session.failure)
    }
  }

  func testNewReplacementRejectsLateSuccessFromPreviousPreparation() async throws {
    let gate = ReplacementGate()
    var prepareCount = 0
    let (session, asset) = try await readySession(prepare: { asset in
      prepareCount += 1
      if prepareCount == 1 { return try await gate.prepare(asset) }
      return AVPlayerItem(asset: asset)
    })
    defer { session.cleanup(); gate.finish(.success(AVPlayerItem(asset: asset))) }
    let previous = Task { try await session.replaceAsset(asset, for: "A") }
    try await waitUntil { gate.started }
    session.updatePlaybackRate(0.75)
    try await boundedReplace(session, asset)
    let current = session.player.currentItem
    gate.finish(.success(AVPlayerItem(asset: asset)))
    do { try await previous.value; XCTFail("Superseded replacement cannot install") }
    catch is CancellationError {} catch { XCTFail("Expected cancellation: \(error)") }
    XCTAssertTrue(session.player.currentItem === current)
    XCTAssertEqual(session.playbackConfig.playbackRate, 0.75)
  }

  func testPreparationFailureKeepsOldPlaybackAndConfiguration() async throws {
    let (session, _) = try await readySession()
    defer { session.cleanup() }
    let original = try XCTUnwrap(session.player.currentItem)
    session.togglePlayback()
    session.updatePlaybackRate(0.5)
    let invalid = AVURLAsset(url: URL(fileURLWithPath: "/missing-representation-\(UUID()).mov"))
    do {
      try await boundedReplace(session, invalid)
      XCTFail("Invalid representation must fail")
    } catch {
      XCTAssertTrue(session.player.currentItem === original)
      XCTAssertTrue(session.isPlayerReady)
      XCTAssertTrue(session.isPlaybackRequested)
      XCTAssertEqual(session.player.rate, 0.5, accuracy: 0.01)
      XCTAssertNil(session.failure)
    }
  }

  func testCancellationAndCleanupRejectLatePreparedCandidate() async throws {
    for cleanup in [false, true] {
      let gate = ReplacementGate()
      let (session, asset) = try await readySession(prepare: gate.prepare)
      let original = session.player.currentItem
      let replacement = Task { try await session.replaceAsset(asset, for: "A") }
      try await waitUntil { gate.started }
      if cleanup { session.cleanup() } else { replacement.cancel() }
      gate.finish(.success(AVPlayerItem(asset: asset)))
      do { try await replacement.value; XCTFail("Invalidated candidate must not install") }
      catch is CancellationError {} catch { XCTFail("Expected cancellation: \(error)") }
      XCTAssertTrue(cleanup ? session.player.currentItem == nil : session.player.currentItem === original)
      session.cleanup()
    }
  }

  func testSourceAToBToARejectsOldCandidateWithReusedIdentity() async throws {
    let gate = ReplacementGate()
    let (session, asset) = try await readySession(prepare: gate.prepare)
    defer { session.cleanup() }
    let replacement = Task { try await session.replaceAsset(asset, for: "A") }
    try await waitUntil { gate.started }
    session.load(source: PlaybackSource(identity: "B", load: { asset }),
      playbackRate: 1, isLooping: false, autoplayWhenReady: false)
    try await waitUntil { session.isPlayerReady }
    session.load(source: PlaybackSource(identity: "A", load: { asset }),
      playbackRate: 1, isLooping: false, autoplayWhenReady: false)
    try await waitUntil { session.isPlayerReady }
    let current = session.player.currentItem
    gate.finish(.success(AVPlayerItem(asset: asset)))
    do { try await replacement.value; XCTFail("Old A must not install") }
    catch is CancellationError {} catch { XCTFail("Expected cancellation: \(error)") }
    XCTAssertTrue(session.player.currentItem === current)
  }

  private func readySession(
    prepare: PlaybackSession.PrepareReplacement? = nil,
    transport: @escaping PlaybackSession.TransportSeek = PlaybackSession.seekTransport
  ) async throws -> (PlaybackSession, AVAsset) {
    let asset = try audioAsset(seconds: 8)
    let session: PlaybackSession
    if let prepare { session = PlaybackSession(transportSeek: transport, prepareReplacement: prepare) }
    else { session = PlaybackSession(transportSeek: transport) }
    session.load(source: PlaybackSource(identity: "A", load: { asset }),
      playbackRate: 1, isLooping: false, autoplayWhenReady: false)
    try await waitUntil { session.isPlayerReady && session.durationSeconds > 0 }
    return (session, asset)
  }

  private func boundedReplace(_ session: PlaybackSession, _ asset: AVAsset) async throws {
    var finished = false
    let task = Task {
      defer { finished = true }
      try await session.replaceAsset(asset, for: "A")
    }
    defer { task.cancel() }
    try await waitUntil { finished }
    try await task.value
  }

  private func audioAsset(seconds: Double) throws -> AVAsset {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("replacement-\(UUID()).caf")
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
    let count = AVAudioFrameCount(44_100 * seconds)
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count))
    buffer.frameLength = count
    buffer.floatChannelData?[0].update(repeating: 0, count: Int(count))
    try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
    return AVURLAsset(url: url)
  }

  private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<500 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw ReplacementTestError.timeout
  }
}

private enum ReplacementTestError: Error { case timeout }

@MainActor
private final class ReplacementGate {
  private var continuation: CheckedContinuation<AVPlayerItem, any Error>?
  private var result: Result<AVPlayerItem, any Error>?
  private(set) var started = false

  func prepare(_ asset: AVAsset) async throws -> AVPlayerItem {
    started = true
    if let result { return try result.get() }
    return try await withCheckedThrowingContinuation { continuation = $0 }
  }

  func finish(_ result: Result<AVPlayerItem, any Error>) {
    self.result = result
    continuation?.resume(with: result)
    continuation = nil
  }
}

@MainActor
private final class ReplacementTransport {
  private(set) var targets: [CMTime] = []
  private(set) var finished: [Bool?] = []
  private var completions: [@MainActor (Bool) -> Void] = []

  func seek(player: AVPlayer, target: CMTime, completion: @escaping @MainActor (Bool) -> Void) {
    let index = targets.count
    targets.append(target)
    finished.append(nil)
    completions.append(completion)
    PlaybackSession.seekTransport(player: player, target: target) { [weak self] in self?.finished[index] = $0 }
  }

  func deliver(_ index: Int) { completions[index](finished[index] ?? false) }
  func fail(_ index: Int) { completions[index](false) }
  func deliverLast() { deliver(completions.count - 1) }
}
