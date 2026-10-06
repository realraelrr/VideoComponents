import AVFoundation
import Foundation
import Observation

/// Sources are interned while a caller, preparation, or receipt retains them.
/// This object owns neither a library nor a global media cache.
@MainActor
public final class VideoResources {
  private enum Key: Hashable { case photos(String), file(String) }
  private final class WeakSource {
    weak var value: VideoSource?
    init(_ value: VideoSource) { self.value = value }
  }
  private var sources: [Key: WeakSource] = [:]
  private let photos: PhotosVideoProvider
  private let verifiedFile: (String) async throws -> VerifiedVideoFile

  /// `verifiedFile` verifies an already materialized local file. It must not download,
  /// make account decisions, or recapture facts after the host's integrity check.
  public init(
    photos: PhotosVideoProvider? = nil,
    verifiedFile: @escaping @MainActor (String) async throws -> VerifiedVideoFile = { _ in
      throw VideoResourceFailure.fileUnavailable
    }
  ) {
    self.photos = photos ?? .native()
    self.verifiedFile = verifiedFile
  }

  public func photosSource(serializedCloudIdentifier: String) -> VideoSource {
    source(.photos(serializedCloudIdentifier)) {
      VideoSource(kind: .photos(serializedCloudIdentifier, photos))
    }
  }

  /// The host key identifies the full immutable descriptor, not merely a record UUID.
  public func fileSource(identity: String) -> VideoSource {
    source(.file(identity)) { VideoSource(kind: .file(identity, verifiedFile)) }
  }

  /// Refreshes Photos mapping/authority. It never retries failed acquisitions.
  public func refreshPhotosAccess() {
    photos.refresh()
    for entry in sources.values {
      entry.value?.refreshAuthority()
    }
  }

  private func source(_ key: Key, make: () -> VideoSource) -> VideoSource {
    if let existing = sources[key]?.value { return existing }
    sources = sources.filter { $0.value.value != nil }
    let value = make()
    sources[key] = WeakSource(value)
    return value
  }
}

@MainActor
public struct VideoReceipt {
  public let representationID: VideoRepresentationID
  public let asset: AVAsset
  public let audioMix: AVAudioMix?
  public let evidence: VideoRequest
  private let source: VideoSource
  private let epoch: UInt64
  private let fact: VideoSource.Fact

  fileprivate init(source: VideoSource, epoch: UInt64, value: VideoSource.Loaded) {
    self.source = source
    self.epoch = epoch
    fact = value.fact
    representationID = value.id
    asset = value.representation.asset
    audioMix = value.representation.audioMix
    evidence = value.evidence
  }

  /// An observational use-boundary check, not an atomic lease on AVFoundation reads.
  public var isCurrent: Bool {
    source.isCurrent(epoch: epoch, fact: fact) && VideoSource.backingAvailable(asset)
  }
}

@MainActor @Observable
public final class VideoSource {
  public enum State: Equatable { case idle, acquiring(Double), available, unavailable(VideoResourceFailure) }
  @ObservationIgnored private var storedState: State = .idle
  public var state: State {
    access(keyPath: \.state)
    return storedState
  }
  @ObservationIgnored fileprivate let kind: Kind
  @ObservationIgnored private var epoch: UInt64 = 0
  @ObservationIgnored private var work: [VideoRequest: VideoOperation] = [:]
  @ObservationIgnored private var cached: Loaded?
  @ObservationIgnored private var observedPhotoAuthority: String?
  @ObservationIgnored private var invalidationCallbacks: [UUID: @MainActor () -> Void] = [:]

  fileprivate enum Kind {
    case photos(String, PhotosVideoProvider)
    case file(String, (String) async throws -> VerifiedVideoFile)
  }
  fileprivate enum Fact {
    case photos(String)
    case file(VerifiedVideoFile)
  }
  fileprivate struct Loaded {
    let id: VideoRepresentationID
    let representation: VideoRepresentation
    let evidence: VideoRequest
    let fact: Fact
  }

  fileprivate init(kind: Kind) { self.kind = kind }

  public var preferred: VideoReceipt? {
    access(keyPath: \.preferred)
    guard let cached, isCurrent(epoch: epoch, fact: cached.fact),
      Self.backingAvailable(cached.representation.asset) else { return nil }
    return receipt(cached)
  }

  /// Registers this cancellation share synchronously, before native work can start.
  public func prepare(_ requested: VideoRequest = .init()) -> VideoPreparation {
    let request: VideoRequest
    if case .file = kind { request = .init(quality: .highest, network: .forbidden) }
    else { request = requested }
    if case .photos(let identifier, let provider) = kind {
      do { _ = try observePhotoAuthority(identifier: identifier, provider: provider) }
      catch {
        let operation = VideoOperation(source: self, request: request, epoch: epoch)
        let handle = VideoPreparation(source: self, operation: operation)
        operation.finish(.failure(error is CancellationError ? error : Self.failure(error)))
        return handle
      }
    }
    if let active = work[request] { return VideoPreparation(source: self, operation: active) }
    let operation = VideoOperation(source: self, request: request, epoch: epoch)
    let handle = VideoPreparation(source: self, operation: operation)
    work[request] = operation
    // A local probe cannot clear an ordinary acquisition's known failure.
    if case .unavailable = storedState, isLocalPhotosProbe(request) {} else {
      publishState(.acquiring(0), epoch: operation.epoch, work: work)
    }
    // Observation may synchronously invalidate this operation during publication.
    guard operation.result == nil, operation.epoch == epoch,
      work[request] === operation else { return handle }
    let load: () async throws -> Loaded
    switch kind {
    case .photos(let identifier, let provider):
      guard let authority = observedPhotoAuthority else {
        operation.finish(.failure(VideoResourceFailure.sourceUnavailable))
        return handle
      }
      if let cached, case .photos(let previous) = cached.fact,
        previous == authority, cached.evidence.satisfies(request),
        Self.backingAvailable(cached.representation.asset)
      {
        accept(cached, for: operation)
        return handle
      }
      load = { [weak operation] in
        let value = try await provider.load(identifier, request) { [weak operation] progress in
          Task { @MainActor in operation?.report(progress) }
        }
        return Loaded(id: .init(), representation: value, evidence: request, fact: .photos(authority))
      }
    case .file(let identity, let verify):
      load = {
        let file = try await verify(identity)
        guard file.isCurrent else { throw VideoResourceFailure.fileChanged }
        return Loaded(
          id: .init(), representation: .init(asset: AVURLAsset(url: file.url)),
          evidence: VideoRequest(quality: .highest, network: .forbidden), fact: .file(file)
        )
      }
    }
    operation.start(load)
    return handle
  }

  /// A finite operation whose task cancellation releases its own share.
  public func acquire(_ request: VideoRequest = .init()) async throws -> VideoReceipt {
    try Task.checkCancellation()
    let preparation = prepare(request)
    defer { preparation.cancel() }
    return try await withTaskCancellationHandler {
      try await preparation.value()
    } onCancel: {
      Task { @MainActor in preparation.cancel() }
    }
  }

  /// Observes future source invalidations. Registration does not replay prior changes
  /// or acquire media; the returned closure releases this observation only.
  /// Register after accepting a receipt to observe subsequent source changes.
  public func onInvalidation(
    _ callback: @escaping @MainActor () -> Void
  ) -> @MainActor () -> Void {
    let id = UUID()
    invalidationCallbacks[id] = callback
    return { [weak self] in self?.invalidationCallbacks.removeValue(forKey: id) }
  }

  /// Invalidates pending work and old receipts without starting new work.
  /// A known failure is visible to observers before invalidation callbacks run.
  public func invalidate(reason: VideoResourceFailure? = nil) {
    let callbacks = Array(invalidationCallbacks)
    let hadCached = cached != nil
    epoch &+= 1
    let invalidatedEpoch = epoch
    cached = nil
    let pending = Array(work.values)
    work.removeAll()
    publishState(reason.map(State.unavailable) ?? .idle, epoch: invalidatedEpoch, work: work)
    for operation in pending { operation.finish(.failure(VideoResourceFailure.sourceChanged)) }
    if hadCached { withMutation(keyPath: \.preferred) {} }
    for (id, callback) in callbacks {
      guard invalidationCallbacks[id] != nil else { continue }
      callback()
    }
  }

  fileprivate func isCurrent(epoch: UInt64, fact: Fact) -> Bool {
    switch (kind, fact) {
    case (.photos(let id, let provider), .photos(let authority)):
      let current = try? observePhotoAuthority(identifier: id, provider: provider)
      return epoch == self.epoch && current == authority
    case (.file, .file(let file)): return epoch == self.epoch && file.isCurrent
    default: return false
    }
  }

  fileprivate func refreshAuthority() {
    guard case .photos(let identifier, let provider) = kind else { return }
    _ = try? observePhotoAuthority(identifier: identifier, provider: provider)
  }

  private func observePhotoAuthority(identifier: String, provider: PhotosVideoProvider) throws -> String {
    do {
      let current = try provider.authority(identifier)
      updatePhotoAuthority(current)
      return current
    } catch {
      updatePhotoAuthority(nil, failure: error is CancellationError ? nil : Self.failure(error))
      throw error
    }
  }

  private func updatePhotoAuthority(_ current: String?, failure: VideoResourceFailure? = nil) {
    guard observedPhotoAuthority != current else {
      if current == nil {
        publishState(failure.map(State.unavailable) ?? .idle, epoch: epoch, work: work)
      }
      return
    }
    observedPhotoAuthority = current
    invalidate(reason: failure)
  }

  /// Photos may evict its local URL representation while its library authority stays current.
  /// This existence check is not a Store integrity fact or a promise of atomic access.
  fileprivate static func backingAvailable(_ asset: AVAsset) -> Bool {
    guard let url = (asset as? AVURLAsset)?.url, url.isFileURL else { return true }
    return FileManager.default.fileExists(atPath: url.path)
  }

  fileprivate func accept(_ incoming: Loaded, for operation: VideoOperation) {
    // Authority checks may invalidate the operation. Check ownership again after
    // reading authority, both before committing facts and after notification.
    func current(_ value: Loaded) -> Bool {
      guard operation.result == nil, work[operation.request] === operation,
        operation.epoch == epoch,
        isCurrent(epoch: operation.epoch, fact: value.fact),
        Self.backingAvailable(value.representation.asset)
      else { return false }
      return operation.result == nil && work[operation.request] === operation
        && operation.epoch == epoch
    }
    guard current(incoming) else {
      operation.finish(.failure(VideoResourceFailure.sourceChanged))
      return
    }
    var accepted = incoming
    if let cached, case .file(let previous) = cached.fact,
      case .file(let current) = incoming.fact,
      previous.url == current.url, previous.fingerprint == current.fingerprint
    {
      accepted = cached
    } else if let cached, case .photos(let previous) = cached.fact,
      case .photos(let current) = incoming.fact, previous == current,
      cached.representation.asset === incoming.representation.asset,
      cached.representation.audioMix === incoming.representation.audioMix
    {
      accepted = Loaded(
        id: cached.id, representation: incoming.representation, evidence: incoming.evidence,
        fact: incoming.fact)
    }
    let updatesPreferred: Bool
    if let existing = cached, preferred != nil {
      updatesPreferred = (existing.evidence.quality != .highest && accepted.evidence.quality == .highest)
        || (accepted.evidence.satisfies(existing.evidence)
          && !existing.evidence.satisfies(accepted.evidence))
    } else {
      updatesPreferred = true
    }
    guard current(accepted) else {
      operation.finish(.failure(VideoResourceFailure.sourceChanged))
      return
    }
    if updatesPreferred {
      let changed = cached?.id != accepted.id || cached?.evidence != accepted.evidence
      cached = accepted
      // Facts commit first. Observers may invalidate or prepare synchronously;
      // this notification must never write old facts after their callback.
      if changed { withMutation(keyPath: \.preferred) {} }
    }
    guard current(accepted) else {
      operation.finish(.failure(VideoResourceFailure.sourceChanged))
      return
    }
    operation.finish(.success(receipt(accepted)))
  }

  fileprivate func retired(_ operation: VideoOperation, result: Result<VideoReceipt, Error>) {
    guard work[operation.request] === operation else { return }
    work.removeValue(forKey: operation.request)
    let retiredEpoch = epoch
    let remainingWork = work
    let failure: VideoResourceFailure?
    if case .failure(let error) = result, !(error is CancellationError) {
      failure = Self.failure(error)
    } else { failure = nil }
    let localProbe = isLocalPhotosProbe(operation.request)
    let quietProbeFailure = localProbe &&
      (failure == .networkRequired || failure == .networkFailed || failure == .acquisitionFailed)
    let next: State
    if work.keys.contains(where: { !isLocalPhotosProbe($0) }) { next = .acquiring(0) }
    else if preferred != nil { next = work.isEmpty ? .available : .acquiring(0) }
    else if localProbe, quietProbeFailure || failure == nil {
      if case .unavailable = storedState { next = storedState }
      else { next = work.isEmpty ? .idle : .acquiring(0) }
    } else if let failure { next = .unavailable(failure) }
    else { next = work.isEmpty ? .idle : .acquiring(0) }
    publishState(next, epoch: retiredEpoch, work: remainingWork)
  }

  private func isLocalPhotosProbe(_ request: VideoRequest) -> Bool {
    if case .photos = kind { return request.network == .forbidden }
    return false
  }

  fileprivate func progress(_ operation: VideoOperation, value: Double) {
    guard work[operation.request] === operation else { return }
    if case .unavailable = storedState, isLocalPhotosProbe(operation.request) { return }
    publishState(.acquiring(value.isFinite ? min(1, max(0, value)) : 0),
      epoch: operation.epoch, work: work)
  }

  /// Observation notifies before writing. A callback may start or finish another
  /// request, so the original source facts must still hold inside the mutation.
  @discardableResult
  private func publishState(
    _ next: State, epoch expectedEpoch: UInt64, work expectedWork: [VideoRequest: VideoOperation]
  ) -> Bool {
    // Adding or removing a local Photos probe during a failure notification
    // cannot suppress that failure. An ordinary retry still replaces it.
    let ignoreLocalProbes: Bool
    if case .unavailable = next, case .photos = kind { ignoreLocalProbes = true }
    else { ignoreLocalProbes = false }
    let expected = ignoreLocalProbes
      ? expectedWork.filter { !isLocalPhotosProbe($0.key) } : expectedWork
    let current = {
      let active = ignoreLocalProbes
        ? self.work.filter { !self.isLocalPhotosProbe($0.key) } : self.work
      return self.epoch == expectedEpoch && active.count == expected.count
        && expected.allSatisfy { active[$0.key] === $0.value }
    }
    guard current() else { return false }
    let previous = storedState
    guard previous != next else { return true }
    let published = withMutation(keyPath: \.state) {
      guard current(), storedState == previous else { return false }
      storedState = next
      return true
    }
    return published && current()
  }

  private func receipt(_ value: Loaded) -> VideoReceipt {
    VideoReceipt(source: self, epoch: epoch, value: value)
  }
  fileprivate static func failure(_ error: Error) -> VideoResourceFailure {
    error as? VideoResourceFailure ?? .acquisitionFailed
  }
}

/// One explicit cancellation right. `value()` cancellation only ends that wait.
/// Use `share()` for another consumer; `acquire()` provides automatic task ownership.
@MainActor
public final class VideoPreparation {
  private let source: VideoSource
  private let operation: VideoOperation
  private let shareID: UUID
  private var cancelled: Bool

  fileprivate init(source: VideoSource, operation: VideoOperation, cancelled: Bool = false) {
    self.source = source
    self.operation = operation
    self.cancelled = cancelled
    shareID = cancelled ? UUID() : operation.register()
  }
  isolated deinit { operation.release(shareID) }

  /// Progress reported by this finite acquisition, independently of other source requests.
  public var progress: Double? { cancelled ? nil : operation.progress }

  public func share() -> VideoPreparation {
    VideoPreparation(source: source, operation: operation, cancelled: cancelled)
  }
  public func cancel() {
    if operation.result == nil { cancelled = true }
    operation.release(shareID)
  }
  public func value() async throws -> VideoReceipt {
    try Task.checkCancellation()
    guard !cancelled else { throw CancellationError() }
    guard operation.contains(shareID) || operation.result != nil else { throw CancellationError() }
    return try await operation.value(share: shareID)
  }
}

@MainActor @Observable
fileprivate final class VideoOperation {
  @ObservationIgnored weak var source: VideoSource?
  let request: VideoRequest
  let epoch: UInt64
  private(set) var progress: Double?
  @ObservationIgnored private(set) var result: Result<VideoReceipt, Error>?
  @ObservationIgnored private var shares: Set<UUID> = []
  @ObservationIgnored private var task: Task<Void, Never>?
  private struct Waiter {
    let share: UUID
    let continuation: CheckedContinuation<VideoReceipt, Error>
  }
  @ObservationIgnored private var waiters: [UUID: Waiter] = [:]

  init(source: VideoSource, request: VideoRequest, epoch: UInt64) {
    self.source = source
    self.request = request
    self.epoch = epoch
  }
  func register() -> UUID {
    let id = UUID()
    if result == nil { shares.insert(id) }
    return id
  }
  func contains(_ id: UUID) -> Bool { shares.contains(id) }

  func start(_ load: @escaping () async throws -> VideoSource.Loaded) {
    task = Task { [weak self] in
      do {
        try Task.checkCancellation()
        let value = try await load()
        guard let self, self.result == nil else { return }
        self.source?.accept(value, for: self)
      } catch {
        self?.finish(.failure(error is CancellationError ? error : VideoSource.failure(error)))
      }
    }
  }
  func report(_ progress: Double) {
    guard result == nil else { return }
    if progress.isFinite { self.progress = min(1, max(0, progress)) }
    // Publishing progress may synchronously withdraw the last consumer.
    guard result == nil else { return }
    source?.progress(self, value: progress)
  }

  func release(_ id: UUID) {
    guard result == nil, shares.remove(id) != nil else { return }
    let cancelled = waiters.filter { $0.value.share == id }
    for (key, waiter) in cancelled {
      waiters.removeValue(forKey: key)
      waiter.continuation.resume(throwing: CancellationError())
    }
    if shares.isEmpty { finish(.failure(CancellationError())) }
  }

  func finish(_ result: Result<VideoReceipt, Error>) {
    guard self.result == nil else { return }
    self.result = result
    source?.retired(self, result: result)
    let native = task
    task = nil
    shares.removeAll()
    let pending = Array(waiters.values)
    waiters.removeAll()
    for waiter in pending { waiter.continuation.resume(with: result) }
    if case .failure = result { native?.cancel() }
  }

  func value(share: UUID) async throws -> VideoReceipt {
    let waitID = UUID()
    let outcome: Result<VideoReceipt, Error>
    do {
      let receipt = try await withTaskCancellationHandler {
        try Task.checkCancellation()
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { continuation in
          guard shares.contains(share) else {
            continuation.resume(throwing: CancellationError())
            return
          }
          waiters[waitID] = Waiter(share: share, continuation: continuation)
        }
      } onCancel: {
        Task { @MainActor [weak self] in
          self?.waiters.removeValue(forKey: waitID)?.continuation.resume(throwing: CancellationError())
        }
      }
      outcome = .success(receipt)
    } catch {
      outcome = .failure(error)
    }
    try Task.checkCancellation()
    return try outcome.get()
  }
}
