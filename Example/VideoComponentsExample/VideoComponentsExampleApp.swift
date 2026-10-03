import AVFoundation
import SwiftUI
import VideoFramePicker
import VideoPlayback
import VideoProcessing

@main
struct VideoComponentsExampleApp: App {
  var body: some Scene {
    WindowGroup { VideoComponentsDemo() }
  }
}

private struct VideoComponentsDemo: View {
  @StateObject private var media = DemoMedia()
  @State private var isFullscreen = false
  @State private var isScrollLocked = false
  @State private var exportRequest = 0

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          Text("A moving pattern, made on this device.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
          InlinePlaybackView(
            playbackSession: media.session,
            isFullscreenPresented: isFullscreen,
            isScrollInteractionActive: $isScrollLocked,
            maximumCardSize: CGSize(width: 640, height: 420),
            topTrailingAccessory: { EmptyView() },
            onRequestFullscreen: { isFullscreen = true },
            statusOverlay: { PlaybackStatusOverlay(status: media.session.status) }
          )
          Text("Double-tap to play or pause. Pinch to zoom, or hold to boost playback speed.")
            .font(.footnote)
            .foregroundStyle(.secondary)
          if media.isPreparing { ProgressView("Preparing video…") }
          if let message = media.message { Text(message).foregroundStyle(.secondary) }
          if let firstFrame = media.firstFrame, let poster = media.poster {
            HStack(alignment: .top, spacing: 16) {
              preview(firstFrame, label: "First frame")
              preview(poster, label: "Automatic poster")
            }
          }
          if let originalURL = media.originalURL {
            framePicker(for: originalURL)
          }
          exportControls
        }
        .padding()
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
      }
      .scrollDisabled(isScrollLocked)
      .navigationTitle("Video Components")
      .controlSize(.large)
      .fullScreenCover(isPresented: $isFullscreen) {
        FullscreenPlaybackView(
          playbackSession: media.session,
          onClose: { isFullscreen = false },
          trailingAccessory: { EmptyView() },
          statusOverlay: { PlaybackStatusOverlay(status: media.session.status) }
        )
      }
      .task { await media.prepare() }
      .task(id: exportRequest) {
        guard exportRequest > 0 else { return }
        await media.export()
      }
    }
  }

  private func framePicker(for url: URL) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Choose a frame").font(.headline)
      VideoFramePickerView(
        source: VideoFramePickerSource(identity: url, load: { AVURLAsset(url: url) }),
        onSelection: { selection in
          try media.acceptSelection(selection, for: url)
        }
      )
      if let selection = media.selectedFrame {
        preview(UIImage(cgImage: selection.image), label: "Selected frame")
        Text("Requested: \(selection.requestedSeconds, format: .number.precision(.fractionLength(3))) s")
          .font(.caption.monospacedDigit())
        Text("Decoded: \(selection.actualTime.seconds, format: .number.precision(.fractionLength(3))) s")
          .font(.caption.monospacedDigit())
      }
    }
  }

  private var exportControls: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Slow video export").font(.headline)
      if media.isExporting {
        ProgressView("Creating a 0.5× video…", value: media.exportProgress)
      } else if let output = media.exportedURL {
        Text("The 3-second pattern is now a 6-second video.")
          .font(.subheadline)
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 12) { outputActions(output) }
          VStack(alignment: .leading, spacing: 12) { outputActions(output) }
        }
      } else {
        Button("Create 0.5× video") { exportRequest += 1 }
          .buttonStyle(.borderedProminent)
          .disabled(media.isPreparing)
      }
    }
  }

  @ViewBuilder
  private func outputActions(_ output: URL) -> some View {
    Button("Play original") { media.playOriginal() }
      .buttonStyle(.bordered)
    Button("Play 0.5× export") { media.playExport() }
      .buttonStyle(.bordered)
    ShareLink(item: output) { Label("Share", systemImage: "square.and.arrow.up") }
      .buttonStyle(.bordered)
  }

  private func preview(_ image: UIImage, label: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Image(uiImage: image).resizable().scaledToFit()
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityLabel(label)
      Text(label).font(.caption)
    }
    .frame(maxWidth: .infinity)
  }
}

@MainActor
private final class DemoMedia: ObservableObject {
  let session = PlaybackSession()
  @Published private(set) var firstFrame: UIImage?
  @Published private(set) var poster: UIImage?
  @Published private(set) var selectedFrame: VideoFrameSelection?
  @Published private(set) var originalURL: URL?
  @Published private(set) var exportedURL: URL?
  @Published private(set) var isPreparing = true
  @Published private(set) var isExporting = false
  @Published private(set) var exportProgress = 0.0
  @Published private(set) var message: String?

  isolated deinit {
    session.cleanup()
    if let originalURL { try? FileManager.default.removeItem(at: originalURL) }
    if let exportedURL { try? FileManager.default.removeItem(at: exportedURL) }
  }

  func acceptSelection(_ selection: VideoFrameSelection, for sourceURL: URL) throws {
    // The picker owns cancellation; the host guards its final state mutation.
    try Task.checkCancellation()
    guard originalURL == sourceURL else { throw CancellationError() }
    selectedFrame = selection
  }

  func prepare() async {
    guard originalURL == nil else { return }
    defer { isPreparing = false }
    do {
      let url = try await makePatternVideo()
      originalURL = url
      playOriginal()
      let asset = AVURLAsset(url: url)
      let frame = try await VideoFrameExtractor.frame(
        for: asset, at: 0, maximumSize: CGSize(width: 640, height: 640), exact: true
      )
      firstFrame = UIImage(cgImage: frame.image)
      poster = try await AutomaticVideoPosterSelector.select(from: asset).image
    } catch {
      guard !Task.isCancelled else { return }
      message = "The demo video could not be prepared."
    }
  }

  func export() async {
    guard let originalURL, exportedURL == nil else { return }
    isExporting = true
    message = nil
    defer { isExporting = false }
    do {
      exportedURL = try await SlowVideoExporter.exportSlowedVideo(
        asset: AVURLAsset(url: originalURL), rate: 0.5,
        onProgress: { [weak self] value in self?.exportProgress = value }
      )
    } catch {
      guard !Task.isCancelled else { return }
      message = "The slow video could not be created. Try again."
    }
  }

  func playOriginal() {
    guard let originalURL else { return }
    load(originalURL)
  }

  func playExport() {
    guard let exportedURL else { return }
    load(exportedURL)
  }

  private func load(_ url: URL) {
    let source = PlaybackSource(identity: url, load: { PlaybackLoadedMedia(asset: AVURLAsset(url: url)) })
    session.load(source: source, playbackRate: 1, isLooping: true, autoplayWhenReady: false)
  }

  private func makePatternVideo() async throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("video-demo-\(UUID().uuidString).mp4")
    var succeeded = false
    defer { if !succeeded { try? FileManager.default.removeItem(at: url) } }
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 240
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 240
    ])
    writer.add(input)
    guard writer.startWriting() else { throw DemoError.videoCreation }
    defer { if !succeeded { writer.cancelWriting() } }
    writer.startSession(atSourceTime: .zero)
    for index in 0..<90 {
      try Task.checkCancellation()
      while !input.isReadyForMoreMediaData {
        guard writer.status == .writing else { throw DemoError.videoCreation }
        try await Task.sleep(for: .milliseconds(5))
      }
      guard let pool = adaptor.pixelBufferPool else { throw DemoError.videoCreation }
      var optionalBuffer: CVPixelBuffer?
      guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &optionalBuffer) == kCVReturnSuccess,
            let buffer = optionalBuffer else { throw DemoError.videoCreation }
      CVPixelBufferLockBaseAddress(buffer, [])
      defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
      guard let context = CGContext(
        data: CVPixelBufferGetBaseAddress(buffer), width: 320, height: 240,
        bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
      ) else { throw DemoError.videoCreation }
      for column in 0..<16 {
        context.setFillColor((column.isMultiple(of: 2) ? UIColor.systemIndigo : UIColor.systemOrange).cgColor)
        context.fill(CGRect(x: column * 20, y: 0, width: 20, height: 240))
      }
      context.setFillColor(UIColor.white.cgColor)
      context.fillEllipse(in: CGRect(x: 12 + index * 2, y: 80, width: 72, height: 72))
      guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 30)) else {
        throw DemoError.videoCreation
      }
    }
    writer.endSession(atSourceTime: CMTime(seconds: 3, preferredTimescale: 600))
    input.markAsFinished()
    await writer.finishWriting()
    try Task.checkCancellation()
    guard writer.status == .completed else { throw DemoError.videoCreation }
    succeeded = true
    return url
  }
}

private enum DemoError: Error { case videoCreation }
