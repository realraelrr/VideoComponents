import AVFoundation
import Foundation
import Observation
import VideoResources
import XCTest

@MainActor
final class PhotoAuthorityTests: XCTestCase {
  func testObservedAuthorityChangeThenReturnNeverRevivesOldReceipt() async throws {
    var authority = "A"
    let resources = VideoResources(photos: PhotosVideoProvider(
      authority: { _ in authority }, load: { _, _, _ in .init(asset: AVMutableComposition()) }))
    let source = resources.photosSource(serializedCloudIdentifier: "photo")
    let a = try await source.acquire()
    authority = "B"
    let b = try await source.acquire()
    XCTAssertFalse(a.isCurrent)
    authority = "A"
    let returned = try await source.acquire()
    XCTAssertFalse(a.isCurrent, "An observed incarnation cannot revive")
    XCTAssertFalse(b.isCurrent)
    XCTAssertTrue(returned.isCurrent)
    XCTAssertNotEqual(a.representationID, returned.representationID)
  }

  func testRefreshWithSameAuthorityPreservesPendingWorkAndSuccessfulReceipt() async throws {
    let loader = AuthorityLoader()
    let resources = VideoResources(photos: loader.provider)
    let source = resources.photosSource(serializedCloudIdentifier: "photo")
    let preparation = source.prepare()
    await loader.waitForStart(1)
    resources.refreshPhotosAccess()
    XCTAssertEqual(loader.starts, 1)
    loader.complete(0)
    let receipt = try await preparation.value()
    resources.refreshPhotosAccess()
    XCTAssertTrue(receipt.isCurrent)
    XCTAssertEqual(loader.starts, 1)
    XCTAssertEqual(source.preferred?.representationID, receipt.representationID)
  }

  func testAuthorityChangeIsCheckedBeforeJoiningAndLateOldCompletionCannotWritePreferred() async throws {
    let loader = AuthorityLoader()
    let resources = VideoResources(photos: loader.provider)
    let source = resources.photosSource(serializedCloudIdentifier: "photo")
    let old = source.prepare()
    await loader.waitForStart(1)
    loader.authority = "B"
    let current = source.prepare()
    await loader.waitForStart(2)
    loader.authority = "A"
    let returned = source.prepare()
    await loader.waitForStart(3)
    loader.complete(0)
    loader.complete(1)
    loader.complete(2)
    do { _ = try await old.value(); XCTFail("Old A must remain invalidated") }
    catch { XCTAssertEqual(error as? VideoResourceFailure, .sourceChanged) }
    do { _ = try await current.value(); XCTFail("Old B must remain invalidated") }
    catch { XCTAssertEqual(error as? VideoResourceFailure, .sourceChanged) }
    let result = try await returned.value()
    XCTAssertTrue(result.isCurrent)
    XCTAssertEqual(source.preferred?.representationID, result.representationID)
  }

  func testRevokedAccessInvalidatesWithoutRetryAndRestorationNeedsExplicitAcquire() async throws {
    var accessible = true
    var calls = 0
    let resources = VideoResources(photos: PhotosVideoProvider(
      authority: { _ in
        guard accessible else { throw VideoResourceFailure.photosAccessRequired }
        return "A"
      }, load: { _, _, _ in calls += 1; return .init(asset: AVMutableComposition()) }))
    let source = resources.photosSource(serializedCloudIdentifier: "photo")
    let old = try await source.acquire()
    accessible = false
    resources.refreshPhotosAccess()
    XCTAssertFalse(old.isCurrent)
    accessible = true
    resources.refreshPhotosAccess()
    XCTAssertFalse(old.isCurrent)
    XCTAssertEqual(calls, 1)
    let new = try await source.acquire()
    XCTAssertTrue(new.isCurrent)
    XCTAssertEqual(calls, 2)
  }
  func testPermissionFailureIsVisibleInsideSourceInvalidationBeforeRefreshReturns() async throws {
    let fixture = PermissionAuthorityFixture()
    let source = fixture.source
    let old = try await source.acquire()
    var observed: [VideoSource.State] = []
    let cancel = source.onInvalidation { [weak source] in
      if let source { observed.append(source.state) }
    }
    defer { cancel() }
    fixture.accessible = false
    fixture.resources.refreshPhotosAccess()
    XCTAssertEqual(observed, [.unavailable(.photosAccessRequired)],
      "A mounted consumer must receive the typed permission reason before cleanup")
    XCTAssertEqual(source.state, .unavailable(.photosAccessRequired))
    XCTAssertFalse(old.isCurrent)
    XCTAssertEqual(fixture.loads, 1, "Refresh does not acquire to rediscover its failure")
  }

  func testRepeatedFailedRefreshKeepsTypedReasonWithoutAnotherInvalidationOrAcquire() async throws {
    let fixture = PermissionAuthorityFixture()
    let source = fixture.source
    let old = try await source.acquire()
    var observed: [VideoSource.State] = []
    let cancel = source.onInvalidation { [weak source] in
      if let source { observed.append(source.state) }
    }
    defer { cancel() }
    fixture.accessible = false
    fixture.resources.refreshPhotosAccess()
    fixture.resources.refreshPhotosAccess()
    XCTAssertEqual(observed, [.unavailable(.photosAccessRequired)])
    XCTAssertEqual(source.state, .unavailable(.photosAccessRequired))
    XCTAssertFalse(old.isCurrent)
    XCTAssertEqual(fixture.loads, 1)
  }

  func testStateObservationStartingRetryCannotReceiveOldPermissionFailure() async throws {
    let fixture = PermissionAuthorityFixture()
    let source = fixture.source
    let old = try await source.acquire()
    let observation = PermissionRetryObservation(fixture: fixture, source: source)
    defer { observation.preparation?.cancel(); fixture.finishHighest() }
    observation.track()
    fixture.accessible = false
    fixture.resources.refreshPhotosAccess()
    XCTAssertTrue(observation.fired)
    XCTAssertEqual(source.state, .acquiring(0),
      "The old failed refresh cannot overwrite the reentrant request's acquiring state")
    XCTAssertFalse(old.isCurrent)
    let preparation = try XCTUnwrap(observation.preparation)
    try await fixture.waitForHighest()
    fixture.finishHighest()
    let replacement = try await preparation.value()
    XCTAssertTrue(replacement.isCurrent)
    XCTAssertFalse(old.isCurrent)
    XCTAssertEqual(source.state, .available)
    XCTAssertEqual(fixture.loads, 2)
  }

  func testImmediateAuthorityFailureCannotReplaceReentrantSameRequestWork() async throws {
    let fixture = PermissionAuthorityFixture()
    let source = fixture.source
    let old = try await source.acquire()
    let observation = PermissionRetryObservation(fixture: fixture, source: source, request: .init())
    defer { observation.preparation?.cancel() }
    observation.track()
    fixture.accessible = false
    let failed = source.prepare()
    XCTAssertTrue(observation.fired)
    do {
      _ = try await failed.value()
      XCTFail("The original failed authority attempt still returns its own failure")
    } catch { XCTAssertEqual(error as? VideoResourceFailure, .photosAccessRequired) }
    let retry = try XCTUnwrap(observation.preparation)
    let replacement = try await retry.value()
    XCTAssertTrue(replacement.isCurrent, "The failed attempt cannot replace the retry's pending work")
    XCTAssertFalse(old.isCurrent)
    XCTAssertEqual(source.preferred?.representationID, replacement.representationID)
    XCTAssertEqual(source.state, .available)
    XCTAssertEqual(fixture.loads, 2)
  }

  func testSynchronousFailedRetryKeepsItsNewReasonWhenEpochAndWorkRemainUnchanged() async throws {
    let fixture = PermissionAuthorityFixture()
    let source = fixture.source
    let old = try await source.acquire()
    let observation = PermissionFailureRetryObservation(fixture: fixture, source: source)
    observation.track()
    fixture.accessible = false
    fixture.resources.refreshPhotosAccess()
    XCTAssertTrue(observation.fired)
    XCTAssertEqual(source.state, .unavailable(.sourceUnavailable),
      "The outer permission failure cannot overwrite a newer failed retry's reason")
    let failedRetry = try XCTUnwrap(observation.preparation)
    do {
      _ = try await failedRetry.value()
      XCTFail("The retry's source remains unavailable")
    } catch { XCTAssertEqual(error as? VideoResourceFailure, .sourceUnavailable) }
    XCTAssertEqual(source.state, .unavailable(.sourceUnavailable))
    XCTAssertFalse(old.isCurrent)
    XCTAssertEqual(fixture.loads, 1)
  }

  func testNativeLoadCancellationRetryCannotReceiveTheOuterPermissionFailure() async throws {
    let fixture = PermissionAuthorityFixture()
    let source = fixture.source
    let old = try await source.acquire()
    let retry = PermissionCancellationRetry(fixture: fixture, source: source)
    fixture.onHighestCancellation = {
      MainActor.assumeIsolated { retry.begin() }
    }
    let highest = source.prepare(.init(quality: .highest))
    defer { highest.cancel(); retry.preparation?.cancel(); fixture.finishHighest() }
    try await fixture.waitForHighest()
    var observed: [VideoSource.State] = []
    let cancel = source.onInvalidation { [weak source] in
      if let source { observed.append(source.state) }
    }
    defer { cancel() }
    fixture.accessible = false
    fixture.resources.refreshPhotosAccess()
    XCTAssertTrue(retry.fired, "Retiring the old operation cancels its actual provider task synchronously")
    XCTAssertEqual(source.state, .unavailable(.sourceUnavailable),
      "Cancellation's newer failed retry must keep its own typed reason")
    XCTAssertEqual(observed, [.unavailable(.sourceUnavailable)],
      "Invalidation consumers observe the latest source fact after old work is cancelled")
    let failedRetry = try XCTUnwrap(retry.preparation)
    do {
      _ = try await failedRetry.value()
      XCTFail("The cancellation callback's retry remains unavailable")
    } catch { XCTAssertEqual(error as? VideoResourceFailure, .sourceUnavailable) }
    XCTAssertFalse(old.isCurrent)
    XCTAssertEqual(fixture.loads, 2, "The failed retry starts no additional native load")
  }

  func testInvalidationRegistrationCancellationAndReleaseRemainFinite() {
    let fixture = PermissionAuthorityFixture()
    var source: VideoSource? = fixture.source
    weak var releasedSource = source
    let events = PermissionInvalidationEvents()
    let cancelled = source!.onInvalidation { events.cancelled += 1 }
    cancelled()
    cancelled()
    var later: (@MainActor () -> Void)?
    let cancelFirst = source!.onInvalidation { [weak source] in
      events.first += 1
      if later == nil { later = source?.onInvalidation { events.later += 1 } }
    }
    source!.invalidate()
    XCTAssertEqual(events.cancelled, 0)
    XCTAssertEqual(events.first, 1)
    XCTAssertEqual(events.later, 0, "Registration during a batch observes only future invalidations")
    source!.invalidate()
    XCTAssertEqual(events.first, 2)
    XCTAssertEqual(events.later, 1)
    cancelFirst()
    later?()
    let escapedCancel = source!.onInvalidation { events.cancelled += 1 }
    source = nil
    XCTAssertNil(releasedSource, "A cancellation resource does not retain the source it observes")
    escapedCancel()
  }


}

@MainActor
private final class AuthorityLoader {
  var authority = "A"
  private(set) var starts = 0
  private var continuations: [CheckedContinuation<VideoRepresentation, Error>] = []
  private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
  var provider: PhotosVideoProvider {
    PhotosVideoProvider(authority: { [self] _ in authority }, load: { [self] _, _, _ in
      try await withCheckedThrowingContinuation { continuation in
        continuations.append(continuation)
        starts += 1
        let ready = startWaiters.filter { $0.0 <= starts }
        startWaiters.removeAll { $0.0 <= starts }
        for waiter in ready { waiter.1.resume() }
      }
    })
  }
  func waitForStart(_ count: Int) async {
    if starts >= count { return }
    await withCheckedContinuation { startWaiters.append((count, $0)) }
  }
  func complete(_ index: Int) {
    continuations[index].resume(returning: .init(asset: AVMutableComposition()))
  }
}

@MainActor
private final class PermissionAuthorityFixture {
  var accessible = true
  var failure: VideoResourceFailure = .photosAccessRequired
  private(set) var loads = 0
  private var highest: CheckedContinuation<VideoRepresentation, Error>?
  var onHighestCancellation: (@Sendable () -> Void)?
  lazy var resources = VideoResources(photos: PhotosVideoProvider(
    authority: { [weak self] _ in
      guard let self else { throw CancellationError() }
      guard self.accessible else { throw self.failure }
      return "A"
    }, load: { [weak self] _, request, _ in
      guard let self else { throw CancellationError() }
      return try await self.load(request)
    }))
  var source: VideoSource { resources.photosSource(serializedCloudIdentifier: "photo") }
  private func load(_ request: VideoRequest) async throws -> VideoRepresentation {
    loads += 1
    if request.quality == .highest {
      let cancel = onHighestCancellation
      return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { highest = $0 }
      } onCancel: { cancel?() }
    }
    return .init(asset: AVComposition())
  }
  func waitForHighest() async throws {
    for _ in 0..<300 {
      if highest != nil { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw PermissionAuthorityTestFailure.timeout
  }
  func finishHighest() {
    let pending = highest
    highest = nil
    pending?.resume(returning: .init(asset: AVComposition()))
  }
}

@MainActor
private final class PermissionRetryObservation {
  private let fixture: PermissionAuthorityFixture
  private let source: VideoSource
  private let request: VideoRequest
  private(set) var fired = false
  private(set) var preparation: VideoPreparation?
  init(fixture: PermissionAuthorityFixture, source: VideoSource,
    request: VideoRequest = .init(quality: .highest)) {
    self.fixture = fixture
    self.source = source
    self.request = request
  }
  func track() {
    withObservationTracking { _ = source.state } onChange: { [weak self] in
      MainActor.assumeIsolated {
        guard let self, !self.fired else { return }
        self.fired = true
        self.fixture.accessible = true
        self.preparation = self.source.prepare(self.request)
      }
    }
  }
}

@MainActor
private final class PermissionInvalidationEvents {
  var cancelled = 0
  var first = 0
  var later = 0
}
private enum PermissionAuthorityTestFailure: Error { case timeout }

@MainActor
private final class PermissionFailureRetryObservation {
  private let fixture: PermissionAuthorityFixture
  private let source: VideoSource
  private(set) var fired = false
  private(set) var preparation: VideoPreparation?
  init(fixture: PermissionAuthorityFixture, source: VideoSource) {
    self.fixture = fixture
    self.source = source
  }
  func track() {
    withObservationTracking { _ = source.state } onChange: { [weak self] in
      MainActor.assumeIsolated {
        guard let self, !self.fired else { return }
        self.fired = true
        self.fixture.failure = .sourceUnavailable
        self.preparation = self.source.prepare()
      }
    }
  }
}

@MainActor
private final class PermissionCancellationRetry {
  private let fixture: PermissionAuthorityFixture
  private let source: VideoSource
  private(set) var fired = false
  private(set) var preparation: VideoPreparation?
  init(fixture: PermissionAuthorityFixture, source: VideoSource) {
    self.fixture = fixture
    self.source = source
  }
  func begin() {
    guard !fired else { return }
    fired = true
    fixture.failure = .sourceUnavailable
    preparation = source.prepare()
  }
}
