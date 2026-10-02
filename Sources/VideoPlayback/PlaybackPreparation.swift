import Foundation

/// Host-owned preparation for one continuous playback demand.
/// The UUID identifies a lease, independent of the source or player item.
@MainActor public struct PlaybackPreparation {
  /// Synchronously submit/register the lease before the first suspension, then
  /// await host activation. Late completion must not resurrect a released lease.
  public let prepare: @MainActor (UUID) async throws -> Void
  /// Called once after transport pauses, including pending or uninvoked preparation.
  /// Tolerate unknown leases and serialize with preparation already submitted.
  public let release: @MainActor (UUID) -> Void

  public init(
    prepare: @escaping @MainActor (UUID) async throws -> Void,
    release: @escaping @MainActor (UUID) -> Void
  ) {
    self.prepare = prepare
    self.release = release
  }
}
