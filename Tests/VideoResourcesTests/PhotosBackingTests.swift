import AVFoundation
import Foundation
import VideoResources
import XCTest

@MainActor
final class PhotosBackingTests: XCTestCase {
  func testEvictedPhotosURLInvalidatesReceiptAndExplicitAcquireObtainsAnotherRepresentation() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    var calls = 0
    let resources = VideoResources(photos: PhotosVideoProvider(
      authority: { _ in "same-photo-fact" }, load: { _, _, _ in
        calls += 1
        let url = directory.appendingPathComponent("system-representation-\(calls).mov")
        // Only a backing-existence fixture; real media behavior is tested separately.
        try Data([1, 2, 3]).write(to: url)
        return .init(asset: AVURLAsset(url: url))
      }))
    let source = resources.photosSource(serializedCloudIdentifier: "photo")
    let first = try await source.acquire()
    let firstURL = try XCTUnwrap((first.asset as? AVURLAsset)?.url)
    try FileManager.default.removeItem(at: firstURL)
    XCTAssertFalse(first.isCurrent)
    XCTAssertNil(source.preferred)
    XCTAssertEqual(calls, 1, "Observing missing bytes does not start replacement work")
    let next = try await source.acquire()
    XCTAssertEqual(calls, 2)
    XCTAssertTrue(next.isCurrent)
    XCTAssertFalse(first.isCurrent)
    XCTAssertNotEqual(next.representationID, first.representationID)
    XCTAssertEqual(source.preferred?.representationID, next.representationID)
  }
}
