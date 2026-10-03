import AVFoundation
import CoreVideo
import Foundation
import VideoProcessing
import VideoResources
import VideoResourcesFrames
import XCTest

@MainActor
final class VideoResourcesMixedExportTests: XCTestCase {
  func testActualReceiptMixReachesExportedSamplesAfterTrackRebuilding() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("receipt-mix-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fixture = try await movieWithTone(in: directory)
    XCTAssertEqual(fixture.audioTrackID, 871)
    let parameters = AVMutableAudioMixInputParameters()
    parameters.trackID = fixture.audioTrackID
    parameters.setVolume(0, at: .zero)
    let mix = AVMutableAudioMix()
    mix.inputParameters = [parameters]
    var requests: [VideoRequest] = []
    let resources = VideoResources(photos: PhotosVideoProvider(authority: { _ in "visible-mixed-video" },
      load: { _, request, _ in
        requests.append(request)
        return .init(asset: fixture.asset, audioMix: mix)
      }))
    let source = resources.photosSource(serializedCloudIdentifier: "receipt-mix-export")
    let baseline = try await SlowVideoExporter.exportSlowedVideo(
      asset: fixture.asset, rate: 0.5, outputDirectory: directory, onProgress: { _ in })
    let result = try await VideoResourcesFrames.export(source: source, rate: 0.5,
      outputDirectory: directory, onProgress: { _ in })
    let baselineRMS = try await measuredRMS(baseline)
    let mixedRMS = try await measuredRMS(result.url)
    print("MIX_OUTPUT actual_receipt baseline=\(baselineRMS) mixed=\(mixedRMS)")
    XCTAssertGreaterThan(baselineRMS, 0.2, "The control must contain actual decoded sound")
    XCTAssertLessThan(mixedRMS / baselineRMS, 0.01,
      "Core's actual audio mix must reach native export and apply to the rebuilt track")
    XCTAssertEqual(requests, [.init(quality: .highest, network: .allowed)])
    XCTAssertTrue(result.receipt.isCurrent)
    XCTAssertTrue(result.receipt.asset === fixture.asset)
    XCTAssertEqual(parameters.trackID, 871)
  }

  private func movieWithTone(in directory: URL) async throws
    -> (asset: AVComposition, audioTrackID: CMPersistentTrackID) {
    let videoURL = directory.appendingPathComponent("fixture.mov")
    let writer = try AVAssetWriter(outputURL: videoURL, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
      sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64])
    writer.add(input)
    XCTAssertTrue(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    for frame in 0..<12 {
      for _ in 0..<500 {
        if input.isReadyForMoreMediaData || writer.status != .writing { break }
        try await Task.sleep(for: .milliseconds(10))
      }
      XCTAssertTrue(input.isReadyForMoreMediaData)
      var buffer: CVPixelBuffer?
      XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &buffer), kCVReturnSuccess)
      let pixel = try XCTUnwrap(buffer)
      CVPixelBufferLockBaseAddress(pixel, [])
      memset(CVPixelBufferGetBaseAddress(pixel), 180, CVPixelBufferGetBytesPerRow(pixel) * 64)
      CVPixelBufferUnlockBaseAddress(pixel, [])
      XCTAssertTrue(adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 6)))
    }
    writer.endSession(atSourceTime: CMTime(seconds: 2, preferredTimescale: 600))
    input.markAsFinished()
    await writer.finishWriting()
    XCTAssertEqual(writer.status, .completed)
    let audioURL = directory.appendingPathComponent("fixture.caf")
    let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
    let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 88_200))
    pcm.frameLength = 88_200
    for index in 0..<88_200 {
      pcm.floatChannelData?[0][index] = Float(sin(Double(index) * 2 * .pi * 440 / 44_100)) * 0.5
    }
    do {
      let file = try AVAudioFile(forWriting: audioURL, settings: format.settings)
      try file.write(from: pcm)
    }
    let videoAsset = AVURLAsset(url: videoURL)
    let audioAsset = AVURLAsset(url: audioURL)
    let videos = try await videoAsset.loadTracks(withMediaType: .video)
    let audios = try await audioAsset.loadTracks(withMediaType: .audio)
    // AVAssetTrack.asset is weak; the source assets must survive insertion.
    return try withExtendedLifetime((videoAsset, audioAsset)) {
      let composition = AVMutableComposition()
      let video = try XCTUnwrap(composition.addMutableTrack(withMediaType: .video, preferredTrackID: 203))
      let audio = try XCTUnwrap(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: 871))
      let range = CMTimeRange(start: .zero, duration: CMTime(seconds: 2, preferredTimescale: 600))
      try video.insertTimeRange(range, of: try XCTUnwrap(videos.first), at: .zero)
      try audio.insertTimeRange(range, of: try XCTUnwrap(audios.first), at: .zero)
      return (try XCTUnwrap(composition.copy() as? AVComposition), audio.trackID)
    }
  }

  private func measuredRMS(_ url: URL) async throws -> Double {
    let asset = AVURLAsset(url: url)
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    XCTAssertEqual(tracks.count, 1)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: try XCTUnwrap(tracks.first), outputSettings: [
      AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true,
      AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false,
      AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1])
    reader.add(output)
    XCTAssertTrue(reader.startReading())
    var squareSum = 0.0
    var count = 0
    while let sample = output.copyNextSampleBuffer() {
      guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
      let length = CMBlockBufferGetDataLength(block)
      var values = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
      let status = values.withUnsafeMutableBytes {
        CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
      }
      XCTAssertEqual(status, kCMBlockBufferNoErr)
      let start = CMSampleBufferGetPresentationTimeStamp(sample).seconds
      for (index, value) in values.enumerated() {
        let time = start + Double(index) / 44_100
        if (0.3..<3.7).contains(time) {
          squareSum += Double(value) * Double(value)
          count += 1
        }
      }
    }
    XCTAssertEqual(reader.status, .completed)
    XCTAssertGreaterThan(count, 1_000)
    return sqrt(squareSum / Double(max(count, 1)))
  }
}
