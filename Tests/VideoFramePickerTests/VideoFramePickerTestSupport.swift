import AVFoundation
import UIKit
import XCTest
@testable import VideoFramePicker

enum PickerTestError: Error { case failed, timeout }

@MainActor
func waitForPicker(_ condition: @MainActor () -> Bool) async throws {
  for _ in 0..<500 {
    if condition() { return }
    try await Task.sleep(for: .milliseconds(10))
  }
  throw PickerTestError.timeout
}

/// Deliberately ignores cancellation until the test completes the operation.
/// The result stays actor isolated; no borrowed AVAsset crosses executors.
@MainActor
final class PickerGate<Value> {
  private var continuation: CheckedContinuation<Void, Never>?
  private var result: Result<Value, any Error>?
  private(set) var started = false
  private(set) var cancelled = false

  func run() async throws -> Value {
    started = true
    await withTaskCancellationHandler {
      if result == nil { await withCheckedContinuation { continuation = $0 } }
    } onCancel: {
      Task { @MainActor [weak self] in self?.cancelled = true }
    }
    return try XCTUnwrap(result).get()
  }

  func finish(_ result: Result<Value, any Error>) {
    self.result = result
    continuation?.resume()
    continuation = nil
  }
}

@MainActor
final class PickerFrames {
  struct Request {
    let seconds: Double
    let maximumSize: CGSize
    let gate: PickerGate<VideoFrameSelection>
  }
  private(set) var requests: [Request] = []

  func extract(_ asset: AVAsset, seconds: Double, maximumSize: CGSize) async throws -> VideoFrameSelection {
    let gate = PickerGate<VideoFrameSelection>()
    requests.append(Request(seconds: seconds, maximumSize: maximumSize, gate: gate))
    return try await gate.run()
  }

  func succeed(_ index: Int, actualSeconds: Double? = nil) {
    let request = requests[index]
    let image = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 12)).image { context in
      UIColor.orange.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 16, height: 12))
    }.cgImage!
    request.gate.finish(.success(VideoFrameSelection(
      image: image, requestedSeconds: request.seconds,
      actualTime: CMTime(seconds: actualSeconds ?? request.seconds, preferredTimescale: 600)
    )))
  }

  func fail(_ index: Int, error: any Error = PickerTestError.failed) {
    requests[index].gate.finish(.failure(error))
  }

  func finishOutstanding() {
    for request in requests { request.gate.finish(.failure(CancellationError())) }
  }
}

@MainActor
final class PickerFixture {
  let frames = PickerFrames()
  let owner: VideoFramePickerOwner
  let asset = AVMutableComposition()
  private(set) var failures: [VideoFramePickerFailure] = []
  private(set) var selections: [VideoFrameSelection] = []

  init(duration: CMTime = CMTime(seconds: 10, preferredTimescale: 600)) {
    let frames = frames
    owner = VideoFramePickerOwner(inspectAsset: { _ in duration }, extractFrame: frames.extract)
  }

  var callbacks: VideoFramePickerCallbacks {
    VideoFramePickerCallbacks(
      onFailure: { [weak self] in self?.failures.append($0) },
      onSelection: { [weak self] in self?.selections.append($0) }
    )
  }

  func start(identity: String = "video", initialTime: Double? = nil) {
    let asset = asset
    owner.start(
      source: VideoFramePickerSource(identity: identity, load: { .init(asset: asset) }),
      initialTime: initialTime, maximumFrameSize: CGSize(width: 1280, height: 1280),
      onFailure: callbacks.onFailure
    )
  }

  func ready() async throws {
    start()
    try await waitForPicker { self.frames.requests.count == 1 }
    frames.succeed(0, actualSeconds: 0.9)
    try await waitForPicker { self.owner.preview != nil }
  }

  func stop() {
    owner.stop()
    frames.finishOutstanding()
  }
}
