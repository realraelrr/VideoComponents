import Foundation

public enum PlaybackStatus: Equatable {
    case none
    case loading
    case loadingPlayerItem
    case buffering
    case slowPreparing
    case slowBuffering
    case unavailable

    public var allowsHitTesting: Bool {
      if case .unavailable = self { return true }
      return false
    }
  }


struct PlaybackState: Equatable {
  struct GenerationToken: Equatable, Sendable {
    fileprivate let value: Int
  }

  enum Phase: Equatable {
    case idle
    case resolvingFile
    case loadingPlayerItem
    case buffering
    case slowPreparing
    case slowBuffering
    case ready
    case unavailable

    var isTerminal: Bool {
      if case .unavailable = self { return true }
      return false
    }
  }

  private(set) var phase: Phase = .idle
  private var generation = 0

  init() {}

  var overlay: PlaybackStatus {
    switch phase {
    case .idle, .ready:
      return .none
    case .resolvingFile:
      return .loading
    case .loadingPlayerItem:
      return .loadingPlayerItem
    case .buffering:
      return .buffering
    case .slowPreparing:
      return .slowPreparing
    case .slowBuffering:
      return .slowBuffering
    case .unavailable:
      return .unavailable
    }
  }

  mutating func startLoading() -> GenerationToken {
    generation += 1
    phase = .resolvingFile
    return GenerationToken(value: generation)
  }

  mutating func reset() {
    generation += 1
    phase = .idle
  }

  func isCurrent(_ token: GenerationToken) -> Bool {
    token.value == generation
  }

  mutating func transition(to phase: Phase, token: GenerationToken) {
    guard isCurrent(token),
          !self.phase.isTerminal else {
      return
    }
    if shouldPreserveSlowPhase(whenTransitioningTo: phase) {
      return
    }
    self.phase = phase
  }

  mutating func fail(token: GenerationToken) {
    guard isCurrent(token),
          !phase.isTerminal else {
      return
    }
    phase = .unavailable
  }

  mutating func markSlow(token: GenerationToken) {
    guard isCurrent(token),
          !phase.isTerminal else {
      return
    }

    switch phase {
    case .resolvingFile, .loadingPlayerItem:
      phase = .slowPreparing
    case .buffering:
      phase = .slowBuffering
    case .idle, .slowPreparing, .slowBuffering, .ready, .unavailable:
      break
    }
  }

  private func shouldPreserveSlowPhase(whenTransitioningTo nextPhase: Phase) -> Bool {
    switch (phase, nextPhase) {
    case (.slowPreparing, .resolvingFile),
         (.slowPreparing, .loadingPlayerItem),
         (.slowPreparing, .buffering),
         (.slowBuffering, .buffering):
      return true
    default:
      return false
    }
  }
}
