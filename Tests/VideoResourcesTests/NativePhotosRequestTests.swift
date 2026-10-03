import AVFoundation
import Foundation
import Photos
import XCTest
@testable import VideoResources

/// These tests observe the native request/cancel seam. They do not claim that
/// a physical Photos download stopped or that an audio mix was rendered.
@MainActor
final class NativePhotosRequestTests: XCTestCase {
  func testCancellationBeforeNativeIDReturnsCancelsThatRequestOnce() async {
    let probe = NativeRequestProbe()
    let bridge = NativePhotosVideoRequest(
      request: { _, _, completion in
        probe.register(completion)
        withUnsafeCurrentTask { $0?.cancel() }
        return 71
      },
      cancelRequest: { probe.recordCancellation($0) }
    )
    let task = Task { try await bridge.load(asset: PHAsset(), options: PHVideoRequestOptions()) }

    await assertCancellation(of: task)
    XCTAssertEqual(probe.cancelledRequests, [71])
    probe.complete(asset: AVMutableComposition())
    XCTAssertEqual(probe.cancelledRequests, [71])
  }

  func testAlreadyCancelledTaskDoesNotStartANativeRequest() async {
    let probe = NativeRequestProbe()
    let bridge = NativePhotosVideoRequest(
      request: { _, _, completion in
        probe.register(completion)
        return 72
      },
      cancelRequest: { probe.recordCancellation($0) }
    )
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await bridge.load(asset: PHAsset(), options: PHVideoRequestOptions())
    }

    await assertCancellation(of: task)
    XCTAssertEqual(probe.startedRequests, 0)
    XCTAssertTrue(probe.cancelledRequests.isEmpty)
  }

  func testCancellationAfterNativeIDRegistrationCancelsThatRequestOnce() async {
    let started = expectation(description: "native request started")
    let probe = NativeRequestProbe()
    let bridge = NativePhotosVideoRequest(
      request: { _, _, completion in
        probe.register(completion)
        started.fulfill()
        return 73
      },
      cancelRequest: { probe.recordCancellation($0) }
    )
    let task = Task { try await bridge.load(asset: PHAsset(), options: PHVideoRequestOptions()) }
    await fulfillment(of: [started], timeout: 1)

    task.cancel()
    await assertCancellation(of: task)
    XCTAssertEqual(probe.cancelledRequests, [73])
    probe.complete(asset: AVMutableComposition())
    probe.complete(info: [PHImageCancelledKey: true])
    XCTAssertEqual(probe.cancelledRequests, [73])
  }

  func testSynchronousSuccessPreservesAssetAndMixWithoutCancellingNativeRequest() async throws {
    let probe = NativeRequestProbe()
    let asset = AVMutableComposition()
    let mix = AVMutableAudioMix()
    let bridge = NativePhotosVideoRequest(
      request: { _, _, completion in
        probe.register(completion)
        completion(asset, mix, nil)
        return 74
      },
      cancelRequest: { probe.recordCancellation($0) }
    )

    let representation = try await bridge.load(asset: PHAsset(), options: PHVideoRequestOptions())
    XCTAssertTrue(representation.asset === asset)
    XCTAssertTrue(representation.audioMix === mix)
    XCTAssertTrue(probe.cancelledRequests.isEmpty)

    // A later callback cannot replace the first result or resume it again.
    probe.complete(asset: AVMutableComposition(), audioMix: AVMutableAudioMix())
    probe.complete(info: [PHImageCancelledKey: true])
    XCTAssertTrue(representation.asset === asset)
    XCTAssertTrue(representation.audioMix === mix)
    XCTAssertTrue(probe.cancelledRequests.isEmpty)
  }

  func testSynchronousFailureCancelsIDWhenItReturnsAndIgnoresLateSuccess() async {
    let probe = NativeRequestProbe()
    let bridge = NativePhotosVideoRequest(
      request: { _, _, completion in
        probe.register(completion)
        completion(nil, nil, [PHImageResultIsInCloudKey: true])
        return 75
      },
      cancelRequest: { probe.recordCancellation($0) }
    )

    do {
      _ = try await bridge.load(asset: PHAsset(), options: PHVideoRequestOptions())
      XCTFail("A missing cloud representation must require network access")
    } catch {
      XCTAssertEqual(error as? VideoResourceFailure, .networkRequired)
    }
    XCTAssertEqual(probe.cancelledRequests, [75])
    probe.complete(asset: AVMutableComposition())
    probe.complete(info: [PHImageCancelledKey: true])
    XCTAssertEqual(probe.cancelledRequests, [75])
  }

  func testNativeErrorIsTypedAndDoesNotEscapeWithDiagnosticDetail() async {
    let probe = NativeRequestProbe()
    let rawError = NSError(
      domain: "FixtureNativeError", code: 908,
      userInfo: [NSLocalizedDescriptionKey: "fixture diagnostic detail"]
    )
    let bridge = NativePhotosVideoRequest(
      request: { _, _, completion in
        probe.register(completion)
        completion(nil, nil, [PHImageErrorKey: rawError])
        return 76
      },
      cancelRequest: { probe.recordCancellation($0) }
    )

    do {
      _ = try await bridge.load(asset: PHAsset(), options: PHVideoRequestOptions())
      XCTFail("A native failure must remain a failure")
    } catch {
      XCTAssertEqual(error as? VideoResourceFailure, .acquisitionFailed)
    }
    XCTAssertEqual(probe.cancelledRequests, [76])
  }

  func testSuccessfulCallbackFollowedByTaskCancellationStillReturnsCancellation() async {
    let probe = NativeRequestProbe()
    let bridge = NativePhotosVideoRequest(
      request: { _, _, completion in
        probe.register(completion)
        completion(AVMutableComposition(), AVMutableAudioMix(), nil)
        withUnsafeCurrentTask { $0?.cancel() }
        return 77
      },
      cancelRequest: { probe.recordCancellation($0) }
    )
    let task = Task { try await bridge.load(asset: PHAsset(), options: PHVideoRequestOptions()) }

    await assertCancellation(of: task)
    // The native request already completed successfully; only the caller's
    // cancelled task rejects consumption of that result.
    XCTAssertTrue(probe.cancelledRequests.isEmpty)
  }

  private func assertCancellation(
    of task: Task<VideoRepresentation, Error>,
    file: StaticString = #filePath, line: UInt = #line
  ) async {
    switch await task.result {
    case .success:
      XCTFail("A cancelled consumer must finish with cancellation", file: file, line: line)
    case .failure(let error):
      XCTAssertTrue(error is CancellationError, file: file, line: line)
    }
  }
}

private final class NativeRequestProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var completion: NativePhotosVideoRequest.ResultHandler?
  private var starts = 0
  private var cancellations: [PHImageRequestID] = []

  var startedRequests: Int { lock.withLock { starts } }
  var cancelledRequests: [PHImageRequestID] { lock.withLock { cancellations } }

  func register(_ completion: @escaping NativePhotosVideoRequest.ResultHandler) {
    lock.withLock {
      self.completion = completion
      starts += 1
    }
  }

  func recordCancellation(_ requestID: PHImageRequestID) {
    lock.withLock { cancellations.append(requestID) }
  }

  func complete(
    asset: AVAsset? = nil, audioMix: AVAudioMix? = nil, info: [AnyHashable: Any]? = nil
  ) {
    let callback = lock.withLock { completion }
    callback?(asset, audioMix, info)
  }
}
