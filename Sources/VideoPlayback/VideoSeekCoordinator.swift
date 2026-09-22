import AVFoundation

public enum VideoSeekPrecision: Equatable, Sendable {
  case interactive
  case exact

  var tolerance: CMTime {
    switch self {
    case .interactive:
      CMTime(seconds: 0.05, preferredTimescale: 600)
    case .exact:
      .zero
    }
  }
}

struct VideoSeekRequest: Equatable, Sendable {
  let time: CMTime
  let precision: VideoSeekPrecision
}

struct VideoSeekScheduler {
  private(set) var inFlight: VideoSeekRequest?
  private(set) var pending: VideoSeekRequest?

  mutating func submit(_ request: VideoSeekRequest) -> VideoSeekRequest? {
    guard inFlight == nil else {
      pending = request
      return nil
    }
    inFlight = request
    return request
  }

  mutating func complete(_ request: VideoSeekRequest) -> VideoSeekRequest? {
    guard inFlight == request else { return nil }
    inFlight = nil
    guard let next = pending else { return nil }
    pending = nil
    guard next != request else { return nil }
    inFlight = next
    return next
  }

  mutating func reset() {
    inFlight = nil
    pending = nil
  }
}

/// Borrows the player; while active this must be the item's only seek initiator.
/// The host may render/pause the player and must reset before replacing its item.
@MainActor
public final class VideoSeekCoordinator {
  private let player: AVPlayer

  private var scheduler = VideoSeekScheduler()
  private var generation = 0

  public init(player: AVPlayer) {
    self.player = player
  }

  @discardableResult
  public func seek(
    to seconds: Double,
    duration: Double,
    precision: VideoSeekPrecision
  ) -> Bool {
    guard seconds.isFinite, duration.isFinite, duration >= 0 else { return false }
    let boundedSeconds = min(max(seconds, 0), duration)
    let request = VideoSeekRequest(
      time: CMTime(
        seconds: boundedSeconds,
        preferredTimescale: CMTimeScale(NSEC_PER_SEC)
      ),
      precision: precision
    )
    guard let requestToStart = scheduler.submit(request) else { return true }
    perform(requestToStart)
    return true
  }

  /// Cancels every pending seek on the borrowed item. Reset before external seeks or item replacement.
  public func reset() {
    generation += 1
    scheduler.reset()
    player.currentItem?.cancelPendingSeeks()
  }

  private func perform(_ request: VideoSeekRequest) {
    let playerItem = player.currentItem
    let generation = generation
    player.seek(
      to: request.time,
      toleranceBefore: request.precision.tolerance,
      toleranceAfter: request.precision.tolerance
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self,
              self.generation == generation,
              self.player.currentItem === playerItem,
              self.scheduler.inFlight == request else {
          return
        }
        if let next = self.scheduler.complete(request) {
          self.perform(next)
        }
      }
    }
  }
}
