import SwiftUI

public struct VideoPlaybackLabels {
  public var play: String
  public var pause: String
  public var fullscreen: String
  public var progress: String
  public var resetZoom: String
  public var close: String

  public init(locale: Locale? = nil) {
    let localization = locale.flatMap {
      Bundle.preferredLocalizations(from: Bundle.module.localizations, forPreferences: [$0.identifier]).first
    }
    let bundle = localization.flatMap {
      Bundle.module.path(forResource: $0, ofType: "lproj")
    }.flatMap(Bundle.init(path:)) ?? Bundle.module
    func text(_ key: String) -> String {
      bundle.localizedString(forKey: "video." + key, value: nil, table: nil)
    }
    play = text("play")
    pause = text("pause")
    fullscreen = text("fullscreen")
    progress = text("progress")
    resetZoom = text("reset_zoom")
    close = text("close")
  }
}

public struct VideoPlaybackStyle {
  public var tint: Color
  public var foreground: Color
  public var background: Color

  public init(tint: Color = .accentColor, foreground: Color = .primary, background: Color = Color(uiColor: .secondarySystemBackground)) {
    self.tint = tint
    self.foreground = foreground
    self.background = background
  }
}

/// A neutral default; hosts can replace it with their own resource recovery presentation.
public struct PlaybackStatusOverlay: View {
  public let status: PlaybackStatus
  public init(status: PlaybackStatus) { self.status = status }
  public var body: some View {
    switch status {
    case .none, .slowPreparing, .slowBuffering:
      EmptyView()
    case .unavailable:
      Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.white)
    case .loading, .loadingPlayerItem, .buffering:
      ProgressView().tint(.white)
    }
  }
}
