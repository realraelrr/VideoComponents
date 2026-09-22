import SwiftUI

enum VideoPlaybackControlsStyle {
  case inline
  case fullscreen

  var spacing: CGFloat {
    switch self {
    case .inline:
      return 10
    case .fullscreen:
      return 12
    }
  }

  var playButtonSize: CGFloat {
    44
  }

  fileprivate var scrubBarStyle: VideoScrubBar.Style {
    switch self {
    case .inline:
      return .inline
    case .fullscreen:
      return .fullscreen
    }
  }

  var showsPlaybackTime: Bool {
    self == .fullscreen
  }
}

struct VideoPlaybackControls: View {
  @ObservedObject var playbackSession: PlaybackSession
  let style: VideoPlaybackControlsStyle
  let labels: VideoPlaybackLabels
  let tint: Color
  let fullscreenAction: (() -> Void)?

  var body: some View {
    HStack(spacing: style.spacing) {
      Button(action: playbackSession.togglePlayback) {
        Image(systemName: playbackSession.isPlaybackRequested ? "pause.fill" : "play.fill")
          .font(.body.weight(.semibold))
          .frame(width: style.playButtonSize, height: style.playButtonSize)
      }
      .accessibilityLabel(
        playbackSession.isPlaybackRequested
          ? labels.pause
          : labels.play
      )

      VideoScrubBar(
        progress: playbackProgressBinding,
        style: style.scrubBarStyle,
        tint: tint,
        label: labels.progress,
        accessibilityValue: playbackSession.playbackTimeText,
        onEditingChanged: playbackSession.handleScrubEditingChanged
      )

      if style.showsPlaybackTime {
        Text(playbackSession.playbackTimeText)
          .font(.caption.monospacedDigit())
          .foregroundStyle(.white.opacity(0.92))
          .lineLimit(1)
          .frame(minWidth: 78, alignment: .trailing)
      }

      if let fullscreenAction {
        Button(action: fullscreenAction) {
          Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.body.weight(.semibold))
            .frame(width: style.playButtonSize, height: style.playButtonSize)
        }
        .accessibilityLabel(labels.fullscreen)
      }
    }
  }

  private var playbackProgressBinding: Binding<Double> {
    Binding(
      get: {
        playbackSession.displayedProgress
      },
      set: { value in
        playbackSession.setScrubProgress(value)
      }
    )
  }
}

private struct VideoScrubBar: View {
  enum Style {
    case inline
    case fullscreen

    var visualThumbDiameter: CGFloat {
      switch self {
      case .inline:
        return 10
      case .fullscreen:
        return 12
      }
    }

    var trackHeight: CGFloat {
      switch self {
      case .inline:
        return 3
      case .fullscreen:
        return 4
      }
    }

    var hitHeight: CGFloat { 44 }

  }

  @Binding var progress: Double
  let style: Style
  let tint: Color
  let label: String
  let accessibilityValue: String
  let onEditingChanged: (Bool) -> Void

  @State private var isDragging = false

  var body: some View {
    GeometryReader { proxy in
      let width = proxy.size.width

      ZStack(alignment: .leading) {
        Capsule()
          .fill(tint.opacity(0.28))
          .frame(height: style.trackHeight)

        Capsule()
          .fill(tint)
          .frame(width: filledTrackWidth(for: width), height: style.trackHeight)

        Circle()
          .fill(tint)
          .frame(width: style.visualThumbDiameter, height: style.visualThumbDiameter)
          .shadow(color: .black.opacity(0.24), radius: 2, x: 0, y: 1)
          .offset(x: thumbOffset(for: width))
      }
      .frame(maxWidth: .infinity, minHeight: style.hitHeight, maxHeight: style.hitHeight, alignment: .center)
      .contentShape(Rectangle())
      .gesture(dragGesture(width: width))
    }
    .frame(height: style.hitHeight)
    .accessibilityElement()
    .accessibilityLabel(label)
    .accessibilityValue(accessibilityValue)
    .accessibilityAdjustableAction { direction in
      switch direction {
      case .increment:
        adjustProgress(by: 0.05)
      case .decrement:
        adjustProgress(by: -0.05)
      @unknown default:
        break
      }
    }
  }

  private var normalizedProgress: Double {
    VideoPlaybackPresentation.normalizedProgress(progress)
  }

  private func filledTrackWidth(for width: CGFloat) -> CGFloat {
    guard width.isFinite,
          width > 0 else {
      return 0
    }
    return min(max(CGFloat(normalizedProgress) * width, 0), width)
  }

  private func thumbOffset(for width: CGFloat) -> CGFloat {
    guard width.isFinite,
          width > style.visualThumbDiameter else {
      return 0
    }
    let rawOffset = CGFloat(normalizedProgress) * width - style.visualThumbDiameter / 2
    return min(max(rawOffset, 0), width - style.visualThumbDiameter)
  }

  private func dragGesture(width: CGFloat) -> some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { value in
        if !isDragging {
          isDragging = true
          onEditingChanged(true)
        }
        progress = VideoScrubBarGeometry.progress(forX: value.location.x, width: width)
      }
      .onEnded { value in
        progress = VideoScrubBarGeometry.progress(forX: value.location.x, width: width)
        isDragging = false
        onEditingChanged(false)
      }
  }

  private func adjustProgress(by delta: Double) {
    onEditingChanged(true)
    progress = VideoPlaybackPresentation.normalizedProgress(progress + delta)
    onEditingChanged(false)
  }
}
