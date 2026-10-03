import AVFoundation
import CoreGraphics
import Foundation
import Observation
import VideoResources
import VideoResourcesFrames
import XCTest
@testable import VideoFramePicker

@MainActor
final class VideoResourcesPickerInvalidationTests: XCTestCase {
  func testIdleRevocationDetachesSynchronouslyAndRestorationNeedsExplicitRetry() async throws {
    let fixture = IdlePickerFixture()
    let source = fixture.resources.photosSource(serializedCloudIdentifier: "photo")
    let owner = fixture.owner()
    defer { owner.stop(); fixture.finishOutstanding() }
    try await fixture.ready(owner, source: source)
    let retiredPlayer = try XCTUnwrap(owner.player)
    let oldSelection = try XCTUnwrap(owner.preview)
    try oldSelection.validate()

    fixture.accessible = false
    fixture.resources.refreshPhotosAccess()
    XCTAssertNil(retiredPlayer.currentItem, "Refresh must detach the idle native item before returning")
    XCTAssertNil(owner.player)
    XCTAssertNil(owner.preview)
    guard case .failed(.source) = owner.sourceStatus else {
      return XCTFail("A revoked mounted source must show the existing source failure state")
    }
    XCTAssertThrowsError(try oldSelection.validate()) { XCTAssertTrue($0 is CancellationError) }
    XCTAssertEqual(fixture.loads.count, 1)

    fixture.accessible = true
    fixture.resources.refreshPhotosAccess()
    await settle()
    XCTAssertEqual(fixture.loads.count, 1, "Restoration must not reacquire a stopped picker")
    XCTAssertNil(owner.player)
    guard case .failed(.source) = owner.sourceStatus else {
      return XCTFail("Restoration waits for an explicit retry")
    }
    fixture.start(owner, source: source, identity: "retry-attempt")
    try await wait { fixture.frames.count == 2 }
    fixture.finishFrame(1)
    try await wait { owner.preview != nil || owner.failure != nil }
    XCTAssertNil(owner.failure)
    XCTAssertNotNil(owner.player?.currentItem)
    XCTAssertEqual(fixture.loads.count, 2)
    XCTAssertThrowsError(try oldSelection.validate()) { XCTAssertTrue($0 is CancellationError) }
  }

  func testFirstAuthoritySameAuthorityRefreshProgressAndPreferredHQPreserveMountedMedia() async throws {
    let fixture = IdlePickerFixture()
    let source = fixture.resources.photosSource(serializedCloudIdentifier: "photo")
    let owner = fixture.owner()
    defer { owner.stop(); fixture.finishOutstanding() }
    // Do not pre-acquire: this mount must survive the source's first nil-to-known authority.
    try await fixture.ready(owner, source: source)
    let player = try XCTUnwrap(owner.player)
    let item = try XCTUnwrap(player.currentItem)
    let selection = try XCTUnwrap(owner.preview)
    XCTAssertEqual(fixture.loads.count, 1)
    XCTAssertTrue(item.asset === fixture.automatic)
    fixture.resources.refreshPhotosAccess()
    XCTAssertTrue(owner.player === player)
    XCTAssertTrue(player.currentItem === item)
    try selection.validate()

    let hq = source.prepare(.init(quality: .highest))
    defer { hq.cancel() }
    try await wait { fixture.loads.count == 2 }
    fixture.loads[1].progress(0.4)
    try await wait { source.state == .acquiring(0.4) }
    fixture.resources.refreshPhotosAccess()
    XCTAssertTrue(owner.player === player)
    XCTAssertTrue(player.currentItem === item)
    try selection.validate()
    fixture.highQuality.finish(.success(.init(asset: fixture.highest)))
    let receipt = try await hq.value()
    XCTAssertTrue(receipt.asset === fixture.highest)
    XCTAssertTrue(source.preferred?.asset === fixture.highest)
    XCTAssertTrue(owner.player === player)
    XCTAssertTrue(player.currentItem === item)
    XCTAssertTrue(item.asset === fixture.automatic, "A preferred receipt does not replace a mounted receipt")
    XCTAssertEqual(fixture.loads.count, 2, "Only the explicitly requested HQ consumer acquired")
    XCTAssertNil(owner.failure)
    try selection.validate()
  }

  func testRefreshCancelsHeldInspectionAndFrameAndRejectsTheirLateCompletions() async throws {
    for phase in HeldIdlePickerPhase.allCases {
      let fixture = IdlePickerFixture()
      let source = fixture.resources.photosSource(serializedCloudIdentifier: "photo")
      let owner = fixture.owner(holdInspection: phase == .inspection)
      defer { owner.stop(); fixture.finishOutstanding() }
      if phase == .inspection {
        fixture.start(owner, source: source)
        try await wait { fixture.inspection.started }
      } else {
        try await fixture.ready(owner, source: source)
        owner.changeSeconds(0.5, callbacks: fixture.callbacks)
        try await wait { fixture.frames.count == 2 }
      }
      let retiredPlayer = owner.player
      fixture.authority = "changed-content"
      fixture.resources.refreshPhotosAccess()
      XCTAssertNil(owner.player)
      XCTAssertNil(owner.preview)
      XCTAssertNil(retiredPlayer?.currentItem)
      guard case .failed(.source) = owner.sourceStatus else {
        XCTFail("Refreshing expired authority must fail the current source immediately")
        continue
      }
      if phase == .inspection {
        try await wait { fixture.inspection.cancelled }
        fixture.inspection.finish(.success(CMTime(seconds: 2, preferredTimescale: 600)))
      } else {
        try await wait { fixture.frames[1].gate.cancelled }
        fixture.finishFrame(1)
      }
      await settle()
      XCTAssertNil(owner.player)
      XCTAssertNil(owner.preview)
      XCTAssertTrue(fixture.selections.isEmpty)
      XCTAssertEqual(fixture.loads.count, 1)
      if phase == .inspection { XCTAssertTrue(fixture.frames.isEmpty) }
    }
  }

  func testRefreshCancelsSuspendedConsumerBeforeItsFinalSelectionCommit() async throws {
    let fixture = IdlePickerFixture()
    let source = fixture.resources.photosSource(serializedCloudIdentifier: "photo")
    let owner = fixture.owner()
    let consumer = IdlePickerGate<Void>()
    defer { owner.stop(); fixture.finishOutstanding(); consumer.finish(.success(())) }
    try await fixture.ready(owner, source: source)
    var committed = false
    owner.changeSeconds(0.5, callbacks: VideoFramePickerCallbacks(onFailure: { _ in },
      onSelection: { selection in
        try await consumer.run()
        try selection.validate()
        committed = true
      }))
    try await wait { fixture.frames.count == 2 }
    fixture.finishFrame(1)
    try await wait { consumer.started }
    fixture.authority = "changed-content"
    fixture.resources.refreshPhotosAccess()
    XCTAssertNil(owner.player)
    XCTAssertNil(owner.preview)
    XCTAssertFalse(owner.hasPendingSelection)
    XCTAssertFalse(owner.isProcessingSelection)
    guard case .failed(.source) = owner.sourceStatus else {
      return XCTFail("An invalidated consumer must preserve the source failure presentation")
    }
    try await wait { consumer.cancelled }
    consumer.finish(.success(()))
    await settle()
    XCTAssertFalse(committed)
    guard case .failed(.source) = owner.sourceStatus else {
      return XCTFail("Late consumer completion cannot replace source failure")
    }
    XCTAssertEqual(fixture.loads.count, 1)
  }

  func testSwitchAndOwnerReleaseKeepOldInvalidationFromAffectingTheCurrentSource() async throws {
    let fixture = IdlePickerFixture()
    let sourceA = fixture.resources.photosSource(serializedCloudIdentifier: "photo")
    let sourceB = fixture.resources.photosSource(serializedCloudIdentifier: "second")
    var owner: VideoFramePickerOwner? = fixture.owner()
    weak var releasedOwner = owner
    defer { owner?.stop(); fixture.finishOutstanding() }
    try await fixture.ready(try XCTUnwrap(owner), source: sourceA)
    let escapedA = try XCTUnwrap(owner?.preview)
    fixture.start(try XCTUnwrap(owner), source: sourceB, identity: "B")
    try await wait { fixture.frames.count == 2 }
    fixture.finishFrame(1)
    try await wait { owner?.preview != nil }
    let playerB = try XCTUnwrap(owner?.player)
    let itemB = try XCTUnwrap(playerB.currentItem)
    sourceA.invalidate()
    XCTAssertTrue(owner?.player === playerB)
    XCTAssertTrue(playerB.currentItem === itemB)
    XCTAssertTrue(itemB.asset === fixture.second)
    XCTAssertThrowsError(try escapedA.validate()) { XCTAssertTrue($0 is CancellationError) }
    let escapedB = try XCTUnwrap(owner?.preview)
    owner = nil
    XCTAssertNil(releasedOwner, "A source subscription and escaped selection must not retain their owner")
    XCTAssertNil(playerB.currentItem)
    sourceB.invalidate()
    XCTAssertThrowsError(try escapedB.validate()) { XCTAssertTrue($0 is CancellationError) }
  }

  func testInvalidationObservationStartingBDoesNotPublishOldFailureOrCleanUpB() async throws {
    let fixture = IdlePickerFixture()
    let sourceA = fixture.resources.photosSource(serializedCloudIdentifier: "photo")
    let sourceB = fixture.resources.photosSource(serializedCloudIdentifier: "second")
    let owner = fixture.owner()
    defer { owner.stop(); fixture.finishOutstanding() }
    try await fixture.ready(owner, source: sourceA)
    let retiredPlayer = try XCTUnwrap(owner.player)
    let observation = IdlePickerObservation()
    var oldFailureCount = 0
    // Replace the initial source's callback through a distinct mount, then finish its preview.
    fixture.start(owner, source: sourceA, identity: "observed-A", onFailure: { _ in oldFailureCount += 1 })
    try await wait { fixture.frames.count == 2 }
    fixture.finishFrame(1)
    try await wait { owner.preview != nil }
    let actualRetiredPlayer = try XCTUnwrap(owner.player)
    withObservationTracking { _ = owner.player } onChange: {
      MainActor.assumeIsolated {
        guard !observation.fired else { return }
        observation.fired = true
        fixture.start(owner, source: sourceB, identity: "selected-B")
      }
    }
    sourceA.invalidate()
    XCTAssertTrue(observation.fired, "Idle invalidation must notify the mounted native owner synchronously")
    XCTAssertNil(retiredPlayer.currentItem)
    XCTAssertNil(actualRetiredPlayer.currentItem)
    try await wait { fixture.frames.count == 3 }
    fixture.finishFrame(2)
    try await wait { owner.preview != nil || owner.failure != nil }
    XCTAssertNil(owner.failure)
    XCTAssertTrue(owner.player?.currentItem?.asset === fixture.second)
    XCTAssertEqual(oldFailureCount, 0, "The obsolete source cannot publish failure after B takes ownership")
    try XCTUnwrap(owner.preview).validate()
  }

  func testFailureObservationStartingBDoesNotWriteOldSourceFailureIntoB() async throws {
    let fixture = IdlePickerFixture()
    let sourceA = fixture.resources.photosSource(serializedCloudIdentifier: "photo")
    let sourceB = fixture.resources.photosSource(serializedCloudIdentifier: "second")
    let owner = fixture.owner()
    defer { owner.stop(); fixture.finishOutstanding() }
    try await fixture.ready(owner, source: sourceA)
    let retiredPlayer = try XCTUnwrap(owner.player)
    let observation = IdlePickerFailureObservation(owner: owner) {
      fixture.start(owner, source: sourceB, identity: "failure-observed-B")
    }
    observation.track()
    fixture.authority = "changed-content"
    fixture.resources.refreshPhotosAccess()
    XCTAssertNil(retiredPlayer.currentItem)
    XCTAssertNil(owner.failure, "The old source failure cannot write into B after its notification")
    guard case .loading = owner.sourceStatus else {
      XCTFail("B's scheduled load must retain its own loading presentation")
      return
    }
    try await wait { fixture.frames.count == 2 }
    fixture.finishFrame(1)
    try await wait { owner.preview != nil }
    XCTAssertNil(owner.failure)
    XCTAssertTrue(owner.player?.currentItem?.asset === fixture.second)
    try XCTUnwrap(owner.preview).validate()
  }

  private func wait(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<300 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw IdlePickerTestError.timeout
  }
  private func settle() async { try? await Task.sleep(for: .milliseconds(40)) }
}

private enum HeldIdlePickerPhase: CaseIterable { case inspection, frame }
private enum IdlePickerTestError: Error { case timeout, unavailableFixture }

@MainActor
private final class IdlePickerObservation { var fired = false }

/// The native completion deliberately survives task cancellation so late-result rejection is observable.
@MainActor
private final class IdlePickerGate<Value> {
  private var continuation: CheckedContinuation<Void, Never>?
  private var result: Result<Value, Error>?
  private(set) var started = false
  private(set) var cancelled = false
  func run() async throws -> Value {
    started = true
    await withTaskCancellationHandler {
      if result == nil { await withCheckedContinuation { continuation = $0 } }
    } onCancel: { Task { @MainActor [weak self] in self?.cancelled = true } }
    guard let result else { throw IdlePickerTestError.unavailableFixture }
    return try result.get()
  }
  func finish(_ result: Result<Value, Error>) {
    self.result = result
    continuation?.resume()
    continuation = nil
  }
}

@MainActor
private final class IdlePickerFixture {
  struct Load { let request: VideoRequest; let progress: PhotosVideoProvider.Progress }
  struct Frame { let seconds: Double; let gate: IdlePickerGate<VideoFrameSelection> }
  var authority = "A"
  var accessible = true
  let automatic = AVMutableComposition()
  let highest = AVMutableComposition()
  let second = AVMutableComposition()
  let highQuality = IdlePickerGate<VideoRepresentation>()
  let inspection = IdlePickerGate<CMTime>()
  private(set) var loads: [Load] = []
  private(set) var frames: [Frame] = []
  private(set) var selections: [VideoFrameSelection] = []
  lazy var resources = VideoResources(photos: PhotosVideoProvider(
    authority: { [weak self] identifier in
      guard let self else { throw CancellationError() }
      guard accessible else { throw VideoResourceFailure.photosAccessRequired }
      return identifier + ":" + authority
    }, load: { [weak self] identifier, request, progress in
      guard let self else { throw CancellationError() }
      return try await load(identifier, request: request, progress: progress)
    }))
  private func load(
    _ identifier: String, request: VideoRequest, progress: @escaping PhotosVideoProvider.Progress
  ) async throws -> VideoRepresentation {
    loads.append(Load(request: request, progress: progress))
    if request.quality == .highest { return try await highQuality.run() }
    return .init(asset: identifier == "second" ? second : automatic)
  }
  var callbacks: VideoFramePickerCallbacks {
    .init(onFailure: { _ in }, onSelection: { [weak self] in self?.selections.append($0) })
  }
  func owner(holdInspection: Bool = false) -> VideoFramePickerOwner {
    VideoFramePickerOwner(inspectAsset: { [weak self] _ in
      guard let self else { throw CancellationError() }
      if holdInspection { return try await inspection.run() }
      return CMTime(seconds: 2, preferredTimescale: 600)
    }, extractFrame: { [weak self] _, seconds, _ in
      guard let self else { throw CancellationError() }
      let gate = IdlePickerGate<VideoFrameSelection>()
      frames.append(Frame(seconds: seconds, gate: gate))
      return try await gate.run()
    })
  }
  func start(_ owner: VideoFramePickerOwner, source: VideoSource, identity: String = "initial",
    onFailure: @escaping @MainActor (VideoFramePickerFailure) -> Void = { _ in }) {
    owner.start(source: VideoResourcesFrames.pickerSource(source: source, identity: identity),
      initialTime: 0, maximumFrameSize: CGSize(width: 16, height: 16), onFailure: onFailure)
  }
  func ready(_ owner: VideoFramePickerOwner, source: VideoSource) async throws {
    let next = frames.count
    start(owner, source: source)
    for _ in 0..<300 {
      if frames.count > next || owner.failure != nil { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertNil(owner.failure)
    guard frames.count > next else { throw IdlePickerTestError.timeout }
    finishFrame(next)
    for _ in 0..<300 {
      if owner.preview != nil || owner.failure != nil { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertNil(owner.failure)
    XCTAssertNotNil(owner.preview)
  }
  func finishFrame(_ index: Int) {
    let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
    let frame = frames[index]
    frame.gate.finish(.success(.init(image: context.makeImage()!, requestedSeconds: frame.seconds,
      actualTime: CMTime(seconds: frame.seconds, preferredTimescale: 600))))
  }
  func finishOutstanding() {
    inspection.finish(.failure(CancellationError()))
    highQuality.finish(.failure(CancellationError()))
    for frame in frames { frame.gate.finish(.failure(CancellationError())) }
  }
}

/// Re-arm after stop's nil publication, then switch during the source-failure willSet.
@MainActor
private final class IdlePickerFailureObservation {
  private let owner: VideoFramePickerOwner
  private let switchSource: @MainActor () -> Void
  private(set) var notifications = 0
  init(owner: VideoFramePickerOwner, switchSource: @escaping @MainActor () -> Void) {
    self.owner = owner
    self.switchSource = switchSource
  }
  func track() {
    withObservationTracking { _ = owner.failure } onChange: { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.notifications += 1
        if self.notifications == 1 { self.track() }
        else if self.notifications == 2 { self.switchSource() }
      }
    }
  }
}
