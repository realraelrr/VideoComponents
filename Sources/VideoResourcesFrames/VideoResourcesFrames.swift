import AVFoundation
import VideoFramePicker
import VideoPlayback
import VideoProcessing
import VideoResources

/// Stateless, finite consumption of actual resource receipts by native frame APIs.
@MainActor
public enum VideoResourcesFrames {
  /// Construction does not acquire. The mounted native picker owns its loader task.
  public static func pickerSource<ID: Hashable>(
    source: VideoSource, identity: ID, request: VideoRequest = .init()
  ) -> VideoFramePickerSource {
    VideoFramePickerSource(identity: identity, load: {
      let receipt = try await source.acquire(request)
      try validate(receipt)
      return PlaybackLoadedMedia(asset: receipt.asset, audioMix: receipt.audioMix, validate: {
        guard receipt.isCurrent else { throw VideoResourceFailure.sourceChanged }
      })
    })
  }

  /// The host retains the returned actual receipt through its final output boundary.
  public static func frame(
    source: VideoSource, request: VideoRequest = .init(), at seconds: Double,
    maximumSize: CGSize, exact: Bool = false
  ) async throws -> (frame: ExtractedVideoFrame, receipt: VideoReceipt) {
    let receipt = try await source.acquire(request)
    try validate(receipt)
    let frame = try await VideoFrameExtractor.frame(
      for: receipt.asset, at: seconds, maximumSize: maximumSize, exact: exact)
    try validate(receipt)
    return (frame, receipt)
  }

  /// Success transfers only this operation's unique output file to the host.
  public static func export(
    source: VideoSource, rate: Double,
    outputDirectory: URL = FileManager.default.temporaryDirectory,
    onProgress: @escaping @MainActor (Double) -> Void
  ) async throws -> (url: URL, receipt: VideoReceipt) {
    let receipt = try await source.acquire(.init(quality: .highest, network: .allowed))
    try validate(receipt)
    let url = try await SlowVideoExporter.exportSlowedVideo(
      asset: receipt.asset, rate: rate, outputDirectory: outputDirectory, onProgress: { progress in
        // Native completion is followed by this adapter's actual-receipt gate.
        if progress < 1, !Task.isCancelled, receipt.isCurrent { onProgress(progress) }
      })
    var transferred = false
    defer { if !transferred { try? FileManager.default.removeItem(at: url) } }
    try validate(receipt)
    onProgress(1)
    // Host progress publication can synchronously close or supersede this operation.
    try validate(receipt)
    transferred = true
    return (url, receipt)
  }
  private static func validate(_ receipt: VideoReceipt) throws {
    try Task.checkCancellation()
    let isCurrent = receipt.isCurrent
    try Task.checkCancellation()
    guard isCurrent else { throw VideoResourceFailure.sourceChanged }
  }
}
