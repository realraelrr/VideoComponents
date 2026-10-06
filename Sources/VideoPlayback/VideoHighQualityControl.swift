import SwiftUI

/// Optional fullscreen control supplied by the host; acquisition stays with the host.
public enum VideoHighQualityControl: Sendable {
  case available(@MainActor @Sendable () -> Void)
  case loading(Double?)
}

struct VideoHighQualityButton: View {
  let control: VideoHighQualityControl
  let labels: VideoPlaybackLabels

  var body: some View {
    Button {
      if case .available(let action) = control { action() }
    } label: {
      Group {
        switch control {
        case .available:
          Text(verbatim: labels.highQuality)
            .font(.body.weight(.semibold))
            .frame(minWidth: 44, minHeight: 44)
            .background(.black.opacity(0.58), in: Circle())
        case .loading:
          loadingIndicator
        }
      }
      .foregroundStyle(.white)
    }
    .buttonStyle(.plain)
    .disabled(isLoading)
    .accessibilityLabel(labels.highQualityAccessibility)
    .accessibilityValue(Text(verbatim: progress?.formatted(.percent.precision(.fractionLength(0))) ?? ""))
  }

  private var isLoading: Bool {
    if case .loading = control { return true }
    return false
  }

  private var progress: Double? {
    guard case .loading(let progress) = control, let progress else { return nil }
    return VideoPlaybackPresentation.normalizedProgress(progress)
  }

  private var loadingIndicator: some View {
    Group {
      if let progress {
        ZStack {
          Circle().stroke(.white.opacity(0.25), lineWidth: 3)
          Circle()
            .trim(from: 0, to: progress)
            .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
            .rotationEffect(.degrees(-90))
        }
      } else {
        ProgressView()
          .controlSize(.regular)
          .tint(.white)
      }
    }
    .frame(width: 32, height: 32)
    .padding(12)
    .background(.black.opacity(0.58), in: Circle())
    .padding()
    .frame(width: 44, height: 44)
    .accessibilityHidden(true)
  }
}
