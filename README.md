# VideoComponents

iOS libraries for AVFoundation video and finite Photos/local-file resource acquisition:

| Product | Includes | Dependencies |
| --- | --- | --- |
| `VideoResources` | Finite shareable acquisition, actual asset/audio-mix receipts, Photos authority and verified local-file facts | Apple frameworks only |
| `VideoResourcesPlayback` | One session's acquisition shares and independent representation installation | `VideoResources`, `VideoPlayback` |
| `VideoPlayback` | A playback session, inline/fullscreen SwiftUI views, zoom and transport gestures, an independent seek coordinator, localized controls | Apple frameworks only |
| `VideoProcessing` | Frame extraction, automatic poster selection, slow MP4 export | Apple frameworks only |
| `VideoFramePicker` | A paused SwiftUI preview and time slider that asynchronously delivers exact user-selected frames | `VideoPlayback`, `VideoProcessing` |

`VideoPlayback` and `VideoProcessing` remain independent: neither depends on the other or on `VideoFramePicker`. The picker composes both. Playback, processing and picker remain independent of the host app, Photos, CloudKit and application persistence. The optional resource core uses Photos but owns no application persistence, account binding or download policy. `VideoProcessing` does not import SwiftUI.

## Platform and toolchain

The deployment target is iOS/iPadOS 17 or later. The manifest declares Swift tools 6.2 and Swift 6 language mode; the implementation uses Swift 6.2 syntax, including isolated deinitialization. This is a compiler requirement, separate from the OS deployment target.

The exercised toolchain is Xcode 27.0 (27A266a), Apple Swift 6.4, with iOS 27 Simulator. The oldest supported toolchain and iOS 17 runtime have not yet been exercised. A generic iOS build checks compilation against the deployment target, not runtime behavior on iOS 17.

## Installation

Choose **File → Add Package Dependencies** in Xcode, enter
`https://github.com/realraelrr/VideoComponents.git`, and select **Up to Next Major
Version** from `0.3.0`. Link only the product or products your target needs.
Version `0.2.0` adds the optional picker and automatic poster V2; the original
`VideoPlayback` and `VideoProcessing` products were introduced in `0.1.0`.
Version `0.2.1` fixes fullscreen idle chrome, zoomed pan boundaries and cancelled scrubbing.
Version `0.2.2` fixes repeated-pinch focus, fullscreen status layering, same-source loading and rate consistency, loading presentation, layout limits, frame cancellation ordering and disabled export tracks.
Version `0.3.0` adds cancellable same-source representation replacement with transport restoration, host-provided picker source-status overlays, and a paused preview that appears before initial exact-frame decoding completes. The picker view is now generic over its source-status content; consumers using an explicit `VideoFramePickerView` type must account for that type change.

For a Swift package consumer, add the dependency and link the required products in
`Package.swift`:

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "MyFeature",
  platforms: [.iOS(.v17)],
  dependencies: [
    .package(url: "https://github.com/realraelrr/VideoComponents.git", from: "0.3.0"),
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
let source = PlaybackSource(identity: fileURL, load: { PlaybackLoadedMedia(asset: AVURLAsset(url: fileURL)) })
session.load(source: source, playbackRate: 1, isLooping: true, autoplayWhenReady: false)
```

The source identity must change when the underlying media changes and remain stable across view updates. The source supplies a cancellable `@MainActor` loaded-media loader and an optional thumbnail loader. Supply the host's authorization and resource-access logic there. Access refreshes use `revalidateAccess(source:refreshID:validation:)`; its synchronous validation factory is invoked only for the current source and a new refresh ID. The session owns suspension, cancellation, stale-result rejection and restoration of its existing item. Same-identity `load` calls preserve in-flight loading or access validation and apply the latest playback configuration; autoplay requests can establish playback intent without ordinary view appearances clearing it.

Pass `isFullscreenPresented` to `InlinePlaybackView` while presenting the fullscreen view. This detaches the inline rendering layer while the fullscreen view renders the same player. Closing fullscreen must not destroy the session. Call `cleanup()` when the feature actually releases its playback work, rather than on every inline view disappearance.

Inline and fullscreen keep a supplied poster opaque while the source prepares in the background, including after the item and native layer become ready. Play/pause remains available during acquisition: the first tap requests playback and another tap cancels that intent without discarding background preparation. Use `session.isWaitingForPlayback` to show a loading indicator only after playback is requested, including host preparation and later buffering. Keep unavailable/retry content independent of that indicator. The poster hands off only when the current item is ready, its rendering layer is ready for display, and native playback is actually playing; `willPlay` and item readiness alone do not prove presentation.

Both accept an optional `placeholderImage: { ... }` provider, which can supply an already displayed host image before acquisition finishes. A supplied provider is authoritative even when it returns nil; omitting it uses the source thumbnail. If a poster is unavailable before the first playback, the existing black media background stays opaque rather than exposing a paused first frame.

The native layer reports presentation to the source-scoped `session.hasPresentedVideo` fact. Pausing keeps the current video picture, and moving that session into fullscreen or back retains the handoff. The standalone `InlineVideoPlayerLayer` keeps its default readiness-based behavior for independent paused previews; shared playback views enable `waitsForPlayback`.

Once a source displays video, replacing its representation keeps the native picture visible instead of showing its poster again. When the host selection can change before `load`, pass its expected `sourceIdentity` to the shared view; only a matching session source can render. Omitting this argument uses `PlaybackSession.currentSourceIdentity`. A true source change or session cleanup resets the handoff. Temporary layer detachment for fullscreen and same-source representation changes preserve it.

`session.player` is a rendering surface. Do not replace its item, seek it directly, or maintain a second transport state. Configure playback through session methods. Global audio category/activation, photo access, screen orientation, haptics and recovery copy belong to the host. `onEvent` exposes observational playback/cleanup/hold events; `willPlay` is not an awaitable preparation boundary.

When playback requires host preparation, set `session.preparation` before `load`:

```swift
session.preparation = PlaybackPreparation(
  prepare: { leaseID in try await audioPolicy.prepare(leaseID) },
  release: { leaseID in audioPolicy.release(leaseID) }
)
```

`PlaybackPreparation` and both closures are `@MainActor`. The default is nil, preserving direct playback for consumers that need no preparation. Each continuous playback demand has a unique UUID lease. Native playback waits for `prepare` to succeed. Repeated reconciliation, rate changes, temporary scrubbing/seeking, loop restarts and same-source representation replacement retain that lease. After preparation returns, the session reads its current item, seek readiness, intent and rate rather than restoring captured values.

`pausePlayback()` ends playback intent and any hold without discarding media or time; use it for host interruptions or media-service resets. Explicit pause, the end of a hold that began paused, playback failure, nonlooping playback end, source replacement and `cleanup()` invalidate pending preparation before pausing the player, then call `release` once. Cleanup also detaches the item. Preparation checks request identity before invoking the host and after every result, so a request cancelled before its task runs cannot activate, and late success/failure cannot play or alter a newer request. A suspended preparation task does not retain the session.

The host's `prepare` closure must synchronously register or submit the UUID reservation before its first suspension. Serialize that submitted preparation with `release`, which can be called while preparation is pending, and guarantee that late completion cannot resurrect a released reservation. Task cancellation alone does not roll back physical activation already underway. `release` must also tolerate an unknown UUID: if the session pauses before the preparation task enters, the host receives only release and that task will never invoke prepare. These host ordering requirements are part of the contract; arbitrary asynchronous preparation does not provide them. The session captures the preparation/release pair for each lease; configure a different pair before loading another source or after cleanup.

A current preparation error publishes `PlaybackFailure.preparation(error)` and `.unavailable`, ends intent and hold, and releases the lease while retaining the source, ready item and position. Map this distinct failure to the host's concise audio recovery message. Call `retryPlaybackPreparation()` only from an explicit user retry; it prepares a new lease and resumes the retained item at its current position. Ordinary load updates, rate changes and gestures do not retry a preparation failure. Access revalidation, same-source representation replacement and even a forced same-identity source reload preserve that failure and stopped intent. Source retry remains a separate loading operation; a new source identity clears the old failure.

For a different representation of the same media, call `try await session.replaceAsset(media, for: source.identity)`. `PlaybackLoadedMedia` carries the actual asset, optional audio mix and a synchronous throwing validity check; native validates this same result before installation and after asynchronous readiness/seek boundaries. An invalid previous result cannot be restored on rollback. Native never imports the resource core. `currentLoadedMedia` describes the actual current item; a newly obtained access result does not replace the retained snapshot's media. Asset preparation keeps the existing item usable. Native item readiness briefly pauses the same player after candidate installation; native readiness or restoring-seek failure restores the previous item. The switch uses the latest position or pending seek/scrub target, playback intent, configured rate and loop setting. A hold ends rather than becoming the new playback rate or intent. The operation waits for the restoring seek to succeed. A newer user seek can instead adopt the ready candidate, completing the replacement while its own transport continues; the obsolete restoring callback is rejected. Playback always waits for the current seek to succeed. Task cancellation restores the previous item while the operation is pending. Source replacement, cleanup and newer representation requests invalidate older results, including A → B → A reuse of an identity.

Controls support scrubbing, double-tap play/pause, long-press boost, pinch zoom and panning when zoomed. The inline view accepts an outer-scroll binding; connect it to the containing scroll view's `.scrollDisabled` modifier so video gestures and scrolling do not compete. The host provides accessories, status content, style and optional localized labels.

Fullscreen chrome hides after three idle seconds. Single-tap the video to show or hide it; double-tap still changes playback. Contact with the video or controls suspends the idle countdown until all fingers leave. VoiceOver keeps chrome available. Zoomed panning is limited by the actual aspect-fit video bounds: smaller axes stay centered, larger axes cover the viewport, and resizing recalculates the limits. Each pinch keeps the current source point beneath the fingers, including after an earlier pinch or pan. Status content stays below fullscreen chrome so close remains available.

For a separate manual-frame preview, `VideoSeekCoordinator` borrows an independent `AVPlayer`. It must be the only seek initiator for that item while active. Call `reset()` before an external seek or item replacement; it cancels pending seeks. Do not attach a second coordinator to the playback session's player.

## Optional resource ownership (current unreleased main)

`VideoResources` and `VideoResourcesPlayback`, together with the single `PlaybackLoadedMedia` API, are changes on main. Existing release tags retain their previous APIs. An app using the old raw-asset loader must adapt its load/access/replacement call sites before selecting this revision; the changes are not a transparent dependency update.

A host retains one `VideoResources` for sources that should share acquisition. A source has a stable Photos cloud reference or a host key identifying a complete immutable file descriptor. The file verifier must inspect an already materialized local file and return the facts from that integrity check. It must not download or make account decisions. Core file checks are observational facts, not an atomic lease on future AVFoundation reads.

`source.prepare(request)` synchronously registers a cancellation share; `share()` creates another cancellation right. Cancelling one handle does not cancel another. `value()` waits for the finite result; cancelling a waiting Task alone does not withdraw a held share. Release the preparation with `cancel()` or use `source.acquire(request)` for Task-owned finite acquisition. Photos authority refresh invalidates stale receipts without automatically retrying. Cached `preferred` is a source result, never proof that a playback session installed it.

```swift
import VideoResources
import VideoResourcesPlayback

let resources = VideoResources(verifiedFile: { key in
  try await localStore.inspectMaterializedVideo(key)
})
let playback = VideoResourcePlayback(preparation: hostAudioPreparation)
playback.load(source: resources.fileSource(identity: immutableDescriptorKey))
// Pass playback.session to the existing inline/fullscreen views.
// Explicit owner action, not an inline rendering view's onDisappear:
playback.requestHighQuality()
playback.cleanup()
```

A `VideoResourcePlayback` owns the native session's event hook. Supply host observations through its initializer; do not replace `session.onEvent`. Its loader starts a source visit only when native loading actually enters. Cleanup synchronously withdraws only this owner's initial/HQ shares, before forwarding the host event. Inline/fullscreen share this owner. HQ success is installed independently in each session; one session's installation failure does not invalidate the shared result. `installedReceipt` is available only for a current, ready, matching asset/mix. Initial loading may have obtained a result before this property becomes available. `qualityFailure` is local to this session, with host-owned recovery copy and interactions. This product adds no UI, audio policy or operation-progress controller.

Audio preparation Retry calls the native preparation path with zero resource acquisitions. Resource Retry explicitly accepts the host's currently selected source and creates a new finite consumption for this owner, including after native source invalidation has released the old visit; callers preserve their explicit autoplay choice through `retry(source:request:thumbnail:autoplayWhenReady:)`. Rate and loop settings remain owned by the native session. Business draft/save/export consumers use their own shares and final receipt validation; a playback owner cannot cancel their work.

The DanceCheckin production resolver has not been migrated to these products. Its eventual cutover must replace every resource consumer together: playback, editor/frame selection, HQ/export, draft preview and save. Remove the old resolver's acquisition task/cache, owner/consumer bookkeeping, preferred/revision facts and global retry startup with that switch. Retain host resource mapping, local Store integrity/materialization, Photos authorization interactions, account isolation, audio FIFO, poster masters/thumbnail cache, cancellation at final business mutations and the actual feature-exit boundary. Do not copy the isolated HostHarness Store into production or operate two source authorities for one media identity.

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

The paused player is shown as soon as the source installs, while the initial exact frame is still decoding. Inspection checks duration and the video track; `isReadable` is not an image-generator capability requirement. An optional `statusOverlay` closure receives `VideoFramePickerSourceStatus.loading`, `.ready` or `.failed(failure)` so a host can reuse its source progress and error presentation. Supplying it replaces the default source spinner and source-error text. Exact-frame and selection-processing failures retain the picker's localized feedback. The component's source loader remains the sole loading entry point.

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

Export accepts only finite rates in `0.25...1.0`, includes only enabled source tracks, preserves track orientation and scaled audio/video timing, and uses spectral audio time pitch. The destination must be an existing local directory. Each operation gets a unique MP4 filename and does not overwrite existing files. Progress `1` is emitted only after successful native completion. Success transfers the file to the host; cancellation/failure removes only this operation's output. The source and unrelated files remain owned by the host. Photos saving and permission requests are deliberately host responsibilities.

Public errors distinguish validation, unavailable media and export failure. Causes are intended for privacy-safe diagnostics; map them to the host's concise user-facing messages. A genuinely cancelled task throws `CancellationError`; a framework-only cancellation can remain a typed failure.

## Verification

Allocate an iPhone Simulator, then run:

```bash
VIDEO_COMPONENTS_SIMULATOR_ID="<allocated iPhone Simulator UUID>" \
  ./Scripts/verify.sh
```

Optional variables are `VIDEO_COMPONENTS_RESULTS_DIR` (a fresh result directory outside the repository) and `VIDEO_COMPONENTS_JOBS` (default `2`). Existing results are never overwritten. Coordinate Simulator use with other test runs.

The script copies the package and public example to an external directory. It builds Playback-only, Processing-only and FramePicker-only public consumers. Playback-only and Processing-only must not build the other product or the picker; FramePicker-only must build all three. It then runs the `VideoComponents-Package` aggregate test scheme, the example's runtime resource tests, and generic iOS/Simulator example builds. Product schemes are for building products; they do not provide the package test actions.

The consumer action also runs poster handoff tests. `verify.sh` starts a bounded `simctl` screenshot driver for the allocated Simulator, supplies its fresh capture directory to the test host, and stops it after testing. Requests, native readiness facts and PNGs remain in `CaptureScreens`; driver errors remain in `CaptureDriver.log`. Tests first calibrate real red poster and green video pixels, then cover readiness ordering, layer transfer, replacement, cleanup, missing poster and an authoritative nil provider. Missing capture evidence fails the test. Product code has no capture protocol or test timing behavior.

The xcresult checker requires a successful nonempty result, no failures/skips/expected failures, all test IDs discovered from the isolated snapshot, and explicit critical cases. Runtime resource tests resolve each compiled package bundle through `VideoPlaybackLabels(locale:)` and `VideoFramePickerLabels(locale:)`: all six labels per module in English and Simplified Chinese, plus regional Chinese/Spanish resolution. They do not read resource source files.

The four mounted SwiftUI picker tests, five mounted playback tests and three mounted status/layout tests run in the existing example app's test target, which supplies the UIKit application host required by `UIWindow` and `UIHostingController`. The picker tests retain their test IDs and share the package's test helper source. Playback tests check idle chrome, contact cancellation and single-tap restoration, rendered video boundaries after panning and resizing, repeated-pinch focus, and close-button visibility above a blocking status overlay. Status/layout tests check source-load failure feedback, slow-operation progress and caller-provided size limits. The example app uses ordinary product imports; these tests use `@testable` access. Package and consumer expectations are discovered and checked separately.

Supplied media coverage includes synthetic image scoring, real short H.264 frames, actual frame times, rotation, multiple slow rates, offset audio and export cancellation/file cleanup. Poster V2 tests independently cover the quality gate, representativeness, timestamp deduplication, the exact final request, rejection, failures and cancellation through an internal extraction closure. Picker tests cover initial preview, gestures versus value changes, suspended consumption, callback snapshots, source replacement and lifecycle cancellation. Cancellation registration ordering is covered with controlled native-boundary tests. Started iOS image-generator cancellation is not directly instrumented. Physical-device permissions, iCloud/Photos behavior, UIKit gesture competition, HDR, long media and a broad codec matrix require separate acceptance evidence. Supplied checks and successful builds do not imply that all those environments have passed.

## License

Licensed under the [Apache License 2.0](LICENSE). See [NOTICE](NOTICE) for attribution.
