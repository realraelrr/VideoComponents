import AVFoundation
import CoreGraphics
import Foundation
import XCTest

@testable import VideoProcessing

@MainActor
final class VideoFrameGenerationTests: XCTestCase {
  func testAlreadyCancelledRequestDoesNotRegisterNativeWork() async throws {
    let request = try ControlledFrameRequest()
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await generate(request)
    }
    await assertCancellation(task)
    XCTAssertTrue(request.events.isEmpty)
  }

  func testCancellationAtRegistrationRunsAfterNativeWorkRegisters() async throws {
    let request = try ControlledFrameRequest()
    let task = Task {
      try await VideoFrameExtractor.generatedFrame { completion in
        // Cancel in the last window before the synchronous native registration.
        withUnsafeCurrentTask { $0?.cancel() }
        request.register(completion)
      } cancel: {
        request.cancel()
      }
    }
    await assertCancellation(task)
    XCTAssertEqual(request.events, ["registered", "cancelled"])
    XCTAssertNil(request.completion)
  }

  func testCancellingOutstandingRequestStopsItsNativeWork() async throws {
    let request = try ControlledFrameRequest()
    let started = expectation(description: "native request registered")
    let task = Task {
      try await VideoFrameExtractor.generatedFrame { completion in
        request.register(completion)
        started.fulfill()
      } cancel: {
        request.cancel()
      }
    }
    await fulfillment(of: [started], timeout: 3)
    task.cancel()
    await assertCancellation(task)
    XCTAssertEqual(request.events, ["registered", "cancelled"])
    XCTAssertNil(request.completion)
  }

  func testNativeSuccessRacingTaskCancellationDoesNotReturnFrame() async throws {
    let request = try ControlledFrameRequest()
    let cancelled = expectation(description: "native cancellation forwarded")
    let task = Task {
      try await VideoFrameExtractor.generatedFrame { completion in
        request.register(completion)
        withUnsafeCurrentTask { $0?.cancel() }
        request.finishSuccessfully()
      } cancel: {
        request.cancel()
        cancelled.fulfill()
      }
    }
    await assertCancellation(task)
    await fulfillment(of: [cancelled], timeout: 3)
    XCTAssertEqual(request.events, ["registered", "completed", "cancelled"])
  }

  private func generate(_ request: ControlledFrameRequest) async throws -> ExtractedVideoFrame {
    try await VideoFrameExtractor.generatedFrame(start: request.register, cancel: request.cancel)
  }

  private func assertCancellation(_ task: Task<ExtractedVideoFrame, any Error>) async {
    do {
      _ = try await task.value
      XCTFail("A cancelled extraction must not return a frame")
    } catch is CancellationError {
    } catch {
      XCTFail("Expected CancellationError, got \(error)")
    }
  }
}

@MainActor
private final class ControlledFrameRequest {
  let frame: ExtractedVideoFrame
  private(set) var events: [String] = []
  private(set) var completion: (@Sendable (Result<ExtractedVideoFrame, any Error>) -> Void)?
  private var cancelledBeforeRegistration = false

  init() throws {
    let provider = try XCTUnwrap(CGDataProvider(data: Data([128]) as CFData))
    let image = try XCTUnwrap(CGImage(
      width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: 1,
      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
    ))
    frame = ExtractedVideoFrame(image: image, actualTime: .zero)
  }

  func register(_ completion: @escaping @Sendable (Result<ExtractedVideoFrame, any Error>) -> Void) {
    events.append("registered")
    self.completion = completion
    if cancelledBeforeRegistration {
      // Native cancel affects only outstanding requests. Future work still runs.
      // Finish it so a broken ordering fails the assertion without hanging.
      finishSuccessfully()
    }
  }

  func cancel() {
    events.append("cancelled")
    guard let completion else {
      cancelledBeforeRegistration = true
      return
    }
    self.completion = nil
    completion(.failure(VideoFrameExtractionError.frameUnavailable(cause: CancellationError())))
  }

  func finishSuccessfully() {
    guard let completion else { return }
    self.completion = nil
    events.append("completed")
    completion(.success(frame))
  }
}
