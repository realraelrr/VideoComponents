# VideoComponents

Three iOS libraries for AVFoundation video:

| Product | Includes | Dependencies |
| --- | --- | --- |
| `VideoPlayback` | A playback session, inline/fullscreen SwiftUI views, zoom and transport gestures, an independent seek coordinator, localized controls | Apple frameworks only |
| `VideoProcessing` | Frame extraction, automatic poster selection, slow MP4 export | Apple frameworks only |
| `VideoFramePicker` | A paused SwiftUI preview and time slider that asynchronously delivers exact user-selected frames | `VideoPlayback`, `VideoProcessing` |

`VideoPlayback` and `VideoProcessing` remain independent: neither depends on the other or on `VideoFramePicker`. The picker composes both. All three are independent of the host app, Photos, CloudKit and application persistence. `VideoProcessing` does not import SwiftUI.

## Platform and toolchain

The deployment target is iOS/iPadOS 17 or later. The manifest declares Swift tools 6.2 and Swift 6 language mode; the implementation uses Swift 6.2 syntax, including isolated deinitialization. This is a compiler requirement, separate from the OS deployment target.

The exercised toolchain is Xcode 27.0 (27A266a), Apple Swift 6.4, with iOS 27 Simulator. The oldest supported toolchain and iOS 17 runtime have not yet been exercised. A generic iOS build checks compilation against the deployment target, not runtime behavior on iOS 17.

## Installation

Choose **File → Add Package Dependencies** in Xcode, enter
`https://github.com/realraelrr/VideoComponents.git`, and select **Up to Next Major
Version** from `0.2.0`. Link only the product or products your target needs.
Version `0.2.0` adds the optional picker and automatic poster V2; the original
`VideoPlayback` and `VideoProcessing` products were introduced in `0.1.0`.

For a Swift package consumer, add the dependency and link the required products in
`Package.swift`:

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "MyFeature",
  platforms: [.iOS(.v17)],
  dependencies: [
    .package(url: "https://github.com/realraelrr/VideoComponents.git", from: "0.2.0"),
  ],
  targets: [
    .target(
      name: "MyFeature",
      dependencies: [
        .product(name: "VideoFramePicker", package: "VideoComponents"),
      ]
    ),
  ]
)
```

The example above links the picker and its two dependencies. For playback or
processing alone, replace the product name with `VideoPlayback` or
`VideoProcessing`; either can be consumed without building the picker.

## Public example

Open `Example/VideoComponentsExample.xcodeproj`, select `VideoComponentsExample`, and run on an iPhone or iPad Simulator. The example uses ordinary imports of all three public products. It creates a three-second H.264 pattern locally, with no downloaded media or photo permission, and demonstrates:

- `InlinePlaybackView` and `FullscreenPlaybackView` sharing one `PlaybackSession`.
- A real first frame and an automatic poster from `VideoProcessing`.
- `VideoFramePickerView` delivering an image, the requested position, and the actual decoded time to its host.
- A 0.5× export, playback of the original/exported file, and sharing the resulting MP4.

The example owns its generated files and removes them when its media owner is released. It uses normal scene orientation support and makes no global audio-session or window-orientation changes.

## Playback ownership

Create the session once at the feature owner, then pass the same instance to inline and fullscreen views. With the current `ObservableObject` API, a SwiftUI owner can use `@StateObject`:

```swift
import AVFoundation
import SwiftUI
import VideoPlayback

@StateObject private var session = PlaybackSession()

// Call from the owner's loading lifecycle, using a stable media identity.
let source = PlaybackSource(identity: fileURL, load: { AVURLAsset(url: fileURL) })
session.load(source: source, playbackRate: 1, isLooping: true, autoplayWhenReady: false)
```

The source identity must change when the underlying media changes and remain stable across view updates. The source supplies a cancellable `@MainActor` asset loader and an optional thumbnail loader. Supply the host's authorization and resource-access logic there. Access refreshes use `revalidateAccess(source:refreshID:validation:)`; its synchronous validation factory is invoked only for the current source and a new refresh ID. The session owns suspension, cancellation, stale-result rejection and restoration of its existing item.

Pass `isFullscreenPresented` to `InlinePlaybackView` while presenting the fullscreen view. This detaches the inline rendering layer while the fullscreen view renders the same player. Closing fullscreen must not destroy the session. Call `cleanup()` when the feature actually releases its playback work, rather than on every inline view disappearance.

`session.player` is a rendering surface. Do not replace its item, seek it directly, or maintain a second transport state. Configure playback through session methods. Global audio category/activation, photo access, screen orientation, haptics and recovery copy belong to the host; `onEvent` exposes playback/cleanup/hold events for host integration.

Controls support scrubbing, double-tap play/pause, long-press boost, pinch zoom and panning when zoomed. The inline view accepts an outer-scroll binding; connect it to the containing scroll view's `.scrollDisabled` modifier so video gestures and scrolling do not compete. The host provides accessories, status content, style and optional localized labels.

For a separate manual-frame preview, `VideoSeekCoordinator` borrows an independent `AVPlayer`. It must be the only seek initiator for that item while active. Call `reset()` before an external seek or item replacement; it cancels pending seeks. Do not attach a second coordinator to the playback session's player.

## Manual frame selection

The picker owns its paused player, seeks, frame requests and cancellation. Its source borrows an asset from the host; it never cancels loading on that asset. Ordinary `import VideoFramePicker` is sufficient:

```swift
import AVFoundation
import SwiftUI
import VideoFramePicker

struct FrameSelectionExample: View {
  let fileURL: URL
  @State private var selectedFrame: VideoFrameSelection?
  @State private var isSelecting = false

  var body: some View {
    VideoFramePickerView(
      source: VideoFramePickerSource(identity: fileURL, load: { AVURLAsset(url: fileURL) }),
      initialTime: 0,
      maximumFrameSize: CGSize(width: 1280, height: 1280),
      onSelectionActivityChanged: { isSelecting = $0 },
      onSelection: { frame in
        try Task.checkCancellation()
        selectedFrame = frame
      }
    )
  }
}
```

The initial preview never invokes `onSelection`. Touching the slider without changing its value does not consume a frame. Dragging uses interactive preview seeks; release extracts the latest user position with exact tolerance, then awaits `onSelection`. Accessibility or keyboard value changes use the same exact extraction and consumption path. The slider stays disabled while the host callback is running. A consumer failure retains the exact preview and reports a neutral, localized failure.

`onSelection` is an `@MainActor` async throwing callback executed in the picker's cancellable task. Keep any asynchronous preparation inside that callback. After every suspension and immediately before the final visible or persistent mutation, the host must check cancellation and confirm the destination identity is still current. Cancellation cannot roll back a host write that already happened. `VideoFrameSelection.image` is a `CGImage`; retain `requestedSeconds` and `actualTime` separately because native decoding may choose a different encoded timestamp, including at the duration endpoint.

Source identity covers both the media and its selection destination. Change it when either changes. The loader, initial time and frame size are captured for that identity; changing just their values does not reload a mounted picker. Selection and failure callbacks are captured at each user value change, so a pending selection retains the callbacks that accepted it. Disappearance and source replacement cancel old work and reject late results, including A → B → A replacement.

The activity observer reports the initial `false`, pending-selection changes, and `false` on disappearance. Its state destination must remain attached to the same mounted picker instance. Replacing the observer closure does not replay the current busy state; unmount before transferring observation to another state container. Labels and colors are supplied through `VideoFramePickerLabels` and `VideoFramePickerStyle`. `Labels(locale:)` resolves the package's own localized resources, including regional locales. No Photos permission, persistence, retry button or screen-level navigation is added by the component.

## Processing and file ownership

```swift
import AVFoundation
import VideoProcessing

let frame = try await VideoFrameExtractor.frame(
  for: asset, at: 0, maximumSize: CGSize(width: 1280, height: 1280), exact: true
)
// frame.image is CGImage; frame.actualTime is the generator's actual result time.
let poster = try await AutomaticVideoPosterSelector.select(from: asset)

let output = try await SlowVideoExporter.exportSlowedVideo(
  asset: asset,
  rate: 0.5,
  outputDirectory: FileManager.default.temporaryDirectory,
  onProgress: { progress in /* update host presentation */ }
)
// Success transfers ownership of output to the caller. Save, share or delete it.
```

These operations are `@MainActor` async APIs. Frame time must be finite and nonnegative; each maximum-size dimension must be finite and within 1...4096 pixels. Invalid values produce typed errors. This size bound is a resource budget, not a claim that every device can process every 4096-pixel asset efficiently.

Extraction does not preload duration or clamp a finite nonnegative request to it. `exact` sets both native tolerances to zero; it does not guarantee that a duration endpoint is an encoded frame. AVFoundation may return a nearby final frame even with zero tolerance, so always use `actualTime`. An unavailable frame produces `frameUnavailable`, with a diagnostic cause when available.

Automatic posters use algorithm version **2**. Up to 12 equal-segment midpoints cover the clip, with fewer requests for short clips: `count = min(12, max(1, floor(duration / 0.10)))`. Analysis decoding is bounded to 192 pixels; grayscale analysis preserves aspect ratio with a 96-pixel long edge. Black, white and low-information rejection thresholds remain unchanged. Equivalent decoded `actualTime` values are counted once.

The technical score is bounded to `0...1`: capped contrast (`standardDeviation / 64`) and gradient (`gradient / 24`) each contribute 40%, and exposure contributes 20%. Only frames scoring at least 80% of the best usable candidate may win. From those, the selector chooses the smallest squared distance to the mean normalized 16-bin luminance histogram of all usable candidates. Equal distances choose the earliest actual timestamp. The representative-histogram idea is inspired by [FFmpeg's thumbnail filter](https://www.ffmpeg.org/doxygen/trunk/vf__thumbnail_8c_source.html); no FFmpeg code or dependency is included.

Only the selected frame is decoded again at up to 1280 pixels, with exact tolerance and the original rational `CMTime`. The final actual timestamp must match the analyzed frame; mismatch or extraction failure does not silently select another time. Zero duration attempts time zero once; negative or nonfinite durations yield no candidate. No usable candidate produces `noUsableFrame`. Sampling, caps and the 80% threshold are empirical choices, without a claimed blind-review improvement. This heuristic does not identify people, choose a best dance pose, or support live/indefinite media; it adds no Vision/ML, scene clustering, extra cache or background analysis system.

Export accepts only finite rates in `0.25...1.0`, preserves track orientation and scaled audio/video timing, and uses spectral audio time pitch. The destination must be an existing local directory. Each operation gets a unique MP4 filename and does not overwrite existing files. Progress `1` is emitted only after successful native completion. Success transfers the file to the host; cancellation/failure removes only this operation's output. The source and unrelated files remain owned by the host. Photos saving and permission requests are deliberately host responsibilities.

Public errors distinguish validation, unavailable media and export failure. Causes are intended for privacy-safe diagnostics; map them to the host's concise user-facing messages. A genuinely cancelled task throws `CancellationError`; a framework-only cancellation can remain a typed failure.

## Verification

Allocate an iPhone Simulator, then run:

```bash
VIDEO_COMPONENTS_SIMULATOR_ID="<allocated iPhone Simulator UUID>" \
  ./Scripts/verify.sh
```

Optional variables are `VIDEO_COMPONENTS_RESULTS_DIR` (a fresh result directory outside the repository) and `VIDEO_COMPONENTS_JOBS` (default `2`). Existing results are never overwritten. Coordinate Simulator use with other test runs.

The script copies the package and public example to an external directory. It builds Playback-only, Processing-only and FramePicker-only public consumers. Playback-only and Processing-only must not build the other product or the picker; FramePicker-only must build all three. It then runs the `VideoComponents-Package` aggregate test scheme, the example's runtime resource tests, and generic iOS/Simulator example builds. Product schemes are for building products; they do not provide the package test actions.

The xcresult checker requires a successful nonempty result, no failures/skips/expected failures, all test IDs discovered from the isolated snapshot, and explicit critical cases. Runtime resource tests resolve each compiled package bundle through `VideoPlaybackLabels(locale:)` and `VideoFramePickerLabels(locale:)`: all six labels per module in English and Simplified Chinese, plus regional Chinese/Spanish resolution. They do not read resource source files.

The four mounted SwiftUI picker tests run in the existing example app's test target, which supplies the UIKit application host required by `UIWindow` and `UIHostingController`. They retain their test IDs and share the package's test helper source. The example app uses ordinary product imports; only these white-box tests use `@testable` owner injection. Package and consumer expectations are discovered and checked separately.

Supplied media coverage includes synthetic image scoring, real short H.264 frames, actual frame times, rotation, multiple slow rates, offset audio and export cancellation/file cleanup. Poster V2 tests independently cover the quality gate, representativeness, timestamp deduplication, the exact final request, rejection, failures and cancellation through an internal extraction closure. Picker tests cover initial preview, gestures versus value changes, suspended consumption, callback snapshots, source replacement and lifecycle cancellation. Started native image-generator cancellation is not directly instrumented. Physical-device permissions, iCloud/Photos behavior, UIKit gesture competition, HDR, long media and a broad codec matrix require separate acceptance evidence. Supplied checks and successful builds do not imply that all those environments have passed.

## License

Licensed under the [Apache License 2.0](LICENSE). See [NOTICE](NOTICE) for attribution.
