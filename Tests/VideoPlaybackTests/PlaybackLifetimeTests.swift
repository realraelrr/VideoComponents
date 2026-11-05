import AVFoundation
import Foundation
import XCTest
@testable import VideoPlayback

private enum LifetimeContext {
  @TaskLocal static var marker = 0
}

@MainActor
final class PlaybackLifetimeTests: XCTestCase {
  func testOwnerReleaseCancelsPendingSeekOnRetainedItemBeforeDetachingPlayer() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("lifetime-\(UUID()).caf")
    defer { try? FileManager.default.removeItem(at: url) }
    let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000))
    buffer.frameLength = 8_000
    buffer.floatChannelData?[0].update(repeating: 0, count: 8_000)
    try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
    var lateCompletion: (@MainActor (Bool) -> Void)?
    var cancelledItems: [AVPlayerItem] = []
    var wasAttachedWhenCancelled = false
    weak var observedPlayer: AVPlayer?
    var session: PlaybackSession? = PlaybackSession(transportSeek: { player, target, completion in
      lateCompletion = completion
      // Run a real native seek, but hold its SDK acknowledgement until after release.
      PlaybackSession.seekTransport(player: player, target: target) { _ in }
    }, cancelPendingSeeks: { item in
      wasAttachedWhenCancelled = observedPlayer?.currentItem === item
      cancelledItems.append(item)
      item.cancelPendingSeeks()
    })
    defer { session?.cleanup() }
    weak var released = session
    let player = try XCTUnwrap(session?.player)
    observedPlayer = player
    session?.load(source: PlaybackSource(identity: UUID(), load: {
      PlaybackLoadedMedia(asset: AVURLAsset(url: url))
    }), playbackRate: 1, isLooping: false, autoplayWhenReady: false)
    for _ in 0..<400 where session?.isPlayerReady != true {
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertTrue(session?.isPlayerReady == true)
    let retainedItem = try XCTUnwrap(player.currentItem)
    session?.handleScrubEditingChanged(true)
    session?.setScrubProgress(0.4)
    session?.handleScrubEditingChanged(false)
    XCTAssertNotNil(lateCompletion)
    session = nil
    XCTAssertNil(released)
    XCTAssertEqual(cancelledItems.count, 1, "Release must cancel the still-pending transport on its retained item")
    XCTAssertTrue(cancelledItems.first === retainedItem)
    XCTAssertTrue(wasAttachedWhenCancelled)
    XCTAssertNil(player.currentItem)
    lateCompletion?(true)
    lateCompletion?(false)
    XCTAssertNil(player.currentItem)
    XCTAssertEqual(player.rate, 0)
    XCTAssertEqual(cancelledItems.count, 1)
  }

  func testTasklessThreadLocalReleaseCleansUpOnMainActorWithoutRetainingOwner() async {
    let cleaned = expectation(description: "Native playback lifetime is released")
    DispatchQueue.main.async {
      LifetimeContext.$marker.withValue(17) {
        var session: PlaybackSession? = PlaybackSession { event in
          guard case .didCleanup = event else { return }
          XCTAssertTrue(Thread.isMainThread)
          cleaned.fulfill()
        }
        weak var released = session
        XCTAssertEqual(LifetimeContext.marker, 17)
        session = nil
        XCTAssertNil(released, "Cleanup must not capture or resurrect its owner")
      }
    }
    await fulfillment(of: [cleaned], timeout: 3)
  }
}
