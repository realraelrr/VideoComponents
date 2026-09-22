import SwiftUI

struct VideoChromeOverlay<LeadingAction: View, TrailingAction: View>: View {
  let isZooming: Bool
  let isMultiTouchGestureActive: Bool
  let isBlockingStatusOverlayVisible: Bool
  let safeAreaInsets: EdgeInsets
  let playbackRateText: String?
  let labels: VideoPlaybackLabels
  let onResetZoom: @MainActor () -> Void
  let leadingAction: LeadingAction
  let trailingAction: TrailingAction

  init(
    isZooming: Bool,
    isMultiTouchGestureActive: Bool,
    isBlockingStatusOverlayVisible: Bool,
    safeAreaInsets: EdgeInsets = EdgeInsets(),
    playbackRateText: String?,
    labels: VideoPlaybackLabels = .init(),
    onResetZoom: @escaping @MainActor () -> Void,
    @ViewBuilder leadingAction: () -> LeadingAction,
    @ViewBuilder trailingAction: () -> TrailingAction
  ) {
    self.isZooming = isZooming
    self.isMultiTouchGestureActive = isMultiTouchGestureActive
    self.isBlockingStatusOverlayVisible = isBlockingStatusOverlayVisible
    self.safeAreaInsets = safeAreaInsets
    self.playbackRateText = playbackRateText
    self.labels = labels
    self.onResetZoom = onResetZoom
    self.leadingAction = leadingAction()
    self.trailingAction = trailingAction()
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(alignment: .top, spacing: 8) {
        HStack(spacing: 8) {
          leadingAction

          if showsResetButton {
            VideoChromeIconButton(
              systemName: "arrow.counterclockwise",
              accessibilityLabel: labels.resetZoom,
              action: onResetZoom
            )
          }

          if let playbackRateText,
             !isBlockingStatusOverlayVisible {
            VideoPlaybackRateBadge(text: playbackRateText)
          }
        }

        Spacer(minLength: 8)

        if !isBlockingStatusOverlayVisible {
          HStack(spacing: 8) {
            trailingAction
          }
        }
      }
      .padding(.top, safeAreaInsets.top + 12)
      .padding(.horizontal, 12)
      .padding(.leading, safeAreaInsets.leading)
      .padding(.trailing, safeAreaInsets.trailing)
      .padding(.bottom, 12)

      Spacer(minLength: 0)
    }
  }

  private var showsResetButton: Bool {
    isZooming && !isMultiTouchGestureActive && !isBlockingStatusOverlayVisible
  }
}

extension VideoChromeOverlay where LeadingAction == EmptyView {
  init(
    isZooming: Bool,
    isMultiTouchGestureActive: Bool,
    isBlockingStatusOverlayVisible: Bool,
    safeAreaInsets: EdgeInsets = EdgeInsets(),
    playbackRateText: String?,
    labels: VideoPlaybackLabels = .init(),
    onResetZoom: @escaping @MainActor () -> Void,
    @ViewBuilder trailingAction: () -> TrailingAction
  ) {
    self.init(
      isZooming: isZooming,
      isMultiTouchGestureActive: isMultiTouchGestureActive,
      isBlockingStatusOverlayVisible: isBlockingStatusOverlayVisible,
      safeAreaInsets: safeAreaInsets,
      playbackRateText: playbackRateText,
      labels: labels,
      onResetZoom: onResetZoom,
      leadingAction: { EmptyView() },
      trailingAction: trailingAction
    )
  }
}

struct VideoChromeIconButton: View {
  let systemName: String
  let accessibilityLabel: String
  let action: @MainActor @Sendable () -> Void

  var body: some View {
    Button {
      action()
    } label: {
      Image(systemName: systemName)
        .font(.body.weight(.semibold))
        .foregroundStyle(.white)
        .frame(width: 44, height: 44)
        .background(.black.opacity(0.58), in: Circle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(accessibilityLabel)
  }
}

struct VideoPlaybackRateBadge: View {
  let text: String

  var body: some View {
    Label {
      Text(verbatim: text)
    } icon: {
      Image(systemName: "speedometer")
    }
      .font(.caption.weight(.bold))
      .foregroundStyle(.white)
      .padding(.horizontal, 9)
      .padding(.vertical, 6)
      .background(.black.opacity(0.65), in: Capsule())
      .allowsHitTesting(false)
  }
}
