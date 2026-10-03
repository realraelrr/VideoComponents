import AVFoundation
import Foundation
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
