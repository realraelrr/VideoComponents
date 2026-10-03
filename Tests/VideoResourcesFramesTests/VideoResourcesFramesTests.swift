import AVFoundation
import CoreVideo
import Foundation
import VideoResources
import VideoResourcesFrames
import XCTest
@testable import VideoFramePicker

@MainActor
final class VideoResourcesFramesTests: XCTestCase {
  func testPickerFactoriesAreLazyAndClosingOneSharedPickerDoesNotCancelAnother() async throws {
    let probe = FramesResourceProbe()
    let source = probe.resources().photosSource(serializedCloudIdentifier: "shared-picker")
    let firstSource = VideoResourcesFrames.pickerSource(source: source, identity: "first")
    let secondSource = VideoResourcesFrames.pickerSource(source: source, identity: "second")
    XCTAssertEqual(probe.invocations.count, 0, "Constructing a picker source acquires no resource")
    XCTAssertEqual(source.state, .idle)
    let first = VideoFramePickerOwner()
    let second = VideoFramePickerOwner()
    defer { first.stop(); second.stop(); probe.finishOutstanding() }
    let asset = try await movie()
    start(first, source: firstSource)
    start(second, source: secondSource)
    try await waitUntil { probe.invocations.count == 1 }
    await settle()
    first.stop()
    await settle()
    XCTAssertTrue(probe.cancelledIndices.isEmpty,
      "Each mounted picker owns a separate finite share of the shared request")
    probe.finish(0, with: .success(.init(asset: asset)))
    try await waitUntil { second.preview != nil || second.failure != nil }

    XCTAssertNil(second.failure)
    XCTAssertNotNil(second.preview)
    XCTAssertNil(first.player)
    XCTAssertNil(first.preview)
    XCTAssertTrue(source.preferred?.isCurrent == true)
    XCTAssertEqual(probe.invocations.count, 1)
    XCTAssertTrue(probe.cancelledIndices.isEmpty)
  }

  func testOnePickersFrameFailureDoesNotInvalidatePreferredOrAnotherPicker() async throws {
    let probe = FramesResourceProbe()
    let source = probe.resources().photosSource(serializedCloudIdentifier: "picker-frame-failure")
    let failing = VideoFramePickerOwner(extractFrame: { _, _, _ in throw FramesTestError.extractionDenied })
    let surviving = VideoFramePickerOwner()
    defer { failing.stop(); surviving.stop(); probe.finishOutstanding() }
    let asset = try await movie()
    start(failing, source: VideoResourcesFrames.pickerSource(source: source, identity: "failing"))
    start(surviving, source: VideoResourcesFrames.pickerSource(source: source, identity: "surviving"))
    try await waitUntil { probe.invocations.count == 1 }
    probe.finish(0, with: .success(.init(asset: asset)))
    try await waitUntil { failing.failure != nil && (surviving.preview != nil || surviving.failure != nil) }

    guard case .frame(let cause) = failing.failure else { return XCTFail("Expected a consumer-local frame failure") }
    XCTAssertEqual(cause as? FramesTestError, .extractionDenied)
    XCTAssertNil(surviving.failure)
    XCTAssertNotNil(surviving.preview)
    XCTAssertTrue(source.preferred?.isCurrent == true)
    XCTAssertTrue(source.preferred?.asset === asset)
    XCTAssertEqual(source.state, .available)
    XCTAssertEqual(probe.invocations.count, 1)
    failing.stop()
    XCTAssertTrue(source.preferred?.isCurrent == true)
    XCTAssertNotNil(surviving.player?.currentItem)
  }

  func testMountedPickerKeepsActualReceiptWhileNewFrameUsesPreferredHighQualityReceipt() async throws {
    let automatic = try await movie()
    let highest = try await movie(blue: true)
    var requests: [VideoRequest] = []
    let resources = VideoResources(photos: PhotosVideoProvider(authority: { _ in "same-visible-photo" },
      load: { _, request, _ in
        requests.append(request)
        return .init(asset: request.quality == .highest ? highest : automatic)
      }))
    let source = resources.photosSource(serializedCloudIdentifier: "two-representations")
    let owner = VideoFramePickerOwner()
    defer { owner.stop() }
    start(owner, source: VideoResourcesFrames.pickerSource(source: source, identity: "mounted-automatic"))
    try await waitUntil { owner.preview != nil || owner.failure != nil }
    XCTAssertNil(owner.failure)
    let original = try XCTUnwrap(source.preferred)
    XCTAssertTrue(original.asset === automatic)
    let hq = try await source.acquire(.init(quality: .highest))
    XCTAssertTrue(hq.asset === highest)
    XCTAssertEqual(source.preferred?.representationID, hq.representationID)
    XCTAssertTrue(original.isCurrent)

    var selected: VideoFrameSelection?
    owner.changeSeconds(0.5, callbacks: VideoFramePickerCallbacks(onFailure: { _ in },
      onSelection: { selected = $0 }))
    try await waitUntil { selected != nil || owner.failure != nil }
    XCTAssertNil(owner.failure)
    let oldSelection = try XCTUnwrap(selected)
    try oldSelection.validate()
    let oldColor = try color(oldSelection.image)
    XCTAssertGreaterThan(oldColor.red, oldColor.blue + 80,
      "A mounted picker's exact frame belongs to its actual automatic receipt")
    let extracted = try await VideoResourcesFrames.frame(source: source, request: .init(),
      at: 0, maximumSize: CGSize(width: 64, height: 64), exact: true)
    let newColor = try color(extracted.frame.image)
    XCTAssertGreaterThan(newColor.blue, newColor.red + 80)
    XCTAssertEqual(extracted.receipt.representationID, hq.representationID)
    XCTAssertTrue(extracted.receipt.asset === highest)
    XCTAssertTrue(extracted.receipt.isCurrent)
    XCTAssertEqual(requests.count, 2,
      "The frame helper reuses sufficient HQ evidence without reacquiring the source")
    try oldSelection.validate()
  }

  func testExportRejectsReceiptInvalidatedByNativeCompletionAndRemovesOnlyItsOutput() async throws {
    let asset = try await movie()
    var loads = 0
    let resources = VideoResources(photos: PhotosVideoProvider(authority: { _ in "export-photo" },
      load: { _, _, _ in loads += 1; return .init(asset: asset) }))
    let source = resources.photosSource(serializedCloudIdentifier: "export-boundary")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("receipt-export-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let sentinel = directory.appendingPathComponent("sentinel.txt")
    try Data("unrelated file".utf8).write(to: sentinel)
    var nativeCompleted = false
    do {
      let result = try await VideoResourcesFrames.export(source: source, rate: 0.5,
        outputDirectory: directory, onProgress: { progress in
          if progress == 1 {
            nativeCompleted = true
            source.invalidate()
          }
        })
      // Preserve evidence in directory until the oracle below; the binding owns
      // the obligation to discard an output it cannot transfer to the caller.
      XCTAssertFalse(result.receipt.isCurrent)
      XCTFail("An export cannot return success after its actual receipt expires at native completion")
    } catch {
      XCTAssertEqual(error as? VideoResourceFailure, .sourceChanged)
    }

    XCTAssertTrue(nativeCompleted, "The fixture must reach real AVFoundation export completion")
    XCTAssertEqual(loads, 1)
    let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    XCTAssertEqual(remaining, ["sentinel.txt"],
      "Failed final validation removes the current export output and preserves unrelated files")
    XCTAssertEqual(try Data(contentsOf: sentinel), Data("unrelated file".utf8))
  }

  func testExportCancelledAtNativeCompletionRejectsResultAndPreservesSharedReceipt() async throws {
    let asset = try await movie()
    var loads = 0
    let resources = VideoResources(photos: PhotosVideoProvider(authority: { _ in "cancellation-photo" },
      load: { _, _, _ in loads += 1; return .init(asset: asset) }))
    let source = resources.photosSource(serializedCloudIdentifier: "export-completion-cancel")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cancelled-receipt-export-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let sentinel = directory.appendingPathComponent("sentinel.txt")
    try Data("unrelated file".utf8).write(to: sentinel)
    let holder = FramesExportTaskHolder()
    var nativeCompleted = false
    defer { holder.task?.cancel(); holder.task = nil }
    holder.task = Task { @MainActor [weak holder] in
      _ = try await VideoResourcesFrames.export(source: source, rate: 0.5,
        outputDirectory: directory, onProgress: { [weak holder] progress in
          if progress == 1 {
            nativeCompleted = true
            holder?.task?.cancel()
          }
        })
      // Deliberately add no Task.checkCancellation here: the binding's final
      // return boundary must reject cancellation that follows native success.
    }
    do {
      try await XCTUnwrap(holder.task).value
      XCTFail("Cancellation at native completion must reject the exported result")
    } catch is CancellationError {
    } catch { XCTFail("Expected cancellation at the final return boundary, got \(error)") }
    holder.task = nil

    XCTAssertTrue(nativeCompleted, "The cancellation fixture must reach real native completion")
    XCTAssertEqual(loads, 1)
    XCTAssertTrue(source.preferred?.isCurrent == true,
      "Cancelling export output ownership does not invalidate the shared resource")
    XCTAssertEqual(source.state, .available)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["sentinel.txt"],
      "Only the cancelled operation's own completed output must be removed")
    XCTAssertEqual(try Data(contentsOf: sentinel), Data("unrelated file".utf8))
  }

  private func start(_ owner: VideoFramePickerOwner, source: VideoFramePickerSource) {
    owner.start(source: source, initialTime: 0, maximumFrameSize: CGSize(width: 64, height: 64),
      onFailure: { _ in })
  }

  private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<500 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw FramesTestError.timeout
  }

  private func settle() async { try? await Task.sleep(for: .milliseconds(50)) }

  private func color(_ image: CGImage) throws -> (red: Int, blue: Int) {
    var rgba = [UInt8](repeating: 0, count: 4)
    try rgba.withUnsafeMutableBytes { bytes in
      let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 1, height: 1,
        bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.interpolationQuality = .none
      context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    }
    return (Int(rgba[0]), Int(rgba[2]))
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
private enum FramesTestError: Error, Equatable { case timeout, extractionDenied }

/// Holds the native callback after cancellation so a shared consumer can finish
/// independently; no borrowed AVAsset is cancelled globally by a picker.
@MainActor
private final class FramesResourceProbe {
  struct Invocation {
    let request: VideoRequest
    var continuation: CheckedContinuation<VideoRepresentation, Error>?
  }
  private(set) var invocations: [Invocation] = []
  private(set) var cancelledIndices: [Int] = []

  func resources() -> VideoResources {
    VideoResources(photos: PhotosVideoProvider(authority: { "visible:\($0)" },
      load: { [self] _, request, _ in try await load(request) }))
  }

  func finish(_ index: Int, with result: Result<VideoRepresentation, Error>,
    file: StaticString = #filePath, line: UInt = #line) {
    guard invocations.indices.contains(index), let continuation = invocations[index].continuation else {
      XCTFail("Expected unfinished native request \(index)", file: file, line: line)
      return
    }
    invocations[index].continuation = nil
    continuation.resume(with: result)
  }

  func finishOutstanding() {
    for index in invocations.indices {
      guard let continuation = invocations[index].continuation else { continue }
      invocations[index].continuation = nil
      continuation.resume(throwing: CancellationError())
    }
  }

  private func load(_ request: VideoRequest) async throws -> VideoRepresentation {
    let index = invocations.count
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        invocations.append(Invocation(request: request, continuation: continuation))
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.cancelledIndices.append(index) }
    }
  }
}

@MainActor
private final class FramesExportTaskHolder {
  var task: Task<Void, any Error>?
}
