import AVFoundation
import CoreGraphics
import SwiftUI
import VideoPlayback

/// A stable media and selection-target identity with a borrowed media loader.
///
/// Change identity when the media or the destination for a selection changes.
/// Updating the loader alone does not reload an already mounted session. The
/// picker never calls `cancelLoading()` on the asset supplied by the host.
@MainActor
public struct VideoFramePickerSource {
  let identity: AnyHashable
  let load: @MainActor () async throws -> PlaybackLoadedMedia

  public init<ID: Hashable>(
    identity: ID,
    load: @escaping @MainActor () async throws -> PlaybackLoadedMedia
  ) {
    self.identity = AnyHashable(identity)
    self.load = load
  }
}

/// The requested position and AVFoundation's actual decoded position can differ.
public struct VideoFrameSelection: Sendable {
  public let image: CGImage
  public let requestedSeconds: Double
  public let actualTime: CMTime
  private let validation: @MainActor @Sendable () throws -> Void

  public init(
    image: CGImage, requestedSeconds: Double, actualTime: CMTime,
    validate: @escaping @MainActor @Sendable () throws -> Void = {}
  ) {
    self.image = image
    self.requestedSeconds = requestedSeconds
    self.actualTime = actualTime
    validation = validate
  }

  /// Check immediately before committing output derived from this selection.
  @MainActor
  public func validate() throws {
    try validation()
  }
}

/// Source preparation is independent of exact frame extraction and host consumption.
public enum VideoFramePickerSourceStatus {
  case loading
  case ready
  case failed(VideoFramePickerFailure)
}

/// Neutral categories for diagnostics. The picker never displays an underlying cause.
public enum VideoFramePickerFailure: Error {
  public enum ConfigurationReason: Equatable, Sendable {
    case invalidInitialTime
    case invalidMaximumFrameSize
  }

  public enum SourceReason: Equatable, Sendable {
    case unavailable
    case invalidDuration
    case noVideoTrack
  }

  case configuration(ConfigurationReason)
  case source(SourceReason, cause: (any Error)?)
  case frame(cause: (any Error)?)
  case selectionProcessing(cause: (any Error)?)
}

public struct VideoFramePickerLabels: Sendable {
  public var preview: String
  public var time: String
  public var processing: String
  public var sourceUnavailable: String
  public var frameUnavailable: String
  public var selectionFailed: String

  public init(
    locale: Locale = .current,
    preview: String? = nil,
    time: String? = nil,
    processing: String? = nil,
    sourceUnavailable: String? = nil,
    frameUnavailable: String? = nil,
    selectionFailed: String? = nil
  ) {
    let localization = Bundle.preferredLocalizations(
      from: Bundle.module.localizations, forPreferences: [locale.identifier]
    ).first
    let bundle = localization.flatMap {
      Bundle.module.path(forResource: $0, ofType: "lproj")
    }.flatMap(Bundle.init(path:)) ?? Bundle.module
    func text(_ key: String) -> String {
      bundle.localizedString(forKey: "frame_picker." + key, value: nil, table: nil)
    }
    self.preview = preview ?? text("preview")
    self.time = time ?? text("time")
    self.processing = processing ?? text("processing")
    self.sourceUnavailable = sourceUnavailable ?? text("source_unavailable")
    self.frameUnavailable = frameUnavailable ?? text("frame_unavailable")
    self.selectionFailed = selectionFailed ?? text("selection_failed")
  }

  func message(for failure: VideoFramePickerFailure) -> String {
    switch failure {
    case .configuration, .source: sourceUnavailable
    case .frame: frameUnavailable
    case .selectionProcessing: selectionFailed
    }
  }
}

public struct VideoFramePickerStyle {
  public var tint: Color
  public var background: Color
  public var error: Color

  public init(tint: Color = .accentColor, background: Color = .black, error: Color = .red) {
    self.tint = tint
    self.background = background
    self.error = error
  }
}
