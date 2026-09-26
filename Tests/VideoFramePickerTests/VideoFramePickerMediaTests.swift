import AVFoundation
import UIKit
import XCTest
@testable import VideoFramePicker

@MainActor
final class VideoFramePickerMediaTests: XCTestCase {
  func testRealInitialPipelineHandlesLandscapePortraitRotationAndFrameBudget() async throws {
    let fixtures: [(Int, Int, Bool)] = [(1600, 900, false), (96, 128, false), (128, 96, true)]
    for (width, height, rotated) in fixtures {
      let asset = try await makeVideo(width: width, height: height, frameCount: 1, rotated: rotated)
      let owner = VideoFramePickerOwner()
      owner.start(
        source: VideoFramePickerSource(identity: UUID(), load: { asset }),
        initialTime: 0, maximumFrameSize: CGSize(width: 1280, height: 1280), onFailure: { _ in }
      )
      try await waitForPicker { owner.preview != nil || owner.failure != nil }
      XCTAssertNil(owner.failure)
      let preview = try XCTUnwrap(owner.preview)
      XCTAssertEqual(preview.requestedSeconds, 0)
      XCTAssertEqual(preview.actualTime.seconds, 0, accuracy: 0.001)
      XCTAssertLessThanOrEqual(preview.image.width, 1280)
      XCTAssertLessThanOrEqual(preview.image.height, 1280)
      if rotated || height > width {
        XCTAssertLessThan(preview.image.width, preview.image.height)
      } else {
        XCTAssertGreaterThan(preview.image.width, preview.image.height)
        XCTAssertEqual(preview.image.width, 1280)
      }
      XCTAssertFalse(owner.hasPendingSelection)
      owner.stop()
    }
  }

  func testRealUserSelectionReturnsDecodedFrameInPausedMutedPlayer() async throws {
    let asset = try await makeVideo(width: 128, height: 96, frameCount: 30)
    let owner = VideoFramePickerOwner()
    defer { owner.stop() }
    var selections: [VideoFrameSelection] = []
    owner.start(
      source: VideoFramePickerSource(identity: "real", load: { asset }),
      initialTime: 0, maximumFrameSize: CGSize(width: 1280, height: 1280), onFailure: { _ in }
    )
    try await waitForPicker { owner.preview != nil || owner.failure != nil }
    XCTAssertNil(owner.failure)
    owner.changeSeconds(0.5, callbacks: VideoFramePickerCallbacks(
      onFailure: { _ in XCTFail("Expected a decodable frame at 0.5 seconds") },
      onSelection: { selections.append($0) }
    ))
    try await waitForPicker { selections.count == 1 || owner.failure != nil }
    let selection = try XCTUnwrap(selections.first)
    XCTAssertEqual(selection.requestedSeconds, 0.5)
    XCTAssertEqual(selection.actualTime.seconds, 0.5, accuracy: 0.001)
    XCTAssertEqual(selection.image.width, 128)
    XCTAssertEqual(selection.image.height, 96)
    XCTAssertEqual(owner.player?.rate, 0)
    XCTAssertTrue(owner.player?.isMuted == true)
    XCTAssertFalse(owner.hasPendingSelection)
  }

  func testRealEndpointReturnsActualEncodedTimeOrTypedFrameFailure() async throws {
    let asset = try await makeVideo(width: 128, height: 96, frameCount: 3)
    let owner = VideoFramePickerOwner()
    defer { owner.stop() }
    var selection: VideoFrameSelection?
    owner.start(
      source: VideoFramePickerSource(identity: "endpoint", load: { asset }),
      initialTime: 0, maximumFrameSize: CGSize(width: 1280, height: 1280), onFailure: { _ in }
    )
    try await waitForPicker { owner.preview != nil || owner.failure != nil }
    XCTAssertNil(owner.failure)
    let duration = owner.duration
    owner.changeSeconds(duration, callbacks: VideoFramePickerCallbacks(
      onFailure: { _ in }, onSelection: { selection = $0 }
    ))
    try await waitForPicker { !owner.hasPendingSelection }
    if let selection {
      XCTAssertEqual(selection.requestedSeconds, duration)
      XCTAssertTrue(selection.actualTime.isNumeric)
      XCTAssertTrue((0..<duration).contains(selection.actualTime.seconds))
    } else {
      guard case .frame = owner.failure else { return XCTFail("Expected a typed frame failure") }
      XCTAssertEqual(owner.preview?.requestedSeconds, 0, "Keep the last usable image")
    }
  }

  func testRealMissingVideoAndUnreadableFileProduceSourceFailure() async throws {
    let badURL = temporaryURL()
    try Data("invalid video".utf8).write(to: badURL)
    for asset in [AVMutableComposition(), AVURLAsset(url: badURL)] as [AVAsset] {
      let owner = VideoFramePickerOwner()
      owner.start(
        source: VideoFramePickerSource(identity: UUID(), load: { asset }),
        initialTime: 0, maximumFrameSize: CGSize(width: 1280, height: 1280), onFailure: { _ in }
      )
      try await waitForPicker { owner.failure != nil }
      guard case .source = owner.failure else {
        owner.stop()
        return XCTFail("Expected a source failure")
      }
      XCTAssertNil(owner.player)
      XCTAssertNil(owner.preview)
      XCTAssertTrue(owner.isSliderDisabled)
      owner.stop()
    }
  }

  private func makeVideo(
    width: Int, height: Int, frameCount: Int, rotated: Bool = false
  ) async throws -> AVURLAsset {
    let url = temporaryURL()
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height
    ])
    if rotated {
      input.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: CGFloat(height), ty: 0)
    }
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height
    ])
    writer.add(input)
    XCTAssertTrue(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    for frame in 0..<frameCount {
      while !input.isReadyForMoreMediaData {
        guard writer.status == .writing else { throw try XCTUnwrap(writer.error) }
        await Task.yield()
      }
      var buffer: CVPixelBuffer?
      XCTAssertEqual(
        CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &buffer), kCVReturnSuccess
      )
      let pixel = try XCTUnwrap(buffer)
      CVPixelBufferLockBaseAddress(pixel, [])
      let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixel)).assumingMemoryBound(to: UInt8.self)
      let stride = CVPixelBufferGetBytesPerRow(pixel)
      for y in 0..<height {
        for x in 0..<width {
          let position = y * stride + x * 4
          let value: UInt8 = (x / 8 + y / 8).isMultiple(of: 2) ? 220 : 30
          bytes[position] = value
          bytes[position + 1] = value
          bytes[position + 2] = UInt8(40 + frame)
          bytes[position + 3] = 255
        }
      }
      CVPixelBufferUnlockBaseAddress(pixel, [])
      XCTAssertTrue(adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
    }
    writer.endSession(atSourceTime: CMTime(value: Int64(frameCount), timescale: 30))
    input.markAsFinished()
    await writer.finishWriting()
    XCTAssertEqual(writer.status, .completed)
    return AVURLAsset(url: url)
  }

  private func temporaryURL() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("picker-media-\(UUID()).mov")
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }
}
