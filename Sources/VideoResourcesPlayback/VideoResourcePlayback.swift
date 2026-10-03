import AVFoundation
import Observation
import UIKit
import VideoPlayback
import VideoResources

/// One playback owner's finite consumption of a resource source.
/// Keep this owner across inline/fullscreen moves; clean it up when playback actually closes.
@MainActor @Observable
public final class VideoResourcePlayback {
  public enum HighQualityAction: Equatable {
    case hidden, available, loading(Double?)
  }
  public enum LocalHighQualityAvailability: Equatable {
    case unknown, requiresNetwork
  }

  public let session: PlaybackSession
  /// Only this owner's explicit HQ operation supplies busy state and progress.
  public var highQualityAction: HighQualityAction {
    let attempt = qualityAttempt
    guard let visit, let acceptedReceipt, acceptedReceipt.isCurrent,
      session.isCurrentSource(AnyHashable(ObjectIdentifier(visit.source))) else { return .hidden }
    if let attempt, attempt.purpose == .explicit { return .loading(attempt.preparation.progress) }
    guard let installed = installedReceipt, installed.evidence.quality != .highest else { return .hidden }
    return localHighQualityAvailability == .requiresNetwork || hasRequestedHighQuality ? .available : .hidden
  }

  public var localHighQualityAvailability: LocalHighQualityAvailability {
    let availability = localAvailability
    guard let installed = installedReceipt, installed.evidence.quality != .highest,
      lastLocalCheckRepresentation == installed.representationID else { return .unknown }
    return availability
  }

  /// One forbidden-network check for each usable representation; failures never retry themselves.
  /// Call from the host's existing readiness observation. Verified files are already highest quality.
  public func checkLocalHighQuality() {
    guard let visit, let installed = installedReceipt, installed.evidence.quality != .highest,
      lastLocalCheckRepresentation != installed.representationID, !hasRequestedHighQuality,
      qualityTask == nil, storedQualityAttempt == nil else { return }
    lastLocalCheckRepresentation = installed.representationID
    beginHighQuality(visit: visit, installed: installed, network: .forbidden, purpose: .local)
  }
  public private(set) var qualityFailure: (any Error)?
  private var acceptedReceipt: VideoReceipt?
  @ObservationIgnored private var visit: Visit?
  @ObservationIgnored private var initialPreparation: VideoPreparation?
  @ObservationIgnored private var storedQualityAttempt: QualityAttempt?
  private var qualityAttempt: QualityAttempt? {
    access(keyPath: \.qualityAttempt)
    return storedQualityAttempt
  }
  @ObservationIgnored private var qualityTask: Task<Void, Never>?
  @ObservationIgnored private var lastLocalCheckRepresentation: VideoRepresentationID?
  @ObservationIgnored private var hasRequestedHighQuality = false
  private var localAvailability = LocalHighQualityAvailability.unknown

  private enum QualityPurpose: Equatable { case local, explicit }
  private struct QualityAttempt {
    let preparation: VideoPreparation
    let purpose: QualityPurpose
  }

  private struct Visit {
    let id: UUID
    let source: VideoSource
  }

  /// A current receipt for the representation actually installed and ready in this session.
  /// A shared source's preferred receipt does not prove another session installed it.
  public var installedReceipt: VideoReceipt? {
    guard let visit, let receipt = acceptedReceipt, receipt.isCurrent,
      session.isCurrentSource(AnyHashable(ObjectIdentifier(visit.source))),
      session.isPlayerReady, let media = session.currentLoadedMedia,
      media.asset === receipt.asset, media.audioMix === receipt.audioMix else { return nil }
    return receipt
  }

  public convenience init(
    preparation: PlaybackPreparation? = nil,
    onEvent: @escaping @MainActor (PlaybackEvent) -> Void = { _ in }
  ) {
    self.init(session: PlaybackSession(), onEvent: onEvent)
    session.preparation = preparation
  }

  init(session: PlaybackSession, onEvent: @escaping @MainActor (PlaybackEvent) -> Void = { _ in }) {
    self.session = session
    let originalEvent = session.onEvent
    session.onEvent = { [weak self] event in
      if case .didCleanup = event { self?.releaseVisit() }
      originalEvent(event)
      onEvent(event)
    }
  }

  isolated deinit {
    releaseVisit()
    session.cleanup()
  }

  public func load(
    source: VideoSource,
    request: VideoRequest = .init(),
    thumbnail: @escaping @MainActor (CGSize) async -> UIImage? = { _ in nil },
    playbackRate: Float = 1,
    isLooping: Bool = true,
    autoplayWhenReady: Bool = false
  ) {
    session.load(
      source: playbackSource(source, request: request, thumbnail: thumbnail),
      playbackRate: playbackRate, isLooping: isLooping, autoplayWhenReady: autoplayWhenReady
    )
  }

  /// Audio preparation retry reuses the installed item and never obtains a resource.
  /// A resource retry creates only this owner's new finite consumption.
  public func retry(
    source: VideoSource,
    request: VideoRequest = .init(),
    thumbnail: @escaping @MainActor (CGSize) async -> UIImage? = { _ in nil },
    autoplayWhenReady: Bool = true
  ) {
    if session.isCurrentSource(AnyHashable(ObjectIdentifier(source))),
      case .preparation = session.failure {
      session.retryPlaybackPreparation()
      return
    }
    session.retry(
      source: playbackSource(source, request: request, thumbnail: thumbnail),
      playbackRate: session.playbackConfig.playbackRate,
      isLooping: session.playbackConfig.isLooping, autoplayWhenReady: autoplayWhenReady
    )
  }

  /// Registers this owner's HQ share before returning, including when acquisition is shared.
  /// Candidate installation and failure belong solely to this playback session.
  public func requestHighQuality(network: VideoRequest.Network = .allowed) {
    guard let visit, let installed = installedReceipt,
      installed.evidence.quality != .highest, qualityTask == nil, storedQualityAttempt == nil else { return }
    hasRequestedHighQuality = true
    qualityFailure = nil
    guard self.visit?.id == visit.id else { return }
    beginHighQuality(visit: visit, installed: installed, network: network, purpose: .explicit)
  }

  private func beginHighQuality(
    visit: Visit, installed: VideoReceipt, network: VideoRequest.Network, purpose: QualityPurpose
  ) {
    let preparation = visit.source.prepare(.init(quality: .highest, network: network))
    guard self.visit?.id == visit.id, qualityTask == nil, storedQualityAttempt == nil else {
      preparation.cancel()
      return
    }
    // Observation's willSet callback runs before the write. A synchronous close must
    // not put the retired preparation back into this owner after cleanup returned.
    let published = withMutation(keyPath: \.qualityAttempt) {
      guard self.visit?.id == visit.id, qualityTask == nil, storedQualityAttempt == nil else { return false }
      storedQualityAttempt = QualityAttempt(preparation: preparation, purpose: purpose)
      return true
    }
    guard published, self.visit?.id == visit.id,
      storedQualityAttempt?.preparation === preparation else { preparation.cancel(); return }
    let native = session
    qualityTask = Task { [weak self] in
      var obtainedReceipt = false
      defer {
        preparation.cancel()
        if let self, self.visit?.id == visit.id, storedQualityAttempt?.preparation === preparation {
          qualityTask = nil
          withMutation(keyPath: \.qualityAttempt) {
            guard self.visit?.id == visit.id, self.storedQualityAttempt?.preparation === preparation else { return }
            self.storedQualityAttempt = nil
          }
        }
      }
      do {
        try Task.checkCancellation()
        let receipt = try await preparation.value()
        obtainedReceipt = true
        try Task.checkCancellation()
        guard self?.visit?.id == visit.id, receipt.isCurrent,
          native.isCurrentSource(AnyHashable(ObjectIdentifier(visit.source))) else {
          throw CancellationError()
        }
        if receipt.representationID != installed.representationID {
          try await native.replaceAsset(Self.media(receipt), for: AnyHashable(ObjectIdentifier(visit.source)))
        }
        try Task.checkCancellation()
        guard self?.visit?.id == visit.id, receipt.isCurrent,
          let actual = native.currentLoadedMedia,
          actual.asset === receipt.asset, actual.audioMix === receipt.audioMix else {
          throw CancellationError()
        }
        self?.acceptedReceipt = receipt
      } catch is CancellationError {
        // Closing or superseding this owner is not a resource or installation failure.
      } catch {
        guard let self, self.visit?.id == visit.id, installed.isCurrent,
          self.visit?.id == visit.id else { return }
        switch purpose {
        case .explicit:
          withMutation(keyPath: \.qualityFailure) {
            guard self.visit?.id == visit.id else { return }
            _qualityFailure = error
          }
        case .local:
          let availability: LocalHighQualityAvailability =
            !obtainedReceipt && (error as? VideoResourceFailure) == .networkRequired ? .requiresNetwork : .unknown
          withMutation(keyPath: \.localAvailability) {
            guard self.visit?.id == visit.id else { return }
            _localAvailability = availability
          }
        }
      }
    }
  }

  public func cleanup() { session.cleanup() }

  private func playbackSource(
    _ source: VideoSource, request: VideoRequest,
    thumbnail: @escaping @MainActor (CGSize) async -> UIImage?
  ) -> PlaybackSource {
    // Native beginLoad cleans up the previous visit before invoking this loader.
    // Source construction therefore has no acquisition and captures no attempt generation.
    PlaybackSource(identity: ObjectIdentifier(source), load: { [weak self] in
      try Task.checkCancellation()
      let visit = Visit(id: UUID(), source: source)
      let preparation: VideoPreparation
      // Do not retain the owner across the acquisition await; owner release must cancel its share.
      if let owner = self {
        owner.visit = visit
        preparation = source.prepare(request)
        guard owner.visit?.id == visit.id else { preparation.cancel(); throw CancellationError() }
        owner.initialPreparation = preparation
      } else {
        throw CancellationError()
      }
      defer {
        preparation.cancel()
        if let owner = self, owner.visit?.id == visit.id { owner.initialPreparation = nil }
      }
      let receipt = try await preparation.value()
      try Task.checkCancellation()
      guard let owner = self, owner.visit?.id == visit.id, receipt.isCurrent,
        owner.session.isCurrentSource(AnyHashable(ObjectIdentifier(source))) else {
        throw CancellationError()
      }
      owner.acceptedReceipt = receipt
      return Self.media(receipt)
    }, thumbnail: thumbnail)
  }

  private static func media(_ receipt: VideoReceipt) -> PlaybackLoadedMedia {
    PlaybackLoadedMedia(asset: receipt.asset, audioMix: receipt.audioMix, validate: {
      guard receipt.isCurrent else { throw VideoResourceFailure.sourceChanged }
    })
  }

  private func releaseVisit() {
    let initial = initialPreparation
    let quality = storedQualityAttempt?.preparation
    let task = qualityTask
    visit = nil
    initialPreparation = nil
    qualityTask = nil
    lastLocalCheckRepresentation = nil
    hasRequestedHighQuality = false
    acceptedReceipt = nil
    qualityFailure = nil
    localAvailability = .unknown
    withMutation(keyPath: \.qualityAttempt) { storedQualityAttempt = nil }
    initial?.cancel()
    quality?.cancel()
    task?.cancel()
  }
}
