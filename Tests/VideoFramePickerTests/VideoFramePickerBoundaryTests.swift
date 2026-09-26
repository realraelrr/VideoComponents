import AVFoundation
import XCTest
@testable import VideoFramePicker

@MainActor
final class VideoFramePickerBoundaryTests: XCTestCase {
  func testInvalidConfigurationFailsBeforeCallingLoader() {
    let sizes: [CGSize] = [
      .zero, CGSize(width: 4097, height: 1), CGSize(width: 1, height: 4097),
      CGSize(width: CGFloat.nan, height: 1), CGSize(width: 1, height: CGFloat.infinity),
      CGSize(width: 0.5, height: 1)
    ]
    for size in sizes {
      assertConfigurationFailure(initialTime: nil, maximumSize: size, reason: .invalidMaximumFrameSize)
    }
    for seconds in [Double.nan, .infinity, -.infinity, -0.01] {
      assertConfigurationFailure(
        initialTime: seconds, maximumSize: CGSize(width: 1280, height: 1280), reason: .invalidInitialTime
      )
    }
  }

  func testInvalidAndUnrepresentableDurationsNeverReachPlayerOrExtractor() async throws {
    let durations: [CMTime] = [
      .invalid, .indefinite, .positiveInfinity, .negativeInfinity,
      CMTime(value: -1, timescale: 600), CMTime(value: .max, timescale: 1)
    ]
    for duration in durations {
      let fixture = PickerFixture(duration: duration)
      fixture.start()
      try await waitForPicker { !fixture.failures.isEmpty }
      guard case .source(.invalidDuration, _) = fixture.failures[0] else {
        fixture.stop()
        return XCTFail("Expected invalidDuration for \(duration)")
      }
      XCTAssertNil(fixture.owner.player)
      XCTAssertTrue(fixture.frames.requests.isEmpty)
      XCTAssertTrue(fixture.owner.isSliderDisabled)
      fixture.stop()
    }
  }

  func testLargeFiniteInitialTimeClampsBeforeTimeConstruction() async throws {
    let fixture = PickerFixture()
    defer { fixture.stop() }
    fixture.start(initialTime: .greatestFiniteMagnitude)
    try await waitForPicker { fixture.frames.requests.count == 1 }
    XCTAssertEqual(fixture.frames.requests[0].seconds, 10)
    XCTAssertEqual(fixture.owner.selectedSeconds, 10)
    XCTAssertTrue(fixture.failures.isEmpty)
  }

  func testZeroDurationAttemptsInitialZeroAndDisablesSlider() async throws {
    let fixture = PickerFixture(duration: .zero)
    defer { fixture.stop() }
    fixture.start()
    try await waitForPicker { fixture.frames.requests.count == 1 }
    XCTAssertEqual(fixture.frames.requests[0].seconds, 0)
    XCTAssertTrue(fixture.owner.isSliderDisabled)
    fixture.frames.succeed(0)
    try await waitForPicker { fixture.owner.preview != nil }
    fixture.owner.changeSeconds(1, callbacks: fixture.callbacks)
    XCTAssertEqual(fixture.owner.selectedSeconds, 0)
    XCTAssertTrue(fixture.selections.isEmpty)
  }

  func testDurationEndpointIsRequestedUnchangedAndKeepsActualTime() async throws {
    let fixture = PickerFixture()
    defer { fixture.stop() }
    try await fixture.ready()
    fixture.owner.changeSeconds(10, callbacks: fixture.callbacks)
    try await waitForPicker { fixture.frames.requests.count == 2 }
    XCTAssertEqual(fixture.frames.requests[1].seconds, 10)
    fixture.frames.succeed(1, actualSeconds: 9.9666667)
    try await waitForPicker { fixture.selections.count == 1 }
    XCTAssertEqual(fixture.selections[0].requestedSeconds, 10)
    XCTAssertLessThan(fixture.selections[0].actualTime.seconds, 10)
  }

  func testInvalidSliderValuesCannotCreatePendingOrReplacePreview() async throws {
    let fixture = PickerFixture()
    defer { fixture.stop() }
    try await fixture.ready()
    for seconds in [Double.nan, .infinity, -.infinity, -1] {
      fixture.owner.changeSeconds(seconds, callbacks: fixture.callbacks)
    }
    await Task.yield()
    XCTAssertFalse(fixture.owner.hasPendingSelection)
    XCTAssertEqual(fixture.frames.requests.count, 1)
    XCTAssertEqual(fixture.owner.selectedSeconds, 1)
  }

  func testTimeFormattingPreservesMinutesBeyondThirtyTwoBitRange() throws {
    XCTAssertEqual(VideoFramePickerOwner.formatTime(0), "0:00")
    XCTAssertEqual(VideoFramePickerOwner.formatTime(59.6), "1:00")
    XCTAssertEqual(VideoFramePickerOwner.formatTime(3601), "60:01")
    let large = 3_000_000_001.0
    XCTAssertEqual(try VideoFramePickerOwner.validatedDuration(CMTime(seconds: large, preferredTimescale: 1)), large)
    XCTAssertEqual(VideoFramePickerOwner.formatTime(large), "50000000:01")
    for value in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -1] {
      XCTAssertEqual(VideoFramePickerOwner.formatTime(value), "0:00")
    }
  }

  func testSixLanguageResourcesResolveEveryFieldAndRegionFallback() {
    let locales = ["en", "zh-Hans", "zh-Hant", "es", "ja", "ko"]
    var localizedPreviews = Set<String>()
    for locale in locales {
      let labels = VideoFramePickerLabels(locale: Locale(identifier: locale))
      let values = [labels.preview, labels.time, labels.processing, labels.sourceUnavailable,
                    labels.frameUnavailable, labels.selectionFailed]
      for value in values {
        XCTAssertFalse(value.isEmpty)
        XCTAssertFalse(value.hasPrefix("frame_picker."), "Missing \(locale) translation")
      }
      localizedPreviews.insert(labels.preview)
    }
    XCTAssertEqual(localizedPreviews.count, 6)
    XCTAssertEqual(VideoFramePickerLabels(locale: Locale(identifier: "zh_CN")).preview, "画面预览")
    XCTAssertEqual(VideoFramePickerLabels(locale: Locale(identifier: "es_MX")).preview, "Vista previa del fotograma")
    XCTAssertEqual(VideoFramePickerLabels(locale: Locale(identifier: "en_US")).processing, "Processing selection")
  }

  func testInjectedLabelsAndNeutralFailureMappingNeverExposeUnderlyingError() {
    let labels = VideoFramePickerLabels(
      preview: "Preview override", time: "Time override", processing: "Processing override",
      sourceUnavailable: "Source override", frameUnavailable: "Frame override",
      selectionFailed: "Selection override"
    )
    let secret = NSError(domain: "/private/host/media.mov", code: 42)
    XCTAssertEqual(labels.preview, "Preview override")
    XCTAssertEqual(labels.time, "Time override")
    XCTAssertEqual(labels.processing, "Processing override")
    XCTAssertEqual(labels.message(for: .configuration(.invalidInitialTime)), "Source override")
    XCTAssertEqual(labels.message(for: .source(.unavailable, cause: secret)), "Source override")
    XCTAssertEqual(labels.message(for: .frame(cause: secret)), "Frame override")
    XCTAssertEqual(labels.message(for: .selectionProcessing(cause: secret)), "Selection override")
  }

  private func assertConfigurationFailure(
    initialTime: Double?, maximumSize: CGSize,
    reason: VideoFramePickerFailure.ConfigurationReason,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    let owner = VideoFramePickerOwner()
    defer { owner.stop() }
    var failure: VideoFramePickerFailure?
    owner.start(
      source: VideoFramePickerSource(identity: UUID(), load: {
        XCTFail("Invalid configuration called the loader", file: file, line: line)
        return AVMutableComposition()
      }),
      initialTime: initialTime, maximumFrameSize: maximumSize, onFailure: { failure = $0 }
    )
    guard case .configuration(let actual) = failure else {
      return XCTFail("Expected configuration failure", file: file, line: line)
    }
    XCTAssertEqual(actual, reason, file: file, line: line)
    XCTAssertNil(owner.player, file: file, line: line)
  }
}
