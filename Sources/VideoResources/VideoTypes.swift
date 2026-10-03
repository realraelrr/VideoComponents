import AVFoundation
import Foundation

public struct VideoRequest: Hashable, Sendable {
  public enum Quality: Sendable { case automatic, highest }
  public enum Network: Sendable { case allowed, forbidden }
  public let quality: Quality
  public let network: Network
  public init(quality: Quality = .automatic, network: Network = .allowed) {
    self.quality = quality
    self.network = network
  }
  public func satisfies(_ requested: Self) -> Bool {
    (quality == .highest || requested.quality == .automatic)
      && (network == .forbidden || requested.network == .allowed)
  }
}

public enum VideoResourceFailure: Error, Equatable, Sendable {
  case photosAccessRequired, sourceUnavailable, sourceChanged
  case fileUnavailable, fileChanged, networkRequired, networkFailed, acquisitionFailed
}

/// The native representation and its audio mix travel together.
/// Sendability transports immutable AVFoundation references; consumers use them on their actor.
public struct VideoRepresentation: @unchecked Sendable {
  public let asset: AVAsset
  public let audioMix: AVAudioMix?
  public init(asset: AVAsset, audioMix: AVAudioMix? = nil) {
    self.asset = asset
    self.audioMix = audioMix
  }
}

/// No draft, record, account, audio-session, or playback state is part of this interface.
@MainActor
public struct PhotosVideoProvider {
  public typealias Progress = @Sendable (Double) -> Void
  public let authority: (String) throws -> String
  public let load: (String, VideoRequest, @escaping Progress) async throws -> VideoRepresentation
  public let refresh: () -> Void
  public init(
    authority: @escaping (String) throws -> String,
    load: @escaping (String, VideoRequest, @escaping Progress) async throws -> VideoRepresentation,
    refresh: @escaping () -> Void = {}
  ) {
    self.authority = authority
    self.load = load
    self.refresh = refresh
  }
}

public struct VideoRepresentationID: Hashable, Sendable {
  private let value = UUID()
  init() {}
}
