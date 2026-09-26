import AVFoundation
import CoreGraphics
import XCTest

@testable import VideoProcessing

@MainActor
final class AutomaticVideoPosterSelectionTests: XCTestCase {
  private enum FixtureError: Error { case unavailable }

  func testDeduplicatesEquivalentActualTimesBeforeChoosingRepresentativeFrame() async throws {
    let first = try image(levels: [32, 160])
    let representative = try image(levels: [32, 160, 96, 224])
    let last = try image(levels: [96, 224])
    var analysisCount = 0
    var masterTimes: [CMTime] = []

    let poster = try await AutomaticVideoPosterSelector.select(duration: 20) { time, size, exact in
      if exact {
        masterTimes.append(time)
        XCTAssertEqual(size, CGSize(width: 1_280, height: 1_280))
        return ExtractedVideoFrame(image: representative, actualTime: time)
      }
      XCTAssertEqual(size, CGSize(width: 192, height: 192))
      defer { analysisCount += 1 }
      switch analysisCount {
      case 0..<10:
        // Equal rational values have different stored timescales.
        return ExtractedVideoFrame(image: first, actualTime: CMTime(value: Int64(analysisCount + 1), timescale: Int32(analysisCount + 1)))
      case 10:
        return ExtractedVideoFrame(image: representative, actualTime: CMTime(value: 2, timescale: 1))
      default:
        return ExtractedVideoFrame(image: last, actualTime: CMTime(value: 3, timescale: 1))
      }
    }

    XCTAssertEqual(analysisCount, 12)
    XCTAssertEqual(masterTimes.count, 1)
    XCTAssertEqual(CMTimeCompare(try XCTUnwrap(masterTimes.first), CMTime(value: 2, timescale: 1)), 0)
    XCTAssertEqual(poster.image.cgImage?.width, representative.width)
  }

  func testFinalRequestPreservesRationalTimeWithoutDoubleRoundTrip() async throws {
    let frameImage = try image(levels: [32, 160])
    let actualTime = CMTime(value: 1_001, timescale: 30_000)
    var requests: [(CMTime, Bool)] = []

    _ = try await AutomaticVideoPosterSelector.select(duration: 1.0 / 30) { time, _, exact in
      requests.append((time, exact))
      return ExtractedVideoFrame(image: frameImage, actualTime: actualTime)
    }

    XCTAssertEqual(requests.count, 2)
    XCTAssertFalse(requests[0].1)
    XCTAssertTrue(requests[1].1)
    XCTAssertEqual(requests[1].0.value, actualTime.value)
    XCTAssertEqual(requests[1].0.timescale, actualTime.timescale)
    XCTAssertEqual(requests[1].0.epoch, actualTime.epoch)
  }

  func testFinalExtractionRejectsDifferentActualFrameWithoutFallback() async throws {
    let frameImage = try image(levels: [32, 160])
    var masterCount = 0
    do {
      _ = try await AutomaticVideoPosterSelector.select(duration: 20) { _, _, exact in
        if exact { masterCount += 1 }
        return ExtractedVideoFrame(image: frameImage, actualTime: CMTime(value: exact ? 2 : 1, timescale: 30))
      }
      XCTFail("Expected noUsableFrame")
    } catch AutomaticVideoPosterSelector.SelectionError.noUsableFrame {}
    XCTAssertEqual(masterCount, 1)
  }

  func testFinalExtractionFailureIsPropagatedWithoutTryingAnotherCandidate() async throws {
    let frameImage = try image(levels: [32, 160])
    var masterCount = 0
    do {
      _ = try await AutomaticVideoPosterSelector.select(duration: 20) { time, _, exact in
        if exact {
          masterCount += 1
          throw FixtureError.unavailable
        }
        return ExtractedVideoFrame(image: frameImage, actualTime: time)
      }
      XCTFail("Expected fixture error")
    } catch FixtureError.unavailable {}
    XCTAssertEqual(masterCount, 1)
  }

  func testAnalysisFailuresDoNotHideLaterUsableFrames() async throws {
    let frameImage = try image(levels: [32, 160])
    var analysisCount = 0
    var masterCount = 0
    _ = try await AutomaticVideoPosterSelector.select(duration: 0.45) { time, _, exact in
      if exact {
        masterCount += 1
        return ExtractedVideoFrame(image: frameImage, actualTime: time)
      }
      analysisCount += 1
      guard analysisCount == 4 else { throw FixtureError.unavailable }
      return ExtractedVideoFrame(image: frameImage, actualTime: time)
    }
    XCTAssertEqual(analysisCount, 4)
    XCTAssertEqual(masterCount, 1)
  }

  func testOnlyRejectedFramesNeverDecodeAMaster() async throws {
    let black = try image(levels: [0])
    var masterCount = 0
    do {
      _ = try await AutomaticVideoPosterSelector.select(duration: 20) { time, _, exact in
        if exact { masterCount += 1 }
        return ExtractedVideoFrame(image: black, actualTime: time)
      }
      XCTFail("Expected noUsableFrame")
    } catch AutomaticVideoPosterSelector.SelectionError.noUsableFrame {}
    XCTAssertEqual(masterCount, 0)
  }

  func testInvalidActualTimesAreRejectedBeforeMasterExtraction() async throws {
    let frameImage = try image(levels: [32, 160])
    for actualTime in [CMTime.invalid, .indefinite, .positiveInfinity, CMTime(value: -1, timescale: 30)] {
      var masterCount = 0
      do {
        _ = try await AutomaticVideoPosterSelector.select(duration: 0.01) { _, _, exact in
          if exact { masterCount += 1 }
          return ExtractedVideoFrame(image: frameImage, actualTime: actualTime)
        }
        XCTFail("Expected noUsableFrame")
      } catch AutomaticVideoPosterSelector.SelectionError.noUsableFrame {}
      XCTAssertEqual(masterCount, 0)
    }
  }

  func testInvalidDurationsDoNotRequestExtraction() async {
    for duration in [Double.nan, .infinity, -.infinity, -1] {
      var count = 0
      do {
        _ = try await AutomaticVideoPosterSelector.select(duration: duration) { _, _, _ in
          count += 1
          throw FixtureError.unavailable
        }
        XCTFail("Expected noUsableFrame")
      } catch AutomaticVideoPosterSelector.SelectionError.noUsableFrame {
      } catch {
        XCTFail("Unexpected error: \(error)")
      }
      XCTAssertEqual(count, 0)
    }
  }

  func testZeroDurationStillAttemptsTheFirstFrameOnce() async throws {
    let frameImage = try image(levels: [32, 160])
    var requests = 0
    _ = try await AutomaticVideoPosterSelector.select(duration: 0) { time, _, _ in
      requests += 1
      XCTAssertEqual(CMTimeCompare(time, .zero), 0)
      return ExtractedVideoFrame(image: frameImage, actualTime: .zero)
    }
    XCTAssertEqual(requests, 2) // One analysis, then the single selected master.
  }

  func testCancellationDuringAnalysisStopsBeforeMasterExtraction() async throws {
    let frameImage = try image(levels: [32, 160])
    var requests = 0
    let task = Task {
      try await AutomaticVideoPosterSelector.select(duration: 20) { time, _, _ in
        requests += 1
        withUnsafeCurrentTask { $0?.cancel() }
        return ExtractedVideoFrame(image: frameImage, actualTime: time)
      }
    }
    do { _ = try await task.value; XCTFail("Expected cancellation") }
    catch is CancellationError {}
    XCTAssertEqual(requests, 1)
  }

  func testCancellationErrorFromDecoderIsNotSwallowed() async throws {
    var requests = 0
    do {
      _ = try await AutomaticVideoPosterSelector.select(duration: 20) { _, _, _ in
        requests += 1
        throw CancellationError()
      }
      XCTFail("Expected cancellation")
    } catch is CancellationError {}
    XCTAssertEqual(requests, 1)
  }

  func testCancellationDuringMasterExtractionDoesNotReturnAPoster() async throws {
    let frameImage = try image(levels: [32, 160])
    var requests = 0
    let task = Task {
      try await AutomaticVideoPosterSelector.select(duration: 0.01) { time, _, exact in
        requests += 1
        if exact { withUnsafeCurrentTask { $0?.cancel() } }
        return ExtractedVideoFrame(image: frameImage, actualTime: time)
      }
    }
    do { _ = try await task.value; XCTFail("Expected cancellation") }
    catch is CancellationError {}
    XCTAssertEqual(requests, 2)
  }

  func testCancellationTakesPrecedenceOverDecoderFailure() async throws {
    let frameImage = try image(levels: [32, 160])
    for cancelDuringMaster in [false, true] {
      let task = Task {
        try await AutomaticVideoPosterSelector.select(duration: 0.01) { time, _, exact in
          if exact == cancelDuringMaster {
            withUnsafeCurrentTask { $0?.cancel() }
            throw FixtureError.unavailable
          }
          return ExtractedVideoFrame(image: frameImage, actualTime: time)
        }
      }
      do { _ = try await task.value; XCTFail("Expected cancellation") }
      catch is CancellationError {}
    }
  }

  private func image(levels: [UInt8]) throws -> CGImage {
    let width = 96
    let height = 96
    let pixels = (0..<(width * height)).map { levels[(($0 % width) / 2) % levels.count] }
    let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
    return try XCTUnwrap(CGImage(
      width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
    ))
  }
}
