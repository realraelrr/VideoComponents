import Foundation
import PhotosMappingBridge

/// Resolves Apple's opaque reference, translating synchronous invalid-argument
/// exceptions into sourceUnavailable. Other exceptions are not contained.
/// Does not request authorization.
@MainActor
public enum PhotosReferenceResolver {
  public static func localIdentifier(for serialized: String) throws -> String {
    guard !serialized.isEmpty else { throw VideoResourceFailure.sourceUnavailable }
    var error: NSError?
    if let identifier = VRResolvePhotosReference(serialized, &error) { return identifier }
    if let error, error.domain != "VideoResources.PhotosReference" { throw error }
    throw VideoResourceFailure.sourceUnavailable
  }
}
