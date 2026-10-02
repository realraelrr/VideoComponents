import AVFoundation
import UIKit

/// A stable media identity and cancellable host-owned resource resolution.
/// Identity must change when the underlying media changes, not on view updates.
@MainActor public struct PlaybackSource {
  public let identity: AnyHashable
  let load: @MainActor () async throws -> AVAsset
  let thumbnail: @MainActor (CGSize) async -> UIImage?

  public init<ID: Hashable>(
    identity: ID,
    load: @escaping @MainActor () async throws -> AVAsset,
    thumbnail: @escaping @MainActor (CGSize) async -> UIImage? = { _ in nil }
  ) {
    self.identity = AnyHashable(identity)
    self.load = load
    self.thumbnail = thumbnail
  }

  func replacingLoader(_ loader: @escaping @MainActor () async throws -> AVAsset) -> Self {
    Self(identity: identity, load: loader, thumbnail: thumbnail)
  }
}

public enum PlaybackFailure: Error {
  case source(any Error)
  case playerItemFailed
  /// Host preparation failed; retry preparation without reacquiring the source.
  case preparation(any Error)
}

@MainActor public enum PlaybackAccessValidation {
  case unavailable(any Error)
  case validate(@MainActor () async throws -> AVAsset)
}

public enum PlaybackEvent {
  /// Observational only. Use PlaybackPreparation to await host readiness.
  case willPlay
  case didCleanup
  case holdBegan
}
