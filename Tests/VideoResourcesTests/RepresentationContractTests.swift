import AVFoundation
import CoreVideo
import Foundation
import VideoResources
import XCTest

@MainActor
final class RepresentationContractTests: XCTestCase {
  func testDifferentMediaReceiptsKeepTheirOwnDurationFrameMixAndEvidenceInEitherOrder() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let automatic = try await movie(directory: directory, name: "red", frames: 3, red: true)
    let highest = try await movie(directory: directory, name: "blue", frames: 9, red: false)
    let automaticMix = AVMutableAudioMix()
    let highestMix = AVMutableAudioMix()
    let low = VideoRequest(quality: .automatic, network: .forbidden)
    let high = VideoRequest(quality: .highest, network: .allowed)
    for requests in [[low, high], [high, low]] {
      var calls = 0
      let resources = VideoResources(photos: PhotosVideoProvider(
        authority: { _ in "current-visible-photo" },
        load: { _, request, _ in
          calls += 1
          return request.quality == .highest
            ? VideoRepresentation(asset: highest, audioMix: highestMix)
            : VideoRepresentation(asset: automatic, audioMix: automaticMix)
        }))
      let source = resources.photosSource(serializedCloudIdentifier: "photo")
      var receipts: [VideoRequest: VideoReceipt] = [:]
      for request in requests { receipts[request] = try await source.acquire(request) }
      let a = try XCTUnwrap(receipts[low])
      let b = try XCTUnwrap(receipts[high])
      XCTAssertNotEqual(a.representationID, b.representationID)
      XCTAssertEqual(a.evidence, low)
      XCTAssertEqual(b.evidence, high)
      XCTAssertTrue(a.audioMix === automaticMix)
      XCTAssertTrue(b.audioMix === highestMix)
      XCTAssertTrue(a.isCurrent && b.isCurrent)
      let durationA = try await a.asset.load(.duration)
      let durationB = try await b.asset.load(.duration)
      XCTAssertEqual(CMTimeGetSeconds(durationA), 0.1, accuracy: 0.001)
      XCTAssertEqual(CMTimeGetSeconds(durationB), 0.3, accuracy: 0.001)
      let colorA = try await Self.firstPixel(.init(asset: a.asset))
      let colorB = try await Self.firstPixel(.init(asset: b.asset))
      XCTAssertGreaterThan(colorA.red, colorA.blue + 100)
      XCTAssertGreaterThan(colorB.blue, colorB.red + 100)
      XCTAssertEqual(source.preferred?.representationID, b.representationID)
      let reused = try await source.acquire(high)
      XCTAssertEqual(reused.representationID, b.representationID)
      XCTAssertEqual(calls, 2)
    }
  }

  func testPhotosReuseRequiresCurrentAuthorityAndSufficientEvidence() async throws {
    var authority = "A"
    var calls = 0
    let resources = VideoResources(photos: PhotosVideoProvider(
      authority: { _ in authority }, load: { _, _, _ in
        calls += 1
        return .init(asset: AVMutableComposition())
      }))
    let source = resources.photosSource(serializedCloudIdentifier: "photo")
    XCTAssertTrue(source === resources.photosSource(serializedCloudIdentifier: "photo"))
    let high = VideoRequest(quality: .highest, network: .forbidden)
    let first = try await source.acquire(high)
    let reused = try await source.acquire()
    XCTAssertEqual(first.representationID, reused.representationID)
    XCTAssertEqual(calls, 1)
    authority = "B"
    XCTAssertFalse(first.isCurrent)
    XCTAssertNil(source.preferred)
    let changed = try await source.acquire(high)
    XCTAssertNotEqual(first.representationID, changed.representationID)
    XCTAssertEqual(calls, 2)
    resources.refreshPhotosAccess()
    XCTAssertTrue(changed.isCurrent, "A mapping refresh is not a change in the source fact")
    authority = "C"
    resources.refreshPhotosAccess()
    XCTAssertFalse(changed.isCurrent)
    XCTAssertEqual(calls, 2)
  }

  func testSameActualRepresentationKeepsIdentityAcrossRequestsWithoutPreferredDowngrade() async throws {
    let asset = AVMutableComposition()
    let mix = AVMutableAudioMix()
    var calls = 0
    let resources = VideoResources(photos: PhotosVideoProvider(
      authority: { _ in "A" }, load: { _, _, _ in
        calls += 1
        return .init(asset: asset, audioMix: mix)
      }))
    let source = resources.photosSource(serializedCloudIdentifier: "photo")
    let high = try await source.acquire(.init(quality: .highest, network: .allowed))
    let local = try await source.acquire(.init(quality: .automatic, network: .forbidden))
    XCTAssertEqual(calls, 2, "Network-forbidden evidence cannot be inferred from an allowed request")
    XCTAssertEqual(high.representationID, local.representationID)
    XCTAssertEqual(local.evidence, .init(quality: .automatic, network: .forbidden))
    XCTAssertEqual(source.preferred?.evidence.quality, .highest)
    XCTAssertTrue(local.audioMix === mix)
  }

  func testFailedHigherQualityAttemptPreservesUsablePreferredAndRequiresExplicitRetry() async throws {
    var calls = 0
    var fail = false
    let resources = VideoResources(photos: PhotosVideoProvider(
      authority: { _ in "A" }, load: { _, _, _ in
        calls += 1
        if fail { throw VideoResourceFailure.networkRequired }
        return .init(asset: AVMutableComposition())
      }))
    let source = resources.photosSource(serializedCloudIdentifier: "photo")
    let automatic = try await source.acquire()
    fail = true
    let failed = source.prepare(.init(quality: .highest))
    do { _ = try await failed.value(); XCTFail("Expected failure") }
    catch { XCTAssertEqual(error as? VideoResourceFailure, .networkRequired) }
    XCTAssertEqual(source.preferred?.representationID, automatic.representationID)
    do { _ = try await failed.share().value(); XCTFail("Expected same terminal failure") }
    catch { XCTAssertEqual(error as? VideoResourceFailure, .networkRequired) }
    XCTAssertEqual(calls, 2)
    fail = false
    let higher = try await source.acquire(.init(quality: .highest))
    XCTAssertEqual(calls, 3)
    XCTAssertEqual(source.preferred?.representationID, higher.representationID)
  }

  private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func movie(directory: URL, name: String, frames: Int, red: Bool) async throws -> AVURLAsset {
    let url = directory.appendingPathComponent(name + ".mov")
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64
    ])
    writer.add(input)
    guard writer.startWriting() else { throw try XCTUnwrap(writer.error) }
    writer.startSession(atSourceTime: .zero)
    for index in 0..<frames {
      while !input.isReadyForMoreMediaData {
        guard writer.status == .writing else { throw try XCTUnwrap(writer.error) }
        await Task.yield()
      }
      var buffer: CVPixelBuffer?
      let pool = try XCTUnwrap(adaptor.pixelBufferPool)
      XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer), kCVReturnSuccess)
      let pixel = try XCTUnwrap(buffer)
      CVPixelBufferLockBaseAddress(pixel, [])
      let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixel)).assumingMemoryBound(to: UInt8.self)
      let stride = CVPixelBufferGetBytesPerRow(pixel)
      for y in 0..<64 {
        for x in 0..<64 {
          let position = y * stride + x * 4
          bytes[position] = red ? 0 : 255
          bytes[position + 1] = 0
          bytes[position + 2] = red ? 255 : 0
          bytes[position + 3] = 255
        }
      }
      CVPixelBufferUnlockBaseAddress(pixel, [])
      XCTAssertTrue(adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(index), timescale: 30)))
    }
    writer.endSession(atSourceTime: CMTime(value: Int64(frames), timescale: 30))
    input.markAsFinished()
    await writer.finishWriting()
    XCTAssertEqual(writer.status, .completed)
    return AVURLAsset(url: url)
  }

  nonisolated private static func firstPixel(_ representation: VideoRepresentation) async throws -> (red: Int, blue: Int) {
    let image = try await AVAssetImageGenerator(asset: representation.asset).image(at: .zero).image
    var rgba = [UInt8](repeating: 0, count: 4)
    let space = CGColorSpaceCreateDeviceRGB()
    try rgba.withUnsafeMutableBytes { bytes in
      let context = try XCTUnwrap(CGContext(
        data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    }
    return (Int(rgba[0]), Int(rgba[2]))
  }
}
