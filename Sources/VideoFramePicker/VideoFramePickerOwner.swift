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
  private(set) var player: AVPlayer?
  private(set) var duration = 0.0
  private(set) var selectedSeconds = 0.0
  private(set) var preview: VideoFrameSelection?
  private(set) var isScrubbing = false
  private(set) var isShowingPlayerPreview = false
  private(set) var hasPendingSelection = false
  private(set) var isProcessingSelection = false
  private(set) var failure: VideoFramePickerFailure?

  var isSliderDisabled: Bool { player == nil || duration <= 0 || isProcessingSelection }

  var sourceStatus: VideoFramePickerSourceStatus {
    if player != nil { return .ready }
    if let failure { return .failed(failure) }
    return .loading
  }

  @ObservationIgnored private var sourceIdentity: AnyHashable?
  @ObservationIgnored private var sourceGeneration = UUID()
  @ObservationIgnored private var requestGeneration = UUID()
  @ObservationIgnored private var asset: AVAsset?
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
  }

  func start(
    source: VideoFramePickerSource,
    initialTime: Double?,
    maximumFrameSize: CGSize,
    onFailure: @escaping @MainActor (VideoFramePickerFailure) -> Void
  ) {
    guard sourceIdentity != source.identity else { return }
    stop()
    sourceIdentity = source.identity
    self.maximumFrameSize = maximumFrameSize
    let generation = sourceGeneration
    do {
      try Self.validate(initialTime: initialTime, maximumFrameSize: maximumFrameSize)
    } catch {
      let failure = error as? VideoFramePickerFailure
        ?? .source(.unavailable, cause: error)
      self.failure = failure
      onFailure(failure)
      return
    }

    let load = source.load
    let inspectAsset = inspectAsset
    loadTask = Task { @MainActor [weak self] in
      do {
        try Task.checkCancellation()
        let asset = try await load()
        try Task.checkCancellation()
        guard self?.sourceGeneration == generation else { return }
        let duration = try await inspectAsset(asset)
        try Task.checkCancellation()
        let seconds = try Self.validatedDuration(duration)
        guard self?.sourceGeneration == generation else { return }
        self?.install(
          asset: asset, duration: seconds, initialTime: initialTime, onFailure: onFailure
        )
      } catch {
        guard !Task.isCancelled, self?.sourceGeneration == generation else { return }
        self?.loadFailed(error, onFailure: onFailure)
      }
    }
  }

  func stop() {
    sourceGeneration = UUID()
    sourceIdentity = nil
    loadTask?.cancel()
    loadTask = nil
    invalidateExactRequest()
    player?.pause()
    seekCoordinator?.reset()
    player?.replaceCurrentItem(with: nil)
    player = nil
    seekCoordinator = nil
    asset = nil
    pendingCallbacks = nil
    hasPendingSelection = false
    isProcessingSelection = false
    isScrubbing = false
    isShowingPlayerPreview = false
    duration = 0
    selectedSeconds = 0
    preview = nil
    failure = nil
  }

  func beginScrubbing() {
    guard !isSliderDisabled else { return }
    isScrubbing = true
    invalidateExactRequest()
    isShowingPlayerPreview = true
    seek(to: selectedSeconds, precision: .interactive)
  }

  func changeSeconds(_ seconds: Double, callbacks: VideoFramePickerCallbacks) {
    guard !isSliderDisabled, seconds.isFinite, seconds >= 0 else { return }
    let seconds = min(seconds, duration)
    guard seconds != selectedSeconds else { return }
    selectedSeconds = seconds
    pendingCallbacks = callbacks
    hasPendingSelection = true
    isShowingPlayerPreview = true
    if isScrubbing {
      seek(to: seconds, precision: .interactive)
    } else {
      seek(to: seconds, precision: .exact)
      startExactRequest(onFailure: callbacks.onFailure)
    }
  }

  func endScrubbing(onFailure: @escaping @MainActor (VideoFramePickerFailure) -> Void) {
    guard isScrubbing else { return }
    isScrubbing = false
    seek(to: selectedSeconds, precision: .exact)
    startExactRequest(onFailure: onFailure)
  }

  private func install(
    asset: AVAsset, duration: Double, initialTime: Double?,
    onFailure: @escaping @MainActor (VideoFramePickerFailure) -> Void
  ) {
    loadTask = nil
    self.asset = asset
    self.duration = duration
    selectedSeconds = min(initialTime ?? min(duration * 0.1, 1), duration)
    let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
    player.isMuted = true
    player.pause()
    self.player = player
    isShowingPlayerPreview = true
    seekCoordinator = VideoSeekCoordinator(player: player)
    seek(to: selectedSeconds, precision: .exact)
    startExactRequest(onFailure: onFailure)
  }

  private func seek(to seconds: Double, precision: VideoSeekPrecision) {
    player?.pause()
    seekCoordinator?.seek(to: seconds, duration: duration, precision: precision)
  }

  private func invalidateExactRequest() {
    requestGeneration = UUID()
    frameTask?.cancel()
    frameTask = nil
  }

  private func startExactRequest(
    onFailure: @escaping @MainActor (VideoFramePickerFailure) -> Void
  ) {
    guard let asset else { return }
    invalidateExactRequest()
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
        let frame = try await extractFrame(asset, seconds, maximumSize)
        try Task.checkCancellation()
        guard self?.publish(frame, generation: generation, consuming: callbacks != nil) == true
        else { return }
        if let callbacks {
          processing = true
          try await callbacks.onSelection(frame)
          try Task.checkCancellation()
        }
        self?.complete(generation: generation)
      } catch {
        guard !Task.isCancelled else { return }
        let failure: VideoFramePickerFailure = processing
          ? .selectionProcessing(cause: error) : .frame(cause: error)
        self?.fail(failure, generation: generation, onFailure: failureHandler)
      }
    }
  }

  private func publish(_ frame: VideoFrameSelection, generation: UUID, consuming: Bool) -> Bool {
    guard requestGeneration == generation else { return false }
    preview = frame
    isShowingPlayerPreview = false
    failure = nil
    isProcessingSelection = consuming
    return true
  }

  private func complete(generation: UUID) {
    guard requestGeneration == generation else { return }
    frameTask = nil
    pendingCallbacks = nil
    hasPendingSelection = false
    isProcessingSelection = false
  }

  private func fail(
    _ failure: VideoFramePickerFailure, generation: UUID,
    onFailure: @MainActor (VideoFramePickerFailure) -> Void
  ) {
    guard requestGeneration == generation else { return }
    frameTask = nil
    pendingCallbacks = nil
    hasPendingSelection = false
    isProcessingSelection = false
    // A previous exact image is still useful when the current request fails.
    isShowingPlayerPreview = preview == nil
    self.failure = failure
    onFailure(failure)
  }

  private func loadFailed(
    _ error: any Error, onFailure: @MainActor (VideoFramePickerFailure) -> Void
  ) {
    loadTask = nil
    let failure = error as? VideoFramePickerFailure ?? .source(.unavailable, cause: error)
    self.failure = failure
    onFailure(failure)
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
