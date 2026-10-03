import AVFoundation
import Observation
import VideoPlayback
import VideoProcessing

@MainActor
struct VideoFramePickerCallbacks {
  let onFailure: @MainActor (VideoFramePickerFailure) -> Void
  let onSelection: @MainActor (VideoFrameSelection) async throws -> Void
}

/// One mounted picker's resources and pending user intent. Tasks only borrow this
/// owner between awaits; cancellation cannot keep an unmounted picker alive.
@MainActor
@Observable
final class VideoFramePickerOwner {
  @ObservationIgnored private var storedPlayer: AVPlayer?
  var player: AVPlayer? {
    access(keyPath: \.player)
    return storedPlayer
  }
  private(set) var duration = 0.0
  private(set) var selectedSeconds = 0.0
  @ObservationIgnored private var storedPreview: VideoFrameSelection?
  var preview: VideoFrameSelection? {
    access(keyPath: \.preview)
    return storedPreview
  }
  private(set) var isScrubbing = false
  private(set) var isShowingPlayerPreview = false
  @ObservationIgnored private var storedPendingSelection = false
  var hasPendingSelection: Bool {
    access(keyPath: \.hasPendingSelection)
    return storedPendingSelection
  }
  @ObservationIgnored private var storedProcessingSelection = false
  var isProcessingSelection: Bool {
    access(keyPath: \.isProcessingSelection)
    return storedProcessingSelection
  }
  @ObservationIgnored private var storedFailure: VideoFramePickerFailure?
  var failure: VideoFramePickerFailure? {
    access(keyPath: \.failure)
    return storedFailure
  }

  var isSliderDisabled: Bool { player == nil || duration <= 0 || isProcessingSelection }

  var sourceStatus: VideoFramePickerSourceStatus {
    if player != nil { return .ready }
    if let failure { return .failed(failure) }
    return .loading
  }

  @ObservationIgnored private var sourceIdentity: AnyHashable?
  @ObservationIgnored private var sourceGeneration = UUID()
  @ObservationIgnored private var requestGeneration = UUID()
  @ObservationIgnored private var loadedMedia: PlaybackLoadedMedia?
  @ObservationIgnored private var cancelInvalidation: (@MainActor () -> Void)?
  @ObservationIgnored private var maximumFrameSize = CGSize(width: 1280, height: 1280)
  @ObservationIgnored private var seekCoordinator: VideoSeekCoordinator?
  @ObservationIgnored private var pendingCallbacks: VideoFramePickerCallbacks?
  @ObservationIgnored private var loadTask: Task<Void, Never>?
  @ObservationIgnored private var frameTask: Task<Void, Never>?
  @ObservationIgnored private let inspectAsset: @MainActor (AVAsset) async throws -> CMTime
  @ObservationIgnored private let extractFrame:
    @MainActor (AVAsset, Double, CGSize) async throws -> VideoFrameSelection

  init(
    inspectAsset: @escaping @MainActor (AVAsset) async throws -> CMTime = VideoFramePickerOwner.inspect,
    extractFrame: @escaping @MainActor (AVAsset, Double, CGSize) async throws -> VideoFrameSelection
      = VideoFramePickerOwner.extract
  ) {
    self.inspectAsset = inspectAsset
    self.extractFrame = extractFrame
  }

  isolated deinit {
    loadTask?.cancel()
    frameTask?.cancel()
    player?.pause()
    seekCoordinator?.reset()
    player?.replaceCurrentItem(with: nil)
    cancelInvalidation?()
  }

  func start(
    source: VideoFramePickerSource,
    initialTime: Double?,
    maximumFrameSize: CGSize,
    onFailure: @escaping @MainActor (VideoFramePickerFailure) -> Void
  ) {
    guard sourceIdentity != source.identity, stop() else { return }
    sourceIdentity = source.identity
    self.maximumFrameSize = maximumFrameSize
    let generation = sourceGeneration
    do {
      try Self.validate(initialTime: initialTime, maximumFrameSize: maximumFrameSize)
    } catch {
      let failure = error as? VideoFramePickerFailure
        ?? .source(.unavailable, cause: error)
      guard mutateCurrent(\.failure, source: generation, {
        storedFailure = failure
      }) else { return }
      onFailure(failure)
      return
    }

    let load = source.load
    let onInvalidation = source.onInvalidation
    let inspectAsset = inspectAsset
    loadTask = Task { @MainActor [weak self] in
      do {
        try Task.checkCancellation()
        let media = try await load()
        try Task.checkCancellation()
        try self?.validateCurrent(media, source: generation)
        guard self?.isCurrent(source: generation) == true else { return }
        if let onInvalidation {
          try self?.subscribeToInvalidation(onInvalidation, media: media, generation: generation)
        }
        guard self?.isCurrent(source: generation) == true else { return }
        let duration = try await inspectAsset(media.asset)
        try Task.checkCancellation()
        try self?.validateCurrent(media, source: generation)
        guard self?.isCurrent(source: generation) == true else { return }
        let seconds = try Self.validatedDuration(duration)
        try self?.install(
          media: media, duration: seconds, initialTime: initialTime,
          generation: generation, onFailure: onFailure
        )
      } catch {
        guard !Task.isCancelled, self?.isCurrent(source: generation) == true else { return }
        self?.loadFailed(error, onFailure: onFailure)
      }
    }
  }

  @discardableResult
  func stop() -> Bool {
    sourceGeneration = UUID()
    let generation = sourceGeneration
    sourceIdentity = nil
    loadTask?.cancel()
    loadTask = nil
    invalidateExactRequest()
    let retiredPlayer = player
    let retiredSeek = seekCoordinator
    let cancelInvalidation = cancelInvalidation
    self.cancelInvalidation = nil
    seekCoordinator = nil
    loadedMedia = nil
    pendingCallbacks = nil
    retiredPlayer?.pause()
    retiredSeek?.reset()
    retiredPlayer?.replaceCurrentItem(with: nil)
    cancelInvalidation?()
    guard isCurrent(source: generation) else { return false }
    guard mutateCurrent(\.player, source: generation, { storedPlayer = nil }) else { return false }
    guard mutateCurrent(\.hasPendingSelection, source: generation, {
      storedPendingSelection = false
    }) else { return false }
    guard mutateCurrent(\.isProcessingSelection, source: generation, {
      storedProcessingSelection = false
    }) else { return false }
    isScrubbing = false
    guard isCurrent(source: generation) else { return false }
    isShowingPlayerPreview = false
    guard isCurrent(source: generation) else { return false }
    duration = 0
    guard isCurrent(source: generation) else { return false }
    selectedSeconds = 0
    guard isCurrent(source: generation) else { return false }
    guard mutateCurrent(\.preview, source: generation, { storedPreview = nil }) else { return false }
    return mutateCurrent(\.failure, source: generation, { storedFailure = nil })
  }

  private func subscribeToInvalidation(
    _ subscribe: @MainActor (@escaping @MainActor () -> Void) -> (@MainActor () -> Void),
    media: PlaybackLoadedMedia, generation: UUID
  ) throws {
    guard isCurrent(source: generation) else { throw CancellationError() }
    let cancel = subscribe { [weak self] in self?.sourceInvalidated(generation: generation) }
    guard isCurrent(source: generation) else {
      cancel()
      throw CancellationError()
    }
    cancelInvalidation = cancel
    try validateCurrent(media, source: generation)
  }

  private func sourceInvalidated(generation: UUID) {
    guard isCurrent(source: generation), stop() else { return }
    let stoppedGeneration = sourceGeneration
    _ = mutateCurrent(\.failure, source: stoppedGeneration, {
      storedFailure = .source(.unavailable, cause: nil)
    })
  }

  func beginScrubbing() {
    guard !isSliderDisabled else { return }
    let source = sourceGeneration
    let request = requestGeneration
    isScrubbing = true
    guard isCurrent(source: source, request: request) else { return }
    invalidateExactRequest()
    let nextRequest = requestGeneration
    isShowingPlayerPreview = true
    guard isCurrent(source: source, request: nextRequest) else { return }
    _ = seek(to: selectedSeconds, precision: .interactive)
  }

  func changeSeconds(_ seconds: Double, callbacks: VideoFramePickerCallbacks) {
    guard !isSliderDisabled, seconds.isFinite, seconds >= 0 else { return }
    let seconds = min(seconds, duration)
    guard seconds != selectedSeconds else { return }
    let source = sourceGeneration
    let request = requestGeneration
    selectedSeconds = seconds
    guard isCurrent(source: source, request: request) else { return }
    pendingCallbacks = callbacks
    guard mutateCurrent(\.hasPendingSelection, source: source, request: request, {
      storedPendingSelection = true
    }) else { return }
    isShowingPlayerPreview = true
    guard isCurrent(source: source, request: request) else { return }
    if isScrubbing {
      _ = seek(to: seconds, precision: .interactive, onFailure: callbacks.onFailure)
    } else {
      guard seek(to: seconds, precision: .exact, onFailure: callbacks.onFailure),
            isCurrent(source: source, request: request) else { return }
      startExactRequest(onFailure: callbacks.onFailure)
    }
  }

  func endScrubbing(onFailure: @escaping @MainActor (VideoFramePickerFailure) -> Void) {
    guard isScrubbing else { return }
    let source = sourceGeneration
    let request = requestGeneration
    isScrubbing = false
    guard isCurrent(source: source, request: request),
          seek(to: selectedSeconds, precision: .exact, onFailure: onFailure),
          isCurrent(source: source, request: request) else { return }
    startExactRequest(onFailure: onFailure)
  }

  private func install(
    media: PlaybackLoadedMedia, duration: Double, initialTime: Double?, generation: UUID,
    onFailure: @escaping @MainActor (VideoFramePickerFailure) -> Void
  ) throws {
    try validateCurrent(media, source: generation)
    loadTask = nil
    loadedMedia = media
    self.duration = duration
    guard isCurrent(source: generation) else { return }
    selectedSeconds = min(initialTime ?? min(duration * 0.1, 1), duration)
    guard isCurrent(source: generation) else { return }
    let item = AVPlayerItem(asset: media.asset)
    item.audioMix = media.audioMix
    let player = AVPlayer(playerItem: item)
    player.isMuted = true
    player.pause()
    defer {
      if self.player !== player { player.replaceCurrentItem(with: nil) }
    }
    guard try mutateCurrent(\.player, source: generation, {
      try validateCurrent(media, source: generation)
      storedPlayer = player
    }) else { return }
    guard self.player === player, player.currentItem === item else { return }
    isShowingPlayerPreview = true
    guard isCurrent(source: generation), self.player === player,
          player.currentItem === item else { return }
    seekCoordinator = VideoSeekCoordinator(player: player)
    guard seek(to: selectedSeconds, precision: .exact, onFailure: onFailure),
          isCurrent(source: generation), self.player === player,
          player.currentItem === item else { return }
    startExactRequest(onFailure: onFailure)
  }

  private func seek(
    to seconds: Double, precision: VideoSeekPrecision,
    onFailure: (@MainActor (VideoFramePickerFailure) -> Void)? = nil
  ) -> Bool {
    guard let media = loadedMedia, let player, let item = player.currentItem,
          let coordinator = seekCoordinator else { return false }
    let source = sourceGeneration
    let request = requestGeneration
    do {
      try validateCurrent(media, source: source, request: request)
    } catch {
      guard isCurrent(source: source, request: request), self.player === player,
            player.currentItem === item else { return false }
      let failure = VideoFramePickerFailure.source(.unavailable, cause: error)
      guard stop() else { return false }
      let stoppedGeneration = sourceGeneration
      guard mutateCurrent(\.failure, source: stoppedGeneration, {
        storedFailure = failure
      }) else { return false }
      onFailure?(failure)
      return false
    }
    guard isCurrent(source: source, request: request), self.player === player,
          player.currentItem === item else { return false }
    player.pause()
    guard isCurrent(source: source, request: request), self.player === player,
          player.currentItem === item else { return false }
    coordinator.seek(to: seconds, duration: duration, precision: precision)
    return isCurrent(source: source, request: request)
      && self.player === player && player.currentItem === item
  }

  private func invalidateExactRequest() {
    requestGeneration = UUID()
    frameTask?.cancel()
    frameTask = nil
  }

  private func startExactRequest(
    onFailure: @escaping @MainActor (VideoFramePickerFailure) -> Void
  ) {
    guard let media = loadedMedia else { return }
    invalidateExactRequest()
    let source = sourceGeneration
    let generation = requestGeneration
    let seconds = selectedSeconds
    let maximumSize = maximumFrameSize
    let callbacks = pendingCallbacks
    let failureHandler = callbacks?.onFailure ?? onFailure
    let extractFrame = extractFrame
    frameTask = Task { @MainActor [weak self] in
      var processing = false
      do {
        try Task.checkCancellation()
        try self?.validateCurrent(media, source: source, request: generation)
        guard self?.isCurrent(source: source, request: generation) == true else { return }
        let decoded = try await extractFrame(media.asset, seconds, maximumSize)
        try Task.checkCancellation()
        guard let frame = self?.scopedSelection(
          decoded, media: media, source: source, request: generation
        ) else { return }
        guard try self?.publish(frame, source: source, generation: generation,
          consuming: callbacks != nil) == true else { return }
        if let callbacks {
          try frame.validate()
          processing = true
          try await callbacks.onSelection(frame)
          try Task.checkCancellation()
        }
        try frame.validate()
        self?.complete(generation: generation)
      } catch {
        guard !Task.isCancelled else { return }
        let failure: VideoFramePickerFailure = processing
          ? .selectionProcessing(cause: error) : .frame(cause: error)
        self?.fail(failure, generation: generation, onFailure: failureHandler)
      }
    }
  }

  private func publish(
    _ frame: VideoFrameSelection, source: UUID, generation: UUID, consuming: Bool
  ) throws -> Bool {
    try frame.validate()
    guard try mutateCurrent(\.preview, source: source, request: generation, {
      try frame.validate()
      storedPreview = frame
    }) else { return false }
    try frame.validate()
    isShowingPlayerPreview = false
    guard isCurrent(source: source, request: generation) else { return false }
    guard mutateCurrent(\.failure, source: source, request: generation, {
      storedFailure = nil
    }) else { return false }
    guard mutateCurrent(\.isProcessingSelection, source: source, request: generation, {
      storedProcessingSelection = consuming
    }) else { return false }
    try frame.validate()
    return isCurrent(source: source, request: generation)
  }

  private func complete(generation: UUID) {
    guard requestGeneration == generation else { return }
    let source = sourceGeneration
    frameTask = nil
    pendingCallbacks = nil
    guard mutateCurrent(\.hasPendingSelection, source: source, request: generation, {
      storedPendingSelection = false
    }) else { return }
    _ = mutateCurrent(\.isProcessingSelection, source: source, request: generation, {
      storedProcessingSelection = false
    })
  }

  private func fail(
    _ failure: VideoFramePickerFailure, generation: UUID,
    onFailure: @MainActor (VideoFramePickerFailure) -> Void
  ) {
    guard requestGeneration == generation else { return }
    let source = sourceGeneration
    frameTask = nil
    pendingCallbacks = nil
    guard mutateCurrent(\.hasPendingSelection, source: source, request: generation, {
      storedPendingSelection = false
    }) else { return }
    guard mutateCurrent(\.isProcessingSelection, source: source, request: generation, {
      storedProcessingSelection = false
    }) else { return }
    // A previous exact image is still useful when the current request fails.
    isShowingPlayerPreview = preview == nil
    guard isCurrent(source: source, request: generation) else { return }
    guard mutateCurrent(\.failure, source: source, request: generation, {
      storedFailure = failure
    }) else { return }
    onFailure(failure)
  }

  private func loadFailed(
    _ error: any Error, onFailure: @MainActor (VideoFramePickerFailure) -> Void
  ) {
    let source = sourceGeneration
    loadTask = nil
    loadedMedia = nil
    let cancelInvalidation = cancelInvalidation
    self.cancelInvalidation = nil
    cancelInvalidation?()
    guard isCurrent(source: source) else { return }
    let failure = error as? VideoFramePickerFailure ?? .source(.unavailable, cause: error)
    guard mutateCurrent(\.failure, source: source, {
      storedFailure = failure
    }) else { return }
    onFailure(failure)
  }

  private func isCurrent(source: UUID, request: UUID? = nil) -> Bool {
    sourceGeneration == source && (request == nil || requestGeneration == request)
  }

  /// Observation notifies before writing. Recheck the original operation after
  /// that notification so a synchronous stop or switch cannot receive an old value.
  private func mutateCurrent<Member>(
    _ keyPath: KeyPath<VideoFramePickerOwner, Member>, source: UUID, request: UUID? = nil,
    _ mutation: () throws -> Void
  ) rethrows -> Bool {
    let mutated = try withMutation(keyPath: keyPath) {
      guard isCurrent(source: source, request: request) else { return false }
      try mutation()
      return true
    }
    return mutated && isCurrent(source: source, request: request)
  }

  private func validateCurrent(
    _ media: PlaybackLoadedMedia, source: UUID, request: UUID? = nil
  ) throws {
    guard isCurrent(source: source, request: request) else { throw CancellationError() }
    do {
      try media.validate()
    } catch {
      guard isCurrent(source: source, request: request) else { throw CancellationError() }
      throw error
    }
    guard isCurrent(source: source, request: request) else { throw CancellationError() }
  }

  private func scopedSelection(
    _ frame: VideoFrameSelection, media: PlaybackLoadedMedia, source: UUID, request: UUID
  ) -> VideoFrameSelection {
    VideoFrameSelection(image: frame.image, requestedSeconds: frame.requestedSeconds,
      actualTime: frame.actualTime, validate: { [weak self] in
        guard let self, isCurrent(source: source, request: request) else {
          throw CancellationError()
        }
        do {
          try frame.validate()
        } catch {
          guard isCurrent(source: source, request: request) else { throw CancellationError() }
          throw error
        }
        try validateCurrent(media, source: source, request: request)
      })
  }

  static func validate(initialTime: Double?, maximumFrameSize: CGSize) throws {
    if let initialTime, !initialTime.isFinite || initialTime < 0 {
      throw VideoFramePickerFailure.configuration(.invalidInitialTime)
    }
    guard maximumFrameSize.width.isFinite, maximumFrameSize.height.isFinite,
          (1...4096).contains(maximumFrameSize.width),
          (1...4096).contains(maximumFrameSize.height) else {
      throw VideoFramePickerFailure.configuration(.invalidMaximumFrameSize)
    }
  }

  static func validatedDuration(_ duration: CMTime) throws -> Double {
    let seconds = duration.seconds
    guard duration.isNumeric, seconds.isFinite, seconds >= 0,
          CMTime(seconds: seconds, preferredTimescale: CMTimeScale(NSEC_PER_SEC)).isNumeric,
          Int64(exactly: seconds.rounded()) != nil else {
      throw VideoFramePickerFailure.source(.invalidDuration, cause: nil)
    }
    return seconds
  }

  static func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0, let value = Int64(exactly: seconds.rounded()) else {
      return "0:00"
    }
    let remainder = value % 60
    return "\(value / 60):\(remainder < 10 ? "0" : "")\(remainder)"
  }

  private static func inspect(_ asset: AVAsset) async throws -> CMTime {
    let duration = try await asset.load(.duration)
    try Task.checkCancellation()
    guard try await !asset.loadTracks(withMediaType: .video).isEmpty else {
      throw VideoFramePickerFailure.source(.noVideoTrack, cause: nil)
    }
    try Task.checkCancellation()
    return duration
  }

  private static func extract(
    _ asset: AVAsset, seconds: Double, maximumSize: CGSize
  ) async throws -> VideoFrameSelection {
    let frame = try await VideoFrameExtractor.frame(
      for: asset, at: seconds, maximumSize: maximumSize, exact: true
    )
    return VideoFrameSelection(
      image: frame.image, requestedSeconds: seconds, actualTime: frame.actualTime
    )
  }
}
