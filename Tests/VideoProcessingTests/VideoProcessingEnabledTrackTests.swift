import AVFoundation
import CoreGraphics
import Foundation
import XCTest

@testable import VideoProcessing

@MainActor
final class VideoProcessingEnabledTrackTests: XCTestCase {
  func testExportDoesNotReenableDisabledAudio() async throws {
    let directory = try fixtureDirectory()
    let videoAsset = try await makeVideo(in: directory)
    let audioAsset = AVURLAsset(url: try makeAudio(in: directory))
    let videoTracks = try await videoAsset.loadTracks(withMediaType: .video)
    let audioTracks = try await audioAsset.loadTracks(withMediaType: .audio)
    let sourceVideo = try XCTUnwrap(videoTracks.first)
    let sourceAudio = try XCTUnwrap(audioTracks.first)
    let composition = AVMutableComposition()
    let video = try track(in: composition, mediaType: .video)
    let audio = try track(in: composition, mediaType: .audio)
    try video.insertTimeRange(
      CMTimeRange(start: .zero, duration: CMTime(value: 18, timescale: 30)),
      of: sourceVideo, at: .zero
    )
    try audio.insertTimeRange(
      CMTimeRange(start: .zero, duration: CMTime(value: 3, timescale: 10)),
      of: sourceAudio, at: .zero
    )
    audio.isEnabled = false

    let native = try await nativeExport(composition, in: directory)
    let nativeAudio = try await native.loadTracks(withMediaType: .audio)
    XCTAssertTrue(nativeAudio.isEmpty, "The native control must respect the disabled source track")
    let nativeVideo = try await native.loadTracks(withMediaType: .video)
    XCTAssertEqual(nativeVideo.count, 1)

    let output = try await SlowVideoExporter.exportSlowedVideo(
      asset: composition, rate: 1, outputDirectory: directory, onProgress: { _ in }
    )
    let exported = AVURLAsset(url: output)
    let exportedAudio = try await exported.loadTracks(withMediaType: .audio)
    XCTAssertTrue(exportedAudio.isEmpty, "Export must not render a disabled source audio track")
    let exportedVideo = try await exported.loadTracks(withMediaType: .video)
    XCTAssertEqual(exportedVideo.count, 1)
  }

  func testExportUsesEnabledVideoInsteadOfEarlierDisabledTrack() async throws {
    let directory = try fixtureDirectory()
    let source = try await makeVideo(in: directory)
    let tracks = try await source.loadTracks(withMediaType: .video)
    let sourceVideo = try XCTUnwrap(tracks.first)
    let composition = AVMutableComposition()
    let disabled = try track(in: composition, mediaType: .video)
    let enabled = try track(in: composition, mediaType: .video)
    let half = CMTime(value: 3, timescale: 10)
    try disabled.insertTimeRange(CMTimeRange(start: .zero, duration: half), of: sourceVideo, at: .zero)
    disabled.isEnabled = false
    try enabled.insertTimeRange(CMTimeRange(start: half, duration: half), of: sourceVideo, at: .zero)

    let native = try await nativeExport(composition, in: directory)
    let expected = try await grayPixel(in: native, at: 0.1)
    let excluded = try await grayPixel(in: source, at: 0.1)
    XCTAssertGreaterThan(abs(expected - excluded), 30, "Enabled and disabled fixture clips must differ")

    let output = try await SlowVideoExporter.exportSlowedVideo(
      asset: composition, rate: 1, outputDirectory: directory, onProgress: { _ in }
    )
    let exported = AVURLAsset(url: output)
    let actual = try await grayPixel(in: exported, at: 0.1)
    XCTAssertEqual(actual, expected, accuracy: 2, "Export must render the same enabled video as the native control")
  }

  private func fixtureDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("enabled-track-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    return directory
  }

  private func track(in composition: AVMutableComposition, mediaType: AVMediaType) throws -> AVMutableCompositionTrack {
    try XCTUnwrap(composition.addMutableTrack(withMediaType: mediaType, preferredTrackID: kCMPersistentTrackID_Invalid))
  }

  private func nativeExport(_ asset: AVAsset, in directory: URL) async throws -> AVURLAsset {
    let url = directory.appendingPathComponent("native-control.mp4")
    let session = try XCTUnwrap(AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality))
    session.outputURL = url
    session.outputFileType = .mp4
    await session.export()
    XCTAssertEqual(session.status, .completed)
    if session.status != .completed { throw try XCTUnwrap(session.error) }
    return AVURLAsset(url: url)
  }

  private func grayPixel(in asset: AVAsset, at seconds: Double) async throws -> Double {
    let generator = AVAssetImageGenerator(asset: asset)
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    let image: CGImage = try await withCheckedThrowingContinuation { continuation in
      generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: CMTime(seconds: seconds, preferredTimescale: 600))]) { _, image, _, result, error in
        if result == .succeeded, let image {
          continuation.resume(returning: image)
        } else {
          continuation.resume(throwing: error ?? NSError(domain: "VideoProcessingTests", code: 1))
        }
      }
    }
    var pixel: UInt8 = 0
    try withUnsafeMutableBytes(of: &pixel) { bytes in
      let context = try XCTUnwrap(CGContext(
        data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 1,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
      ))
      context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    }
    return Double(pixel)
  }

  private func makeVideo(in directory: URL) async throws -> AVURLAsset {
    let url = directory.appendingPathComponent("source.mov")
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 128, AVVideoHeightKey: 96
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: 128, kCVPixelBufferHeightKey as String: 96
    ])
    writer.add(input)
    XCTAssertTrue(writer.startWriting())
    if writer.status != .writing { throw try XCTUnwrap(writer.error) }
    writer.startSession(atSourceTime: .zero)
    for index in 0..<18 {
      while !input.isReadyForMoreMediaData {
        try Task.checkCancellation()
        if writer.status != .writing { throw try XCTUnwrap(writer.error) }
        await Task.yield()
      }
      var buffer: CVPixelBuffer?
      let pool = try XCTUnwrap(adaptor.pixelBufferPool)
      XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer), kCVReturnSuccess)
      let pixel = try XCTUnwrap(buffer)
      CVPixelBufferLockBaseAddress(pixel, [])
      memset(CVPixelBufferGetBaseAddress(pixel), Int32(40 + index * 8), CVPixelBufferGetBytesPerRow(pixel) * 96)
      CVPixelBufferUnlockBaseAddress(pixel, [])
      XCTAssertTrue(adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(index), timescale: 30)))
    }
    writer.endSession(atSourceTime: CMTime(value: 18, timescale: 30))
    input.markAsFinished()
    await writer.finishWriting()
    XCTAssertEqual(writer.status, .completed)
    if writer.status != .completed { throw try XCTUnwrap(writer.error) }
    return AVURLAsset(url: url)
  }

  private func makeAudio(in directory: URL) throws -> URL {
    let url = directory.appendingPathComponent("source.caf")
    let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100))
    buffer.frameLength = 44_100
    let samples = try XCTUnwrap(buffer.floatChannelData?[0])
    for index in 0..<44_100 {
      samples[index] = Float(sin(Double(index) * 2 * .pi * 440 / 44_100)) * 0.5
    }
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
    return url
  }
}
