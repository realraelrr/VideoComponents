import XCTest
@testable import VideoResources

@MainActor
final class PhotosReferenceResolverTests: XCTestCase {
  func testMalformedNativeReferencesFailWithoutTerminatingProcess() {
    for reference in ["", "not-a-cloud-identifier", "photos-test", " ", "\u{0}"] {
      XCTAssertThrowsError(try PhotosReferenceResolver.localIdentifier(for: reference)) { error in
        XCTAssertEqual(error as? VideoResourceFailure, .sourceUnavailable)
      }
    }
  }

  func testMalformedReferenceFromAsyncCallerRemainsTyped() async {
    do {
      _ = try PhotosReferenceResolver.localIdentifier(for: "mounted-roundtrip")
      XCTFail("Malformed native reference must fail")
    } catch {
      XCTAssertEqual(error as? VideoResourceFailure, .sourceUnavailable)
    }
  }

}
