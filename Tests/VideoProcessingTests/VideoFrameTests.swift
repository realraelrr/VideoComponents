import AVFoundation
import UIKit
import XCTest

@testable import VideoProcessing

@MainActor
final class VideoFrameTests: XCTestCase {
  func testRejectsInvalidTimeBeforeReadingAsset() async throws {
    for seconds in [Double.nan, .infinity, -.infinity, -0.01] {
      do {
        _ = try await VideoFrameExtractor.frame(for: AVMutableComposition(), at: seconds, maximumSize: CGSize(width: 128, height: 128))
        XCTFail("Expected invalidTime")
      } catch VideoFrameExtractionError.invalidTime {}
    }
  }

  func testRejectsInvalidSizeBeforeReadingAsset() async throws {
    let sizes: [CGSize] = [
      .zero, CGSize(width: -1, height: 10), CGSize(width: 10, height: 0.5),
      CGSize(width: 4097, height: 10), CGSize(width: 10, height: 4097),
      CGSize(width: CGFloat.nan, height: 10), CGSize(width: 10, height: CGFloat.infinity)
    ]
    for size in sizes {
      do {
        _ = try await VideoFrameExtractor.frame(for: AVMutableComposition(), at: 0, maximumSize: size)
        XCTFail("Expected invalidSize")
      } catch VideoFrameExtractionError.invalidSize {}
    }
  }

  func testZeroAndNonexactFrameReturnActualTimeAndRotatedPixels() async throws {
    let asset = try await makeVideo(frameCount: 60)
    let first = try await VideoFrameExtractor.frame(for: asset, at: 0, maximumSize: CGSize(width: 128, height: 128), exact: true)
    XCTAssertEqual(first.actualTime.seconds, 0, accuracy: 0.001)
    XCTAssertEqual(first.image.width, 96)
    XCTAssertEqual(first.image.height, 128)
    let nearby = try await VideoFrameExtractor.frame(for: asset, at: 0.5123, maximumSize: CGSize(width: 64, height: 64))
    XCTAssertTrue(nearby.actualTime.isNumeric)
    XCTAssertTrue((0..<2).contains(nearby.actualTime.seconds))
    XCTAssertLessThanOrEqual(nearby.image.width, 64)
    XCTAssertLessThanOrEqual(nearby.image.height, 64)
    // The requested time is between encoded frames, so reporting it as actual is wrong.
    XCTAssertGreaterThan(abs(nearby.actualTime.seconds - 0.5123), 0.0001)
  }

  func testEndAndOutOfRangeRequestsDoNotInventAnExactFrame() async throws {
    let asset = try await makeVideo(frameCount: 60)
    let duration = try await asset.load(.duration).seconds
    for seconds in [duration, duration + 10] {
      do {
        let frame = try await VideoFrameExtractor.frame(for: asset, at: seconds, maximumSize: CGSize(width: 128, height: 128), exact: true)
        // Even with zero tolerance AVFoundation can return the last frame at the
        // duration endpoint. Preserve its actual encoded time, never the request.
        XCTAssertTrue((0..<duration).contains(frame.actualTime.seconds))
        XCTAssertEqual(frame.actualTime.seconds * 30, (frame.actualTime.seconds * 30).rounded(), accuracy: 0.001)
        XCTAssertEqual(frame.image.width, 96)
        XCTAssertEqual(frame.image.height, 128)
      } catch VideoFrameExtractionError.frameUnavailable {}
      // Nonexact time tolerance is AVFoundation's decision, including refusal.
      do {
        let frame = try await VideoFrameExtractor.frame(for: asset, at: seconds, maximumSize: CGSize(width: 128, height: 128))
        XCTAssertTrue(frame.actualTime.isNumeric)
        XCTAssertTrue((0..<duration).contains(frame.actualTime.seconds))
        XCTAssertGreaterThan(frame.image.width, 0)
      } catch VideoFrameExtractionError.frameUnavailable {}
    }
  }

  func testVeryShortVideoHasARealFrameAtZero() async throws {
    let asset = try await makeVideo(frameCount: 1)
    let frame = try await VideoFrameExtractor.frame(for: asset, at: 0, maximumSize: CGSize(width: 4096, height: 4096), exact: true)
    XCTAssertEqual(frame.actualTime.seconds, 0, accuracy: 0.001)
    XCTAssertEqual(frame.image.width, 96)
    XCTAssertEqual(frame.image.height, 128)
    XCTAssertEqual(AutomaticVideoPosterSelector.candidateTimes(duration: 1.0 / 30), [0])
  }

  func testMissingVideoAndDamagedAssetHaveTypedFrameFailures() async throws {
    let corruptURL = temporaryFile(suffix: "mov")
    try Data("not a movie".utf8).write(to: corruptURL)
    for asset in [AVMutableComposition(), AVURLAsset(url: corruptURL)] as [AVAsset] {
      do {
        _ = try await VideoFrameExtractor.frame(for: asset, at: 0, maximumSize: CGSize(width: 128, height: 128))
        XCTFail("Expected frameUnavailable")
      } catch VideoFrameExtractionError.frameUnavailable(let cause) {
        XCTAssertNotNil(cause)
      }
    }
  }

  func testAutomaticPosterKeepsVersionOneAndUnknownDurationCandidateStrategy() {
    XCTAssertEqual(AutomaticVideoPosterSelector.algorithmVersion, 1)
    XCTAssertEqual(AutomaticVideoPosterSelector.candidateTimes(duration: 20), [2, 5, 9, 13, 17])
    for duration in [Double.nan, .infinity, -.infinity, 0, -1] {
      XCTAssertEqual(AutomaticVideoPosterSelector.candidateTimes(duration: duration), [0])
    }
  }

  func testAutomaticPosterSelectsUsablePixelsThroughRealVideoPipeline() async throws {
    let asset = try await makeVideo(frameCount: 60)
    let poster = try await AutomaticVideoPosterSelector.select(from: asset)
    let image = try XCTUnwrap(poster.image.cgImage)
    XCTAssertEqual(image.width, 96)
    XCTAssertEqual(image.height, 128)
    XCTAssertFalse(VideoFrameQualityScorer.score(image).isObviouslyBad)
  }

  func testAutomaticPosterRejectsUniformVideoAndUnavailableAssetSeparately() async throws {
    let black = try await makeVideo(frameCount: 3, detailed: false)
    do {
      _ = try await AutomaticVideoPosterSelector.select(from: black)
      XCTFail("Expected noUsableFrame")
    } catch AutomaticVideoPosterSelector.SelectionError.noUsableFrame {}
    let corruptURL = temporaryFile(suffix: "mov")
    try Data("not a movie".utf8).write(to: corruptURL)
    do {
      _ = try await AutomaticVideoPosterSelector.select(from: AVURLAsset(url: corruptURL))
      XCTFail("Expected assetUnavailable")
    } catch AutomaticVideoPosterSelector.SelectionError.assetUnavailable {}
  }

  func testCancelledFrameAndPosterRequestsThrowCancellation() async throws {
    let asset = try await makeVideo(frameCount: 3)
    let frameTask = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await VideoFrameExtractor.frame(for: asset, at: 0, maximumSize: CGSize(width: 128, height: 128))
    }
    do { _ = try await frameTask.value; XCTFail("Expected cancellation") }
    catch is CancellationError {}
    let posterTask = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await AutomaticVideoPosterSelector.select(from: asset)
    }
    do { _ = try await posterTask.value; XCTFail("Expected cancellation") }
    catch is CancellationError {}
  }

  private func makeVideo(frameCount: Int, detailed: Bool = true) async throws -> AVURLAsset {
    let url = temporaryFile(suffix: "mov")
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 128, AVVideoHeightKey: 96
    ])
    input.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 96, ty: 0)
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: 128, kCVPixelBufferHeightKey as String: 96
    ])
    writer.add(input)
    XCTAssertTrue(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    for index in 0..<frameCount {
      while !input.isReadyForMoreMediaData {
        guard writer.status == .writing else { throw try XCTUnwrap(writer.error) }
        await Task.yield()
      }
      var buffer: CVPixelBuffer?
      XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &buffer), kCVReturnSuccess)
      let pixel = try XCTUnwrap(buffer)
      CVPixelBufferLockBaseAddress(pixel, [])
      let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixel)).assumingMemoryBound(to: UInt8.self)
      let stride = CVPixelBufferGetBytesPerRow(pixel)
      for y in 0..<96 {
        for x in 0..<128 {
          let value: UInt8 = detailed && ((x / 8 + y / 8).isMultiple(of: 2)) ? 230 : 20
          let position = y * stride + x * 4
          bytes[position] = value
          bytes[position + 1] = value
          bytes[position + 2] = value
          bytes[position + 3] = 255
        }
      }
      CVPixelBufferUnlockBaseAddress(pixel, [])
      XCTAssertTrue(adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(index), timescale: 30)))
    }
    writer.endSession(atSourceTime: CMTime(value: Int64(frameCount), timescale: 30))
    input.markAsFinished()
    await writer.finishWriting()
    XCTAssertEqual(writer.status, .completed)
    return AVURLAsset(url: url)
  }

  private func temporaryFile(suffix: String) -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("frame-fixture-\(UUID().uuidString).\(suffix)")
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }
}
