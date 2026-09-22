# VideoComponents

Two independent iOS libraries for AVFoundation video:

| Product | Includes | Dependencies |
| --- | --- | --- |
| `VideoPlayback` | A playback session, inline/fullscreen SwiftUI views, zoom and transport gestures, an independent seek coordinator, localized controls | Apple frameworks only |
| `VideoProcessing` | Frame extraction, automatic poster selection, slow MP4 export | Apple frameworks only |

Neither product depends on the other. Both are independent of the host app, Photos, CloudKit and application persistence. `VideoProcessing` does not import SwiftUI.

## Platform and toolchain

The deployment target is iOS/iPadOS 17 or later. The manifest declares Swift tools 6.2 and Swift 6 language mode; the implementation uses Swift 6.2 syntax, including isolated deinitialization. This is a compiler requirement, separate from the OS deployment target.

The exercised toolchain is Xcode 27.0 (27A266a), Apple Swift 6.4, with iOS 27 Simulator. The oldest supported toolchain and iOS 17 runtime have not yet been exercised. A generic iOS build checks compilation against the deployment target, not runtime behavior on iOS 17.

## Installation

In Xcode, choose **File → Add Package Dependencies**, enter
`https://github.com/realraelrr/VideoComponents.git`, and select **Up to Next Major
Version** from `0.1.0`. Link only the product or products your target needs.

For a Swift package consumer, add the dependency and link the required products in
`Package.swift`:

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "MyFeature",
  platforms: [.iOS(.v17)],
  dependencies: [
    .package(url: "https://github.com/realraelrr/VideoComponents.git", from: "0.1.0"),
  ],
  targets: [
    .target(
      name: "MyFeature",
      dependencies: [
        .product(name: "VideoPlayback", package: "VideoComponents"),
        .product(name: "VideoProcessing", package: "VideoComponents"),
      ]
    ),
  ]
)
```

The example above links both products. Remove either `.product` entry when you
only need the other; neither product pulls in the other as a dependency.

## Public example

Open `Example/VideoComponentsExample.xcodeproj`, select `VideoComponentsExample`, and run on an iPhone or iPad Simulator. The example uses ordinary imports of both public products. It creates a three-second H.264 pattern locally, with no downloaded media or photo permission, and demonstrates:

- `InlinePlaybackView` and `FullscreenPlaybackView` sharing one `PlaybackSession`.
- A real first frame and an automatic poster from `VideoProcessing`.
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

Automatic posters retain algorithm version **1**: five bounded candidate times, the existing grayscale contrast/exposure/detail score, 192-pixel analysis, and a final nonexact extraction at up to 1280 pixels. Unknown or nonfinite durations keep the existing `[0]` candidate attempt. The final image can differ from the scored analysis frame. This heuristic does not promise the best person, pose or action frame, nor support for live/indefinite media. No usable candidate produces `noUsableFrame`.

Export accepts only finite rates in `0.25...1.0`, preserves track orientation and scaled audio/video timing, and uses spectral audio time pitch. The destination must be an existing local directory. Each operation gets a unique MP4 filename and does not overwrite existing files. Progress `1` is emitted only after successful native completion. Success transfers the file to the host; cancellation/failure removes only this operation's output. The source and unrelated files remain owned by the host. Photos saving and permission requests are deliberately host responsibilities.

Public errors distinguish validation, unavailable media and export failure. Causes are intended for privacy-safe diagnostics; map them to the host's concise user-facing messages. A genuinely cancelled task throws `CancellationError`; a framework-only cancellation can remain a typed failure.

## Verification

Allocate an iPhone Simulator, then run:

```bash
VIDEO_COMPONENTS_SIMULATOR_ID="<allocated iPhone Simulator UUID>" \
  ./Scripts/verify.sh
```

Optional variables are `VIDEO_COMPONENTS_RESULTS_DIR` (a fresh result directory outside the repository) and `VIDEO_COMPONENTS_JOBS` (default `2`). Existing results are never overwritten. Coordinate Simulator use with other test runs.

The script copies the package and public example to an external directory. It builds independent Playback-only and Processing-only consumers and checks that the other product was not built. It then runs the `VideoComponents-Package` aggregate test scheme, the example's runtime resource tests, and generic iOS/Simulator example builds. The `VideoPlayback` and `VideoProcessing` product schemes are for building products; they do not provide the package test actions.

The xcresult checker requires a successful nonempty result, no failures/skips/expected failures, all test IDs discovered from the isolated snapshot, and explicit critical cases. Runtime resource tests resolve the compiled package bundle through `VideoPlaybackLabels(locale:)`: all six labels in English and Simplified Chinese, plus regional Chinese/Spanish resolution. They do not read resource source files.

Current media coverage includes synthetic image scoring, real short H.264 frames, actual frame times, rotation, multiple slow rates, offset audio and export cancellation/file cleanup. Frame/poster cancellation coverage includes pre-cancelled requests; started image-generator cancellation is not directly instrumented. Physical-device permissions, iCloud/Photos behavior, UIKit gesture competition, HDR, long media and a broad codec matrix require separate acceptance evidence. Supplied checks and successful builds do not imply that all those environments have passed.

## License

Licensed under the [Apache License 2.0](LICENSE). See [NOTICE](NOTICE) for attribution.
