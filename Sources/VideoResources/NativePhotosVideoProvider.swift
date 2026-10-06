import AVFoundation
import Foundation
import Photos

extension PhotosVideoProvider {
  /// Resolves only videos visible under the existing Photos authorization.
  /// The host refreshes this provider when its Photos access facts change.
  public static func native() -> Self {
    let source = NativePhotosSource()
    return Self(
      authority: { try source.authority(for: $0) },
      load: { try await source.load($0, request: $1, progress: $2) },
      refresh: { source.refresh() }
    )
  }
}

@MainActor
private final class NativePhotosSource {
  private var localIdentifiers: [String: String] = [:]

  func authority(for serializedCloudIdentifier: String) throws -> String {
    let asset = try visibleAsset(for: serializedCloudIdentifier)
    // This is an equality fact about the current Photos representation, not
    // a distributed ordering clock or an account/library ownership decision.
    let modified = asset.modificationDate.map {
      String($0.timeIntervalSinceReferenceDate.bitPattern)
    } ?? "none"
    return [
      asset.localIdentifier, modified, String(asset.duration.bitPattern),
      String(asset.pixelWidth), String(asset.pixelHeight),
      String(asset.mediaSubtypes.rawValue)
    ].joined(separator: "|")
  }

  func load(
    _ serializedCloudIdentifier: String,
    request: VideoRequest,
    progress: @escaping PhotosVideoProvider.Progress
  ) async throws -> VideoRepresentation {
    try Task.checkCancellation()
    let asset = try visibleAsset(for: serializedCloudIdentifier)
    let options = PHVideoRequestOptions()
    options.version = .current
    options.deliveryMode = request.quality == .highest ? .highQualityFormat : .automatic
    options.isNetworkAccessAllowed = request.network == .allowed
    options.progressHandler = { value, _, _, _ in
      guard value.isFinite else { return }
      progress(min(1, max(0, value)))
    }
    return try await NativePhotosVideoRequest().load(asset: asset, options: options)
  }

  func refresh() {
    localIdentifiers.removeAll()
  }

  private func visibleAsset(for serializedCloudIdentifier: String) throws -> PHAsset {
    #if DEBUG
    let traceID = UUID()
    traceVideoPreparation("photos.resolve.begin", id: traceID)
    defer { traceVideoPreparation("photos.resolve.end", id: traceID) }
    #endif
    let authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    guard authorization == .authorized || authorization == .limited else {
      throw VideoResourceFailure.photosAccessRequired
    }
    guard !serializedCloudIdentifier.isEmpty else {
      throw VideoResourceFailure.sourceUnavailable
    }
    let localIdentifier: String
    if let cached = localIdentifiers[serializedCloudIdentifier] {
      localIdentifier = cached
    } else {
      #if DEBUG
      traceVideoPreparation("photos.mapping.begin", id: traceID)
      defer { traceVideoPreparation("photos.mapping.end", id: traceID) }
      #endif
      let cloudIdentifier = PHCloudIdentifier(stringValue: serializedCloudIdentifier)
      guard let mapping = PHPhotoLibrary.shared()
        .localIdentifierMappings(for: [cloudIdentifier])[cloudIdentifier]
      else { throw VideoResourceFailure.sourceUnavailable }
      do {
        localIdentifier = try mapping.get()
      } catch {
        throw nativePhotosFailure(error)
      }
      guard !localIdentifier.isEmpty else { throw VideoResourceFailure.sourceUnavailable }
      localIdentifiers[serializedCloudIdentifier] = localIdentifier
    }
    guard let asset = PHAsset.fetchAssets(
      withLocalIdentifiers: [localIdentifier], options: nil
    ).firstObject, asset.mediaType == .video else {
      localIdentifiers[serializedCloudIdentifier] = nil
      throw VideoResourceFailure.sourceUnavailable
    }
    return asset
  }
}

private func nativePhotosFailure(_ error: Error) -> Error {
  let error = error as NSError
  guard error.domain == PHPhotosErrorDomain else {
    return VideoResourceFailure.acquisitionFailed
  }
  switch PHPhotosError.Code(rawValue: error.code) {
  case .userCancelled, .operationInterrupted:
    return CancellationError()
  case .accessRestricted, .accessUserDenied:
    return VideoResourceFailure.photosAccessRequired
  case .identifierNotFound, .multipleIdentifiersFound:
    return VideoResourceFailure.sourceUnavailable
  case .networkAccessRequired:
    return VideoResourceFailure.networkRequired
  case .networkError:
    return VideoResourceFailure.networkFailed
  default:
    return VideoResourceFailure.acquisitionFailed
  }
}

/// The lock protects only one native request's continuation and cancellation.
/// Neither a caller's task lifetime nor a late Photos callback can retain work.
final class NativePhotosVideoRequest: @unchecked Sendable {
  typealias ResultHandler = (AVAsset?, AVAudioMix?, [AnyHashable: Any]?) -> Void
  typealias Request = (PHAsset, PHVideoRequestOptions, @escaping ResultHandler) -> PHImageRequestID

  private enum State {
    case pending
    case finished(cancelNative: Bool)
  }

  #if DEBUG
  private let preparationTraceID = UUID()
  #endif
  private let lock = NSLock()
  private let request: Request
  private let cancelRequest: (PHImageRequestID) -> Void
  private var state: State = .pending
  private var continuation: CheckedContinuation<VideoRepresentation, Error>?
  private var requestID: PHImageRequestID?

  init(
    request: @escaping Request = { asset, options, completion in
      PHImageManager.default().requestAVAsset(
        forVideo: asset, options: options, resultHandler: completion
      )
    },
    cancelRequest: @escaping (PHImageRequestID) -> Void = PHImageManager.default()
      .cancelImageRequest
  ) {
    self.request = request
    self.cancelRequest = cancelRequest
  }

  nonisolated(nonsending) func load(
    asset: PHAsset, options: PHVideoRequestOptions
  ) async throws -> VideoRepresentation {
    let representation: VideoRepresentation = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        lock.lock()
        guard case .pending = state else {
          lock.unlock()
          continuation.resume(throwing: CancellationError())
          return
        }
        self.continuation = continuation
        lock.unlock()

        #if DEBUG
        traceVideoPreparation("photos.request.submit", id: preparationTraceID)
        #endif
        let requestID = request(asset, options) { [weak self] asset, audioMix, info in
          self?.complete(asset: asset, audioMix: audioMix, info: info)
        }

        #if DEBUG
        traceVideoPreparation("photos.request.registered", id: preparationTraceID)
        #endif
        lock.lock()
        switch state {
        case .pending:
          self.requestID = requestID
          lock.unlock()
        case .finished(let cancelNative):
          lock.unlock()
          if cancelNative { cancelRequest(requestID) }
        }
      }
    } onCancel: {
      finish(.failure(CancellationError()))
    }
    try Task.checkCancellation()
    return representation
  }

  private func complete(asset: AVAsset?, audioMix: AVAudioMix?, info: [AnyHashable: Any]?) {
    #if DEBUG
    traceVideoPreparation("photos.request.callback", id: preparationTraceID)
    #endif
    if (info?[PHImageCancelledKey] as? NSNumber)?.boolValue == true {
      finish(.failure(CancellationError()))
    } else if let error = info?[PHImageErrorKey] as? Error {
      finish(.failure(nativePhotosFailure(error)))
    } else if let asset {
      finish(.success(VideoRepresentation(asset: asset, audioMix: audioMix)))
    } else if (info?[PHImageResultIsInCloudKey] as? NSNumber)?.boolValue == true {
      finish(.failure(VideoResourceFailure.networkRequired))
    } else {
      finish(.failure(VideoResourceFailure.sourceUnavailable))
    }
  }

  private func finish(_ result: Result<VideoRepresentation, Error>) {
    lock.lock()
    guard case .pending = state else {
      lock.unlock()
      return
    }
    let cancelNative: Bool
    switch result {
    case .success: cancelNative = false
    case .failure: cancelNative = true
    }
    state = .finished(cancelNative: cancelNative)
    let continuation = self.continuation
    let requestID = self.requestID
    self.continuation = nil
    self.requestID = nil
    lock.unlock()
    if cancelNative, let requestID { cancelRequest(requestID) }
    continuation?.resume(with: result)
  }
}
