import AVFoundation
import Foundation
import SwiftUI
import UIKit

@MainActor public final class PlaybackSession: ObservableObject {
  typealias TransportSeek = @MainActor (AVPlayer, CMTime, @escaping @MainActor (Bool) -> Void) -> Void
  typealias SlowStatusDelay = @MainActor (UInt64) async throws -> Void

  private enum PlaybackInteraction {
    case idle
    case holding
    case scrubbing
  }

  private struct PendingTransport {
    let token: UUID
    let target: CMTime
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
  private var loadedResource: AnyHashable?
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
  private var accessPlaybackSnapshot: AccessPlaybackSnapshot?
  private var scrubSeekCoordinator: VideoSeekCoordinator?
  public var onEvent: @MainActor (PlaybackEvent) -> Void
  @Published public private(set) var failure: PlaybackFailure?

  public convenience init(onEvent: @escaping @MainActor (PlaybackEvent) -> Void = { _ in }) {
    self.init(transportSeek: Self.seekTransport, slowStatusDelay: { try await Task.sleep(nanoseconds: $0) }, onEvent: onEvent)
  }

  init(
    transportSeek: @escaping TransportSeek,
    slowStatusDelay: @escaping SlowStatusDelay = { try await Task.sleep(nanoseconds: $0) },
    onEvent: @escaping @MainActor (PlaybackEvent) -> Void = { _ in }
  ) {
    self.transportSeek = transportSeek
    self.slowStatusDelay = slowStatusDelay
    self.onEvent = onEvent
  }

  isolated deinit {
    cleanup()
  }

  public var hasCurrentItem: Bool {
    player.currentItem != nil
  }

  var hasActivePlayerObservers: Bool {
    playbackEndObserver != nil || playerItemStatusObservation != nil
      || timeControlObservation != nil || periodicTimeObserver != nil
  }

  public var status: PlaybackStatus {
    playbackCoordinator.overlay
  }

  public var canUsePlaybackControls: Bool {
    hasCurrentItem && isPlayerReady && !status.allowsHitTesting
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
      transitionAccessToFailure(reason: .source(error), refreshID: refreshID,
        resource: video.identity, expectedRevalidationItem: nil)
      return
    case .validate(let operation):
      validator = operation
    }

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
      accessPlaybackSnapshot?.item === snapshot.item
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
    beginTransport(to: snapshot.time)
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

    guard
      forceReload || !hasCurrentItem || loadedResource != resource
    else {
      startPlaybackIfReady(autoplayWhenReady: autoplayWhenReady)
      return
    }

    cleanup()
    playbackConfig.update(playbackRate: playbackRate, isLooping: isLooping)
    loadedResource = resource
    wantsPlayback = autoplayWhenReady
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
    guard hasCurrentItem else { return }
    let shouldPause = isPlaybackRequested

    if playbackInteraction == .holding {
      endHold(reconcile: false)
    } else if playbackInteraction == .scrubbing {
      finishScrubbing()
    }

    wantsPlayback = !shouldPause

    if wantsPlayback,
      playbackProgress >= 1
    {
      beginTransport(to: .zero)
    } else {
      reconcilePlayback()
    }
  }

  public func handleScrubEditingChanged(_ isEditing: Bool) {
    guard hasCurrentItem,
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
        playbackInteraction != .holding
      else {
        return
      }
      if playbackInteraction == .scrubbing {
        finishScrubbing()
      }
      playbackInteraction = .holding
      onEvent(.holdBegan)
      onEvent(.willPlay)
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
    currentLoadTask?.cancel()
    currentLoadTask = nil
    accessValidationTask?.cancel()
    accessValidationTask = nil
    accessPlaybackSnapshot = nil
    playbackInteraction = .idle
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
    failure = nil
    lastAccessRefreshID = nil
    wantsPlayback = false
    isPlayerReady = false
    currentTimeSeconds = 0
    durationSeconds = 0
    playbackProgress = 0
    scrubProgress = 0
    playbackConfig = VideoPlaybackConfig()
    videoAspectRatio = nil
    player.pause()
    player.replaceCurrentItem(with: nil)
    onEvent(.didCleanup)
  }

  private func cancelLoading(token: PlaybackState.GenerationToken) {
    guard playbackCoordinator.isCurrent(token) else { return }
    cleanup()
  }

  private func startPlaybackIfReady(autoplayWhenReady: Bool) {
    guard autoplayWhenReady,
      hasCurrentItem
    else {
      return
    }

    wantsPlayback = true
    guard isPlayerReady || player.currentItem?.status == .readyToPlay else { return }
    if playbackProgress >= 1 {
      beginTransport(to: .zero)
    } else {
      reconcilePlayback()
    }
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
        self.playbackInteraction = .idle
        self.wantsPlayback = false
        self.updatePlaybackProgress(from: self.player.currentTime())
        self.player.pause()
        return
      }
      self.updateTransportPresentation(to: transport.target)
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
  }

  private func updateTransportPresentation(to target: CMTime) {
    guard let seconds = playableSeconds(from: target) else { return }
    currentTimeSeconds = seconds
    guard durationSeconds > 0 else { return }

    let progress = VideoPlaybackPresentation.normalizedProgress(seconds / durationSeconds)
    playbackProgress = progress
  }

  private func reconcilePlayback() {
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

    guard isPlaybackRequested else {
      player.pause()
      return
    }

    onEvent(.willPlay)
    let rate =
      playbackInteraction == .holding
      ? playbackConfig.holdBoostedRate
      : playbackConfig.playbackRate
    player.playImmediately(atRate: rate)
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
      wantsPlayback = false
      player.pause()
      playbackProgress = 1
      currentTimeSeconds = durationSeconds
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
          self.playbackCoordinator.isCurrent(token)
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
