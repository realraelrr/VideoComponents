import AVFoundation
import Foundation
import SwiftUI
import UIKit

@MainActor public final class PlaybackSession: ObservableObject {
  typealias TransportSeek = @MainActor (AVPlayer, CMTime, @escaping @MainActor (Bool) -> Void) -> Void
  typealias SlowStatusDelay = @MainActor (UInt64) async throws -> Void
  typealias PrepareReplacement = @MainActor (AVAsset) async throws -> AVPlayerItem

  private enum PlaybackInteraction {
    case idle
    case holding
    case scrubbing
  }

  private struct PendingTransport {
    let token: UUID
    let target: CMTime
  }

  private struct PreparationRequest {
    let id: UUID
    let preparation: PlaybackPreparation
    var isReady = false
  }

  private struct AccessPlaybackSnapshot {
    let item: AVPlayerItem
    let time: CMTime
  }

  private static let slowLoadingDelayNanoseconds: UInt64 = 5_000_000_000

  /// Render only. The session exclusively owns item replacement, seeks and transport.
  /// Use a separate player with VideoSeekCoordinator for independent previews.
  public let player = AVPlayer()

  @Published public private(set) var thumbnailImage: UIImage?
  @Published private var playbackCoordinator = PlaybackState()
  @Published public private(set) var isPlayerReady = false
  /// A native rendering layer has displayed playback for this source.
  /// Pauses and representation changes retain this fact; releasing the source clears it.
  @Published public private(set) var hasPresentedVideo = false
  @Published public private(set) var currentTimeSeconds: Double = 0
  @Published public private(set) var durationSeconds: Double = 0
  @Published public private(set) var playbackConfig = VideoPlaybackConfig()
  @Published public private(set) var videoAspectRatio: CGFloat?
  @Published private var playbackInteraction = PlaybackInteraction.idle
  @Published private var wantsPlayback = false
  @Published private var playbackProgress = 0.0
  @Published private var scrubProgress = 0.0

  private let transportSeek: TransportSeek
  private let slowStatusDelay: SlowStatusDelay
  private let prepareReplacement: PrepareReplacement
  private var replacementGeneration = UUID()
  private var replacementItem: AVPlayerItem?
  private var replacementObservation: NSKeyValueObservation?
  private var replacementContinuation: CheckedContinuation<Void, any Error>?
  private var replacementSnapshot: AccessPlaybackSnapshot?
  private var loadedResource: AnyHashable?
  // Separate from loading/item generations: HQ and access refresh retain this source visit.
  private(set) var sourcePresentationID = UUID()
  private var lastAccessRefreshID: UInt64?
  private var pendingTransport: PendingTransport?
  private var playbackEndObserver: NSObjectProtocol?
  private var playerItemStatusObservation: NSKeyValueObservation?
  private var timeControlObservation: NSKeyValueObservation?
  private var periodicTimeObserver: Any?
  private var slowStatusTask: Task<Void, Never>?
  private var previewImageTask: Task<Void, Never>?
  private var aspectRatioTask: Task<Void, Never>?
  private var currentLoadTask: Task<Void, Never>?
  private var accessValidationTask: Task<Void, Never>?
  private var preparationRequest: PreparationRequest?
  private var preparationTask: Task<Void, Never>?
  private var accessPlaybackSnapshot: AccessPlaybackSnapshot?
  private var scrubSeekCoordinator: VideoSeekCoordinator?
  public var onEvent: @MainActor (PlaybackEvent) -> Void
  /// Set before loading. Nil leaves preparation to the package consumer.
  public var preparation: PlaybackPreparation?
  @Published public private(set) var failure: PlaybackFailure?

  public convenience init(onEvent: @escaping @MainActor (PlaybackEvent) -> Void = { _ in }) {
    self.init(transportSeek: Self.seekTransport, slowStatusDelay: { try await Task.sleep(nanoseconds: $0) }, onEvent: onEvent)
  }

  init(
    transportSeek: @escaping TransportSeek,
    slowStatusDelay: @escaping SlowStatusDelay = { try await Task.sleep(nanoseconds: $0) },
    prepareReplacement: @escaping PrepareReplacement = PlaybackSession.prepareReplacementItem,
    onEvent: @escaping @MainActor (PlaybackEvent) -> Void = { _ in }
  ) {
    self.transportSeek = transportSeek
    self.slowStatusDelay = slowStatusDelay
    self.prepareReplacement = prepareReplacement
    self.onEvent = onEvent
  }

  isolated deinit {
    cleanup()
  }

  public var hasCurrentItem: Bool {
    player.currentItem != nil
  }

  /// The source being prepared or displayed, independent of its current representation.
  public var currentSourceIdentity: AnyHashable? { loadedResource }

  var hasActivePlayerObservers: Bool {
    playbackEndObserver != nil || playerItemStatusObservation != nil
      || timeControlObservation != nil || periodicTimeObserver != nil
  }

  public var status: PlaybackStatus {
    if case .preparation = failure { return .unavailable }
    return playbackCoordinator.overlay
  }

  public var canUsePlaybackControls: Bool {
    hasCurrentItem && isPlayerReady && !status.allowsHitTesting
  }

  /// Play/pause intent is available while the current source is still being acquired.
  public var canTogglePlayback: Bool {
    loadedResource != nil && failure == nil && !playbackCoordinator.phase.isTerminal
  }

  public var isWaitingForPlayback: Bool {
    guard isPlaybackRequested, failure == nil, playbackInteraction != .scrubbing else { return false }
    return !hasPresentedVideo || !isPlayerReady || status != .none
      || (preparation != nil && preparationRequest?.isReady != true)
  }

  func didPresentVideo(for identity: AnyHashable, sourcePresentationID: UUID) {
    // The rendering layer already witnessed native playback and display readiness.
    // A pause before delivery must not erase a picture that was actually shown.
    guard loadedResource == identity, self.sourcePresentationID == sourcePresentationID else { return }
    hasPresentedVideo = true
  }

  public var displayedProgress: Double {
    playbackInteraction == .scrubbing
      ? scrubProgress
      : playbackProgress
  }

  public var isPlaybackRequested: Bool {
    wantsPlayback || playbackInteraction == .holding
  }

  public var playbackTimeText: String {
    let displayedTime =
      durationSeconds > 0 ? displayedProgress * durationSeconds : currentTimeSeconds
    return "\(Self.formatPlaybackTime(displayedTime))/\(Self.formatPlaybackTime(durationSeconds))"
  }

  public var playbackRateIndicatorText: String? {
    VideoPlaybackRateDisplay.indicatorText(
      playbackRate: playbackConfig.playbackRate,
      isHolding: playbackInteraction == .holding
    )
  }

  public func load(
    source video: PlaybackSource,
    playbackRate: Float,
    isLooping: Bool,
    autoplayWhenReady: Bool
  ) {
    beginLoad(
      source: video,
      playbackRate: playbackRate,
      isLooping: isLooping,
      autoplayWhenReady: autoplayWhenReady,
      forceReload: false
    )
  }

  public func retry(
    source video: PlaybackSource,
    playbackRate: Float,
    isLooping: Bool,
    autoplayWhenReady: Bool
  ) {
    beginLoad(
      source: video,
      playbackRate: playbackRate,
      isLooping: isLooping,
      autoplayWhenReady: autoplayWhenReady,
      forceReload: true
    )
  }

  public func isCurrentSource(_ identity: AnyHashable) -> Bool { loadedResource == identity }

  /// Replaces the current source's representation without interrupting its old item
  /// during asset preparation. Native item readiness briefly pauses transport after
  /// installation; failure restores the previous item. Completion waits for the
  /// restoring seek, unless a newer user seek adopts the ready candidate first.
  public func replaceAsset(_ asset: AVAsset, for identity: AnyHashable) async throws {
    guard loadedResource == identity else { throw CancellationError() }
    cancelReplacement()
    guard isPlayerReady, let original = player.currentItem,
      accessPlaybackSnapshot == nil else { throw CancellationError() }
    let generation = replacementGeneration
    do {
      try Task.checkCancellation()
      let candidate = try await prepareReplacement(asset)
      try Task.checkCancellation()
      guard replacementGeneration == generation, loadedResource == identity,
        player.currentItem === original else { throw CancellationError() }

      let interruptedTarget = endInteractionForAccessRefresh()
      let time = pendingTransport?.target ?? interruptedTarget ?? player.currentTime()
      replacementSnapshot = AccessPlaybackSnapshot(item: original, time: time)
      cancelPendingTransport()
      scrubSeekCoordinator?.reset()
      scrubSeekCoordinator = nil
      removePlayerObservers()
      cancelAspectRatioLoad()
      cancelPreviewImageLoad()
      player.pause()
      isPlayerReady = false
      let token = playbackCoordinator.startLoading()
      scheduleSlowStatusOverlay(token: token)

      try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
          replacementItem = candidate
          replacementContinuation = continuation
          replacementObservation = candidate.observe(\.status, options: [.initial, .new]) {
            [weak self] _, _ in
            Task { @MainActor in self?.finishReplacementPreparation(generation: generation) }
          }
          player.replaceCurrentItem(with: candidate)
        }
      } onCancel: {
        Task { @MainActor [weak self] in
          guard self?.replacementGeneration == generation else { return }
          self?.cancelReplacement()
        }
      }
      try Task.checkCancellation()
      guard replacementGeneration == generation, loadedResource == identity,
        player.currentItem === candidate, replacementItem === candidate,
        candidate.status == .readyToPlay else { throw CancellationError() }

      replacementObservation?.invalidate()
      replacementObservation = nil
      durationSeconds = playableSeconds(from: candidate.duration) ?? durationSeconds
      observePlayerItemStatus(candidate, token: token)
      observePlaybackEnd(for: candidate, token: token)
      observePlayerBuffering(token: token)
      observePlayerTime(token: token)
      startAspectRatioLoad(for: asset, token: token)
      try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
          replacementContinuation = continuation
          beginTransport(to: time)
          handlePlayerReady(token: token)
        }
      } onCancel: {
        Task { @MainActor [weak self] in
          guard self?.replacementGeneration == generation else { return }
          self?.cancelReplacement()
        }
      }
      try Task.checkCancellation()
      guard replacementGeneration == generation, loadedResource == identity,
        player.currentItem === candidate else { throw CancellationError() }
    } catch {
      if replacementGeneration == generation { cancelReplacement() }
      throw error
    }
  }

  private static func prepareReplacementItem(_ asset: AVAsset) async throws -> AVPlayerItem {
    guard try await asset.load(.isPlayable) else { throw PlaybackFailure.playerItemFailed }
    try Task.checkCancellation()
    return AVPlayerItem(asset: asset)
  }

  private func finishReplacementPreparation(generation: UUID) {
    guard replacementGeneration == generation, let candidate = replacementItem else { return }
    switch candidate.status {
    case .unknown: return
    case .readyToPlay:
      replacementObservation?.invalidate()
      replacementObservation = nil
      let continuation = replacementContinuation
      replacementContinuation = nil
      continuation?.resume()
    case .failed:
      let continuation = replacementContinuation
      replacementContinuation = nil
      continuation?.resume(throwing: PlaybackFailure.playerItemFailed)
    @unknown default:
      let continuation = replacementContinuation
      replacementContinuation = nil
      continuation?.resume(throwing: PlaybackFailure.playerItemFailed)
    }
  }

  private func cancelReplacement(restoreOriginal: Bool = true) {
    replacementGeneration = UUID()
    replacementObservation?.invalidate()
    replacementObservation = nil
    let snapshot = replacementSnapshot
    let shouldRestore = restoreOriginal && snapshot != nil
      && player.currentItem === replacementItem && loadedResource != nil
    replacementItem = nil
    replacementSnapshot = nil
    let continuation = replacementContinuation
    replacementContinuation = nil
    continuation?.resume(throwing: CancellationError())
    if shouldRestore, let snapshot {
      cancelPendingTransport()
      removePlayerObservers()
      cancelAspectRatioLoad()
      isPlayerReady = false
      let token = playbackCoordinator.startLoading()
      player.pause()
      player.replaceCurrentItem(with: snapshot.item)
      durationSeconds = playableSeconds(from: snapshot.item.duration) ?? durationSeconds
      observePlayerItemStatus(snapshot.item, token: token)
      observePlaybackEnd(for: snapshot.item, token: token)
      observePlayerBuffering(token: token)
      observePlayerTime(token: token)
      startAspectRatioLoad(for: snapshot.item.asset, token: token)
      beginTransport(to: snapshot.time)
      if snapshot.item.status == .readyToPlay { handlePlayerReady(token: token) }
    }
  }

  /// Revalidates access without replacing an already loaded item. Calls are deduplicated per source.
  public func revalidateAccess(
    source video: PlaybackSource,
    refreshID: UInt64,
    validation: @MainActor () -> PlaybackAccessValidation
  ) {
    guard loadedResource == video.identity, lastAccessRefreshID != refreshID else { return }
    lastAccessRefreshID = refreshID
    let validator: @MainActor () async throws -> AVAsset
    switch validation() {
    case .unavailable(let error):
      cancelReplacement(restoreOriginal: false)
      transitionAccessToFailure(reason: .source(error), refreshID: refreshID,
        resource: video.identity, expectedRevalidationItem: nil)
      return
    case .validate(let operation):
      validator = operation
    }
    cancelReplacement()

    let snapshot: AccessPlaybackSnapshot
    if let accessPlaybackSnapshot {
      snapshot = accessPlaybackSnapshot
    } else if let currentItem = player.currentItem {
      let interruptedScrubTarget = endInteractionForAccessRefresh()
      let currentTime = pendingTransport?.target ?? interruptedScrubTarget ?? player.currentTime()
      snapshot = AccessPlaybackSnapshot(
        item: currentItem,
        time: currentTime.seconds.isFinite && currentTime.seconds >= 0 ? currentTime : .zero
      )
      cancelPendingTransport()
      removePlayerObservers()
      player.pause()
      isPlayerReady = false
      scrubSeekCoordinator?.reset()
      scrubSeekCoordinator = nil
      cancelPreviewImageLoad()
      cancelAspectRatioLoad()
      player.replaceCurrentItem(with: nil)
      accessPlaybackSnapshot = snapshot
    } else {
      let resumePlayback = wantsPlayback
      retry(
        source: video.replacingLoader(validator),
        playbackRate: playbackConfig.playbackRate,
        isLooping: playbackConfig.isLooping,
        autoplayWhenReady: resumePlayback
      )
      lastAccessRefreshID = refreshID
      return
    }

    cancelSlowStatusOverlay()
    let token = playbackCoordinator.startLoading()
    scheduleSlowStatusOverlay(token: token)
    accessValidationTask?.cancel()
    let resource = video.identity
    accessValidationTask = Task { [weak self] in
      let asset: AVAsset
      do {
        try Task.checkCancellation()
        asset = try await validator()
        try Task.checkCancellation()
      } catch {
        guard !Task.isCancelled, let self else { return }
        transitionAccessToFailure(
          reason: .source(error),
          refreshID: refreshID,
          resource: resource,
          expectedRevalidationItem: snapshot.item
        )
        return
      }

      self?.restoreAccess(
        snapshot,
        refreshID: refreshID,
        source: video,
        asset: asset,
        token: token
      )
    }
  }

  private func transitionAccessToFailure(
    reason: PlaybackFailure,
    refreshID: UInt64,
    resource: AnyHashable,
    expectedRevalidationItem: AVPlayerItem?
  ) {
    guard lastAccessRefreshID == refreshID,
      loadedResource == resource
    else {
      return
    }
    if let expectedRevalidationItem {
      guard player.currentItem == nil,
        accessPlaybackSnapshot?.item === expectedRevalidationItem
      else {
        return
      }
    }

    let currentPlaybackConfig = playbackConfig
    cleanup()
    playbackConfig = currentPlaybackConfig
    loadedResource = resource
    lastAccessRefreshID = refreshID
    let token = playbackCoordinator.startLoading()
    failPlayback(reason: reason, token: token)
  }

  private func restoreAccess(
    _ snapshot: AccessPlaybackSnapshot,
    refreshID: UInt64,
    source video: PlaybackSource,
    asset: AVAsset,
    token: PlaybackState.GenerationToken
  ) {
    guard lastAccessRefreshID == refreshID,
      loadedResource == video.identity,
      playbackCoordinator.isCurrent(token),
      player.currentItem == nil,
      let currentSnapshot = accessPlaybackSnapshot,
      currentSnapshot.item === snapshot.item
    else {
      return
    }

    guard snapshot.item.status != .failed else {
      transitionAccessToFailure(
        reason: .playerItemFailed,
        refreshID: refreshID,
        resource: video.identity,
        expectedRevalidationItem: snapshot.item
      )
      return
    }

    accessValidationTask = nil
    accessPlaybackSnapshot = nil
    if thumbnailImage == nil {
      startPreviewImageLoad(for: video, token: token)
    }
    if videoAspectRatio == nil {
      startAspectRatioLoad(for: asset, token: token)
    }
    player.replaceCurrentItem(with: snapshot.item)
    observePlayerItemStatus(snapshot.item, token: token)
    observePlaybackEnd(for: snapshot.item, token: token)
    observePlayerBuffering(token: token)
    observePlayerTime(token: token)
    beginTransport(to: currentSnapshot.time)
    if snapshot.item.status == .readyToPlay {
      handlePlayerReady(token: token)
    } else {
      playbackCoordinator.transition(to: .loadingPlayerItem, token: token)
    }
  }

  private func beginLoad(
    source video: PlaybackSource,
    playbackRate: Float,
    isLooping: Bool,
    autoplayWhenReady: Bool,
    forceReload: Bool
  ) {
    let resource = video.identity
    playbackConfig.update(playbackRate: playbackRate, isLooping: isLooping)

    if playbackCoordinator.phase.isTerminal,
      loadedResource == resource,
      !forceReload
    {
      return
    }

    guard forceReload || loadedResource != resource else {
      guard failure == nil else { return }
      if autoplayWhenReady {
        wantsPlayback = true
      }
      if autoplayWhenReady, playbackProgress >= 1 {
        if let snapshot = accessPlaybackSnapshot {
          accessPlaybackSnapshot = AccessPlaybackSnapshot(item: snapshot.item, time: .zero)
          updateTransportPresentation(to: .zero)
        } else {
          beginTransport(to: .zero)
        }
      } else {
        reconcilePlayback()
      }
      return
    }

    let retainedPreparationFailure: PlaybackFailure?
    if loadedResource == resource, case .preparation = failure {
      retainedPreparationFailure = failure
    } else {
      retainedPreparationFailure = nil
    }
    cleanup()
    playbackConfig.update(playbackRate: playbackRate, isLooping: isLooping)
    loadedResource = resource
    failure = retainedPreparationFailure
    wantsPlayback = autoplayWhenReady && retainedPreparationFailure == nil
    let token = playbackCoordinator.startLoading()
    scheduleSlowStatusOverlay(token: token)

    let assetLoader = video.load
    currentLoadTask = Task { [weak self] in
      defer {
        if let self, playbackCoordinator.isCurrent(token) {
          currentLoadTask = nil
        }
      }

      let asset: AVAsset
      do {
        try Task.checkCancellation()
        asset = try await assetLoader()
        try Task.checkCancellation()
      } catch {
        guard let self else { return }
        guard !Task.isCancelled else {
          cancelLoading(token: token)
          return
        }
        failPlayback(reason: .source(error), token: token)
        return
      }

      guard let self else { return }
      continueLoading(asset: asset, source: video, token: token)
    }
  }

  private func continueLoading(
    asset: AVAsset,
    source video: PlaybackSource,
    token: PlaybackState.GenerationToken
  ) {
    if Task.isCancelled {
      cancelLoading(token: token)
      return
    }
    guard playbackCoordinator.isCurrent(token) else { return }

    startPreviewImageLoad(for: video, token: token)
    startAspectRatioLoad(for: asset, token: token)
    playbackCoordinator.transition(to: .loadingPlayerItem, token: token)
    let playerItem = AVPlayerItem(asset: asset)
    player.replaceCurrentItem(with: playerItem)
    observePlayerItemStatus(playerItem, token: token)
    observePlaybackEnd(for: playerItem, token: token)
    observePlayerBuffering(token: token)
    observePlayerTime(token: token)
    playbackCoordinator.transition(
      to: playerItem.status == .readyToPlay ? .ready : .loadingPlayerItem,
      token: token
    )
  }

  public func updatePlaybackRate(_ playbackRate: Float) {
    playbackConfig.update(playbackRate: playbackRate, isLooping: playbackConfig.isLooping)
    reconcilePlayback()
  }

  public func updateLooping(_ isLooping: Bool) {
    playbackConfig.update(playbackRate: playbackConfig.playbackRate, isLooping: isLooping)
  }

  public func setScrubProgress(_ progress: Double) {
    guard playbackInteraction == .scrubbing else { return }
    scrubProgress = VideoPlaybackPresentation.normalizedProgress(progress)
    submitScrubSeek(toProgress: progress)
  }

  public func togglePlayback() {
    guard canTogglePlayback else { return }
    if isPlaybackRequested {
      pausePlayback()
      return
    }

    if playbackInteraction == .scrubbing {
      finishScrubbing()
    }

    wantsPlayback = true

    if playbackProgress >= 1 {
      beginTransport(to: .zero)
    } else {
      reconcilePlayback()
    }
  }

  /// Suspends playback without discarding the current media or position.
  public func pausePlayback() {
    wantsPlayback = false
    if playbackInteraction == .holding { playbackInteraction = .idle }
    stopPlaybackDemand()
    if playbackInteraction == .scrubbing { finishScrubbing() }
  }

  /// Explicitly retries host preparation while retaining the current item and time.
  public func retryPlaybackPreparation() {
    guard case .preparation = failure, hasCurrentItem else { return }
    failure = nil
    wantsPlayback = true
    if playbackProgress >= 1 {
      beginTransport(to: .zero)
    } else {
      reconcilePlayback()
    }
  }

  public func handleScrubEditingChanged(_ isEditing: Bool) {
    guard hasCurrentItem,
      failure == nil,
      durationSeconds > 0
    else {
      return
    }

    if isEditing {
      guard playbackInteraction != .scrubbing else { return }
      if playbackInteraction == .holding {
        endHold(reconcile: false)
      }
      cancelPendingTransport()
      scrubSeekCoordinator?.reset()
      scrubSeekCoordinator = nil
      playbackInteraction = .scrubbing
      scrubProgress = playbackProgress
      player.pause()
      return
    }

    guard playbackInteraction == .scrubbing else { return }
    finishScrubbing()
  }

  public func handleHoldGestureStateChanged(_ state: UIGestureRecognizer.State, allowsHoldBoost: Bool) {
    guard allowsHoldBoost else {
      cancelHold()
      return
    }
    switch state {
    case .began:
      guard isPlayerReady,
        failure == nil,
        playbackInteraction != .holding
      else {
        return
      }
      if playbackInteraction == .scrubbing {
        finishScrubbing()
      }
      playbackInteraction = .holding
      onEvent(.holdBegan)
      if playbackProgress >= 1 {
        beginTransport(to: .zero)
      } else {
        reconcilePlayback()
      }
    case .ended, .cancelled, .failed:
      cancelHold()
    default:
      break
    }
  }

  public func cancelHold() {
    endHold(reconcile: true)
  }

  public func cleanup() {
    wantsPlayback = false
    playbackInteraction = .idle
    stopPlaybackDemand()
    cancelReplacement(restoreOriginal: false)
    currentLoadTask?.cancel()
    currentLoadTask = nil
    accessValidationTask?.cancel()
    accessValidationTask = nil
    accessPlaybackSnapshot = nil
    cancelSlowStatusOverlay()
    cancelPreviewImageLoad()
    cancelAspectRatioLoad()
    cancelPendingTransport()
    scrubSeekCoordinator?.reset()
    scrubSeekCoordinator = nil
    playbackCoordinator.reset()
    removePlayerObservers()
    thumbnailImage = nil
    loadedResource = nil
    sourcePresentationID = UUID()
    hasPresentedVideo = false
    failure = nil
    lastAccessRefreshID = nil
    isPlayerReady = false
    currentTimeSeconds = 0
    durationSeconds = 0
    playbackProgress = 0
    scrubProgress = 0
    playbackConfig = VideoPlaybackConfig()
    videoAspectRatio = nil
    player.replaceCurrentItem(with: nil)
    onEvent(.didCleanup)
  }

  private func cancelLoading(token: PlaybackState.GenerationToken) {
    guard playbackCoordinator.isCurrent(token) else { return }
    cleanup()
  }

  private func handlePlayerReady(token: PlaybackState.GenerationToken) {
    guard playbackCoordinator.isCurrent(token),
      !isPlayerReady
    else { return }

    isPlayerReady = true
    if pendingTransport == nil {
      updatePlaybackProgress(from: player.currentTime())
    }
    playbackCoordinator.transition(to: .ready, token: token)
    cancelSlowStatusOverlay()
    updatePlaybackBufferingOverlay(for: player.timeControlStatus, token: token)
    reconcilePlayback()
  }

  private func submitScrubSeek(toProgress progress: Double) {
    guard durationSeconds > 0 else { return }

    let clampedProgress = VideoPlaybackPresentation.normalizedProgress(progress)
    if scrubSeekCoordinator == nil {
      scrubSeekCoordinator = VideoSeekCoordinator(player: player)
    }
    scrubSeekCoordinator?.seek(
      to: durationSeconds * clampedProgress,
      duration: durationSeconds,
      precision: .interactive
    )
  }

  private func finishScrubbing() {
    guard playbackInteraction == .scrubbing,
      durationSeconds > 0
    else {
      return
    }

    let targetProgress = scrubProgress
    playbackProgress = targetProgress
    playbackInteraction = .idle
    beginTransport(
      to: CMTime(
        seconds: durationSeconds * targetProgress,
        preferredTimescale: CMTimeScale(NSEC_PER_SEC)
      )
    )
  }

  private func endHold(reconcile: Bool) {
    guard playbackInteraction == .holding else { return }
    playbackInteraction = .idle
    if !wantsPlayback { stopPlaybackDemand() }
    if reconcile {
      reconcilePlayback()
    }
  }

  private func endInteractionForAccessRefresh() -> CMTime? {
    switch playbackInteraction {
    case .idle:
      return nil
    case .holding:
      endHold(reconcile: false)
      return nil
    case .scrubbing:
      let targetProgress = scrubProgress
      playbackProgress = targetProgress
      playbackInteraction = .idle
      guard durationSeconds > 0 else { return .zero }
      return CMTime(
        seconds: durationSeconds * targetProgress,
        preferredTimescale: CMTimeScale(NSEC_PER_SEC)
      )
    }
  }

  private func beginTransport(to target: CMTime) {
    guard let currentItem = player.currentItem else { return }

    cancelPendingTransport()
    scrubSeekCoordinator?.reset()
    scrubSeekCoordinator = nil

    let seconds = playableSeconds(from: target) ?? 0
    let boundedSeconds = durationSeconds > 0 ? min(seconds, durationSeconds) : seconds
    let boundedTarget = CMTime(
      seconds: boundedSeconds,
      preferredTimescale: CMTimeScale(NSEC_PER_SEC)
    )
    let token = UUID()
    pendingTransport = PendingTransport(token: token, target: boundedTarget)
    player.pause()
    updateTransportPresentation(to: boundedTarget)

    transportSeek(player, boundedTarget) { [weak self] finished in
      guard let self,
        self.player.currentItem === currentItem,
        let transport = self.pendingTransport,
        transport.token == token
      else {
        return
      }

      self.pendingTransport = nil
      guard finished else {
        if self.replacementItem === currentItem {
          let continuation = self.replacementContinuation
          self.replacementContinuation = nil
          self.player.pause()
          continuation?.resume(throwing: PlaybackFailure.playerItemFailed)
          return
        }
        self.playbackInteraction = .idle
        self.wantsPlayback = false
        self.updatePlaybackProgress(from: self.player.currentTime())
        self.stopPlaybackDemand()
        return
      }
      self.updateTransportPresentation(to: transport.target)
      if self.replacementItem === currentItem {
        self.replacementItem = nil
        self.replacementSnapshot = nil
        let continuation = self.replacementContinuation
        self.replacementContinuation = nil
        continuation?.resume()
      }
      self.reconcilePlayback()
    }
  }

  static func seekTransport(
    player: AVPlayer,
    target: CMTime,
    completion: @escaping @MainActor (Bool) -> Void
  ) {
    player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
      Task { @MainActor in completion(finished) }
    }
  }

  private func cancelPendingTransport() {
    guard pendingTransport != nil else { return }
    pendingTransport = nil
    player.currentItem?.cancelPendingSeeks()
    if let replacementItem, player.currentItem === replacementItem {
      // A newer user transport intent adopts this ready representation. Its old
      // restoring callback cannot undo adoption or overwrite the new target.
      self.replacementItem = nil
      replacementSnapshot = nil
      let continuation = replacementContinuation
      replacementContinuation = nil
      continuation?.resume()
    }
  }

  private func updateTransportPresentation(to target: CMTime) {
    guard let seconds = playableSeconds(from: target) else { return }
    currentTimeSeconds = seconds
    guard durationSeconds > 0 else { return }

    let progress = VideoPlaybackPresentation.normalizedProgress(seconds / durationSeconds)
    playbackProgress = progress
  }

  private func reconcilePlayback() {
    guard isPlaybackRequested, failure == nil else {
      stopPlaybackDemand()
      return
    }

    guard hasCurrentItem,
      isPlayerReady,
      pendingTransport == nil,
      playbackInteraction != .scrubbing
    else {
      if pendingTransport != nil || playbackInteraction == .scrubbing {
        player.pause()
      }
      return
    }

    if let request = preparationRequest {
      guard request.isReady else { return }
    } else if let preparation {
      startPlaybackPreparation(preparation)
      return
    }

    let requestID = preparationRequest?.id
    onEvent(.willPlay)
    // An observational callback can synchronously pause or replace the source.
    guard isPlaybackRequested, failure == nil, isPlayerReady, hasCurrentItem,
      pendingTransport == nil, playbackInteraction != .scrubbing,
      preparationRequest?.id == requestID else { return }
    let rate =
      playbackInteraction == .holding
      ? playbackConfig.holdBoostedRate
      : playbackConfig.playbackRate
    player.playImmediately(atRate: rate)
  }

  private func startPlaybackPreparation(_ preparation: PlaybackPreparation) {
    let id = UUID()
    preparationRequest = PreparationRequest(id: id, preparation: preparation)
    preparationTask = Task { [weak self] in
      // Do not bind self across the host await: the session must remain releasable.
      guard !Task.isCancelled, self?.preparationRequest?.id == id,
        self?.isPlaybackRequested == true else { return }
      do {
        try await preparation.prepare(id)
      } catch {
        guard !Task.isCancelled, let self, preparationRequest?.id == id else { return }
        failure = .preparation(error)
        pausePlayback()
        return
      }
      guard !Task.isCancelled, let self, preparationRequest?.id == id,
        isPlaybackRequested else { return }
      preparationTask = nil
      preparationRequest?.isReady = true
      reconcilePlayback()
    }
  }

  private func stopPlaybackDemand() {
    let request = preparationRequest
    preparationRequest = nil
    preparationTask?.cancel()
    preparationTask = nil
    player.pause()
    if let request { request.preparation.release(request.id) }
  }

  private func scheduleSlowStatusOverlay(token: PlaybackState.GenerationToken) {
    cancelSlowStatusOverlay()
    let slowStatusDelay = slowStatusDelay
    slowStatusTask = Task { [weak self] in
      do {
        try await slowStatusDelay(Self.slowLoadingDelayNanoseconds)
      } catch {
        return
      }
      guard !Task.isCancelled,
        let self,
        playbackCoordinator.isCurrent(token)
      else {
        return
      }
      playbackCoordinator.markSlow(token: token)
      slowStatusTask = nil
    }
  }

  private func cancelSlowStatusOverlay() {
    slowStatusTask?.cancel()
    slowStatusTask = nil
  }

  private func startPreviewImageLoad(
    for video: PlaybackSource,
    token: PlaybackState.GenerationToken
  ) {
    cancelPreviewImageLoad()
    let thumbnailLoader = video.thumbnail
    previewImageTask = Task { [weak self] in
      let image = await thumbnailLoader(
        CGSize(
          width: VideoPlayerLayout.targetWidth * 2,
          height: VideoPlayerLayout.targetHeight * 2
        )
      )
      guard !Task.isCancelled,
        let self,
        playbackCoordinator.isCurrent(token)
      else {
        return
      }
      thumbnailImage = image
      previewImageTask = nil
    }
  }

  private func cancelPreviewImageLoad() {
    previewImageTask?.cancel()
    previewImageTask = nil
  }

  private func startAspectRatioLoad(
    for asset: AVAsset,
    token: PlaybackState.GenerationToken
  ) {
    cancelAspectRatioLoad()
    aspectRatioTask = Task { [weak self] in
      var aspectRatio: CGFloat?
      do {
        aspectRatio = try await Self.aspectRatio(for: asset)
        try Task.checkCancellation()
      } catch is CancellationError {
        return
      } catch {
        aspectRatio = nil
      }
      guard let self,
        playbackCoordinator.isCurrent(token)
      else {
        return
      }
      videoAspectRatio = aspectRatio
      aspectRatioTask = nil
    }
  }

  private func cancelAspectRatioLoad() {
    aspectRatioTask?.cancel()
    aspectRatioTask = nil
  }

  private func failPlayback(
    reason: PlaybackFailure,
    token: PlaybackState.GenerationToken
  ) {
    guard playbackCoordinator.isCurrent(token) else { return }
    cancelSlowStatusOverlay()
    failure = reason
    playbackCoordinator.fail(token: token)
    pausePlayback()
  }

  private func observePlaybackEnd(
    for playerItem: AVPlayerItem,
    token: PlaybackState.GenerationToken
  ) {
    removePlaybackEndObserver()
    playbackEndObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: playerItem,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.handlePlaybackEnded(for: playerItem, token: token)
      }
    }
  }

  private func handlePlaybackEnded(
    for playerItem: AVPlayerItem,
    token: PlaybackState.GenerationToken
  ) {
    guard player.currentItem === playerItem,
      playbackCoordinator.isCurrent(token),
      pendingTransport == nil,
      playbackInteraction != .scrubbing,
      playableSeconds(from: playerItem.duration) != nil,
      CMTimeCompare(player.currentTime(), playerItem.duration) >= 0
    else {
      return
    }

    if playbackConfig.isLooping {
      beginTransport(to: .zero)
    } else {
      playbackProgress = 1
      currentTimeSeconds = durationSeconds
      pausePlayback()
    }
  }

  private func observePlayerItemStatus(
    _ playerItem: AVPlayerItem,
    token: PlaybackState.GenerationToken
  ) {
    playerItemStatusObservation?.invalidate()
    playerItemStatusObservation = playerItem.observe(\.status, options: [.initial, .new]) {
      [weak self] item, _ in
      Task { @MainActor in
        guard let self,
          self.playbackCoordinator.isCurrent(token),
          self.player.currentItem === item
        else {
          return
        }
        switch item.status {
        case .readyToPlay:
          self.handlePlayerReady(token: token)
        case .failed:
          self.failPlayback(reason: .playerItemFailed, token: token)
        case .unknown:
          self.playbackCoordinator.transition(to: .loadingPlayerItem, token: token)
        @unknown default:
          self.failPlayback(reason: .playerItemFailed, token: token)
        }
      }
    }
  }

  private func observePlayerBuffering(token: PlaybackState.GenerationToken) {
    timeControlObservation?.invalidate()
    timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) {
      [weak self] player, _ in
      Task { @MainActor in
        guard let self,
          self.playbackCoordinator.isCurrent(token)
        else {
          return
        }
        if player.timeControlStatus == .playing {
          self.onEvent(.willPlay)
        }
        self.updatePlaybackBufferingOverlay(for: player.timeControlStatus, token: token)
      }
    }
  }

  private func updatePlaybackBufferingOverlay(
    for status: AVPlayer.TimeControlStatus,
    token: PlaybackState.GenerationToken
  ) {
    guard playbackCoordinator.isCurrent(token),
      isPlayerReady
    else {
      return
    }

    if status == .waitingToPlayAtSpecifiedRate {
      playbackCoordinator.transition(to: .buffering, token: token)
      scheduleSlowStatusOverlay(token: token)
      return
    }

    cancelSlowStatusOverlay()
    playbackCoordinator.transition(to: .ready, token: token)
  }

  private func observePlayerTime(token: PlaybackState.GenerationToken) {
    removePeriodicTimeObserver()
    let interval = CMTime(seconds: 0.25, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
    periodicTimeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) {
      [weak self] time in
      MainActor.assumeIsolated {
        guard let self,
          self.playbackCoordinator.isCurrent(token)
        else {
          return
        }
        self.updatePlaybackProgress(from: time)
      }
    }
  }

  private func updatePlaybackProgress(from time: CMTime) {
    guard pendingTransport == nil else { return }

    if let duration = playableSeconds(from: player.currentItem?.duration) {
      durationSeconds = duration
    }

    guard let seconds = playableSeconds(from: time) else { return }

    currentTimeSeconds = seconds
    guard durationSeconds > 0 else {
      playbackProgress = 0
      return
    }

    let progress = VideoPlaybackPresentation.normalizedProgress(seconds / durationSeconds)
    playbackProgress = progress
  }

  private func playableSeconds(from time: CMTime?) -> Double? {
    guard let time else { return nil }
    let seconds = time.seconds
    guard seconds.isFinite,
      seconds >= 0
    else {
      return nil
    }
    return seconds
  }

  private func removePlaybackEndObserver() {
    guard let playbackEndObserver else { return }
    NotificationCenter.default.removeObserver(playbackEndObserver)
    self.playbackEndObserver = nil
  }

  private func removePlayerObservers() {
    removePlaybackEndObserver()
    playerItemStatusObservation?.invalidate()
    playerItemStatusObservation = nil
    timeControlObservation?.invalidate()
    timeControlObservation = nil
    removePeriodicTimeObserver()
  }

  private func removePeriodicTimeObserver() {
    guard let periodicTimeObserver else { return }
    player.removeTimeObserver(periodicTimeObserver)
    self.periodicTimeObserver = nil
  }

  private static func aspectRatio(for asset: AVAsset) async throws -> CGFloat? {
    try Task.checkCancellation()
    guard let track = try await asset.loadTracks(withMediaType: .video).first else {
      return nil
    }

    let size = try await track.load(.naturalSize)
    let transform = try await track.load(.preferredTransform)
    try Task.checkCancellation()
    let transformedSize = size.applying(transform)
    let width = abs(transformedSize.width)
    let height = abs(transformedSize.height)
    guard width > 0, height > 0 else { return nil }
    return width / height
  }

  private static func formatPlaybackTime(_ seconds: Double) -> String {
    guard seconds.isFinite,
      seconds > 0
    else {
      return "0:00"
    }

    let roundedSeconds = Int(seconds.rounded())
    let minutes = roundedSeconds / 60
    let remainingSeconds = roundedSeconds % 60
    return String(format: "%d:%02d", minutes, remainingSeconds)
  }
}
