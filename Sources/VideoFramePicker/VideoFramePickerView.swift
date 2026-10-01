import SwiftUI
import VideoPlayback

/// Paused video preview and automatic delivery of each completed user selection.
///
/// Initial previewing never calls `onSelection`. During host processing the slider
/// stays disabled. The callback runs in the picker's cancellable task: hosts must
/// check cancellation and destination identity before committing any side effect.
/// Loader, initial time and frame size are snapshotted for each source identity;
/// selection/failure callbacks are snapshotted at each user value change.
///
/// Activity reports pending-user-selection edges, including the initial false.
/// Its destination must belong to this mounted instance for its entire lifetime.
/// Replacing the closure does not replay current activity. To transfer observation
/// to a different state container, unmount this picker before mounting another.
@MainActor
public struct VideoFramePickerView<StatusOverlay: View>: View {
  private let source: VideoFramePickerSource
  private let initialTime: Double?
  private let maximumFrameSize: CGSize
  private let labels: VideoFramePickerLabels
  private let style: VideoFramePickerStyle
  private let onSelectionActivityChanged: @MainActor (Bool) -> Void
  private let onFailure: @MainActor (VideoFramePickerFailure) -> Void
  private let onSelection: @MainActor (VideoFrameSelection) async throws -> Void
  private let statusOverlay: @MainActor (VideoFramePickerSourceStatus) -> StatusOverlay
  private let usesDefaultSourcePresentation: Bool
  @State private var owner: VideoFramePickerOwner

  public init(
    source: VideoFramePickerSource,
    initialTime: Double? = nil,
    maximumFrameSize: CGSize = CGSize(width: 1280, height: 1280),
    labels: VideoFramePickerLabels = .init(),
    style: VideoFramePickerStyle = .init(),
    @ViewBuilder statusOverlay: @escaping @MainActor (VideoFramePickerSourceStatus) -> StatusOverlay,
    onSelectionActivityChanged: @escaping @MainActor (Bool) -> Void = { _ in },
    onFailure: @escaping @MainActor (VideoFramePickerFailure) -> Void = { _ in },
    onSelection: @escaping @MainActor (VideoFrameSelection) async throws -> Void
  ) {
    self.init(
      source: source, initialTime: initialTime, maximumFrameSize: maximumFrameSize,
      labels: labels, style: style, onSelectionActivityChanged: onSelectionActivityChanged,
      onFailure: onFailure, onSelection: onSelection, statusOverlay: statusOverlay,
      usesDefaultSourcePresentation: false, owner: VideoFramePickerOwner()
    )
  }

  init(
    source: VideoFramePickerSource,
    initialTime: Double? = nil,
    maximumFrameSize: CGSize = CGSize(width: 1280, height: 1280),
    labels: VideoFramePickerLabels = .init(),
    style: VideoFramePickerStyle = .init(),
    onSelectionActivityChanged: @escaping @MainActor (Bool) -> Void = { _ in },
    onFailure: @escaping @MainActor (VideoFramePickerFailure) -> Void = { _ in },
    onSelection: @escaping @MainActor (VideoFrameSelection) async throws -> Void,
    statusOverlay: @escaping @MainActor (VideoFramePickerSourceStatus) -> StatusOverlay,
    usesDefaultSourcePresentation: Bool,
    owner: VideoFramePickerOwner
  ) {
    self.source = source
    self.initialTime = initialTime
    self.maximumFrameSize = maximumFrameSize
    self.labels = labels
    self.style = style
    self.onSelectionActivityChanged = onSelectionActivityChanged
    self.onFailure = onFailure
    self.onSelection = onSelection
    self.statusOverlay = statusOverlay
    self.usesDefaultSourcePresentation = usesDefaultSourcePresentation
    _owner = State(initialValue: owner)
  }

  public var body: some View {
    VStack(spacing: 16) {
      previewCard
      timeControl
      if let failure = owner.failure, usesDefaultSourcePresentation || owner.player != nil {
        Text(labels.message(for: failure))
          .font(.footnote)
          .foregroundStyle(style.error)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .tint(style.tint)
    .onAppear { startSource() }
    .onChange(of: source.identity, initial: true) { _, _ in
      startSource()
    }
    .onChange(of: owner.hasPendingSelection, initial: true) { _, pending in
      onSelectionActivityChanged(pending)
    }
    .onDisappear {
      owner.stop()
      // onChange is not guaranteed to run once its view has been removed.
      onSelectionActivityChanged(false)
    }
  }

  private func startSource() {
    owner.start(
      source: source, initialTime: initialTime,
      maximumFrameSize: maximumFrameSize, onFailure: onFailure
    )
  }

  private var previewCard: some View {
    AdaptiveVideoCardLayout(contentAspectRatio: 4 / 3) {
      ZStack {
        style.background
        if let player = owner.player {
          InlineVideoPlayerLayer(player: player, videoGravity: .resizeAspect)
        }
        if !owner.isShowingPlayerPreview {
          if let preview = owner.preview {
            Image(decorative: preview.image, scale: 1)
              .resizable()
              .scaledToFit()
          } else if owner.failure == nil && usesDefaultSourcePresentation {
            ProgressView()
              .tint(.white)
          }
        }
        statusOverlay(owner.sourceStatus)
      }
      .clipShape(RoundedRectangle(cornerRadius: 14))
    }
    .padding(.horizontal, 16)
    .frame(maxWidth: .infinity, alignment: .center)
    .accessibilityLabel(labels.preview)
  }

  private var timeControl: some View {
    VStack(spacing: 8) {
      Slider(
        value: Binding(
          get: { owner.selectedSeconds },
          set: { seconds in
            owner.changeSeconds(seconds, callbacks: VideoFramePickerCallbacks(
              onFailure: onFailure, onSelection: onSelection
            ))
          }
        ),
        in: 0...max(owner.duration, 0.01),
        onEditingChanged: { editing in
          if editing {
            owner.beginScrubbing()
          } else {
            owner.endScrubbing(onFailure: onFailure)
          }
        }
      )
      .disabled(owner.isSliderDisabled)
      .accessibilityLabel(labels.time)
      .accessibilityValue(VideoFramePickerOwner.formatTime(owner.selectedSeconds))

      HStack {
        Text(VideoFramePickerOwner.formatTime(owner.selectedSeconds))
        Spacer()
        if owner.hasPendingSelection && !owner.isScrubbing {
          ProgressView()
            .controlSize(.small)
            .accessibilityLabel(labels.processing)
        }
        Text(VideoFramePickerOwner.formatTime(owner.duration))
      }
      .font(.caption.monospacedDigit())
      .foregroundStyle(.secondary)
    }
  }
}

extension VideoFramePickerView where StatusOverlay == EmptyView {
  public init(
    source: VideoFramePickerSource,
    initialTime: Double? = nil,
    maximumFrameSize: CGSize = CGSize(width: 1280, height: 1280),
    labels: VideoFramePickerLabels = .init(),
    style: VideoFramePickerStyle = .init(),
    onSelectionActivityChanged: @escaping @MainActor (Bool) -> Void = { _ in },
    onFailure: @escaping @MainActor (VideoFramePickerFailure) -> Void = { _ in },
    onSelection: @escaping @MainActor (VideoFrameSelection) async throws -> Void
  ) {
    self.init(
      source: source, initialTime: initialTime, maximumFrameSize: maximumFrameSize,
      labels: labels, style: style, onSelectionActivityChanged: onSelectionActivityChanged,
      onFailure: onFailure, onSelection: onSelection, owner: VideoFramePickerOwner()
    )
  }

  init(
    source: VideoFramePickerSource,
    initialTime: Double? = nil,
    maximumFrameSize: CGSize = CGSize(width: 1280, height: 1280),
    labels: VideoFramePickerLabels = .init(),
    style: VideoFramePickerStyle = .init(),
    onSelectionActivityChanged: @escaping @MainActor (Bool) -> Void = { _ in },
    onFailure: @escaping @MainActor (VideoFramePickerFailure) -> Void = { _ in },
    onSelection: @escaping @MainActor (VideoFrameSelection) async throws -> Void,
    owner: VideoFramePickerOwner
  ) {
    self.init(
      source: source, initialTime: initialTime, maximumFrameSize: maximumFrameSize,
      labels: labels, style: style, onSelectionActivityChanged: onSelectionActivityChanged,
      onFailure: onFailure, onSelection: onSelection, statusOverlay: { _ in EmptyView() },
      usesDefaultSourcePresentation: true, owner: owner
    )
  }
}
