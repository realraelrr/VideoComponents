import AVFoundation
import Foundation

/// Neutral failure categories. Causes are diagnostic and should not be displayed.
public enum SlowVideoExportError: Error {
  case invalidRate
  case invalidDuration
  case noVideoTrack
  case assetUnavailable(cause: any Error)
  case outputUnavailable(cause: (any Error)?)
  case exportUnavailable
  case exportFailed(cause: (any Error)?)
}

@MainActor
public enum SlowVideoExporter {
  /// Exports an MP4 at a finite rate in 0.25...1.0, preserving track orientation
  /// and audio timing. The existing local output directory receives a unique file.
  ///
  /// Only success transfers file ownership to the caller, which must save or
  /// delete it. Cancellation and failure remove only this operation's output.
  /// Progress 1 is emitted only after successful native completion.
  public static func exportSlowedVideo(
    asset: AVAsset,
    rate: Double,
    outputDirectory: URL = FileManager.default.temporaryDirectory,
    onProgress: @escaping @MainActor (Double) -> Void
  ) async throws -> URL {
    try Task.checkCancellation()
    guard rate.isFinite, (0.25...1).contains(rate) else {
      throw SlowVideoExportError.invalidRate
    }
    let composition: AVMutableComposition
    do {
      composition = try await slowedComposition(from: asset, rate: rate)
    } catch {
      try Task.checkCancellation()
      if let failure = error as? SlowVideoExportError { throw failure }
      throw SlowVideoExportError.assetUnavailable(cause: error)
    }
    try Task.checkCancellation()
    let outputURL = try outputURL(in: outputDirectory)
    guard let exportSession = AVAssetExportSession(
      asset: composition,
      presetName: AVAssetExportPresetHighestQuality
    ) else {
      throw SlowVideoExportError.exportUnavailable
    }
    exportSession.outputURL = outputURL
    exportSession.outputFileType = .mp4
    exportSession.shouldOptimizeForNetworkUse = true
    exportSession.audioTimePitchAlgorithm = .spectral
    return try await SlowVideoExportRunner(session: exportSession, outputURL: outputURL)
      .export(onProgress: onProgress)
  }

  private static func slowedComposition(
    from asset: AVAsset,
    rate: Double
  ) async throws -> AVMutableComposition {
    let duration = try await asset.load(.duration)
    guard duration.seconds.isFinite,
          duration.seconds > 0 else {
      throw SlowVideoExportError.invalidDuration
    }

    let composition = AVMutableComposition()
    let sourceTimeRange = CMTimeRange(start: .zero, duration: duration)
    let scaledDuration = CMTimeMultiplyByFloat64(duration, multiplier: 1.0 / rate)
    var insertedTrack = false

    let videoTracks = try await asset.loadTracks(withMediaType: .video)
    for sourceTrack in videoTracks {
      guard try await sourceTrack.load(.isEnabled) else { continue }
      guard let compositionTrack = composition.addMutableTrack(
        withMediaType: .video,
        preferredTrackID: kCMPersistentTrackID_Invalid
      ) else {
        continue
      }
      try compositionTrack.insertTimeRange(
        sourceTimeRange,
        of: sourceTrack,
        at: .zero
      )
      compositionTrack.scaleTimeRange(
        sourceTimeRange,
        toDuration: scaledDuration
      )
      compositionTrack.preferredTransform = try await sourceTrack.load(.preferredTransform)
      insertedTrack = true
    }

    let audioTracks = try await asset.loadTracks(withMediaType: .audio)
    for sourceTrack in audioTracks {
      guard try await sourceTrack.load(.isEnabled) else { continue }
      guard let compositionTrack = composition.addMutableTrack(
        withMediaType: .audio,
        preferredTrackID: kCMPersistentTrackID_Invalid
      ) else {
        continue
      }
      try compositionTrack.insertTimeRange(
        sourceTimeRange,
        of: sourceTrack,
        at: .zero
      )
      compositionTrack.scaleTimeRange(
        sourceTimeRange,
        toDuration: scaledDuration
      )
    }

    guard insertedTrack else {
      throw SlowVideoExportError.noVideoTrack
    }

    return composition
  }

  private static func outputURL(in directory: URL) throws -> URL {
    guard directory.isFileURL else { throw SlowVideoExportError.outputUnavailable(cause: nil) }
    do {
      let values = try directory.resourceValues(forKeys: [.isDirectoryKey])
      guard values.isDirectory == true else {
        throw SlowVideoExportError.outputUnavailable(cause: nil)
      }
      let url = directory.appendingPathComponent("video-export-\(UUID().uuidString).mp4")
      guard !FileManager.default.fileExists(atPath: url.path) else {
        throw SlowVideoExportError.outputUnavailable(cause: nil)
      }
      return url
    } catch {
      if let failure = error as? SlowVideoExportError { throw failure }
      throw SlowVideoExportError.outputUnavailable(cause: error)
    }
  }
}

@MainActor
protocol VideoExportSession: AnyObject {
  var progress: Float { get }
  var status: AVAssetExportSession.Status { get }
  var error: (any Error)? { get }
  func start(completion: @escaping @Sendable () -> Void)
  func cancel()
}

extension AVAssetExportSession: VideoExportSession {
  func start(completion: @escaping @Sendable () -> Void) {
    exportAsynchronously(completionHandler: completion)
  }

  func cancel() {
    cancelExport()
  }
}

@MainActor
final class SlowVideoExportRunner {
  private let exportSession: any VideoExportSession
  private let outputURL: URL

  init(session: any VideoExportSession, outputURL: URL) {
    self.exportSession = session
    self.outputURL = outputURL
  }

  func export(onProgress: @escaping @MainActor (Double) -> Void) async throws -> URL {
    var succeeded = false
    defer {
      if !succeeded { try? FileManager.default.removeItem(at: outputURL) }
    }
    try Task.checkCancellation()
    onProgress(0)

    let progressTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        let progress = Double(self.exportSession.progress)
        // A native progress value is not a successful terminal result.
        if progress.isFinite, (0..<1).contains(progress) { onProgress(progress) }
        try? await Task.sleep(nanoseconds: 120_000_000)
      }
    }
    defer { progressTask.cancel() }

    try Task.checkCancellation()
    do {
      try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
          exportSession.start { [weak self] in
            Task { @MainActor [weak self] in
              guard let self else {
                continuation.resume(throwing: SlowVideoExportError.exportFailed(cause: nil))
                return
              }
              self.resume(continuation)
            }
          }
        }
      } onCancel: { [weak self] in
        progressTask.cancel()
        Task { @MainActor [weak self] in
          self?.exportSession.cancel()
        }
      }
    } catch {
      try Task.checkCancellation()
      throw error
    }

    try Task.checkCancellation()
    succeeded = true
    onProgress(1)
    return outputURL
  }

  private func resume(_ continuation: CheckedContinuation<Void, Error>) {
    switch exportSession.status {
    case .completed:
      continuation.resume()
    case .failed:
      continuation.resume(throwing: SlowVideoExportError.exportFailed(cause: exportSession.error))
    case .cancelled:
      continuation.resume(throwing: SlowVideoExportError.exportFailed(cause: CancellationError()))
    default:
      continuation.resume(throwing: SlowVideoExportError.exportFailed(cause: nil))
    }
  }
}
