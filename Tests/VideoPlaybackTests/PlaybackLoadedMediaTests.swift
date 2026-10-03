import AVFoundation
import XCTest
@testable import VideoPlayback

@MainActor
final class PlaybackLoadedMediaTests: XCTestCase {
  func testInitialInstallationKeepsNativeAssetAndAudioMixParameters() async throws {
    let fixture = try await nativeMedia(trackID: 101, startVolume: 0.15, endVolume: 0.65)
    let media = PlaybackLoadedMedia(asset: fixture.asset, audioMix: fixture.audioMix)
    let session = try await readySession(media: media)
    defer { session.cleanup() }

    let item = try XCTUnwrap(session.player.currentItem)
    XCTAssertEqual(item.status, .readyToPlay)
    XCTAssertTrue(item.asset === fixture.asset)
    XCTAssertTrue(session.currentLoadedMedia?.asset === fixture.asset)
    try assertAudioMix(item.audioMix, matches: fixture)
    try assertAudioMix(session.currentLoadedMedia?.audioMix, matches: fixture)
    try session.currentLoadedMedia?.validate()
  }

  func testHighQualityReplacementUpdatesNativeAssetAndAudioMixTogether() async throws {
    let original = try await nativeMedia(trackID: 102, startVolume: 0.1, endVolume: 0.4)
    let highQuality = try await nativeMedia(trackID: 202, startVolume: 0.25, endVolume: 0.85)
    let session = try await readySession(media: original.loadedMedia())
    defer { session.cleanup() }
    let oldItem = try XCTUnwrap(session.player.currentItem)

    try await boundedReplacement(highQuality.loadedMedia(), in: session)

    let item = try XCTUnwrap(session.player.currentItem)
    XCTAssertFalse(item === oldItem)
    XCTAssertEqual(item.status, .readyToPlay)
    XCTAssertTrue(item.asset === highQuality.asset)
    XCTAssertTrue(session.currentLoadedMedia?.asset === highQuality.asset)
    try assertAudioMix(item.audioMix, matches: highQuality)
    try assertAudioMix(session.currentLoadedMedia?.audioMix, matches: highQuality)
    XCTAssertNil(session.failure)
  }

  func testSourceInvalidatedAfterNativeAssetPreparationRejectsCandidateAndInvalidOldItem() async throws {
    let original = try await nativeMedia(trackID: 103, startVolume: 0.1, endVolume: 0.5)
    let candidate = try await nativeMedia(trackID: 203, startVolume: 0.3, endVolume: 0.9)
    let authority = LoadedMediaAuthority()
    let gate = LoadedMediaReplacementPreparationGate()
    let transport = LoadedMediaNativeTransport()
    let session = try await readySession(
      media: original.loadedMedia(validate: authority.validate),
      transport: transport.seek,
      prepare: gate.prepare
    )
    let oldItem = try XCTUnwrap(session.player.currentItem)
    var outcome: Result<Void, any Error>?
    let replacement = Task {
      do {
        try await session.replaceAsset(candidate.loadedMedia(validate: authority.validate), for: "loaded-media")
        outcome = .success(())
      } catch { outcome = .failure(error) }
    }
    defer { replacement.cancel(); session.cleanup(); gate.cancel() }

    try await waitUntil { gate.isWaiting }
    XCTAssertTrue(gate.didLoadPlayableAsset)
    XCTAssertTrue(session.player.currentItem === oldItem)
    XCTAssertTrue(session.currentLoadedMedia?.asset === original.asset)
    authority.isValid = false
    gate.release()
    try await waitUntil { outcome != nil }

    assertReplacementFailed(outcome)
    assertInvalidMediaRemoved(session)
    XCTAssertTrue(transport.requests.isEmpty, "An invalid source cannot start a candidate or rollback seek")
    await replacement.value
  }

  func testSourceInvalidatedAtActualNativeReadinessRejectsCandidateWithoutRestorationSeek() async throws {
    let original = try await nativeMedia(trackID: 104, startVolume: 0.1, endVolume: 0.5)
    let candidate = try await nativeMedia(trackID: 204, startVolume: 0.3, endVolume: 0.9)
    let authority = LoadedMediaAuthority()
    let transport = LoadedMediaNativeTransport()
    var nativeCandidate: AVPlayerItem?
    var witnessedNativeReadiness = false
    let session = try await readySession(
      media: original.loadedMedia(validate: authority.validate),
      transport: transport.seek,
      prepare: { asset in
        guard try await asset.load(.isPlayable) else { throw LoadedMediaTestError.notPlayable }
        let item = AVPlayerItem(asset: asset)
        nativeCandidate = item
        return item
      }
    )
    let loadedCandidate = candidate.loadedMedia {
      if nativeCandidate?.status == .readyToPlay {
        witnessedNativeReadiness = true
        authority.isValid = false
      }
      try authority.validate()
    }
    var outcome: Result<Void, any Error>?
    let replacement = Task {
      do {
        try await session.replaceAsset(loadedCandidate, for: "loaded-media")
        outcome = .success(())
      } catch { outcome = .failure(error) }
    }
    defer { replacement.cancel(); session.cleanup() }

    try await waitUntil { outcome != nil }

    XCTAssertTrue(witnessedNativeReadiness, "Authority expires only after the actual AVPlayerItem becomes ready")
    assertReplacementFailed(outcome)
    assertInvalidMediaRemoved(session)
    XCTAssertTrue(transport.requests.isEmpty, "Neither the invalid candidate nor the invalid old media may seek")
    await replacement.value
  }

  func testSourceInvalidatedWhileSuccessfulNativeRestorationSeekAwaitsDeliveryRejectsLateSuccess() async throws {
    let original = try await nativeMedia(trackID: 105, startVolume: 0.1, endVolume: 0.5)
    let candidate = try await nativeMedia(trackID: 205, startVolume: 0.3, endVolume: 0.9)
    let authority = LoadedMediaAuthority()
    let transport = LoadedMediaNativeTransport()
    let session = try await readySession(
      media: original.loadedMedia(validate: authority.validate), transport: transport.seek
    )
    session.togglePlayback()
    try await waitUntil { session.player.rate > 0 }
    var outcome: Result<Void, any Error>?
    let replacement = Task {
      do {
        try await session.replaceAsset(candidate.loadedMedia(validate: authority.validate), for: "loaded-media")
        outcome = .success(())
      } catch { outcome = .failure(error) }
    }
    defer { replacement.cancel(); session.cleanup() }

    try await waitUntil { transport.finished(0) == true }
    let item = try XCTUnwrap(session.player.currentItem)
    XCTAssertTrue(item.asset === candidate.asset)
    XCTAssertEqual(item.status, .readyToPlay)
    XCTAssertNil(outcome, "The real seek has succeeded, but replacement still awaits its callback")
    XCTAssertEqual(session.player.rate, 0)
    authority.isValid = false
    try transport.deliver(0)
    try await waitUntil { outcome != nil }

    assertReplacementFailed(outcome)
    assertInvalidMediaRemoved(session)
    XCTAssertEqual(transport.requests.count, 1, "A late successful candidate seek cannot restore invalid old media")
    await replacement.value
  }

  func testInvalidCandidateRestoresIndependentlyValidOriginalAtReadinessAndRestorationSeek() async throws {
    for invalidateAtReadiness in [true, false] {
      let original = try await nativeMedia(trackID: 106, startVolume: 0.12, endVolume: 0.42)
      let candidate = try await nativeMedia(trackID: 206, startVolume: 0.32, endVolume: 0.92)
      let originalAuthority = LoadedMediaAuthority()
      let candidateAuthority = LoadedMediaAuthority()
      let transport = LoadedMediaNativeTransport()
      var nativeCandidate: AVPlayerItem?
      var witnessedNativeReadiness = false
      let session = try await readySession(
        media: original.loadedMedia(validate: originalAuthority.validate),
        transport: transport.seek,
        prepare: { asset in
          guard try await asset.load(.isPlayable) else { throw LoadedMediaTestError.notPlayable }
          let item = AVPlayerItem(asset: asset)
          nativeCandidate = item
          return item
        }
      )
      let oldItem = try XCTUnwrap(session.player.currentItem)
      session.togglePlayback()
      try await waitUntil { session.player.rate > 0 }
      let loadedCandidate = candidate.loadedMedia {
        if invalidateAtReadiness, nativeCandidate?.status == .readyToPlay {
          witnessedNativeReadiness = true
          candidateAuthority.isValid = false
        }
        try candidateAuthority.validate()
      }
      var outcome: Result<Void, any Error>?
      let replacement = Task {
        do {
          try await session.replaceAsset(loadedCandidate, for: "loaded-media")
          outcome = .success(())
        } catch { outcome = .failure(error) }
      }
      defer { replacement.cancel(); session.cleanup() }

      if invalidateAtReadiness {
        try await waitUntil { witnessedNativeReadiness && outcome != nil }
      } else {
        try await waitUntil { transport.finished(0) == true }
        XCTAssertEqual(nativeCandidate?.status, .readyToPlay)
        XCTAssertTrue(session.player.currentItem === nativeCandidate)
        XCTAssertNil(outcome)
        candidateAuthority.isValid = false
        try transport.deliver(0)
        try await waitUntil { outcome != nil }
      }
      assertReplacementFailed(outcome)
      let rollbackSeek = invalidateAtReadiness ? 0 : 1
      try await waitUntil { session.player.currentItem === oldItem && transport.finished(rollbackSeek) == true }
      try transport.deliver(rollbackSeek)
      try await waitUntil { session.isPlayerReady && session.player.rate > 0 }

      XCTAssertTrue(originalAuthority.isValid)
      XCTAssertFalse(candidateAuthority.isValid)
      XCTAssertTrue(session.player.currentItem === oldItem)
      XCTAssertTrue(session.currentLoadedMedia?.asset === original.asset)
      try assertAudioMix(session.player.currentItem?.audioMix, matches: original)
      try assertAudioMix(session.currentLoadedMedia?.audioMix, matches: original)
      try session.currentLoadedMedia?.validate()
      XCTAssertTrue(session.isPlaybackRequested)
      XCTAssertNil(session.failure, "An invalid HQ candidate must not revoke the valid original representation")
      await replacement.value
    }
  }

  func testAccessAcquiringDifferentMediaCannotGrantItsValidatorOrMixToOriginalSnapshot() async throws {
    for originalIsValid in [true, false] {
      for acquiredIsValid in [true, false] {
        let original = try await nativeMedia(trackID: 107, startVolume: 0.14, endVolume: 0.44)
        let acquired = try await nativeMedia(trackID: 207, startVolume: 0.34, endVolume: 0.94)
        let originalAuthority = LoadedMediaAuthority()
        let acquiredAuthority = LoadedMediaAuthority()
        acquiredAuthority.isValid = acquiredIsValid
        let gate = LoadedMediaAcquisitionGate()
        let transport = LoadedMediaNativeTransport()
        let originalMedia = original.loadedMedia(validate: originalAuthority.validate)
        let source = PlaybackSource(identity: "loaded-media", load: { originalMedia })
        let session = try await readySession(source: source, transport: transport.seek)
        defer { session.cleanup(); gate.cancel() }
        let oldItem = try XCTUnwrap(session.player.currentItem)

        session.revalidateAccess(source: source, refreshID: 1) { .validate { try await gate.acquire() } }
        try await waitUntil { gate.isWaiting }
        XCTAssertNil(session.player.currentItem)
        XCTAssertNil(session.currentLoadedMedia)
        originalAuthority.isValid = originalIsValid
        gate.release(acquired.loadedMedia(validate: acquiredAuthority.validate))

        if originalIsValid {
          try await waitUntil { transport.finished(0) == true }
          try transport.deliver(0)
          try await waitUntil { session.isPlayerReady }
          XCTAssertTrue(session.player.currentItem === oldItem)
          XCTAssertTrue(session.currentLoadedMedia?.asset === original.asset)
          XCTAssertFalse(session.currentLoadedMedia?.asset === acquired.asset)
          try assertAudioMix(session.player.currentItem?.audioMix, matches: original)
          try assertAudioMix(session.currentLoadedMedia?.audioMix, matches: original)
          try session.currentLoadedMedia?.validate()
          XCTAssertNil(session.failure)
        } else {
          try await waitUntil { session.failure != nil }
          assertInvalidMediaRemoved(session)
          XCTAssertTrue(transport.requests.isEmpty, "Fresh B acquisition cannot authorize a restoring seek for invalid A")
        }
      }
    }
  }

  func testPreparationRetryRevalidatesCurrentMediaBeforeNativePlayWithoutReloadingSource() async throws {
    let fixture = try await nativeMedia(trackID: 108, startVolume: 0.16, endVolume: 0.66)
    let authority = LoadedMediaAuthority()
    let media = fixture.loadedMedia(validate: authority.validate)
    var sourceLoads = 0
    var preparationCalls = 0
    var retryContinuation: CheckedContinuation<Void, any Error>?
    let source = PlaybackSource(identity: "loaded-media", load: {
      sourceLoads += 1
      return media
    })
    let preparation = PlaybackPreparation(prepare: { _ in
      preparationCalls += 1
      if preparationCalls == 1 { throw LoadedMediaTestError.preparationDenied }
      try await withCheckedThrowingContinuation { retryContinuation = $0 }
    }, release: { _ in })
    let session = try await readySession(source: source, preparation: preparation)
    defer {
      session.cleanup()
      let continuation = retryContinuation
      retryContinuation = nil
      continuation?.resume(throwing: CancellationError())
    }
    let original = try XCTUnwrap(session.player.currentItem)
    session.togglePlayback()
    try await waitUntil { session.failure != nil }
    guard case .preparation = session.failure else { return XCTFail("First playback preparation must fail") }
    XCTAssertTrue(session.player.currentItem === original)
    XCTAssertTrue(session.currentLoadedMedia?.asset === fixture.asset)
    XCTAssertEqual(session.player.rate, 0)
    XCTAssertEqual(sourceLoads, 1)

    session.retryPlaybackPreparation()
    try await waitUntil { retryContinuation != nil }
    XCTAssertEqual(preparationCalls, 2)
    XCTAssertEqual(session.player.rate, 0)
    authority.isValid = false
    let continuation = try XCTUnwrap(retryContinuation)
    retryContinuation = nil
    continuation.resume()
    try await waitUntil { session.failure != nil }

    assertInvalidMediaRemoved(session)
    XCTAssertEqual(sourceLoads, 1, "Retrying preparation must validate the current result without acquiring another source")
    XCTAssertEqual(preparationCalls, 2)
  }

  func testSynchronousValidationPauseAfterPreparationPreventsNativeReplayAndReleasesLease() async throws {
    let fixture = try await nativeMedia(trackID: 109, startVolume: 0.18, endVolume: 0.68)
    weak var observedSession: PlaybackSession?
    var hostIsReady = false
    var pausedFromValidation = false
    var preparedOwners: [UUID] = []
    var releasedOwners: [UUID] = []
    var ratesAtRelease: [Float] = []
    let media = fixture.loadedMedia {
      guard hostIsReady, !pausedFromValidation, let session = observedSession,
        session.isPlayerReady, session.isPlaybackRequested else { return }
      pausedFromValidation = true
      session.pausePlayback()
    }
    let preparation = PlaybackPreparation(prepare: { owner in
      preparedOwners.append(owner)
      hostIsReady = true
    }, release: { owner in
      releasedOwners.append(owner)
      ratesAtRelease.append(observedSession?.player.rate ?? -1)
    })
    let source = PlaybackSource(identity: "loaded-media", load: { media })
    let session = try await readySession(source: source, preparation: preparation)
    observedSession = session
    defer { session.cleanup() }
    let item = try XCTUnwrap(session.player.currentItem)

    session.togglePlayback()
    try await waitUntil { pausedFromValidation }

    XCTAssertEqual(preparedOwners.count, 1)
    XCTAssertEqual(releasedOwners, preparedOwners)
    XCTAssertEqual(ratesAtRelease, [0], "The host lease is released only after native playback pauses")
    XCTAssertFalse(session.isPlaybackRequested)
    XCTAssertEqual(session.player.rate, 0, "A synchronous validator pause must survive the final native play boundary")
    XCTAssertTrue(session.player.currentItem === item)
    XCTAssertTrue(session.currentLoadedMedia?.asset === fixture.asset)
    XCTAssertNil(session.failure)
  }

  private func readySession(
    media: PlaybackLoadedMedia,
    transport: @escaping PlaybackSession.TransportSeek = PlaybackSession.seekTransport,
    prepare: PlaybackSession.PrepareReplacement? = nil
  ) async throws -> PlaybackSession {
    let source = PlaybackSource(identity: "loaded-media", load: { media })
    return try await readySession(source: source, transport: transport, prepare: prepare)
  }

  private func readySession(
    source: PlaybackSource,
    transport: @escaping PlaybackSession.TransportSeek = PlaybackSession.seekTransport,
    prepare: PlaybackSession.PrepareReplacement? = nil,
    preparation: PlaybackPreparation? = nil
  ) async throws -> PlaybackSession {
    let session: PlaybackSession
    if let prepare { session = PlaybackSession(transportSeek: transport, prepareReplacement: prepare) }
    else { session = PlaybackSession(transportSeek: transport) }
    session.preparation = preparation
    addTeardownBlock { @MainActor in session.cleanup() }
    session.load(source: source, playbackRate: 1, isLooping: false, autoplayWhenReady: false)
    try await waitUntil { session.isPlayerReady && session.durationSeconds > 0 }
    return session
  }

  private func boundedReplacement(_ media: PlaybackLoadedMedia, in session: PlaybackSession) async throws {
    var outcome: Result<Void, any Error>?
    let replacement = Task {
      do {
        try await session.replaceAsset(media, for: "loaded-media")
        outcome = .success(())
      } catch { outcome = .failure(error) }
    }
    defer { replacement.cancel() }
    try await waitUntil { outcome != nil }
    try XCTUnwrap(outcome).get()
    await replacement.value
  }

  private func nativeMedia(
    trackID: CMPersistentTrackID,
    startVolume: Float,
    endVolume: Float
  ) async throws -> LoadedMediaNativeFixture {
    let duration = CMTime(seconds: 8, preferredTimescale: 600)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("loaded-media-\(UUID()).caf")
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    let sampleRate = 44_100.0
    let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
    let frameCount = AVAudioFrameCount(sampleRate * duration.seconds)
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
    buffer.frameLength = frameCount
    buffer.floatChannelData?[0].update(repeating: 0, count: Int(frameCount))
    do {
      let audioFile = try AVAudioFile(forWriting: url, settings: format.settings)
      try audioFile.write(from: buffer)
    }

    let fileAsset = AVURLAsset(url: url)
    var trackOutcome: Result<[AVAssetTrack], any Error>?
    let trackLoad = Task {
      do { trackOutcome = .success(try await fileAsset.loadTracks(withMediaType: .audio)) }
      catch { trackOutcome = .failure(error) }
    }
    defer { trackLoad.cancel() }
    try await waitUntil { trackOutcome != nil }
    let sourceTrack = try XCTUnwrap(try XCTUnwrap(trackOutcome).get().first)
    let composition = AVMutableComposition()
    let audioTrack = try XCTUnwrap(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: trackID))
    try audioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: sourceTrack, at: .zero)
    let ramp = CMTimeRange(start: .zero, duration: CMTime(seconds: 4, preferredTimescale: 600))
    let parameters = AVMutableAudioMixInputParameters(track: audioTrack)
    parameters.setVolumeRamp(fromStartVolume: startVolume, toEndVolume: endVolume, timeRange: ramp)
    let mix = AVMutableAudioMix()
    mix.inputParameters = [parameters]
    return LoadedMediaNativeFixture(
      asset: composition, audioMix: mix, trackID: audioTrack.trackID,
      startVolume: startVolume, endVolume: endVolume, ramp: ramp
    )
  }

  private func assertAudioMix(
    _ mix: AVAudioMix?,
    matches fixture: LoadedMediaNativeFixture,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    let parameters = try XCTUnwrap(mix?.inputParameters, file: file, line: line)
    XCTAssertEqual(parameters.count, 1, file: file, line: line)
    let parameter = try XCTUnwrap(parameters.first, file: file, line: line)
    XCTAssertEqual(parameter.trackID, fixture.trackID, file: file, line: line)
    var startVolume: Float = -1
    var endVolume: Float = -1
    var ramp = CMTimeRange.invalid
    XCTAssertTrue(parameter.getVolumeRamp(
      for: CMTime(seconds: 1, preferredTimescale: 600),
      startVolume: &startVolume, endVolume: &endVolume, timeRange: &ramp
    ), file: file, line: line)
    XCTAssertEqual(startVolume, fixture.startVolume, accuracy: 0.0001, file: file, line: line)
    XCTAssertEqual(endVolume, fixture.endVolume, accuracy: 0.0001, file: file, line: line)
    XCTAssertEqual(ramp.start.seconds, fixture.ramp.start.seconds, accuracy: 0.0001, file: file, line: line)
    XCTAssertEqual(ramp.duration.seconds, fixture.ramp.duration.seconds, accuracy: 0.0001, file: file, line: line)
  }

  private func assertReplacementFailed(
    _ outcome: Result<Void, any Error>?,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    guard case .failure = outcome else { return XCTFail("Invalid replacement must fail", file: file, line: line) }
  }

  private func assertInvalidMediaRemoved(
    _ session: PlaybackSession,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertNil(session.player.currentItem, file: file, line: line)
    XCTAssertNil(session.currentLoadedMedia, file: file, line: line)
    XCTAssertFalse(session.isPlayerReady, file: file, line: line)
    XCTAssertFalse(session.isPlaybackRequested, file: file, line: line)
    XCTAssertEqual(session.player.rate, 0, file: file, line: line)
    XCTAssertEqual(session.status, .unavailable, file: file, line: line)
    guard case .source(let error) = session.failure,
      let reason = error as? LoadedMediaTestError, case .accessDenied = reason
    else { return XCTFail("Expected the result's access denial", file: file, line: line) }
  }

  private func waitUntil(
    _ condition: @MainActor () -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async throws {
    for _ in 0..<1_000 {
      if condition() { return }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    throw LoadedMediaTestError.timeout("Condition did not become true at \(file):\(line)")
  }
}

@MainActor
private struct LoadedMediaNativeFixture {
  let asset: AVMutableComposition
  let audioMix: AVAudioMix
  let trackID: CMPersistentTrackID
  let startVolume: Float
  let endVolume: Float
  let ramp: CMTimeRange

  func loadedMedia(validate: @escaping @MainActor () throws -> Void = {}) -> PlaybackLoadedMedia {
    PlaybackLoadedMedia(asset: asset, audioMix: audioMix, validate: validate)
  }
}

private enum LoadedMediaTestError: Error {
  case accessDenied
  case preparationDenied
  case notPlayable
  case timeout(String)
}

@MainActor
private final class LoadedMediaAuthority {
  var isValid = true

  func validate() throws {
    if !isValid { throw LoadedMediaTestError.accessDenied }
  }
}

@MainActor
private final class LoadedMediaReplacementPreparationGate {
  private var continuation: CheckedContinuation<AVPlayerItem, any Error>?
  private var candidate: AVPlayerItem?
  private(set) var didLoadPlayableAsset = false
  var isWaiting: Bool { continuation != nil }

  func prepare(_ asset: AVAsset) async throws -> AVPlayerItem {
    guard try await asset.load(.isPlayable) else { throw LoadedMediaTestError.notPlayable }
    try Task.checkCancellation()
    didLoadPlayableAsset = true
    candidate = AVPlayerItem(asset: asset)
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
        else { self.continuation = continuation }
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.cancel() }
    }
  }

  func release() {
    guard let continuation, let candidate else { return }
    self.continuation = nil
    self.candidate = nil
    continuation.resume(returning: candidate)
  }

  func cancel() {
    let continuation = continuation
    self.continuation = nil
    candidate = nil
    continuation?.resume(throwing: CancellationError())
  }
}

@MainActor
private final class LoadedMediaAcquisitionGate {
  private var continuation: CheckedContinuation<PlaybackLoadedMedia, any Error>?
  var isWaiting: Bool { continuation != nil }

  func acquire() async throws -> PlaybackLoadedMedia {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
        else { self.continuation = continuation }
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.cancel() }
    }
  }

  func release(_ media: PlaybackLoadedMedia) {
    let continuation = continuation
    self.continuation = nil
    continuation?.resume(returning: media)
  }

  func cancel() {
    let continuation = continuation
    self.continuation = nil
    continuation?.resume(throwing: CancellationError())
  }
}

/// Every recorded result comes from a real native seek. Only callback delivery is held.
@MainActor
private final class LoadedMediaNativeTransport {
  struct Request {
    let completion: @MainActor (Bool) -> Void
    var finished: Bool?
    var delivered = false
  }

  private(set) var requests: [Request] = []

  func seek(player: AVPlayer, target: CMTime, completion: @escaping @MainActor (Bool) -> Void) {
    let index = requests.count
    requests.append(Request(completion: completion))
    PlaybackSession.seekTransport(player: player, target: target) { [weak self] finished in
      self?.requests[index].finished = finished
    }
  }

  func finished(_ index: Int) -> Bool? {
    guard requests.indices.contains(index) else { return nil }
    return requests[index].finished
  }

  func deliver(_ index: Int) throws {
    guard requests.indices.contains(index) else { throw LoadedMediaTestError.timeout("Missing native seek") }
    let request = requests[index]
    let finished = try XCTUnwrap(request.finished)
    XCTAssertFalse(request.delivered)
    requests[index].delivered = true
    request.completion(finished)
  }
}
