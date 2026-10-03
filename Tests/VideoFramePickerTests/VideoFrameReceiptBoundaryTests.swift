import AVFoundation
import CoreVideo
import Foundation
import Observation
import VideoPlayback
import VideoProcessing
import XCTest
@testable import VideoFramePicker

@MainActor
final class VideoFrameReceiptBoundaryTests: XCTestCase {
  func testReceiptExpiringDuringInspectionCannotInstallPlayerOrStartFrame() async throws {
    let asset = try await movie()
    let authority = FrameBoundaryAuthority()
    let inspection = PickerGate<CMTime>()
    let frames = PickerFrames()
    let owner = VideoFramePickerOwner(inspectAsset: { _ in try await inspection.run() },
      extractFrame: frames.extract)
    defer { owner.stop(); inspection.finish(.success(CMTime(seconds: 2, preferredTimescale: 600))); frames.finishOutstanding() }
    start(owner, asset: asset, authority: authority)
    try await waitForPicker { inspection.started }
    authority.isCurrent = false
    inspection.finish(.success(CMTime(seconds: 2, preferredTimescale: 600)))
    try await waitForPicker { owner.failure != nil || owner.player != nil }

    XCTAssertNil(owner.player)
    XCTAssertNil(owner.preview)
    XCTAssertEqual(frames.requests.count, 0,
      "A representation that expired across inspection cannot start extraction")
    guard case .source(_, let cause) = owner.failure else { return XCTFail("Expected source failure") }
    XCTAssertEqual(cause as? FrameReceiptBoundaryError, .expired)
  }

  func testReceiptExpiringDuringUserFrameExtractionCannotPublishOrDeliverSelection() async throws {
    let asset = try await movie()
    let authority = FrameBoundaryAuthority()
    let frames = PickerFrames()
    let owner = VideoFramePickerOwner(inspectAsset: { _ in CMTime(seconds: 2, preferredTimescale: 600) },
      extractFrame: frames.extract)
    defer { owner.stop(); frames.finishOutstanding() }
    start(owner, asset: asset, authority: authority)
    try await waitForPicker { frames.requests.count == 1 }
    frames.succeed(0)
    try await waitForPicker { owner.preview != nil }
    var selectionCount = 0
    owner.changeSeconds(0.5, callbacks: VideoFramePickerCallbacks(onFailure: { _ in },
      onSelection: { _ in selectionCount += 1 }))
    try await waitForPicker { frames.requests.count == 2 }
    authority.isCurrent = false
    frames.succeed(1)
    try await waitForPicker {
      owner.failure != nil || owner.preview?.requestedSeconds == 0.5 || selectionCount > 0
    }

    XCTAssertNotEqual(owner.preview?.requestedSeconds, 0.5)
    XCTAssertEqual(selectionCount, 0)
    guard case .frame(let cause) = owner.failure else { return XCTFail("Expected frame failure") }
    XCTAssertEqual(cause as? FrameReceiptBoundaryError, .expired)
  }

  func testSelectionFinalGateRejectsCommitAfterHostSuspensionAndReceiptExpiry() async throws {
    let asset = try await movie()
    let authority = FrameBoundaryAuthority()
    let frames = PickerFrames()
    let host = PickerGate<Void>()
    let owner = VideoFramePickerOwner(inspectAsset: { _ in CMTime(seconds: 2, preferredTimescale: 600) },
      extractFrame: frames.extract)
    defer { owner.stop(); frames.finishOutstanding(); host.finish(.success(())) }
    start(owner, asset: asset, authority: authority)
    try await waitForPicker { frames.requests.count == 1 }
    frames.succeed(0)
    try await waitForPicker { owner.preview != nil }
    var committed = false
    owner.changeSeconds(0.5, callbacks: VideoFramePickerCallbacks(onFailure: { _ in },
      onSelection: { selection in
        try await host.run()
        try selection.validate()
        committed = true
      }))
    try await waitForPicker { frames.requests.count == 2 }
    frames.succeed(1)
    try await waitForPicker { host.started }
    authority.isCurrent = false
    host.finish(.success(()))
    try await waitForPicker { owner.failure != nil || committed }

    XCTAssertFalse(committed, "The host checks the carried actual receipt at its final mutation boundary")
    guard case .selectionProcessing(let cause) = owner.failure else {
      return XCTFail("Expected selection processing failure")
    }
    XCTAssertEqual(cause as? FrameReceiptBoundaryError, .expired)
  }

  func testCapturedSelectionBecomesCancelledAfterStopSourceChangeDeinitOrNewRequest() async throws {
    let asset = try await movie()
    for invalidation in FrameSelectionInvalidation.allCases {
      let authority = FrameBoundaryAuthority()
      let frames = PickerFrames()
      var owner: VideoFramePickerOwner? = VideoFramePickerOwner(
        inspectAsset: { _ in CMTime(seconds: 2, preferredTimescale: 600) }, extractFrame: frames.extract)
      weak var releasedOwner = owner
      defer { owner?.stop(); frames.finishOutstanding() }
      start(try XCTUnwrap(owner), asset: asset, authority: authority)
      try await waitForPicker { frames.requests.count == 1 }
      frames.succeed(0)
      try await waitForPicker { owner?.preview != nil }
      let selection = try XCTUnwrap(owner?.preview)
      try selection.validate()
      switch invalidation {
      case .stop: owner?.stop()
      case .sourceChange:
        start(try XCTUnwrap(owner), asset: asset, authority: authority, identity: "new-source")
      case .deinitOwner: owner = nil
      case .newRequest:
        owner?.changeSeconds(0.5, callbacks: VideoFramePickerCallbacks(onFailure: { _ in }, onSelection: { _ in }))
      }
      if invalidation == .deinitOwner {
        XCTAssertNil(releasedOwner, "A carried selection must not retain its picker owner")
      }
      do {
        try selection.validate()
        XCTFail("Selection must be cancelled after \(invalidation)")
      } catch is CancellationError {
      } catch { XCTFail("Expected lifecycle cancellation after \(invalidation), got \(error)") }
    }
  }

  func testStopDuringPreviewPublicationPreventsSelectionCallback() async throws {
    let asset = try await movie()
    let authority = FrameBoundaryAuthority()
    let frames = PickerFrames()
    let owner = VideoFramePickerOwner(inspectAsset: { _ in CMTime(seconds: 2, preferredTimescale: 600) },
      extractFrame: frames.extract)
    defer { owner.stop(); frames.finishOutstanding() }
    start(owner, asset: asset, authority: authority)
    try await waitForPicker { frames.requests.count == 1 }
    frames.succeed(0)
    try await waitForPicker { owner.preview != nil }
    let observation = FrameBoundaryObservation()
    var selectionCount = 0
    withObservationTracking { _ = owner.preview } onChange: {
      MainActor.assumeIsolated {
        guard !observation.fired else { return }
        observation.fired = true
        owner.stop()
      }
    }
    owner.changeSeconds(0.5, callbacks: VideoFramePickerCallbacks(onFailure: { _ in },
      onSelection: { _ in selectionCount += 1 }))
    try await waitForPicker { frames.requests.count == 2 }
    frames.succeed(1)
    try await waitForPicker { observation.fired }
    try await Task.sleep(for: .milliseconds(50))

    XCTAssertEqual(selectionCount, 0,
      "Synchronous preview publication can stop the owner before onSelection is invoked")
    XCTAssertNil(owner.player)
    XCTAssertNil(owner.preview, "Stop during publication must not let the old setter restore a stale preview")
    XCTAssertFalse(owner.hasPendingSelection)
  }

  func testLoadedMediaValidatorChangingSourceCannotPublishOrExtractOldSource() async throws {
    let assetA = try await movie()
    let assetB = try await movie(blue: true)
    let observation = FrameBoundaryObservation()
    var extractedAssets: [AVAsset] = []
    var failureCount = 0
    let owner = VideoFramePickerOwner(
      inspectAsset: { _ in CMTime(seconds: 2, preferredTimescale: 600) },
      extractFrame: { asset, seconds, maximumSize in
        extractedAssets.append(asset)
        let frame = try await VideoFrameExtractor.frame(
          for: asset, at: seconds, maximumSize: maximumSize, exact: true)
        return VideoFrameSelection(image: frame.image, requestedSeconds: seconds, actualTime: frame.actualTime)
      })
    weak var weakOwner = owner
    defer { owner.stop() }
    let sourceB = VideoFramePickerSource(identity: "validator-selected-B", load: {
      PlaybackLoadedMedia(asset: assetB)
    })
    owner.start(source: VideoFramePickerSource(identity: "old-A", load: {
      PlaybackLoadedMedia(asset: assetA, validate: {
        guard !observation.fired else { return }
        observation.fired = true
        weakOwner?.start(source: sourceB, initialTime: 0.5,
          maximumFrameSize: CGSize(width: 64, height: 64), onFailure: { _ in failureCount += 1 })
      })
    }), initialTime: 0, maximumFrameSize: CGSize(width: 64, height: 64),
      onFailure: { _ in failureCount += 1 })
    try await waitForPicker { owner.preview != nil || owner.failure != nil }

    XCTAssertTrue(observation.fired, "The actual loaded-media validator must run at the use boundary")
    XCTAssertTrue(owner.player?.currentItem?.asset === assetB)
    XCTAssertEqual(owner.selectedSeconds, 0.5, accuracy: 0.001)
    XCTAssertEqual(owner.preview?.requestedSeconds, 0.5)
    XCTAssertFalse(extractedAssets.isEmpty)
    XCTAssertTrue(extractedAssets.allSatisfy { $0 === assetB },
      "Starting B synchronously from validation must prevent old A from extracting a frame")
    XCTAssertEqual(failureCount, 0)
    XCTAssertNil(owner.failure)
  }

  func testSelectionValidatorStartingNewRequestCancelsOldSelectionAndNewRequestCompletes() async throws {
    let asset = try await movie()
    let state = FrameBoundaryReentrantValidation()
    var delivered: [VideoFrameSelection] = []
    var failureCount = 0
    let callbacks = VideoFramePickerCallbacks(onFailure: { _ in failureCount += 1 },
      onSelection: { delivered.append($0) })
    let owner = VideoFramePickerOwner(
      inspectAsset: { _ in CMTime(seconds: 2, preferredTimescale: 600) },
      extractFrame: { asset, seconds, maximumSize in
        let frame = try await VideoFrameExtractor.frame(
          for: asset, at: seconds, maximumSize: maximumSize, exact: true)
        return VideoFrameSelection(image: frame.image, requestedSeconds: seconds, actualTime: frame.actualTime)
      })
    weak var weakOwner = owner
    defer { owner.stop() }
    owner.start(source: VideoFramePickerSource(identity: "reentrant-frame-validator", load: {
      PlaybackLoadedMedia(asset: asset, validate: {
        guard state.armed, !state.fired else { return }
        state.fired = true
        weakOwner?.changeSeconds(0.5, callbacks: callbacks)
      })
    }), initialTime: 0, maximumFrameSize: CGSize(width: 64, height: 64),
      onFailure: { _ in failureCount += 1 })
    try await waitForPicker { owner.preview != nil || owner.failure != nil }
    XCTAssertNil(owner.failure)
    let oldSelection = try XCTUnwrap(owner.preview)
    state.armed = true

    do {
      try oldSelection.validate()
      XCTFail("A synchronous new request inside validation must cancel the selection being validated")
    } catch is CancellationError {
    } catch { XCTFail("Expected request cancellation, got \(error)") }
    guard state.fired else { return XCTFail("The carried actual validator must execute") }
    try await waitForPicker { delivered.count == 1 || owner.failure != nil }

    XCTAssertNil(owner.failure)
    XCTAssertEqual(failureCount, 0)
    XCTAssertEqual(delivered.count, 1)
    XCTAssertEqual(delivered.first?.requestedSeconds, 0.5)
    XCTAssertEqual(owner.preview?.requestedSeconds, 0.5)
    XCTAssertTrue(owner.player?.currentItem?.asset === asset)
    try XCTUnwrap(delivered.first).validate()
  }

  func testStopDuringPendingSelectionPublicationKeepsActivityCleared() async throws {
    let asset = try await movie()
    let authority = FrameBoundaryAuthority()
    let frames = PickerFrames()
    let owner = VideoFramePickerOwner(inspectAsset: { _ in CMTime(seconds: 2, preferredTimescale: 600) },
      extractFrame: frames.extract)
    defer { owner.stop(); frames.finishOutstanding() }
    start(owner, asset: asset, authority: authority)
    try await waitForPicker { frames.requests.count == 1 }
    frames.succeed(0)
    try await waitForPicker { owner.preview != nil }
    let observation = FrameBoundaryObservation()
    var selectionCount = 0
    withObservationTracking { _ = owner.hasPendingSelection } onChange: {
      MainActor.assumeIsolated {
        guard !observation.fired else { return }
        observation.fired = true
        owner.stop()
      }
    }

    owner.changeSeconds(0.5, callbacks: VideoFramePickerCallbacks(onFailure: { _ in },
      onSelection: { _ in selectionCount += 1 }))
    XCTAssertTrue(observation.fired, "The fixture must stop synchronously during pending activity publication")
    try await Task.sleep(for: .milliseconds(50))

    XCTAssertFalse(owner.hasPendingSelection,
      "The old pending=true setter must not overwrite stop's cleared activity state")
    XCTAssertNil(owner.player)
    XCTAssertNil(owner.preview)
    XCTAssertEqual(selectionCount, 0)
  }

  func testStopDuringProcessingSelectionPublicationKeepsActivityCleared() async throws {
    let asset = try await movie()
    let authority = FrameBoundaryAuthority()
    let frames = PickerFrames()
    let owner = VideoFramePickerOwner(inspectAsset: { _ in CMTime(seconds: 2, preferredTimescale: 600) },
      extractFrame: frames.extract)
    defer { owner.stop(); frames.finishOutstanding() }
    start(owner, asset: asset, authority: authority)
    try await waitForPicker { frames.requests.count == 1 }
    frames.succeed(0)
    try await waitForPicker { owner.preview != nil }
    let observation = FrameBoundaryObservation()
    var selectionCount = 0
    withObservationTracking { _ = owner.isProcessingSelection } onChange: {
      MainActor.assumeIsolated {
        guard !observation.fired else { return }
        observation.fired = true
        owner.stop()
      }
    }

    owner.changeSeconds(0.5, callbacks: VideoFramePickerCallbacks(onFailure: { _ in },
      onSelection: { _ in selectionCount += 1 }))
    try await waitForPicker { frames.requests.count == 2 }
    frames.succeed(1)
    try await waitForPicker { observation.fired }
    try await Task.sleep(for: .milliseconds(50))

    XCTAssertFalse(owner.isProcessingSelection,
      "The old processing=true setter must not overwrite stop's cleared activity state")
    XCTAssertNil(owner.player)
    XCTAssertNil(owner.preview)
    XCTAssertEqual(selectionCount, 0)
  }

  private func start(_ owner: VideoFramePickerOwner, asset: AVAsset,
    authority: FrameBoundaryAuthority, identity: String = "actual-receipt") {
    owner.start(source: VideoFramePickerSource(identity: identity, load: {
      PlaybackLoadedMedia(asset: asset, validate: authority.validate)
    }), initialTime: 0, maximumFrameSize: CGSize(width: 64, height: 64), onFailure: { _ in })
  }

  private func movie(blue: Bool = false) async throws -> AVURLAsset {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("frame-receipt-\(UUID()).mov")
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64
      ])
    writer.add(input)
    guard writer.startWriting() else { throw try XCTUnwrap(writer.error) }
    writer.startSession(atSourceTime: .zero)
    for frame in 0..<12 {
      for _ in 0..<500 {
        if input.isReadyForMoreMediaData || writer.status != .writing { break }
        try await Task.sleep(for: .milliseconds(10))
      }
      guard input.isReadyForMoreMediaData, writer.status == .writing else {
        throw FrameReceiptMovieError.writerUnavailable
      }
      var buffer: CVPixelBuffer?
      XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &buffer), kCVReturnSuccess)
      let pixel = try XCTUnwrap(buffer)
      CVPixelBufferLockBaseAddress(pixel, [])
      let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixel)).assumingMemoryBound(to: UInt8.self)
      let stride = CVPixelBufferGetBytesPerRow(pixel)
      for y in 0..<64 {
        for x in 0..<64 {
          let position = y * stride + x * 4
          let value: UInt8 = (x / 8 + y / 8).isMultiple(of: 2) ? 220 : 60
          bytes[position] = blue ? value : 20
          bytes[position + 1] = 20
          bytes[position + 2] = blue ? 20 : value
          bytes[position + 3] = 255
        }
      }
      CVPixelBufferUnlockBaseAddress(pixel, [])
      XCTAssertTrue(adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 6)))
    }
    writer.endSession(atSourceTime: CMTime(value: 12, timescale: 6))
    input.markAsFinished()
    await writer.finishWriting()
    XCTAssertEqual(writer.status, .completed)
    return AVURLAsset(url: url)
  }
}

private enum FrameReceiptMovieError: Error { case writerUnavailable }
private enum FrameReceiptBoundaryError: Error, Equatable { case expired }
private enum FrameSelectionInvalidation: CaseIterable { case stop, sourceChange, deinitOwner, newRequest }

@MainActor
private final class FrameBoundaryAuthority {
  var isCurrent = true
  func validate() throws {
    guard isCurrent else { throw FrameReceiptBoundaryError.expired }
  }
}

@MainActor
private final class FrameBoundaryObservation {
  var fired = false
}

@MainActor
private final class FrameBoundaryReentrantValidation {
  var armed = false
  var fired = false
}
