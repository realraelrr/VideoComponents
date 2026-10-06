import AVFoundation
import CoreVideo
import Foundation
import Observation
import VideoResources
import XCTest
@testable import VideoPlayback
@testable import VideoResourcesPlayback

@MainActor
final class VideoResourcePlaybackTests: XCTestCase {
  func testHostObserverIsReleasedWithOwnerAndNotInheritedByNextOwner() {
    let native = PlaybackSession()
    var capturedHost: NSObject? = NSObject()
    weak var releasedHost = capturedHost
    var oldEvents = 0
    var owner: VideoResourcePlayback? = VideoResourcePlayback(session: native) { [capturedHost] _ in
      XCTAssertNotNil(capturedHost)
      oldEvents += 1
    }
    capturedHost = nil
    owner?.cleanup()
    XCTAssertEqual(oldEvents, 1)
    XCTAssertNotNil(releasedHost)
    owner = nil
    XCTAssertNil(releasedHost)
    native.cleanup()
    XCTAssertEqual(oldEvents, 1)

    var newEvents = 0
    let replacement = VideoResourcePlayback(session: native) { _ in newEvents += 1 }
    replacement.cleanup()
    XCTAssertEqual(newEvents, 1)
    replacement.cleanup()
    XCTAssertEqual(newEvents, 2)
    XCTAssertNil(native.currentSourceIdentity)
    XCTAssertNil(native.player.currentItem)
    XCTAssertEqual(oldEvents, 1)
  }

  func testClosingOnlyHighQualityConsumerCancelsNativeWorkAndRejectsLateSuccess() async throws {
    let probe = BindingLoaderProbe()
    let source = probe.resources().photosSource(serializedCloudIdentifier: "sole-HQ")
    let binding = VideoResourcePlayback()
    defer { binding.cleanup(); probe.finishOutstanding() }
    let automatic = try await movie()
    let highest = try await movie(blue: true)
    try await ready(binding, source: source, probe: probe, asset: automatic)
    let originalReceipt = try XCTUnwrap(binding.installedReceipt)

    binding.requestHighQuality()
    try await waitUntil { probe.invocations.count == 2 }
    binding.cleanup()
    try await waitUntil { probe.cancelledIndices == [1] }
    XCTAssertNil(binding.installedReceipt)
    XCTAssertNil(binding.session.player.currentItem)
    XCTAssertEqual(source.preferred?.representationID, originalReceipt.representationID)

    probe.finish(1, with: .success(.init(asset: highest)))
    try await waitUntil { probe.returnedIndices.contains(1) }
    await settle()
    XCTAssertNil(binding.installedReceipt)
    XCTAssertEqual(source.preferred?.representationID, originalReceipt.representationID,
      "A cancelled HQ operation cannot publish its deliberately late native result")
  }

  func testClosingOneSharedHighQualityConsumerKeepsOtherInstallationAlive() async throws {
    let probe = BindingLoaderProbe()
    let source = probe.resources().photosSource(serializedCloudIdentifier: "shared-HQ")
    let first = VideoResourcePlayback()
    let second = VideoResourcePlayback()
    defer { first.cleanup(); second.cleanup(); probe.finishOutstanding() }
    let automatic = try await movie()
    let highest = try await movie(blue: true)
    first.load(source: source)
    second.load(source: source)
    try await waitUntil { probe.invocations.count == 1 }
    probe.finish(0, with: .success(.init(asset: automatic)))
    try await waitUntil { first.session.isPlayerReady && second.session.isPlayerReady }
    XCTAssertFalse(first.session.player.currentItem === second.session.player.currentItem)

    first.requestHighQuality()
    second.requestHighQuality()
    try await waitUntil { probe.invocations.count == 2 }
    await settle()
    first.cleanup()
    await settle()
    XCTAssertTrue(probe.cancelledIndices.isEmpty,
      "The surviving binding owns an independent share of the shared HQ operation")
    probe.finish(1, with: .success(.init(asset: highest)))
    try await waitUntil { second.installedReceipt?.evidence.quality == .highest }

    XCTAssertNil(first.installedReceipt)
    XCTAssertNil(first.session.player.currentItem)
    XCTAssertTrue(second.session.player.currentItem?.asset === highest)
    XCTAssertEqual(second.installedReceipt?.representationID, source.preferred?.representationID)
    XCTAssertEqual(probe.invocations.count, 2)
    XCTAssertTrue(probe.cancelledIndices.isEmpty)
  }

  func testSharedHighQualityInstallationFailureBelongsOnlyToFailingSession() async throws {
    let probe = BindingLoaderProbe()
    let source = probe.resources().photosSource(serializedCloudIdentifier: "installation-isolation")
    let failingSession = PlaybackSession(transportSeek: PlaybackSession.seekTransport,
      prepareReplacement: { _ in throw BindingTestError.installationDenied })
    let failing = VideoResourcePlayback(session: failingSession)
    let surviving = VideoResourcePlayback()
    defer { failing.cleanup(); surviving.cleanup(); probe.finishOutstanding() }
    let automatic = try await movie()
    let highest = try await movie(blue: true)
    failing.load(source: source)
    surviving.load(source: source)
    try await waitUntil { probe.invocations.count == 1 }
    probe.finish(0, with: .success(.init(asset: automatic)))
    try await waitUntil { failing.session.isPlayerReady && surviving.session.isPlayerReady }
    let originalItem = try XCTUnwrap(failing.session.player.currentItem)
    let originalReceipt = try XCTUnwrap(failing.installedReceipt)

    failing.requestHighQuality()
    surviving.requestHighQuality()
    try await waitUntil { probe.invocations.count == 2 }
    probe.finish(1, with: .success(.init(asset: highest)))
    try await waitUntil {
      failing.qualityFailure != nil && surviving.installedReceipt?.evidence.quality == .highest
    }

    XCTAssertTrue(failing.session.player.currentItem === originalItem)
    XCTAssertEqual(failing.installedReceipt?.representationID, originalReceipt.representationID)
    XCTAssertTrue(failing.installedReceipt?.isCurrent == true)
    XCTAssertTrue(failing.session.isPlayerReady)
    XCTAssertNil(failing.session.failure)
    XCTAssertNil(surviving.qualityFailure)
    XCTAssertTrue(surviving.session.player.currentItem?.asset === highest)
    XCTAssertEqual(surviving.installedReceipt?.representationID, source.preferred?.representationID)
    XCTAssertEqual(source.preferred?.evidence.quality, .highest)
    XCTAssertEqual(source.state, .available)
    XCTAssertEqual(probe.invocations.count, 2)
  }

  func testResourceRetryThenImmediateCloseCreatesNoNativeRequestOrGhostShare() async throws {
    let probe = BindingLoaderProbe()
    let source = probe.resources().photosSource(serializedCloudIdentifier: "retry-close")
    let binding = VideoResourcePlayback()
    defer { binding.cleanup(); probe.finishOutstanding() }
    binding.load(source: source)
    try await waitUntil { probe.invocations.count == 1 }
    probe.finish(0, with: .failure(VideoResourceFailure.networkRequired))
    try await waitUntil { binding.session.failure != nil }
    let terminalState = source.state

    // No actor suspension between Retry and close: cancelled loaders must never
    // create preparation shares before the native loader actually enters.
    binding.retry(source: source)
    binding.cleanup()
    await settle()

    XCTAssertEqual(probe.invocations.count, 1)
    XCTAssertEqual(source.state, terminalState,
      "No new operation may leave acquiring state or erase the shared terminal failure")
    XCTAssertNil(source.preferred)
    XCTAssertNil(binding.installedReceipt)
    XCTAssertNil(binding.session.player.currentItem)
  }

  func testCleanupAndSameSourceReloadKeepNewInstalledReceiptAndAllowHighQuality() async throws {
    let probe = BindingLoaderProbe()
    let source = probe.resources().photosSource(serializedCloudIdentifier: "same-source-visit")
    let binding = VideoResourcePlayback()
    defer { binding.cleanup(); probe.finishOutstanding() }
    let automatic = try await movie()
    let highest = try await movie(blue: true)
    try await ready(binding, source: source, probe: probe, asset: automatic)
    let oldVisit = binding.session.sourcePresentationID

    binding.cleanup()
    binding.load(source: source)
    try await waitUntil { binding.session.isPlayerReady && binding.installedReceipt != nil }
    let currentVisit = binding.session.sourcePresentationID
    XCTAssertNotEqual(currentVisit, oldVisit)
    XCTAssertTrue(binding.installedReceipt?.isCurrent == true)
    XCTAssertTrue(binding.session.player.currentItem?.asset === automatic)
    XCTAssertEqual(probe.invocations.count, 1, "The valid resource may be reused across source visits")

    binding.requestHighQuality()
    try await waitUntil { probe.invocations.count == 2 }
    probe.finish(1, with: .success(.init(asset: highest)))
    try await waitUntil { binding.installedReceipt?.evidence.quality == .highest }
    XCTAssertEqual(binding.session.sourcePresentationID, currentVisit,
      "HQ installs within the same source visit rather than resetting its presentation facts")
    XCTAssertTrue(binding.session.player.currentItem?.asset === highest)
  }

  func testNewLoadRejectsLateCompletionFromPreviousSourceVisit() async throws {
    let probe = BindingLoaderProbe()
    let resources = probe.resources()
    let oldSource = resources.photosSource(serializedCloudIdentifier: "old-A")
    let currentSource = resources.photosSource(serializedCloudIdentifier: "current-B")
    let binding = VideoResourcePlayback()
    defer { binding.cleanup(); probe.finishOutstanding() }
    let oldAsset = try await movie()
    let currentAsset = try await movie(blue: true)
    binding.load(source: oldSource)
    try await waitUntil { probe.invocations.count == 1 }

    binding.load(source: currentSource)
    try await waitUntil { probe.invocations.count == 2 && probe.cancelledIndices.contains(0) }
    probe.finish(1, with: .success(.init(asset: currentAsset)))
    try await waitUntil { binding.session.isPlayerReady && binding.installedReceipt != nil }
    let currentItem = try XCTUnwrap(binding.session.player.currentItem)
    let currentReceipt = try XCTUnwrap(binding.installedReceipt)
    probe.finish(0, with: .success(.init(asset: oldAsset)))
    try await waitUntil { probe.returnedIndices.contains(0) }
    await settle()

    XCTAssertTrue(binding.session.player.currentItem === currentItem)
    XCTAssertTrue(currentItem.asset === currentAsset)
    XCTAssertEqual(binding.installedReceipt?.representationID, currentReceipt.representationID)
    XCTAssertEqual(currentSource.preferred?.representationID, currentReceipt.representationID)
    XCTAssertNil(oldSource.preferred)
  }

  func testAudioPreparationRetryDoesNotRequestOrVerifyFileResourceAgain() async throws {
    let asset = try await movie()
    let file = VerifiedVideoFile(url: asset.url,
      fingerprint: try VideoFileFingerprint.capture(at: asset.url))
    var verifiedFileCalls = 0
    var photosCalls = 0
    var preparationCalls = 0
    let resources = VideoResources(photos: PhotosVideoProvider(
      authority: { _ in "unused" }, load: { _, _, _ in
        photosCalls += 1
        throw VideoResourceFailure.sourceUnavailable
      }), verifiedFile: { _ in verifiedFileCalls += 1; return file })
    let source = resources.fileSource(identity: "verified-local-video")
    let binding = VideoResourcePlayback(preparation: PlaybackPreparation(prepare: { _ in
      preparationCalls += 1
      if preparationCalls == 1 { throw BindingTestError.audioDenied }
    }, release: { _ in }))
    defer { binding.cleanup() }
    binding.load(source: source)
    try await waitUntil { binding.session.isPlayerReady && binding.installedReceipt != nil }
    let item = try XCTUnwrap(binding.session.player.currentItem)
    let receipt = try XCTUnwrap(binding.installedReceipt)
    XCTAssertEqual(verifiedFileCalls, 1)
    binding.session.togglePlayback()
    try await waitUntil {
      if case .preparation = binding.session.failure { return true }
      return false
    }

    binding.retry(source: source)
    try await waitUntil { preparationCalls == 2 && binding.session.failure == nil }

    XCTAssertEqual(verifiedFileCalls, 1, "Audio Retry must not even enter the Core file verifier")
    XCTAssertEqual(photosCalls, 0)
    XCTAssertTrue(binding.session.player.currentItem === item)
    XCTAssertEqual(binding.installedReceipt?.representationID, receipt.representationID)
    XCTAssertTrue(binding.session.isPlayerReady)
    XCTAssertTrue(binding.session.isPlaybackRequested)
  }

  func testResourceRetryAndCloseDoNotInvalidateAnotherConsumersExistingShare() async throws {
    let probe = BindingLoaderProbe()
    let source = probe.resources().photosSource(serializedCloudIdentifier: "external-share")
    let externalConsumer = source.prepare()
    let binding = VideoResourcePlayback()
    defer { externalConsumer.cancel(); binding.cleanup(); probe.finishOutstanding() }
    let asset = try await movie()
    binding.load(source: source)
    try await waitUntil { probe.invocations.count == 1 }
    await settle()

    binding.retry(source: source)
    await settle()
    binding.cleanup()
    await settle()
    XCTAssertEqual(probe.invocations.count, 1,
      "A consumer-local Retry may join the independently retained pending operation")
    XCTAssertTrue(probe.cancelledIndices.isEmpty)
    probe.finish(0, with: .success(.init(asset: asset)))
    let externalReceipt = try await externalConsumer.value()

    XCTAssertTrue(externalReceipt.asset === asset)
    XCTAssertTrue(externalReceipt.isCurrent)
    XCTAssertEqual(source.preferred?.representationID, externalReceipt.representationID)
    XCTAssertNil(binding.installedReceipt)
    XCTAssertTrue(probe.cancelledIndices.isEmpty)
  }

  func testHighQualityRequestThenImmediateCloseDoesNotCreateGhostResourceWork() async throws {
    let probe = BindingLoaderProbe()
    let source = probe.resources().photosSource(serializedCloudIdentifier: "HQ-close-before-entry")
    let binding = VideoResourcePlayback()
    defer { binding.cleanup(); probe.finishOutstanding() }
    let asset = try await movie()
    try await ready(binding, source: source, probe: probe, asset: asset)
    let receipt = try XCTUnwrap(binding.installedReceipt)

    binding.requestHighQuality()
    binding.cleanup()
    await settle()

    XCTAssertEqual(probe.invocations.count, 1)
    XCTAssertEqual(source.state, .available)
    XCTAssertEqual(source.preferred?.representationID, receipt.representationID)
    XCTAssertNil(binding.installedReceipt)
    XCTAssertTrue(probe.cancelledIndices.isEmpty)
  }

  func testDroppingOnlyOwnerDuringInitialLoadCancelsShareAndRejectsLateSuccess() async throws {
    let probe = BindingLoaderProbe()
    let source = probe.resources().photosSource(serializedCloudIdentifier: "initial-owner-release")
    let asset = try await movie()
    var binding: VideoResourcePlayback? = VideoResourcePlayback()
    weak var releasedOwner = binding
    let native = try XCTUnwrap(binding?.session)
    defer { native.cleanup(); probe.finishOutstanding() }
    binding?.load(source: source)
    try await waitUntil { probe.invocations.count == 1 }

    // Keep the native session to inspect it, but release the only binding owner.
    // Explicit cleanup here would hide a strong owner captured across the await.
    binding = nil
    XCTAssertNil(releasedOwner, "The initial acquisition task must not retain its binding owner")
    try await waitUntil { probe.cancelledIndices.contains(0) }
    if case .acquiring = source.state {
      XCTFail("Releasing the sole binding must end its pending resource share")
    }
    XCTAssertNil(native.player.currentItem)
    probe.finish(0, with: .success(.init(asset: asset)))
    try await waitUntil { probe.returnedIndices.contains(0) }
    await settle()

    XCTAssertNil(releasedOwner)
    XCTAssertNil(native.player.currentItem)
    XCTAssertNil(source.preferred, "A late result of cancelled initial work cannot become preferred")
  }

  func testDroppingOwnerDuringNativeHighQualityPreparationClearsPlayerAndRejectsLateCandidate() async throws {
    let probe = BindingLoaderProbe()
    let gate = BindingReplacementGate()
    let source = probe.resources().photosSource(serializedCloudIdentifier: "HQ-owner-release")
    let automatic = try await movie()
    let highest = try await movie(blue: true)
    let native = PlaybackSession(transportSeek: PlaybackSession.seekTransport,
      prepareReplacement: gate.prepare)
    var binding: VideoResourcePlayback? = VideoResourcePlayback(session: native)
    weak var releasedOwner = binding
    defer { native.cleanup(); gate.finishAll(); probe.finishOutstanding() }
    try await ready(try XCTUnwrap(binding), source: source, probe: probe, asset: automatic)
    binding?.requestHighQuality()
    try await waitUntil { probe.invocations.count == 2 }
    probe.finish(1, with: .success(.init(asset: highest)))
    try await waitUntil { gate.invocationCount == 1 }
    let sharedHQ = try XCTUnwrap(source.preferred)
    XCTAssertEqual(sharedHQ.evidence.quality, .highest)

    binding = nil
    XCTAssertNil(releasedOwner, "Native replacement awaits must not keep the binding owner alive")
    XCTAssertNil(native.player.currentItem)
    XCTAssertEqual(source.preferred?.representationID, sharedHQ.representationID,
      "Releasing playback owns no right to invalidate an already acquired shared resource")
    gate.finishAll()
    try await waitUntil { gate.returnedCount == 1 }
    await settle()

    XCTAssertNil(native.player.currentItem)
    XCTAssertNil(releasedOwner)
    XCTAssertEqual(source.preferred?.representationID, sharedHQ.representationID)
  }

  func testReentrantHighQualityPublicationCreatesOnlyOneNativeInstallationAttempt() async throws {
    let probe = BindingLoaderProbe()
    let gate = BindingReplacementGate()
    let source = probe.resources().photosSource(serializedCloudIdentifier: "reentrant-HQ-install")
    let native = PlaybackSession(transportSeek: PlaybackSession.seekTransport,
      prepareReplacement: gate.prepare)
    let binding = VideoResourcePlayback(session: native)
    defer { binding.cleanup(); gate.finishAll(); probe.finishOutstanding() }
    let automatic = try await movie()
    let highest = try await movie(blue: true)
    try await ready(binding, source: source, probe: probe, asset: automatic)
    let observation = reenterHighQualityOnce(binding, source: source)

    binding.requestHighQuality()
    XCTAssertTrue(observation.fired, "The fixture must reenter synchronously during acquiring publication")
    try await waitUntil { probe.invocations.count == 2 }
    probe.finish(1, with: .success(.init(asset: highest)))
    try await waitUntil { gate.invocationCount >= 1 }
    await settle()

    XCTAssertEqual(gate.invocationCount, 1,
      "One binding's reentrant HQ request must not create competing native installation attempts")
    binding.cleanup()
    gate.finishAll()
    try await waitUntil { gate.returnedCount == gate.invocationCount }
    await settle()
    XCTAssertNil(native.player.currentItem)
  }

  func testReentrantHighQualityPublicationCloseReleasesEveryOwnedShare() async throws {
    let probe = BindingLoaderProbe()
    let source = probe.resources().photosSource(serializedCloudIdentifier: "reentrant-HQ-close")
    let binding = VideoResourcePlayback()
    defer { binding.cleanup(); probe.finishOutstanding() }
    let automatic = try await movie()
    let highest = try await movie(blue: true)
    try await ready(binding, source: source, probe: probe, asset: automatic)
    let original = try XCTUnwrap(source.preferred)
    let observation = reenterHighQualityOnce(binding, source: source)

    binding.requestHighQuality()
    XCTAssertTrue(observation.fired)
    try await waitUntil { probe.invocations.count == 2 }
    binding.cleanup()
    await settle()
    XCTAssertEqual(probe.cancelledIndices, [1],
      "Close must retain and release all this owner's shares despite synchronous request reentry")
    probe.finish(1, with: .success(.init(asset: highest)))
    try await waitUntil { probe.returnedIndices.contains(1) }
    await settle()

    XCTAssertNil(binding.session.player.currentItem)
    XCTAssertNil(binding.installedReceipt)
    XCTAssertEqual(source.preferred?.representationID, original.representationID,
      "An orphaned reentrant share must not let late HQ publish after playback closes")
  }

  func testExplicitResourceRetryAfterNativeInvalidationReopensSourceWithoutRetainedVisit() async throws {
    let probe = BindingLoaderProbe()
    let source = probe.resources().photosSource(serializedCloudIdentifier: "invalidated-explicit-retry")
    let binding = VideoResourcePlayback()
    defer { binding.cleanup(); probe.finishOutstanding() }
    let originalAsset = try await movie()
    let retryAsset = try await movie(blue: true)
    try await ready(binding, source: source, probe: probe, asset: originalAsset)
    let originalReceipt = try XCTUnwrap(binding.installedReceipt)

    source.invalidate()
    XCTAssertFalse(originalReceipt.isCurrent)
    XCTAssertNil(binding.installedReceipt)
    binding.session.togglePlayback()
    XCTAssertNil(binding.session.player.currentItem,
      "The native final-use validation must clean up the expired source visit")
    guard case .source(let reason) = binding.session.failure else {
      return XCTFail("An expired receipt must produce the native source failure")
    }
    XCTAssertEqual(reason as? VideoResourceFailure, .sourceChanged)

    // The caller supplies its current source. Retry must work even after native
    // cleanup has removed the binding's previous finite consumption/visit.
    binding.retry(source: source, autoplayWhenReady: false)
    try await waitUntil { probe.invocations.count == 2 }
    probe.finish(1, with: .success(.init(asset: retryAsset)))
    try await waitUntil { binding.session.isPlayerReady && binding.installedReceipt != nil }

    let retryReceipt = try XCTUnwrap(binding.installedReceipt)
    XCTAssertNotEqual(retryReceipt.representationID, originalReceipt.representationID)
    XCTAssertTrue(retryReceipt.isCurrent)
    XCTAssertTrue(binding.session.player.currentItem?.asset === retryAsset)
    XCTAssertNil(binding.session.failure)
    XCTAssertEqual(probe.invocations.count, 2)
  }

  func testRetrySelectingDifferentSourceAfterAudioFailureLoadsNewSourceWithoutPreparingOldAudio() async throws {
    let probe = BindingLoaderProbe()
    let resources = probe.resources()
    let sourceA = resources.photosSource(serializedCloudIdentifier: "audio-failed-A")
    let sourceB = resources.photosSource(serializedCloudIdentifier: "selected-B")
    var preparationCalls = 0
    let binding = VideoResourcePlayback(preparation: PlaybackPreparation(prepare: { _ in
      preparationCalls += 1
      if preparationCalls == 1 { throw BindingTestError.audioDenied }
    }, release: { _ in }))
    defer { binding.cleanup(); probe.finishOutstanding() }
    let assetA = try await movie()
    let assetB = try await movie(blue: true)
    try await ready(binding, source: sourceA, probe: probe, asset: assetA)
    let receiptA = try XCTUnwrap(binding.installedReceipt)
    binding.session.togglePlayback()
    try await waitUntil {
      if case .preparation = binding.session.failure { return true }
      return false
    }
    XCTAssertEqual(preparationCalls, 1)

    binding.retry(source: sourceB, autoplayWhenReady: false)
    // Observe which externally visible path Retry took. The old-audio branch
    // fails immediately rather than waiting for an acquisition it never starts.
    try await waitUntil { probe.invocations.count == 2 || preparationCalls > 1 }
    XCTAssertEqual(preparationCalls, 1,
      "Retry selecting B with autoplay disabled must not resume A's failed audio preparation")
    guard probe.invocations.count == 2 else {
      return XCTFail("Selecting source B must enter B's resource acquisition despite A's audio failure")
    }
    XCTAssertEqual(probe.invocations[1].identifier, "selected-B")
    probe.finish(1, with: .success(.init(asset: assetB)))
    try await waitUntil { binding.session.isPlayerReady && binding.installedReceipt != nil }

    XCTAssertTrue(binding.session.player.currentItem?.asset === assetB)
    XCTAssertEqual(binding.installedReceipt?.representationID, sourceB.preferred?.representationID)
    XCTAssertNotEqual(binding.installedReceipt?.representationID, receiptA.representationID)
    XCTAssertTrue(receiptA.isCurrent, "Switching playback does not invalidate source A's resource")
    XCTAssertEqual(preparationCalls, 1)
    XCTAssertFalse(binding.session.isPlaybackRequested)
    XCTAssertNil(binding.session.failure)
  }

  func testInitialAcceptedReceiptObserverCloseReleasesSourceAndMedia() async throws {
    let probe = BindingLoaderProbe()
    let resources = probe.resources()
    var source: VideoSource? = resources.photosSource(serializedCloudIdentifier: "initial-receipt-close")
    var media: AVURLAsset? = try await movie()
    weak var weakSource = source
    weak var weakMedia = media
    let binding = VideoResourcePlayback()
    defer { binding.cleanup(); probe.finishOutstanding() }
    binding.load(source: try XCTUnwrap(source))
    try await waitUntil { probe.invocations.count == 1 }
    let observation = BindingReentrantObservation()
    withObservationTracking {
      _ = binding.installedReceipt
    } onChange: {
      MainActor.assumeIsolated {
        guard !observation.fired else { return }
        observation.fired = true
        binding.cleanup()
      }
    }
    probe.finish(0, with: .success(.init(asset: try XCTUnwrap(media))))
    try await waitUntil { probe.returnedIndices.contains(0) }
    await settle()
    XCTAssertTrue(observation.fired, "Actual receipt publication must reach the public observation")
    XCTAssertNil(binding.installedReceipt)
    XCTAssertNil(binding.session.player.currentItem)
    source = nil
    media = nil
    await settle()
    XCTAssertNil(weakSource, "A closed binding must not restore and retain its retired receipt's source")
    XCTAssertNil(weakMedia, "A closed binding must release the actual media after its host releases it")
  }

  func testHighQualityAcceptedReceiptObserverCloseReleasesSourceAndMedia() async throws {
    let probe = BindingLoaderProbe()
    let resources = probe.resources()
    var source: VideoSource? = resources.photosSource(serializedCloudIdentifier: "HQ-receipt-close")
    var media: AVURLAsset? = try await movie(blue: true)
    weak var weakSource = source
    weak var weakMedia = media
    let binding = VideoResourcePlayback()
    defer { binding.cleanup(); probe.finishOutstanding() }
    try await ready(binding, source: try XCTUnwrap(source), probe: probe, asset: try await movie())
    binding.requestHighQuality()
    try await waitUntil { probe.invocations.count == 2 }
    let observation = BindingReentrantObservation()
    withObservationTracking {
      _ = binding.highQualityAction
    } onChange: {
      MainActor.assumeIsolated {
        guard !observation.fired else { return }
        observation.fired = true
        binding.cleanup()
      }
    }
    probe.finish(1, with: .success(.init(asset: try XCTUnwrap(media))))
    try await waitUntil { probe.returnedIndices.contains(1) && observation.fired }
    await settle()
    XCTAssertEqual(binding.highQualityAction, .hidden)
    XCTAssertNil(binding.installedReceipt)
    XCTAssertNil(binding.session.player.currentItem)
    source = nil
    media = nil
    await settle()
    XCTAssertNil(weakSource, "HQ publication after same-stack close cannot retain the retired source")
    XCTAssertNil(weakMedia, "The discarded actual HQ media must not be held by the closed binding")
  }

  func testInitialPreparationProgressIgnoresPeerHighestQualityRequest() async throws {
    let probe = BindingLoaderProbe()
    let source = probe.resources().photosSource(serializedCloudIdentifier: "initial-owned-progress")
    let binding = VideoResourcePlayback()
    defer { binding.cleanup(); probe.finishOutstanding() }
    let automatic = try await movie()
    XCTAssertNil(binding.preparationProgress)
    binding.load(source: source)
    try await waitUntil { probe.invocations.count == 1 }
    XCTAssertNil(binding.preparationProgress, "No native progress has been reported yet")
    let observation = BindingReentrantObservation()
    withObservationTracking {
      _ = binding.preparationProgress
    } onChange: {
      MainActor.assumeIsolated { observation.fired = true }
    }
    probe.report(0.25, at: 0)
    await settle()
    XCTAssertTrue(observation.fired, "The current operation's native progress must be observable")
    XCTAssertEqual(binding.preparationProgress, 0.25)

    let peer = source.prepare(.init(quality: .highest, network: .allowed))
    defer { peer.cancel() }
    try await waitUntil { probe.invocations.count == 2 }
    probe.report(0.8, at: 1)
    await settle()
    XCTAssertEqual(source.state, .acquiring(0.8), "The peer really changed the source-wide progress")
    XCTAssertEqual(binding.preparationProgress, 0.25,
      "Peer HQ progress must not become this session's initial loading feedback")
    probe.finish(0, with: .success(.init(asset: automatic)))
    try await waitUntil { binding.installedReceipt != nil }
    XCTAssertNil(binding.preparationProgress)
    XCTAssertTrue(binding.session.player.currentItem?.asset === automatic)
  }

  func testInitialPreparationProgressInvalidationRejectsLateProgressAndPlayableResult() async throws {
    let probe = BindingLoaderProbe()
    let source = probe.resources().photosSource(serializedCloudIdentifier: "initial-invalidated-progress")
    let binding = VideoResourcePlayback()
    defer { binding.cleanup(); probe.finishOutstanding() }
    let lateAsset = try await movie()
    binding.load(source: source)
    try await waitUntil { probe.invocations.count == 1 }
    probe.report(0.25, at: 0)
    await settle()
    XCTAssertEqual(binding.preparationProgress, 0.25)

    source.invalidate()
    try await waitUntil { probe.cancelledIndices.contains(0) }
    await settle()
    XCTAssertNil(binding.preparationProgress)
    XCTAssertNil(binding.session.player.currentItem)
    probe.report(0.9, at: 0)
    probe.finish(0, with: .success(.init(asset: lateAsset)))
    try await waitUntil { probe.returnedIndices.contains(0) }
    await settle()
    XCTAssertNil(binding.preparationProgress)
    XCTAssertNil(binding.installedReceipt)
    XCTAssertNil(binding.session.player.currentItem,
      "A playable late native result cannot reinstall an invalidated visit")
    XCTAssertNil(source.preferred)
    XCTAssertEqual(probe.invocations.count, 1, "Invalidation must not automatically request again")
  }

  func testInitialPreparationPublicationObserverCloseCannotRestoreOwnedShare() async throws {
    let probe = BindingLoaderProbe()
    let source = probe.resources().photosSource(serializedCloudIdentifier: "initial-observable-close")
    let binding = VideoResourcePlayback()
    defer { binding.cleanup(); probe.finishOutstanding() }
    let observation = BindingReentrantObservation()
    withObservationTracking {
      _ = binding.preparationProgress
    } onChange: {
      MainActor.assumeIsolated {
        guard !observation.fired else { return }
        observation.fired = true
        binding.cleanup()
      }
    }
    binding.load(source: source)
    await settle()
    XCTAssertTrue(observation.fired, "Initial preparation publication must notify its consumer")
    XCTAssertNil(binding.preparationProgress)
    XCTAssertNil(binding.installedReceipt)
    XCTAssertNil(binding.session.player.currentItem)
    XCTAssertEqual(probe.invocations.count, 0,
      "Synchronous close must retract the preparation before native work enters")
    XCTAssertNil(source.preferred)
    XCTAssertEqual(source.state, .idle)
  }

  func testHighQualityProgressBelongsToEachSharedConsumerAndIgnoresOtherRequests() async throws {
    let probe = BindingLoaderProbe()
    let source = probe.resources().photosSource(serializedCloudIdentifier: "consumer-progress")
    let first = VideoResourcePlayback()
    let second = VideoResourcePlayback()
    defer { first.cleanup(); second.cleanup(); probe.finishOutstanding() }
    let automatic = try await movie()
    let highest = try await movie(blue: true)
    first.load(source: source)
    second.load(source: source)
    try await waitUntil { probe.invocations.count == 1 }
    probe.finish(0, with: .success(.init(asset: automatic)))
    try await waitUntil { first.installedReceipt != nil && second.installedReceipt != nil }

    first.requestHighQuality()
    second.requestHighQuality()
    try await waitUntil { probe.invocations.count == 2 }
    probe.report(0.25, at: 1)
    await settle()
    XCTAssertEqual(first.highQualityAction, .loading(0.25))
    XCTAssertEqual(second.highQualityAction, .loading(0.25))

    let unrelated = source.prepare(.init(quality: .highest, network: .forbidden))
    defer { unrelated.cancel() }
    try await waitUntil { probe.invocations.count == 3 }
    probe.report(0.9, at: 2)
    await settle()
    XCTAssertEqual(first.highQualityAction, .loading(0.25),
      "Another request's progress must not become this consumer's HQ progress")
    XCTAssertEqual(second.highQualityAction, .loading(0.25))

    first.cleanup()
    XCTAssertEqual(first.highQualityAction, .hidden)
    XCTAssertTrue(probe.cancelledIndices.isEmpty)
    probe.report(0.6, at: 1)
    await settle()
    XCTAssertEqual(second.highQualityAction, .loading(0.6))
    probe.finish(1, with: .success(.init(asset: highest)))
    try await waitUntil { second.installedReceipt?.evidence.quality == .highest }
    XCTAssertEqual(first.highQualityAction, .hidden)
    XCTAssertEqual(second.highQualityAction, .hidden)
  }

  func testHighQualityPublicationObserverCloseNeverRestoresOwnedShare() async throws {
    let probe = BindingLoaderProbe()
    let source = probe.resources().photosSource(serializedCloudIdentifier: "observable-HQ-close")
    let binding = VideoResourcePlayback()
    defer { binding.cleanup(); probe.finishOutstanding() }
    let automatic = try await movie()
    try await ready(binding, source: source, probe: probe, asset: automatic)
    let original = try XCTUnwrap(binding.installedReceipt)
    let observation = BindingReentrantObservation()
    withObservationTracking {
      _ = binding.highQualityAction
    } onChange: {
      MainActor.assumeIsolated {
        guard !observation.fired else { return }
        observation.fired = true
        binding.cleanup()
      }
    }

    binding.requestHighQuality()
    await settle()

    XCTAssertTrue(observation.fired, "Starting HQ must publish this consumer's observable action")
    XCTAssertEqual(binding.highQualityAction, .hidden)
    XCTAssertNil(binding.installedReceipt)
    XCTAssertNil(binding.session.player.currentItem)
    XCTAssertEqual(probe.invocations.count, 1,
      "Synchronous close during action publication must withdraw the share before native entry")
    XCTAssertEqual(source.preferred?.representationID, original.representationID)
  }

  func testHighQualityLocalProbeOnlyConfirmedNetworkRequirementOffersExplicitRequest() async throws {
    let probe = BindingLoaderProbe()
    let source = probe.resources().photosSource(serializedCloudIdentifier: "local-needs-network")
    let binding = VideoResourcePlayback()
    defer { binding.cleanup(); probe.finishOutstanding() }
    let automatic = try await movie()
    let highest = try await movie(blue: true)
    try await ready(binding, source: source, probe: probe, asset: automatic)
    let original = try XCTUnwrap(binding.installedReceipt)
    binding.checkLocalHighQuality()
    binding.checkLocalHighQuality()
    await settle()
    guard probe.invocations.count == 2 else {
      return XCTFail("The usable automatic representation requires one finite local HQ check")
    }
    XCTAssertEqual(probe.invocations[1].request, .init(quality: .highest, network: .forbidden))
    XCTAssertEqual(binding.highQualityAction, .hidden, "A passive local check is not an explicit HQ spinner")
    probe.finish(1, with: .failure(VideoResourceFailure.networkRequired))
    try await waitUntil { binding.localHighQualityAvailability == .requiresNetwork }
    XCTAssertEqual(binding.highQualityAction, .available)
    XCTAssertNil(binding.qualityFailure)
    XCTAssertEqual(binding.installedReceipt?.representationID, original.representationID)
    binding.checkLocalHighQuality()
    await settle()
    XCTAssertEqual(probe.invocations.count, 2, "The same representation's failed check never retries automatically")

    binding.requestHighQuality()
    try await waitUntil { probe.invocations.count == 3 }
    XCTAssertEqual(probe.invocations[2].request, .init(quality: .highest, network: .allowed))
    XCTAssertEqual(binding.highQualityAction, .loading(nil))
    probe.finish(2, with: .success(.init(asset: highest)))
    try await waitUntil { binding.installedReceipt?.evidence.quality == .highest }
    XCTAssertEqual(binding.highQualityAction, .hidden)
  }

  func testHighQualityUnknownLocalFailuresKeepUsableMediaAndDoNotOfferNetworkControl() async throws {
    let automatic = try await movie()
    for reason in [VideoResourceFailure.acquisitionFailed, .sourceUnavailable] {
      let probe = BindingLoaderProbe()
      let source = probe.resources().photosSource(serializedCloudIdentifier: "unknown-local")
      let binding = VideoResourcePlayback()
      defer { binding.cleanup(); probe.finishOutstanding() }
      try await ready(binding, source: source, probe: probe, asset: automatic)
      let original = try XCTUnwrap(binding.installedReceipt)
      binding.checkLocalHighQuality()
      await settle()
      guard probe.invocations.count == 2 else {
        return XCTFail("The fixture must exercise the actual forbidden-network HQ request")
      }
      probe.finish(1, with: .failure(reason))
      try await waitUntil { probe.returnedIndices.contains(1) }
      await settle()
      XCTAssertEqual(binding.localHighQualityAvailability, .unknown)
      XCTAssertEqual(binding.highQualityAction, .hidden)
      XCTAssertNil(binding.qualityFailure, "An unknown local check is not an explicit quality failure")
      XCTAssertEqual(binding.installedReceipt?.representationID, original.representationID)
      XCTAssertTrue(binding.session.isPlayerReady)
      binding.checkLocalHighQuality()
      await settle()
      XCTAssertEqual(probe.invocations.count, 2)
    }
  }

  func testHighQualityLocalCheckWaitsForUsableMediaAndSkipsVerifiedFiles() async throws {
    let probe = BindingLoaderProbe()
    let source = probe.resources().photosSource(serializedCloudIdentifier: "probe-after-ready")
    let binding = VideoResourcePlayback()
    defer { binding.cleanup(); probe.finishOutstanding() }
    let automatic = try await movie()
    let highest = try await movie(blue: true)
    binding.load(source: source)
    binding.checkLocalHighQuality()
    try await waitUntil { probe.invocations.count == 1 }
    XCTAssertEqual(probe.invocations.count, 1, "No HQ check runs before the initial item is usable")
    probe.finish(0, with: .success(.init(asset: automatic)))
    try await waitUntil { binding.installedReceipt != nil }
    binding.checkLocalHighQuality()
    await settle()
    guard probe.invocations.count == 2 else {
      return XCTFail("A usable Photos automatic item can start its local classification")
    }
    probe.finish(1, with: .success(.init(asset: highest)))
    try await waitUntil { binding.installedReceipt?.evidence.quality == .highest }
    XCTAssertTrue(binding.session.player.currentItem?.asset === highest)
    XCTAssertEqual(binding.highQualityAction, .hidden)
    XCTAssertNil(binding.qualityFailure)

    let file = VerifiedVideoFile(url: automatic.url,
      fingerprint: try VideoFileFingerprint.capture(at: automatic.url))
    var verifications = 0
    var photosCalls = 0
    let resources = VideoResources(photos: PhotosVideoProvider(authority: { _ in "unused" },
      load: { _, _, _ in photosCalls += 1; throw VideoResourceFailure.sourceUnavailable }),
      verifiedFile: { _ in verifications += 1; return file })
    let local = VideoResourcePlayback()
    defer { local.cleanup() }
    local.load(source: resources.fileSource(identity: "full-verified-descriptor"))
    try await waitUntil { local.installedReceipt != nil }
    local.checkLocalHighQuality()
    local.requestHighQuality()
    await settle()
    XCTAssertEqual(verifications, 1)
    XCTAssertEqual(photosCalls, 0)
    XCTAssertEqual(local.highQualityAction, .hidden)
  }

  func testHighQualityInstallationFailureRetainsOnlyOwnExplicitRetryDespiteSharedHQ() async throws {
    let probe = BindingLoaderProbe()
    let source = probe.resources().photosSource(serializedCloudIdentifier: "independent-HQ-action")
    var installations = 0
    let native = PlaybackSession(transportSeek: PlaybackSession.seekTransport,
      prepareReplacement: { asset in
        installations += 1
        if installations == 1 { throw BindingTestError.installationDenied }
        return AVPlayerItem(asset: asset)
      })
    let failing = VideoResourcePlayback(session: native)
    let succeeding = VideoResourcePlayback()
    defer { failing.cleanup(); succeeding.cleanup(); probe.finishOutstanding() }
    let automatic = try await movie()
    let highest = try await movie(blue: true)
    failing.load(source: source)
    succeeding.load(source: source)
    try await waitUntil { probe.invocations.count == 1 }
    probe.finish(0, with: .success(.init(asset: automatic)))
    try await waitUntil { failing.installedReceipt != nil && succeeding.installedReceipt != nil }
    let original = try XCTUnwrap(failing.installedReceipt)
    failing.requestHighQuality()
    succeeding.requestHighQuality()
    try await waitUntil { probe.invocations.count == 2 }
    probe.finish(1, with: .success(.init(asset: highest)))
    try await waitUntil { failing.qualityFailure != nil && succeeding.installedReceipt?.evidence.quality == .highest }
    await settle()
    XCTAssertEqual(failing.installedReceipt?.representationID, original.representationID)
    XCTAssertEqual(failing.highQualityAction, .available,
      "A peer's shared HQ receipt does not erase this session's explicit installation retry")
    XCTAssertEqual(succeeding.highQualityAction, .hidden)
    XCTAssertEqual(installations, 1, "Shared source publication must not automatically retry a failed installation")
    failing.requestHighQuality()
    try await waitUntil { failing.installedReceipt?.evidence.quality == .highest }
    XCTAssertEqual(installations, 2)
    XCTAssertEqual(probe.invocations.count, 2, "Explicit native retry can install the acquired shared HQ receipt")
    XCTAssertEqual(failing.highQualityAction, .hidden)
    XCTAssertNil(failing.qualityFailure)
  }

  private func reenterHighQualityOnce(_ binding: VideoResourcePlayback,
    source: VideoSource) -> BindingReentrantObservation {
    let observation = BindingReentrantObservation()
    withObservationTracking {
      _ = source.state
    } onChange: {
      MainActor.assumeIsolated {
        guard !observation.fired else { return }
        observation.fired = true
        binding.requestHighQuality()
      }
    }
    return observation
  }

  // Insert inside VideoResourcePlaybackTests before its private helpers.
  // Reuses the existing movie/ready/waitUntil/settle, BindingLoaderProbe,
  // and BindingReplacementGate fixtures. No additional owner or provider.

  func testExternalHighestReceiptBeforeInitialReadinessIsInstalledWithoutAnotherRequest() async throws {
    let probe = BindingLoaderProbe()
    let source = probe.resources().photosSource(
      serializedCloudIdentifier: "external-HQ-before-ready")
    var replacements = 0
    let native = PlaybackSession(
      transportSeek: PlaybackSession.seekTransport,
      prepareReplacement: { asset in
        replacements += 1
        return AVPlayerItem(asset: asset)
      })
    let binding = VideoResourcePlayback(session: native)
    defer { binding.cleanup(); probe.finishOutstanding() }

    let automatic = try await movie()
    let highest = try await movie(blue: true)
    binding.load(source: source, playbackRate: 0.5, isLooping: false)
    try await waitUntil { probe.invocations.count == 1 }

    let external = source.prepare(.init(quality: .highest, network: .allowed))
    defer { external.cancel() }
    try await waitUntil { probe.invocations.count == 2 }

    // Keep the initial automatic request pending to guarantee native is not ready.
    probe.finish(1, with: .success(.init(asset: highest)))
    let hq = try await external.value()
    XCTAssertEqual(hq.evidence.quality, .highest)
    XCTAssertEqual(source.preferred?.representationID, hq.representationID)
    XCTAssertFalse(native.isPlayerReady)
    XCTAssertNil(native.player.currentItem)
    XCTAssertEqual(replacements, 0)

    // The late automatic result cannot downgrade preferred. Once its own native
    // item is ready, playback must adopt the already completed external receipt.
    probe.finish(0, with: .success(.init(asset: automatic)))
    try await waitUntil {
      binding.installedReceipt?.representationID == hq.representationID
        && binding.installedReceipt?.evidence.quality == .highest
    }

    XCTAssertTrue(native.player.currentItem?.asset === highest)
    XCTAssertEqual(native.playbackConfig.playbackRate, 0.5)
    XCTAssertFalse(native.playbackConfig.isLooping)
    XCTAssertFalse(native.isPlaybackRequested)
    XCTAssertEqual(binding.highQualityAction, .hidden)
    XCTAssertNil(binding.qualityFailure)
    XCTAssertEqual(replacements, 1)
    XCTAssertEqual(probe.invocations.count, 2,
      "Adopting an existing receipt must not start another native resource request")
  }

  func testExternalPreferredSameRepresentationUpdatesQualityAndNetworkEvidenceWithoutReplacingItem() async throws {
    let probe = BindingLoaderProbe()
    let source = probe.resources().photosSource(
      serializedCloudIdentifier: "external-same-representation")
    var replacements = 0
    let native = PlaybackSession(
      transportSeek: PlaybackSession.seekTransport,
      prepareReplacement: { asset in
        replacements += 1
        return AVPlayerItem(asset: asset)
      })
    let binding = VideoResourcePlayback(session: native)
    defer { binding.cleanup(); probe.finishOutstanding() }

    let asset = try await movie()
    let mix = AVMutableAudioMix()
    binding.load(source: source)
    try await waitUntil { probe.invocations.count == 1 }
    probe.finish(0, with: .success(.init(asset: asset, audioMix: mix)))
    try await waitUntil { binding.installedReceipt != nil }

    let original = try XCTUnwrap(binding.installedReceipt)
    let originalItem = try XCTUnwrap(native.player.currentItem)
    let visit = native.sourcePresentationID
    XCTAssertEqual(original.evidence.quality, .automatic)

    let highest = source.prepare(.init(quality: .highest, network: .allowed))
    defer { highest.cancel() }
    try await waitUntil { probe.invocations.count == 2 }
    // Identical asset and audioMix objects preserve the representation ID.
    probe.finish(1, with: .success(.init(asset: asset, audioMix: mix)))
    let hq = try await highest.value()
    XCTAssertEqual(hq.representationID, original.representationID)
    XCTAssertEqual(hq.evidence.quality, .highest)

    try await waitUntil { binding.installedReceipt?.evidence == hq.evidence }
    XCTAssertTrue(native.player.currentItem === originalItem)
    XCTAssertTrue(binding.installedReceipt?.audioMix === mix)
    XCTAssertTrue(native.currentLoadedMedia?.audioMix === mix)
    XCTAssertEqual(binding.highQualityAction, .hidden)

    // Preserve the same ID again, changing only network evidence.
    let local = source.prepare(.init(quality: .highest, network: .forbidden))
    defer { local.cancel() }
    try await waitUntil { probe.invocations.count == 3 }
    probe.finish(2, with: .success(.init(asset: asset, audioMix: mix)))
    let localHQ = try await local.value()
    XCTAssertEqual(localHQ.representationID, original.representationID)
    XCTAssertEqual(localHQ.evidence.network, .forbidden)

    try await waitUntil { binding.installedReceipt?.evidence == localHQ.evidence }
    XCTAssertTrue(native.player.currentItem === originalItem)
    XCTAssertEqual(native.sourcePresentationID, visit)
    XCTAssertEqual(replacements, 0)
    XCTAssertEqual(probe.invocations.count, 3,
      "Only the initial request and the two explicit external requests may run")
  }

  func testExternalHighestInstallationFailurePreservesItemAndRequiresExplicitRetry() async throws {
    let probe = BindingLoaderProbe()
    let source = probe.resources().photosSource(
      serializedCloudIdentifier: "external-HQ-failed-install")
    var installations = 0
    let native = PlaybackSession(
      transportSeek: PlaybackSession.seekTransport,
      prepareReplacement: { asset in
        installations += 1
        if installations == 1 { throw BindingTestError.installationDenied }
        return AVPlayerItem(asset: asset)
      })
    let binding = VideoResourcePlayback(session: native)
    defer { binding.cleanup(); probe.finishOutstanding() }

    let automatic = try await movie()
    let highest = try await movie(blue: true)
    try await ready(binding, source: source, probe: probe, asset: automatic)
    let original = try XCTUnwrap(binding.installedReceipt)
    let originalItem = try XCTUnwrap(native.player.currentItem)
    let visit = native.sourcePresentationID

    let external = source.prepare(.init(quality: .highest, network: .allowed))
    defer { external.cancel() }
    try await waitUntil { probe.invocations.count == 2 }
    probe.finish(1, with: .success(.init(asset: highest)))
    let hq = try await external.value()
    try await waitUntil { binding.qualityFailure != nil }
    await settle()

    XCTAssertEqual(installations, 1)
    XCTAssertTrue(native.player.currentItem === originalItem)
    XCTAssertEqual(binding.installedReceipt?.representationID, original.representationID)
    XCTAssertTrue(original.isCurrent)
    XCTAssertTrue(native.isPlayerReady)
    XCTAssertNil(native.failure)
    XCTAssertEqual(binding.highQualityAction, .available)

    // Force a real second preferred notification. The same failed native
    // representation must not install itself again merely because evidence grew.
    let local = source.prepare(.init(quality: .highest, network: .forbidden))
    defer { local.cancel() }
    try await waitUntil { probe.invocations.count == 3 }
    probe.finish(2, with: .success(.init(asset: highest)))
    let localHQ = try await local.value()
    XCTAssertEqual(localHQ.representationID, hq.representationID)
    XCTAssertEqual(localHQ.evidence.network, .forbidden)
    await settle()

    XCTAssertEqual(installations, 1)
    XCTAssertTrue(native.player.currentItem === originalItem)
    XCTAssertNotNil(binding.qualityFailure)
    XCTAssertEqual(binding.highQualityAction, .available)

    // Only the explicit retry below may attempt native installation again.
    binding.requestHighQuality()
    try await waitUntil {
      binding.installedReceipt?.representationID == localHQ.representationID
        && binding.installedReceipt?.evidence == localHQ.evidence
    }
    XCTAssertEqual(installations, 2)
    XCTAssertEqual(probe.invocations.count, 3,
      "Explicit installation retry must reuse the already acquired HQ receipt")
    XCTAssertTrue(native.player.currentItem?.asset === highest)
    XCTAssertEqual(native.sourcePresentationID, visit)
    XCTAssertEqual(binding.highQualityAction, .hidden)
    XCTAssertNil(binding.qualityFailure)
  }

  func testExternalHighestReceiptIsAcceptedOnlyAfterNativeInstallation() async throws {
    let probe = BindingLoaderProbe()
    let gate = BindingReplacementGate()
    let resources = probe.resources()
    let source = resources.photosSource(serializedCloudIdentifier: "external-HQ-pending-success")
    let native = PlaybackSession(
      transportSeek: PlaybackSession.seekTransport,
      prepareReplacement: gate.prepare)
    let binding = VideoResourcePlayback(session: native)
    defer { binding.cleanup(); gate.finishAll(); probe.finishOutstanding() }

    let automatic = try await movie()
    let highest = try await movie(blue: true)
    let mix = AVMutableAudioMix()
    try await ready(binding, source: source, probe: probe, asset: automatic)
    let original = try XCTUnwrap(binding.installedReceipt)
    let originalItem = try XCTUnwrap(native.player.currentItem)
    let visit = native.sourcePresentationID

    let external = source.prepare(.init(quality: .highest, network: .allowed))
    defer { external.cancel() }
    try await waitUntil { probe.invocations.count == 2 }

    // Native progress=1 is neither a receipt nor installation completion.
    probe.report(1, at: 1)
    await settle()
    XCTAssertEqual(source.preferred?.representationID, original.representationID)
    XCTAssertTrue(native.player.currentItem === originalItem)

    probe.finish(1, with: .success(.init(asset: highest, audioMix: mix)))
    let hq = try await external.value()
    try await waitUntil { gate.invocationCount == 1 }
    XCTAssertEqual(source.preferred?.representationID, hq.representationID)
    XCTAssertTrue(native.player.currentItem === originalItem)
    XCTAssertEqual(binding.installedReceipt?.representationID, original.representationID)

    gate.finishAll()
    try await waitUntil {
      binding.installedReceipt?.representationID == hq.representationID
    }
    XCTAssertTrue(native.player.currentItem?.asset === highest)
    XCTAssertTrue(native.currentLoadedMedia?.audioMix === mix)
    XCTAssertTrue(binding.installedReceipt?.audioMix === mix)
    XCTAssertEqual(native.sourcePresentationID, visit)
    XCTAssertEqual(binding.highQualityAction, .hidden)
    XCTAssertNil(binding.qualityFailure)
    XCTAssertEqual(gate.invocationCount, 1)
    XCTAssertEqual(probe.invocations.count, 2)
  }

  func testExternalHighestControlPreservesVisibilityUntilRestorationCompletes() async throws {
    for wasAvailable in [false, true] {
      let probe = BindingLoaderProbe()
      let resources = probe.resources()
      let source = resources.photosSource(serializedCloudIdentifier: "external-HQ-restoration-\(wasAvailable)")
      let automatic = try await movie()
      let highest = try await movie(blue: true)
      var heldRestore: (@MainActor () -> Void)?
      let native = PlaybackSession(transportSeek: { player, target, completion in
        PlaybackSession.seekTransport(player: player, target: target) { finished in
          if player.currentItem?.asset === highest {
            XCTAssertTrue(finished, "The real native seek must succeed before its callback is held")
            heldRestore = { completion(finished) }
          } else {
            completion(finished)
          }
        }
      })
      let binding = VideoResourcePlayback(session: native)
      defer { binding.cleanup(); heldRestore = nil; probe.finishOutstanding() }
      try await ready(binding, source: source, probe: probe, asset: automatic)
      if wasAvailable {
        binding.checkLocalHighQuality()
        try await waitUntil { probe.invocations.count == 2 }
        probe.finish(1, with: .failure(VideoResourceFailure.networkRequired))
        try await waitUntil { binding.highQualityAction == .available }
      } else {
        XCTAssertEqual(binding.highQualityAction, .hidden)
      }

      let external = source.prepare(.init(quality: .highest, network: .allowed))
      defer { external.cancel() }
      let requestCount = wasAvailable ? 3 : 2
      try await waitUntil { probe.invocations.count == requestCount }
      probe.finish(requestCount - 1, with: .success(.init(asset: highest)))
      let hq = try await external.value()
      try await waitUntil {
        heldRestore != nil && native.player.currentItem?.asset === highest && native.isPlayerReady
      }
      XCTAssertNil(binding.installedReceipt, "Native readiness does not complete the owner's restoring seek")
      XCTAssertEqual(binding.highQualityAction, wasAvailable ? .loading(nil) : .hidden,
        "Keep the existing control until acceptance without revealing a previously hidden control")
      let finish = try XCTUnwrap(heldRestore)
      heldRestore = nil
      finish()
      try await waitUntil { binding.installedReceipt?.representationID == hq.representationID }
      XCTAssertEqual(binding.highQualityAction, .hidden)
      XCTAssertNil(binding.qualityFailure)
      XCTAssertEqual(probe.invocations.count, requestCount)
    }
  }

  func testSourceSwapDuringExternalHighestInstallationRejectsOldCandidate() async throws {
    let probe = BindingLoaderProbe()
    let gate = BindingReplacementGate()
    let resources = probe.resources()
    let source = resources.photosSource(serializedCloudIdentifier: "external-HQ-pending-swap")
    let native = PlaybackSession(
      transportSeek: PlaybackSession.seekTransport,
      prepareReplacement: gate.prepare)
    let binding = VideoResourcePlayback(session: native)
    defer { binding.cleanup(); gate.finishAll(); probe.finishOutstanding() }

    let automatic = try await movie()
    let highest = try await movie(blue: true)
    let mix = AVMutableAudioMix()
    try await ready(binding, source: source, probe: probe, asset: automatic)
    let original = try XCTUnwrap(binding.installedReceipt)
    let originalItem = try XCTUnwrap(native.player.currentItem)
    let visit = native.sourcePresentationID

    let external = source.prepare(.init(quality: .highest, network: .allowed))
    defer { external.cancel() }
    try await waitUntil { probe.invocations.count == 2 }
    probe.report(1, at: 1)
    await settle()
    XCTAssertEqual(source.preferred?.representationID, original.representationID)
    XCTAssertTrue(native.player.currentItem === originalItem)

    probe.finish(1, with: .success(.init(asset: highest, audioMix: mix)))
    let hq = try await external.value()
    try await waitUntil { gate.invocationCount == 1 }
    XCTAssertEqual(source.preferred?.representationID, hq.representationID)
    XCTAssertTrue(native.player.currentItem === originalItem)
    XCTAssertEqual(binding.installedReceipt?.representationID, original.representationID)

    let sourceB = resources.photosSource(serializedCloudIdentifier: "replacement-B")
    let assetB = try await movie()
    binding.load(source: sourceB)
    try await waitUntil { probe.invocations.count == 3 }
    probe.finish(2, with: .success(.init(asset: assetB)))
    try await waitUntil { binding.installedReceipt?.asset === assetB }
    let itemB = try XCTUnwrap(native.player.currentItem)
    let receiptB = try XCTUnwrap(binding.installedReceipt)
    let visitB = native.sourcePresentationID

    gate.finishAll()
    try await waitUntil { gate.returnedCount == 1 }
    await settle()

    XCTAssertNotEqual(visitB, visit)
    XCTAssertEqual(native.sourcePresentationID, visitB)
    XCTAssertTrue(native.player.currentItem === itemB)
    XCTAssertEqual(binding.installedReceipt?.representationID, receiptB.representationID)
    XCTAssertTrue(hq.isCurrent,
      "Switching playback must not invalidate another consumer's completed resource")
    XCTAssertEqual(source.preferred?.representationID, hq.representationID)
    XCTAssertNil(binding.qualityFailure)
    XCTAssertEqual(probe.invocations.count, 3)
  }

  func testSourceInvalidationDuringExternalHighestInstallationRejectsExpiredReceipt() async throws {
    let probe = BindingLoaderProbe()
    let gate = BindingReplacementGate()
    let resources = probe.resources()
    let source = resources.photosSource(serializedCloudIdentifier: "external-HQ-pending-invalidation")
    let native = PlaybackSession(
      transportSeek: PlaybackSession.seekTransport,
      prepareReplacement: gate.prepare)
    let binding = VideoResourcePlayback(session: native)
    defer { binding.cleanup(); gate.finishAll(); probe.finishOutstanding() }

    let automatic = try await movie()
    let highest = try await movie(blue: true)
    let mix = AVMutableAudioMix()
    try await ready(binding, source: source, probe: probe, asset: automatic)
    let original = try XCTUnwrap(binding.installedReceipt)
    let originalItem = try XCTUnwrap(native.player.currentItem)

    let external = source.prepare(.init(quality: .highest, network: .allowed))
    defer { external.cancel() }
    try await waitUntil { probe.invocations.count == 2 }
    probe.report(1, at: 1)
    await settle()
    XCTAssertEqual(source.preferred?.representationID, original.representationID)
    XCTAssertTrue(native.player.currentItem === originalItem)

    probe.finish(1, with: .success(.init(asset: highest, audioMix: mix)))
    let hq = try await external.value()
    try await waitUntil { gate.invocationCount == 1 }
    XCTAssertEqual(source.preferred?.representationID, hq.representationID)
    XCTAssertTrue(native.player.currentItem === originalItem)
    XCTAssertEqual(binding.installedReceipt?.representationID, original.representationID)

    source.invalidate()
    XCTAssertFalse(original.isCurrent)
    XCTAssertFalse(hq.isCurrent)
    gate.finishAll()
    try await waitUntil { gate.returnedCount == 1 }
    await settle()

    // The getter can hide an expired receipt: also inspect actual native media.
    XCTAssertFalse(native.player.currentItem?.asset === highest)
    XCTAssertNil(binding.installedReceipt)
    XCTAssertNil(source.preferred)
    XCTAssertNil(binding.qualityFailure)
    XCTAssertEqual(probe.invocations.count, 2)

    // Match the existing invalidated-current final-use contract.
    native.togglePlayback()
    XCTAssertNil(native.player.currentItem)
    guard case .source(let reason) = native.failure else {
      return XCTFail("Invalidated media must fail final-use validation")
    }
    XCTAssertEqual(reason as? VideoResourceFailure, .sourceChanged)
  }

  func testExternalHighestDuringLocalProbeIsInstalledAfterThatProbeFinishes() async throws {
    let probe = BindingLoaderProbe()
    let source = probe.resources().photosSource(serializedCloudIdentifier: "external-HQ-during-local-probe")
    let binding = VideoResourcePlayback()
    defer { binding.cleanup(); probe.finishOutstanding() }
    let automatic = try await movie()
    let highest = try await movie(blue: true)
    try await ready(binding, source: source, probe: probe, asset: automatic)
    let originalItem = try XCTUnwrap(binding.session.player.currentItem)

    binding.checkLocalHighQuality()
    try await waitUntil { probe.invocations.count == 2 }
    XCTAssertEqual(probe.invocations[1].request, .init(quality: .highest, network: .forbidden))
    let external = source.prepare(.init(quality: .highest, network: .allowed))
    defer { external.cancel() }
    try await waitUntil { probe.invocations.count == 3 }
    probe.finish(2, with: .success(.init(asset: highest)))
    let receipt = try await external.value()
    await settle()
    XCTAssertTrue(binding.session.player.currentItem === originalItem,
      "The local probe and preferred observer must use the same serialized quality task")

    probe.finish(1, with: .failure(VideoResourceFailure.networkRequired))
    try await waitUntil { binding.installedReceipt?.representationID == receipt.representationID }
    XCTAssertTrue(binding.session.player.currentItem?.asset === highest)
    XCTAssertEqual(binding.installedReceipt?.evidence, receipt.evidence)
    XCTAssertEqual(binding.highQualityAction, .hidden)
    XCTAssertNil(binding.qualityFailure)
    XCTAssertEqual(probe.invocations.count, 3,
      "A preferred change while the probe is busy must be consumed without another request")
  }

  func testLocalHighestNativeFailureStaysQuietAndDoesNotBecomeAnAutomaticRetry() async throws {
    let probe = BindingLoaderProbe()
    let source = probe.resources().photosSource(serializedCloudIdentifier: "local-HQ-native-failure")
    var installations = 0
    let native = PlaybackSession(transportSeek: PlaybackSession.seekTransport,
      prepareReplacement: { _ in
        installations += 1
        throw BindingTestError.installationDenied
      })
    let binding = VideoResourcePlayback(session: native)
    defer { binding.cleanup(); probe.finishOutstanding() }
    let automatic = try await movie()
    let highest = try await movie(blue: true)
    try await ready(binding, source: source, probe: probe, asset: automatic)
    let originalItem = try XCTUnwrap(native.player.currentItem)
    let originalReceipt = try XCTUnwrap(binding.installedReceipt)

    binding.checkLocalHighQuality()
    try await waitUntil { probe.invocations.count == 2 }
    probe.finish(1, with: .success(.init(asset: highest)))
    try await waitUntil { installations == 1 }
    await settle()
    binding.checkLocalHighQuality()
    await settle()

    XCTAssertEqual(source.preferred?.evidence.quality, .highest)
    XCTAssertEqual(installations, 1,
      "The preferred observer must not retry a local probe's failed native candidate")
    XCTAssertTrue(native.player.currentItem === originalItem)
    XCTAssertEqual(binding.installedReceipt?.representationID, originalReceipt.representationID)
    XCTAssertTrue(native.isPlayerReady)
    XCTAssertNil(native.failure)
    XCTAssertNil(binding.qualityFailure, "A local install failure keeps its existing quiet contract")
    XCTAssertEqual(binding.highQualityAction, .hidden)
    XCTAssertEqual(probe.invocations.count, 2)
  }

  private func ready(_ binding: VideoResourcePlayback, source: VideoSource,
    probe: BindingLoaderProbe, asset: AVAsset) async throws {
    binding.load(source: source)
    try await waitUntil { probe.invocations.count == 1 }
    probe.finish(0, with: .success(.init(asset: asset)))
    try await waitUntil { binding.session.isPlayerReady && binding.installedReceipt != nil }
  }

  private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<500 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw BindingTestError.timeout
  }

  private func settle() async {
    try? await Task.sleep(for: .milliseconds(50))
  }

  /// A real two-second video reaches AVPlayerItem readiness and permits native
  /// replacement/seek completion. No empty composition is used as playable media.
  private func movie(blue: Bool = false) async throws -> AVURLAsset {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("resource-binding-\(UUID()).mov")
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64
      ])
    writer.add(input)
    guard writer.startWriting() else { throw try XCTUnwrap(writer.error) }
    writer.startSession(atSourceTime: .zero)
    for frame in 0..<6 {
      try await waitUntil { input.isReadyForMoreMediaData || writer.status != .writing }
      guard writer.status == .writing else { throw try XCTUnwrap(writer.error) }
      var buffer: CVPixelBuffer?
      let pool = try XCTUnwrap(adaptor.pixelBufferPool)
      XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer), kCVReturnSuccess)
      let pixel = try XCTUnwrap(buffer)
      CVPixelBufferLockBaseAddress(pixel, [])
      let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixel)).assumingMemoryBound(to: UInt8.self)
      let rowBytes = CVPixelBufferGetBytesPerRow(pixel)
      for row in 0..<64 {
        for column in 0..<64 {
          let offset = row * rowBytes + column * 4
          bytes[offset] = blue ? 255 : 0
          bytes[offset + 1] = 0
          bytes[offset + 2] = blue ? 0 : 255
          bytes[offset + 3] = 255
        }
      }
      CVPixelBufferUnlockBaseAddress(pixel, [])
      XCTAssertTrue(adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 3)))
    }
    writer.endSession(atSourceTime: CMTime(value: 6, timescale: 3))
    input.markAsFinished()
    await writer.finishWriting()
    XCTAssertEqual(writer.status, .completed)
    return AVURLAsset(url: url)
  }
}

private enum BindingTestError: Error { case timeout, installationDenied, audioDenied }

/// Cancellation is recorded but deliberately does not finish the native callback.
/// This lets the public tests deliver stale success after cleanup/new source entry.
@MainActor
private final class BindingLoaderProbe {
  struct Invocation {
    let identifier: String
    let request: VideoRequest
    let progress: PhotosVideoProvider.Progress
    var continuation: CheckedContinuation<VideoRepresentation, Error>?
  }
  private(set) var invocations: [Invocation] = []
  private(set) var cancelledIndices: [Int] = []
  private(set) var returnedIndices: Set<Int> = []

  func resources() -> VideoResources {
    VideoResources(photos: PhotosVideoProvider(authority: { "visible:\($0)" },
      load: { [self] identifier, request, progress in
        try await load(identifier, request: request, progress: progress) }))
  }

  func finish(_ index: Int, with result: Result<VideoRepresentation, Error>,
    file: StaticString = #filePath, line: UInt = #line) {
    guard invocations.indices.contains(index), let continuation = invocations[index].continuation else {
      XCTFail("Expected unfinished native request \(index)", file: file, line: line)
      return
    }
    invocations[index].continuation = nil
    continuation.resume(with: result)
  }

  func finishOutstanding() {
    for index in invocations.indices {
      guard let continuation = invocations[index].continuation else { continue }
      invocations[index].continuation = nil
      continuation.resume(throwing: CancellationError())
    }
  }

  func report(_ value: Double, at index: Int) { invocations[index].progress(value) }

  private func load(_ identifier: String, request: VideoRequest,
    progress: @escaping PhotosVideoProvider.Progress) async throws -> VideoRepresentation {
    let index = invocations.count
    defer { returnedIndices.insert(index) }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        invocations.append(.init(identifier: identifier, request: request, progress: progress, continuation: continuation))
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.cancelledIndices.append(index) }
    }
  }
}

@MainActor
private final class BindingReentrantObservation {
  var fired = false
}

@MainActor
private final class BindingReplacementGate {
  private struct Pending {
    let asset: AVAsset
    let continuation: CheckedContinuation<AVPlayerItem, Error>
  }
  private var pending: [Pending] = []
  private(set) var invocationCount = 0
  private(set) var returnedCount = 0

  func prepare(_ asset: AVAsset) async throws -> AVPlayerItem {
    invocationCount += 1
    defer { returnedCount += 1 }
    return try await withCheckedThrowingContinuation {
      pending.append(Pending(asset: asset, continuation: $0))
    }
  }

  func finishAll() {
    let outstanding = pending
    pending.removeAll()
    for request in outstanding {
      request.continuation.resume(returning: AVPlayerItem(asset: request.asset))
    }
  }
}
