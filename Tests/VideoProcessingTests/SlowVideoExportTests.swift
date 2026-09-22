import AVFoundation
import Foundation
import XCTest

@testable import VideoProcessing

@MainActor
final class SlowVideoExportIntegrationTests: XCTestCase {
  func testRejectsInvalidRatesWithoutCreatingFilesOrReportingProgress() async throws {
    let directory = try outputDirectory()
    var progress: [Double] = []
    for rate in [Double.nan, .infinity, -.infinity, -1, 0, 0.249, 1.001] {
      do {
        _ = try await SlowVideoExporter.exportSlowedVideo(
          asset: AVMutableComposition(), rate: rate, outputDirectory: directory,
          onProgress: { progress.append($0) }
        )
        XCTFail("Expected invalidRate")
      } catch SlowVideoExportError.invalidRate {}
    }
    XCTAssertTrue(progress.isEmpty)
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
  }

  func testConfiguredDirectoryGetsUniqueOwnedOutputsAndPreservesOtherFiles() async throws {
    let directory = try outputDirectory()
    let sentinel = directory.appendingPathComponent("existing.mp4")
    let sentinelData = Data("unrelated file".utf8)
    try sentinelData.write(to: sentinel)
    let source = try await videoFixture()
    let sourceData = try Data(contentsOf: source.url)
    let first = try await SlowVideoExporter.exportSlowedVideo(asset: source, rate: 1, outputDirectory: directory, onProgress: { _ in })
    let second = try await SlowVideoExporter.exportSlowedVideo(asset: source, rate: 0.5, outputDirectory: directory, onProgress: { _ in })
    XCTAssertNotEqual(first, second)
    XCTAssertEqual(first.deletingLastPathComponent().standardizedFileURL, directory.standardizedFileURL)
    XCTAssertEqual(second.pathExtension, "mp4")
    XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    let before = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    let cancelled = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await SlowVideoExporter.exportSlowedVideo(asset: source, rate: 0.5, outputDirectory: directory, onProgress: { _ in })
    }
    do { _ = try await cancelled.value; XCTFail("Expected cancellation") }
    catch is CancellationError {}
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), before)
    XCTAssertEqual(try Data(contentsOf: sentinel), sentinelData)
    XCTAssertEqual(try Data(contentsOf: source.url), sourceData)
  }

  func testInvalidOutputDirectoryLeavesItsExistingFileUntouched() async throws {
    let source = try await videoFixture()
    let file = try fixtureURL(extension: "txt")
    let data = Data("keep me".utf8)
    try data.write(to: file)
    for directory in [file, file.appendingPathComponent("missing"), try XCTUnwrap(URL(string: "https://example.invalid/output"))] {
      do {
        _ = try await SlowVideoExporter.exportSlowedVideo(asset: source, rate: 1, outputDirectory: directory, onProgress: { _ in })
        XCTFail("Expected outputUnavailable")
      } catch SlowVideoExportError.outputUnavailable {}
    }
    XCTAssertEqual(try Data(contentsOf: file), data)
  }

  func testRealExporterScalesDurationAndPreservesRotatedDecodableFrames() async throws {
    let source = try await videoFixture()
    for speed in [0.25, 0.5, 0.75, 1.0] {
      var progress: [Double] = []
      let output = try await SlowVideoExporter.exportSlowedVideo(
        asset: source, rate: speed, onProgress: { progress.append($0) }
      )
      defer { try? FileManager.default.removeItem(at: output) }
      let exported = AVURLAsset(url: output)
      let duration = try await exported.load(.duration).seconds
      XCTAssertEqual(duration, 2 / speed, accuracy: 0.08)
      let videoTracks = try await exported.loadTracks(withMediaType: .video)
      let audioTracks = try await exported.loadTracks(withMediaType: .audio)
      XCTAssertEqual(videoTracks.count, 1)
      XCTAssertTrue(audioTracks.isEmpty)
      let generator = AVAssetImageGenerator(asset: exported)
      generator.appliesPreferredTrackTransform = true
      for seconds in [0.0, duration / 2, duration - 0.15] {
        let frame = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
        XCTAssertEqual(frame.image.width, 96)
        XCTAssertEqual(frame.image.height, 128)
      }
      XCTAssertEqual(progress.first, 0)
      XCTAssertEqual(progress.last, 1)
      XCTAssertTrue(progress.allSatisfy { $0.isFinite && (0...1).contains($0) })
    }
  }

  func testShortOffsetAudioKeepsItsScaledTimeline() async throws {
    let source = try await videoFixture()
    let composition = AVMutableComposition()
    let sourceVideoTracks = try await source.loadTracks(withMediaType: .video)
    let videoTrack = try XCTUnwrap(sourceVideoTracks.first)
    let video = try XCTUnwrap(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
    try video.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: 2, preferredTimescale: 600)), of: videoTrack, at: .zero)
    video.preferredTransform = try await videoTrack.load(.preferredTransform)
    let audioAsset = AVURLAsset(url: try audioFixture())
    let sourceAudioTracks = try await audioAsset.loadTracks(withMediaType: .audio)
    let audioTrack = try XCTUnwrap(sourceAudioTracks.first)
    let audio = try XCTUnwrap(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
    try audio.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: 0.75, preferredTimescale: 600)), of: audioTrack, at: CMTime(seconds: 0.5, preferredTimescale: 600))
    let output = try await SlowVideoExporter.exportSlowedVideo(asset: composition, rate: 0.5, onProgress: { _ in })
    defer { try? FileManager.default.removeItem(at: output) }
    let exported = AVURLAsset(url: output)
    let duration = try await exported.load(.duration).seconds
    XCTAssertEqual(duration, 4, accuracy: 0.08)
    let tracks = try await exported.loadTracks(withMediaType: .audio)
    let exportedAudio = try XCTUnwrap(tracks.first)
    XCTAssertEqual(tracks.count, 1)
    let reader = try AVAssetReader(asset: exported)
    let trackOutput = AVAssetReaderTrackOutput(track: exportedAudio, outputSettings: [
      AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true,
      AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false,
      AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1
    ])
    reader.add(trackOutput)
    XCTAssertTrue(reader.startReading())
    var firstSound: Double?
    while let sample = trackOutput.copyNextSampleBuffer() {
      guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
      let length = CMBlockBufferGetDataLength(block)
      var values = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
      let status = values.withUnsafeMutableBytes {
        CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
      }
      XCTAssertEqual(status, kCMBlockBufferNoErr)
      if firstSound == nil, let index = values.firstIndex(where: { abs($0) > 0.03 }) {
        firstSound = CMSampleBufferGetPresentationTimeStamp(sample).seconds + Double(index) / 44_100
      }
    }
    XCTAssertEqual(reader.status, .completed)
    XCTAssertEqual(try XCTUnwrap(firstSound), 1, accuracy: 0.12)
  }

  func testAlreadyCancelledAndInvalidAssetsLeaveNoOutput() async throws {
    let before = try outputFiles()
    let source = try await videoFixture()
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await SlowVideoExporter.exportSlowedVideo(asset: source, rate: 0.5, onProgress: { _ in })
    }
    do { _ = try await task.value; XCTFail("Expected cancellation") }
    catch is CancellationError {}
    let invalid = AVMutableComposition()
    do {
      _ = try await SlowVideoExporter.exportSlowedVideo(asset: invalid, rate: 1, onProgress: { _ in })
      XCTFail("Expected invalid duration")
    } catch SlowVideoExportError.invalidDuration {}
    let audioOnly = AVURLAsset(url: try audioFixture())
    do {
      _ = try await SlowVideoExporter.exportSlowedVideo(asset: audioOnly, rate: 1, onProgress: { _ in })
      XCTFail("Expected no video track")
    } catch SlowVideoExportError.noVideoTrack {}
    let corrupt = try fixtureURL(extension: "mov")
    try Data("not a movie".utf8).write(to: corrupt)
    do {
      _ = try await SlowVideoExporter.exportSlowedVideo(asset: AVURLAsset(url: corrupt), rate: 1, onProgress: { _ in })
      XCTFail("Expected damaged asset failure")
    } catch {}
    XCTAssertEqual(try outputFiles(), before)
  }

  func testRealAVFoundationCancellationAfterStart() async throws {
    let source = try await videoFixture()
    let output = try fixtureURL(extension: "mov")
    let nativeSession = try XCTUnwrap(AVAssetExportSession(asset: source, presetName: AVAssetExportPresetHighestQuality))
    nativeSession.outputURL = output
    nativeSession.outputFileType = .mov
    let cancelled = expectation(description: "cancel forwarded to AVFoundation")
    let finished = expectation(description: "real export cancellation finished")
    let session = StartedVideoExportSession(session: nativeSession) {
      withUnsafeCurrentTask { $0?.cancel() }
    } onCancel: {
      cancelled.fulfill()
    }
    let runner = SlowVideoExportRunner(session: session, outputURL: output)
    var progress: [Double] = []
    var result: Result<URL, any Error>?
    let task = Task {
      defer { finished.fulfill() }
      do { result = .success(try await runner.export { progress.append($0) }) }
      catch { result = .failure(error) }
    }
    defer { task.cancel() }
    await fulfillment(of: [cancelled, finished], timeout: 5)

    guard let result else { return }
    switch result {
    case .success: XCTFail("Cancellation after start must not return success")
    case .failure(let error): XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
    }
    XCTAssertFalse(progress.contains(1))
    XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
  }

  private func videoFixture() async throws -> AVURLAsset {
    let url = try fixtureURL(extension: "mov")
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
    for index in 0..<60 {
      while !input.isReadyForMoreMediaData { await Task.yield() }
      var buffer: CVPixelBuffer?
      XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &buffer), kCVReturnSuccess)
      let pixel = try XCTUnwrap(buffer)
      CVPixelBufferLockBaseAddress(pixel, [])
      memset(CVPixelBufferGetBaseAddress(pixel), Int32(40 + index * 2), CVPixelBufferGetBytesPerRow(pixel) * 96)
      CVPixelBufferUnlockBaseAddress(pixel, [])
      XCTAssertTrue(adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(index), timescale: 30)))
    }
    writer.endSession(atSourceTime: CMTime(seconds: 2, preferredTimescale: 600))
    input.markAsFinished()
    await writer.finishWriting()
    XCTAssertEqual(writer.status, .completed)
    return AVURLAsset(url: url)
  }

  private func audioFixture() throws -> URL {
    let url = try fixtureURL(extension: "caf")
    let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100))
    buffer.frameLength = 44_100
    for index in 0..<44_100 { buffer.floatChannelData?[0][index] = Float(sin(Double(index) * 2 * .pi * 440 / 44_100)) * 0.5 }
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
    return url
  }

  private func fixtureURL(extension suffix: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("export-fixture-\(UUID().uuidString).\(suffix)")
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }

  private func outputDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("export-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }

  private func outputFiles() throws -> Set<String> {
    Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
      .filter { $0.hasPrefix("video-export-") })
  }
}

@MainActor
final class SlowVideoExportRunnerTests: XCTestCase {
  func testTaskCancellationRacingNativeFailureStillThrowsCancellation() async throws {
    let output = try partialOutput()
    let session = ControlledVideoExportSession()
    let started = expectation(description: "session started")
    session.onStart = { started.fulfill() }
    let export = beginExport(session: session, output: output) { _ in }
    defer { export.task.cancel(); session.complete(status: .cancelled) }
    await fulfillment(of: [started], timeout: 3)
    export.task.cancel()
    session.complete(status: .failed, error: RunnerTestError.nativeFailure)
    guard let result = await result(of: export) else { return }
    assertCancellation(result)
    XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
  }

  func testFrameworkCancellationWithoutTaskCancellationIsTypedFailure() async throws {
    let output = try partialOutput()
    let session = ControlledVideoExportSession()
    let started = expectation(description: "session started")
    session.onStart = { started.fulfill() }
    let export = beginExport(session: session, output: output) { _ in }
    defer { export.task.cancel(); session.complete(status: .cancelled) }
    await fulfillment(of: [started], timeout: 3)
    session.complete(status: .cancelled)
    guard let result = await result(of: export) else { return }
    switch result {
    case .success: XCTFail("Expected framework failure")
    case .failure(let error):
      guard case SlowVideoExportError.exportFailed(let cause) = error else {
        XCTFail("Expected typed export failure")
        return
      }
      XCTAssertTrue(cause is CancellationError)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
  }

  func testCancellingStartedExportCancelsSessionAndRemovesPartialOutput() async throws {
    let output = try partialOutput()
    let session = ControlledVideoExportSession()
    let started = expectation(description: "session started")
    let cancelled = expectation(description: "session cancellation requested")
    session.onStart = { started.fulfill() }
    session.onCancel = { cancelled.fulfill() }
    var progress: [Double] = []
    let export = beginExport(session: session, output: output) { progress.append($0) }
    defer { export.task.cancel(); session.complete(status: .cancelled) }

    await fulfillment(of: [started], timeout: 3)
    XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    export.task.cancel()
    await fulfillment(of: [cancelled], timeout: 3)
    XCTAssertEqual(session.cancelCount, 1)
    session.complete(status: .cancelled)

    guard let result = await result(of: export) else { return }
    assertCancellation(result)
    XCTAssertFalse(progress.contains(1))
    XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
  }

  func testCancellationRacingNativeCompletionStillCancelsAndRemovesOutput() async throws {
    let output = try partialOutput()
    let session = ControlledVideoExportSession()
    let started = expectation(description: "session started")
    session.onStart = { started.fulfill() }
    var progress: [Double] = []
    let export = beginExport(session: session, output: output) { progress.append($0) }
    defer { export.task.cancel(); session.complete(status: .cancelled) }
    await fulfillment(of: [started], timeout: 3)

    // Both events occur in this actor turn, before the suspended export can resume.
    export.task.cancel()
    session.complete(status: .completed)

    guard let result = await result(of: export) else { return }
    assertCancellation(result)
    XCTAssertFalse(progress.contains(1))
    XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
  }

  func testNativeProgressOneIsNotPublishedBeforeCompletion() async throws {
    let output = try partialOutput()
    let session = ControlledVideoExportSession()
    session.reportedProgress = 1
    let sampled = expectation(description: "native progress one sampled")
    session.onProgressRead = { sampled.fulfill() }
    var progress: [Double] = []
    let export = beginExport(session: session, output: output) { value in
      if value == 1 {
        XCTAssertTrue(session.didComplete, "Only successful completion may publish progress one")
      }
      progress.append(value)
    }
    defer { export.task.cancel(); session.complete(status: .cancelled) }

    // The getter handshake proves the runner consumed 1 while completion was withheld.
    await fulfillment(of: [sampled], timeout: 3)
    XCTAssertGreaterThan(session.progressReadCount, 0)
    XCTAssertFalse(session.didComplete)
    XCTAssertFalse(progress.contains(1))
    session.complete(status: .completed)

    guard let result = await result(of: export) else { return }
    XCTAssertEqual(try result.get(), output)
    XCTAssertEqual(progress.filter { $0 == 1 }.count, 1)
  }

  func testSynchronousCompletionSucceedsWithoutIntermediateProgress() async throws {
    let output = try partialOutput()
    let session = ControlledVideoExportSession()
    session.completesSynchronously = true
    var progress: [Double] = []
    let export = beginExport(session: session, output: output) { progress.append($0) }
    defer { export.task.cancel(); session.complete(status: .cancelled) }

    guard let result = await result(of: export) else { return }
    XCTAssertEqual(try result.get(), output)
    XCTAssertEqual(session.startCount, 1)
    XCTAssertEqual(session.cancelCount, 0)
    XCTAssertEqual(progress.filter { $0 == 1 }.count, 1)
    XCTAssertFalse(progress.contains { $0 > 0 && $0 < 1 })
    XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
  }

  func testNativeFailurePreservesErrorAndRemovesPartialOutput() async throws {
    try await assertFailedExport(nativeError: RunnerTestError.nativeFailure)
  }

  func testNativeFailureWithoutErrorRemovesPartialOutput() async throws {
    try await assertFailedExport(nativeError: nil)
  }

  func testAlreadyCancelledTaskDoesNotStartSession() async throws {
    let output = try partialOutput()
    let session = ControlledVideoExportSession()
    var progress: [Double] = []
    let export = beginExport(session: session, output: output, alreadyCancelled: true) { progress.append($0) }
    defer { export.task.cancel(); session.complete(status: .cancelled) }

    guard let result = await result(of: export) else { return }
    assertCancellation(result)
    XCTAssertEqual(session.startCount, 0)
    XCTAssertFalse(progress.contains(1))
    XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
  }

  private func assertFailedExport(nativeError: (any Error)?) async throws {
    let output = try partialOutput()
    let session = ControlledVideoExportSession()
    let started = expectation(description: "session started")
    session.onStart = { started.fulfill() }
    var progress: [Double] = []
    let export = beginExport(session: session, output: output) { progress.append($0) }
    defer { export.task.cancel(); session.complete(status: .cancelled) }
    await fulfillment(of: [started], timeout: 3)
    session.complete(status: .failed, error: nativeError)

    guard let result = await result(of: export) else { return }
    switch result {
    case .success:
      XCTFail("Failed export must not return an output")
    case .failure(let error):
      if nativeError != nil {
        guard case SlowVideoExportError.exportFailed(let cause) = error else {
          XCTFail("Expected typed export failure, got \(error)")
          return
        }
        XCTAssertEqual(cause as? RunnerTestError, .nativeFailure)
      } else if case SlowVideoExportError.exportFailed = error {
        // AVFoundation may fail without supplying an error.
      } else {
        XCTFail("Expected exportFailed, got \(error)")
      }
    }
    XCTAssertFalse(progress.contains(1))
    XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
  }

  private func beginExport(
    session: ControlledVideoExportSession,
    output: URL,
    alreadyCancelled: Bool = false,
    onProgress: @escaping @MainActor (Double) -> Void
  ) -> (task: Task<Result<URL, any Error>, Never>, finished: XCTestExpectation) {
    let finished = expectation(description: "export task finished")
    let runner = SlowVideoExportRunner(session: session, outputURL: output)
    let task = Task {
      if alreadyCancelled { withUnsafeCurrentTask { $0?.cancel() } }
      defer { finished.fulfill() }
      do { return Result<URL, any Error>.success(try await runner.export(onProgress: onProgress)) }
      catch { return .failure(error) }
    }
    return (task, finished)
  }

  private func result(
    of export: (task: Task<Result<URL, any Error>, Never>, finished: XCTestExpectation)
  ) async -> Result<URL, any Error>? {
    // A timeout only protects against a deadlock; all race ordering uses explicit events.
    let wait = await XCTWaiter.fulfillment(of: [export.finished], timeout: 3)
    guard wait == .completed else {
      export.task.cancel()
      XCTFail("Export did not finish after the controlled terminal event")
      return nil
    }
    return await export.task.value
  }

  private func assertCancellation(_ result: Result<URL, any Error>) {
    switch result {
    case .success: XCTFail("Cancelled export must not return success")
    case .failure(let error): XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
    }
  }

  private func partialOutput() throws -> URL {
    let output = FileManager.default.temporaryDirectory
      .appendingPathComponent("runner-export-\(UUID().uuidString).mov")
    try Data("partial export".utf8).write(to: output)
    addTeardownBlock { try? FileManager.default.removeItem(at: output) }
    return output
  }
}

private enum RunnerTestError: Error, Equatable {
  case nativeFailure
}

@MainActor
private final class StartedVideoExportSession: VideoExportSession {
  private let session: AVAssetExportSession
  private let onStarted: () -> Void
  private let onCancel: () -> Void

  init(session: AVAssetExportSession, onStarted: @escaping () -> Void, onCancel: @escaping () -> Void) {
    self.session = session
    self.onStarted = onStarted
    self.onCancel = onCancel
  }

  var progress: Float { session.progress }
  var status: AVAssetExportSession.Status { session.status }
  var error: (any Error)? { session.error }

  func start(completion: @escaping @Sendable () -> Void) {
    session.start(completion: completion)
    onStarted()
  }

  func cancel() {
    session.cancel()
    onCancel()
  }
}

@MainActor
private final class ControlledVideoExportSession: VideoExportSession {
  var reportedProgress: Float = 0
  var status: AVAssetExportSession.Status = .unknown
  var error: (any Error)?
  var onStart: (() -> Void)?
  var onCancel: (() -> Void)?
  var onProgressRead: (() -> Void)?
  var completesSynchronously = false
  private(set) var startCount = 0
  private(set) var cancelCount = 0
  private(set) var progressReadCount = 0
  private(set) var didComplete = false
  private var completion: (@Sendable () -> Void)?

  var progress: Float {
    progressReadCount += 1
    let observed = onProgressRead
    onProgressRead = nil
    observed?()
    return reportedProgress
  }

  func start(completion: @escaping @Sendable () -> Void) {
    startCount += 1
    self.completion = completion
    status = .exporting
    onStart?()
    if completesSynchronously { complete(status: .completed) }
  }

  func cancel() {
    cancelCount += 1
    onCancel?()
  }

  func complete(status: AVAssetExportSession.Status, error: (any Error)? = nil) {
    guard let completion else { return }
    self.completion = nil
    self.status = status
    self.error = error
    didComplete = true
    completion()
  }
}
