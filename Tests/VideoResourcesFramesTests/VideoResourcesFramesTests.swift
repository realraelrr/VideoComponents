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

  func testExportReportsActualPreparationAndContinuesOnlyAfterItsReceiptReturns() async throws {
    let probe = FramesProgressProbe()
    let source = probe.resources().photosSource(serializedCloudIdentifier: "export-preparation")
    let asset = try await movie()
    var preparation: VideoPreparation?
    var ended = 0
    var nativeProgress: [Double] = []
    let task = Task { @MainActor in
      try await VideoResourcesFrames.export(source: source, rate: 0.5,
        onPreparation: { handle, began in
          if began { preparation = handle } else {
            ended += 1
            if preparation === handle { preparation = nil }
          }
        }, onProgress: { progress in
          XCTAssertNil(preparation, "Native export begins after resource preparation ends")
          nativeProgress.append(progress)
        })
    }
    defer { task.cancel(); probe.finishOutstanding() }
    try await waitUntil { preparation != nil && probe.invocations.count == 1 }
    let handle = try XCTUnwrap(preparation)
    XCTAssertEqual(probe.invocations[0].request, .init(quality: .highest, network: .allowed))
    XCTAssertNil(handle.progress)
    probe.invocations[0].progress(0.42)
    try await waitUntil { handle.progress == 0.42 }
    XCTAssertTrue(nativeProgress.isEmpty)
    probe.invocations[0].progress(1)
    try await waitUntil { handle.progress == 1 }
    XCTAssertEqual(ended, 0, "Download progress 1 is not an accepted receipt")
    XCTAssertTrue(nativeProgress.isEmpty)
    probe.finish(0, with: .success(.init(asset: asset)))
    let output = try await task.value
    defer { try? FileManager.default.removeItem(at: output.url) }
    XCTAssertEqual(ended, 1)
    XCTAssertNil(preparation)
    XCTAssertEqual(nativeProgress.last, 1)
    XCTAssertTrue(output.receipt.isCurrent)
    XCTAssertEqual(probe.invocations.count, 1)
  }

  func testExportPreparationFailureEndsAndRetryUsesAcceptedHQWithoutAnotherLoad() async throws {
    let probe = FramesProgressProbe()
    let source = probe.resources().photosSource(serializedCloudIdentifier: "export-preparation-retry")
    let asset = try await movie()
    var ended = 0
    var nativeProgress: [Double] = []
    let task = Task { @MainActor in
      try await VideoResourcesFrames.export(source: source, rate: 0.5,
        onPreparation: { _, began in if !began { ended += 1 } },
        onProgress: { nativeProgress.append($0) })
    }
    defer { task.cancel(); probe.finishOutstanding() }
    try await waitUntil { probe.invocations.count == 1 }
    probe.finish(0, with: .failure(VideoResourceFailure.sourceUnavailable))
    do { _ = try await task.value; XCTFail("Failed resource preparation cannot export") }
    catch { XCTAssertEqual(error as? VideoResourceFailure, .sourceUnavailable) }
    XCTAssertEqual(ended, 1)
    XCTAssertTrue(nativeProgress.isEmpty)

    let manual = source.prepare(.init(quality: .highest, network: .allowed))
    defer { manual.cancel() }
    try await waitUntil { probe.invocations.count == 2 }
    probe.finish(1, with: .success(.init(asset: asset)))
    let accepted = try await manual.value()
    var callbacks: [Bool] = []
    let output = try await VideoResourcesFrames.export(source: source, rate: 0.5,
      onPreparation: { _, began in callbacks.append(began) }, onProgress: { _ in })
    defer { try? FileManager.default.removeItem(at: output.url) }
    XCTAssertEqual(callbacks, [true, false])
    XCTAssertEqual(output.receipt.representationID, accepted.representationID)
    XCTAssertEqual(probe.invocations.count, 2, "An already accepted HQ receipt does not download again")
  }

  func testCancellingExportPreparationLeavesManualHQShareAlive() async throws {
    let probe = FramesProgressProbe()
    let source = probe.resources().photosSource(serializedCloudIdentifier: "shared-export-hq")
    let asset = try await movie()
    let manual = source.prepare(.init(quality: .highest, network: .allowed))
    var exportHandle: VideoPreparation?
    var ended = 0
    let task = Task { @MainActor in
      try await VideoResourcesFrames.export(source: source, rate: 0.5,
        onPreparation: { handle, began in
          if began { exportHandle = handle } else { ended += 1 }
        }, onProgress: { _ in XCTFail("Cancelled preparation cannot start native export") })
    }
    defer { task.cancel(); manual.cancel(); probe.finishOutstanding() }
    try await waitUntil { exportHandle != nil && probe.invocations.count == 1 }
    probe.invocations[0].progress(0.42)
    try await waitUntil { exportHandle?.progress == 0.42 && manual.progress == 0.42 }
    task.cancel()
    do { _ = try await task.value; XCTFail("Expected export cancellation") }
    catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    XCTAssertEqual(ended, 1)
    await settle()
    XCTAssertTrue(probe.cancelledIndices.isEmpty)
    probe.finish(0, with: .success(.init(asset: asset)))
    let receipt = try await manual.value()
    XCTAssertTrue(receipt.isCurrent)
    XCTAssertEqual(probe.invocations.count, 1)
  }

  func testPreparationCallbacksCanSynchronouslyCancelExportBeforeNativeWork() async throws {
    let asset = try await movie()
    for cancelOnBegin in [true, false] {
      let resources = VideoResources(photos: PhotosVideoProvider(authority: { _ in "cancel-callback-photo" },
        load: { _, _, _ in .init(asset: asset) }))
      let source = resources.photosSource(serializedCloudIdentifier: "cancel-callback-export")
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent("preparation-cancel-\(UUID())")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: directory) }
      let holder = FramesExportTaskHolder()
      var callbacks: [Bool] = []
      holder.task = Task { @MainActor [weak holder] in
        _ = try await VideoResourcesFrames.export(source: source, rate: 0.5, outputDirectory: directory,
          onPreparation: { [weak holder] _, began in
            callbacks.append(began)
            if began == cancelOnBegin { holder?.task?.cancel() }
          }, onProgress: { _ in XCTFail("Preparation callback cancellation must precede native work") })
      }
      do { try await XCTUnwrap(holder.task).value; XCTFail("Expected callback cancellation") }
      catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
      holder.task = nil
      XCTAssertEqual(callbacks, [true, false])
      XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }
  }

  func testPreparationEndCallbackInvalidatingReceiptPreventsNativeExport() async throws {
    let asset = try await movie()
    let resources = VideoResources(photos: PhotosVideoProvider(authority: { _ in "end-callback-photo" },
      load: { _, _, _ in .init(asset: asset) }))
    let source = resources.photosSource(serializedCloudIdentifier: "end-callback-export")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("preparation-end-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    var callbacks: [Bool] = []
    do {
      _ = try await VideoResourcesFrames.export(source: source, rate: 0.5, outputDirectory: directory,
        onPreparation: { _, began in
          callbacks.append(began)
          if !began { source.invalidate() }
        }, onProgress: { _ in XCTFail("An invalid receipt cannot enter native export") })
      XCTFail("End callback invalidation must reject the receipt")
    } catch { XCTAssertEqual(error as? VideoResourceFailure, .sourceChanged) }
    XCTAssertEqual(callbacks, [true, false])
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
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

  func testPickerPreparationReportsOwnProgressAndClosingOnlyReleasesItsFiniteShare() async throws {
    let probe = FramesProgressProbe()
    let source = probe.resources().photosSource(serializedCloudIdentifier: "picker-progress")
    let first = VideoFramePickerOwner()
    let second = VideoFramePickerOwner()
    var firstPreparation: VideoPreparation?
    var secondPreparation: VideoPreparation?
    var projectedPreparation: VideoPreparation?
    var firstEnded = 0
    var secondEnded = 0
    let firstSource = VideoResourcesFrames.pickerSource(source: source, identity: "first-progress",
      onPreparation: { preparation, began in
        if began {
          firstPreparation = preparation
          projectedPreparation = preparation
        } else {
          firstEnded += 1
          if projectedPreparation === preparation { projectedPreparation = nil }
        }
      })
    let secondSource = VideoResourcesFrames.pickerSource(source: source, identity: "second-progress",
      onPreparation: { preparation, began in
        if began {
          secondPreparation = preparation
          projectedPreparation = preparation
        } else {
          secondEnded += 1
          if projectedPreparation === preparation { projectedPreparation = nil }
        }
      })
    XCTAssertNil(firstPreparation, "Constructing the adapter cannot start the UI operation")
    defer { first.stop(); second.stop(); probe.finishOutstanding() }
    start(first, source: firstSource)
    try await waitUntil { firstPreparation != nil && probe.invocations.count == 1 }
    start(second, source: secondSource)
    try await waitUntil { secondPreparation != nil }
    let firstHandle = try XCTUnwrap(firstPreparation)
    let secondHandle = try XCTUnwrap(secondPreparation)
    XCTAssertFalse(firstHandle === secondHandle)
    XCTAssertNil(firstHandle.progress, "No Photos progress report means spinner, not a zero-percent ring")
    XCTAssertNil(secondHandle.progress)
    XCTAssertEqual(probe.invocations.count, 1, "Each picker owns a finite share of the same request")
    let highQuality = source.prepare(.init(quality: .highest))
    defer { highQuality.cancel() }
    try await waitUntil { probe.invocations.count == 2 }
    probe.invocations[0].progress(0.25)
    probe.invocations[1].progress(0.8)
    try await waitUntil { firstHandle.progress == 0.25 && highQuality.progress == 0.8 }
    XCTAssertEqual(secondHandle.progress, 0.25)
    XCTAssertEqual(projectedPreparation?.progress, 0.25,
      "A peer HQ request must not replace this picker's reported progress")
    XCTAssertEqual(source.state, .acquiring(0.8), "The source-global progress intentionally differs")
    first.stop()
    try await waitUntil { firstEnded == 1 }
    XCTAssertTrue(projectedPreparation === secondHandle,
      "An old mount's completion cannot clear the new mount's preparation")
    XCTAssertEqual(secondHandle.progress, 0.25)
    XCTAssertTrue(probe.cancelledIndices.isEmpty)
    second.stop()
    try await waitUntil { secondEnded == 1 && probe.cancelledIndices.contains(0) }
    XCTAssertNil(projectedPreparation)
    XCTAssertFalse(probe.cancelledIndices.contains(1), "Closing pickers cannot cancel the independent HQ owner")
    XCTAssertEqual(firstEnded, 1)
    XCTAssertEqual(secondEnded, 1)
  }

  func testClosingSynchronouslyFromPreparationStartRejectsLateMediaBeforeNativeLoad() async throws {
    let probe = FramesProgressProbe()
    let source = probe.resources().photosSource(serializedCloudIdentifier: "close-from-preparation")
    let owner = VideoFramePickerOwner()
    var starts = 0
    var ends = 0
    var startedPreparation: VideoPreparation?
    var endedPreparation: VideoPreparation?
    defer { owner.stop(); probe.finishOutstanding() }
    start(owner, source: VideoResourcesFrames.pickerSource(source: source, identity: "close-start",
      onPreparation: { preparation, began in
        if began {
          starts += 1
          startedPreparation = preparation
          owner.stop()
        } else {
          ends += 1
          endedPreparation = preparation
        }
      }))
    try await waitUntil { ends == 1 }
    await settle()
    XCTAssertEqual(starts, 1)
    XCTAssertTrue(startedPreparation === endedPreparation)
    XCTAssertNil(owner.player)
    XCTAssertNil(owner.preview)
    XCTAssertNil(owner.failure, "A user close is not an error state")
    XCTAssertTrue(probe.invocations.isEmpty,
      "The start callback's cancellation must be rechecked before invoking native Photos")
    XCTAssertEqual(source.state, .idle)
  }

  func testPreparationEndInvalidationCannotInstallMediaReturnedByTheLoader() async throws {
    let asset = try await movie()
    let resources = VideoResources(photos: PhotosVideoProvider(authority: { _ in "end-callback-source" },
      load: { _, _, _ in .init(asset: asset) }))
    let source = resources.photosSource(serializedCloudIdentifier: "end-invalidated")
    let owner = VideoFramePickerOwner()
    var starts = 0
    var ends = 0
    defer { owner.stop() }
    start(owner, source: VideoResourcesFrames.pickerSource(source: source, identity: "end-invalidate",
      onPreparation: { _, began in
        if began { starts += 1 }
        else { ends += 1; source.invalidate() }
      }))
    try await waitUntil { owner.failure != nil || owner.preview != nil }
    XCTAssertEqual(starts, 1)
    XCTAssertEqual(ends, 1)
    guard case .source = owner.failure else {
      return XCTFail("Native receipt validation must reject invalidation from the host end callback")
    }
    XCTAssertNil(owner.preview)
    XCTAssertNil(owner.player?.currentItem)
    XCTAssertNil(source.preferred)
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

@MainActor
private final class FramesProgressProbe {
  struct Invocation {
    let request: VideoRequest
    let progress: PhotosVideoProvider.Progress
    var continuation: CheckedContinuation<VideoRepresentation, Error>?
  }
  private(set) var invocations: [Invocation] = []
  private(set) var cancelledIndices: [Int] = []

  func resources() -> VideoResources {
    VideoResources(photos: PhotosVideoProvider(authority: { "visible:\($0)" },
      load: { [self] _, request, progress in try await load(request, progress: progress) }))
  }

  func finish(_ index: Int, with result: Result<VideoRepresentation, Error>) {
    guard invocations.indices.contains(index), let continuation = invocations[index].continuation else {
      XCTFail("Expected unfinished request \(index)")
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

  private func load(_ request: VideoRequest, progress: @escaping PhotosVideoProvider.Progress) async throws
    -> VideoRepresentation {
    let index = invocations.count
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        invocations.append(Invocation(request: request, progress: progress, continuation: continuation))
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.cancelledIndices.append(index) }
    }
  }
}
