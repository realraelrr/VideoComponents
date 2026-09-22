#!/bin/bash
set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
package_root=$(CDPATH='' cd -- "$script_dir/.." && pwd)
simulator_id=${VIDEO_COMPONENTS_SIMULATOR_ID:?Set VIDEO_COMPONENTS_SIMULATOR_ID to the allocated iPhone Simulator UUID}
jobs=${VIDEO_COMPONENTS_JOBS:-2}

python3 "$script_dir/assert-results.py" --self-test
if [ -n "${VIDEO_COMPONENTS_RESULTS_DIR:-}" ]; then
  mkdir -p "$VIDEO_COMPONENTS_RESULTS_DIR"
  result_dir=$(CDPATH='' cd -- "$VIDEO_COMPONENTS_RESULTS_DIR" && pwd)
else
  result_dir=$(mktemp -d "${TMPDIR:-/tmp}/video-components-validation.XXXXXX")
fi
for name in IsolatedConsumer Metadata.log PackageTests.log ConsumerTests.log \
  PackageTests.xcresult ConsumerTests.xcresult PackageDerivedData ConsumerDerivedData \
  ConsumerDeviceDerivedData ConsumerSimulatorBuild.log ConsumerDeviceBuild.log \
  PlaybackOnlyDerivedData ProcessingOnlyDerivedData PlaybackOnlyBuild.log ProcessingOnlyBuild.log; do
  if [ -e "$result_dir/$name" ]; then
    printf 'error: refusing to overwrite %s\n' "$result_dir/$name" >&2
    exit 1
  fi
done
python3 "$script_dir/prepare-validation.py" "$package_root" "$result_dir/IsolatedConsumer"
isolated="$result_dir/IsolatedConsumer"
destination="platform=iOS Simulator,id=$simulator_id"
consumer_project="$isolated/Consumer/VideoComponentsExample.xcodeproj"

{
  xcodebuild -version
  swift --version
  xcrun simctl list --json | python3 -c '
import json, sys
inventory = json.load(sys.stdin)
identifier = sys.argv[1]
matches = [(runtime, device) for runtime, devices in inventory["devices"].items()
           for device in devices if device["udid"] == identifier and device.get("isAvailable")]
if len(matches) != 1:
    raise SystemExit("error: selected Simulator is not available: " + identifier)
runtime_id, device = matches[0]
runtime = next(runtime for runtime in inventory["runtimes"] if runtime["identifier"] == runtime_id)
print("Simulator ID: " + identifier)
print("Simulator name: " + device["name"])
print("Simulator OS: " + runtime["name"] + " " + runtime["version"])
print("Simulator OS build: " + runtime["buildversion"])
' "$simulator_id"
} 2>&1 | tee "$result_dir/Metadata.log"

# Each consumer references exactly one product from the same external package copy.
for product in Playback Processing; do
  (
    cd "$isolated/${product}OnlyConsumer"
    xcodebuild -jobs "$jobs" -scheme "${product}OnlyConsumer" \
      -destination 'generic/platform=iOS' \
      -derivedDataPath "$result_dir/${product}OnlyDerivedData" \
      CODE_SIGNING_ALLOWED=NO build
  ) 2>&1 | tee "$result_dir/${product}OnlyBuild.log"
  python3 - "$result_dir/${product}OnlyDerivedData/Build/Products/Debug-iphoneos" "$product" <<'PY'
from pathlib import Path
import sys
products = Path(sys.argv[1])
expected = "Video" + sys.argv[2]
other = "VideoProcessing" if expected == "VideoPlayback" else "VideoPlayback"
if not (products / (expected + ".swiftmodule")).exists():
    raise SystemExit("error: expected product was not built: " + expected)
if (products / (other + ".swiftmodule")).exists() or (products / (other + ".o")).exists():
    raise SystemExit("error: product consumer unexpectedly built " + other)
print("verified independent product: " + expected)
PY
done

(
  cd "$isolated/VideoComponents"
  # Product schemes do not include test actions; the package scheme runs both targets.
  xcodebuild -jobs "$jobs" -scheme VideoComponents-Package -destination "$destination" \
    -derivedDataPath "$result_dir/PackageDerivedData" \
    -resultBundlePath "$result_dir/PackageTests.xcresult" \
    -parallel-testing-enabled NO -collect-test-diagnostics never CODE_SIGNING_ALLOWED=NO test
) 2>&1 | tee "$result_dir/PackageTests.log"

python3 "$script_dir/assert-results.py" "$result_dir/PackageTests.xcresult" \
  --expectations "$isolated/ExpectedPackageTests.json" \
  --suite VideoFrameTests --suite SlowVideoExportIntegrationTests \
  --suite SlowVideoExportRunnerTests --suite VideoPosterSelectionAlgorithmTests \
  --suite VideoAdaptiveLayoutTests --suite PlaybackTransportTests --suite PlaybackAccessTests \
  --suite PlaybackGestureTests --suite PlaybackLocalizationTests \
  --suite PlaybackSeekCancellationTests \
  --test VideoFrameTests/testZeroAndNonexactFrameReturnActualTimeAndRotatedPixels \
  --test VideoFrameTests/testEndAndOutOfRangeRequestsDoNotInventAnExactFrame \
  --test VideoFrameTests/testAutomaticPosterSelectsUsablePixelsThroughRealVideoPipeline \
  --test SlowVideoExportIntegrationTests/testRealExporterScalesDurationAndPreservesRotatedDecodableFrames \
  --test SlowVideoExportIntegrationTests/testShortOffsetAudioKeepsItsScaledTimeline \
  --test SlowVideoExportRunnerTests/testCancellationRacingNativeCompletionStillCancelsAndRemovesOutput \
  --test PlaybackAccessTests/testNoItemRefreshCancelsOldLoadAndPreservesAutoplayIntent \
  --test PlaybackAccessTests/testCleanupCancelsSuspendedValidatorAndDiscardsLateSuccess \
  --test PlaybackAccessTests/testReplacementCancelsSuspendedValidatorAndKeepsNewItem \
  --test PlaybackAccessTests/testSuspendedValidatorDoesNotRetainOwnerAndReceivesCancellation \
  --test PlaybackAccessTests/testFrameworkCancellationIsFailureAndLaterRefreshCanLoadWithoutOldIntent \
  --test PlaybackTransportTests/testPlaybackEndSettlesSynchronouslyBeforeFollowingToggle \
  --test PlaybackTransportTests/testPendingRestartTransfersToHoldAndUsesLatestRates \
  --test PlaybackTransportTests/testCleanupDoesNotPublishPositionFromLateSuccessfulScrub \
  --test PlaybackSeekCancellationTests/testResetRejectsOldCompletionWhenNewRequestHasSameTimeAndPrecision \
  --test PlaybackGestureTests/testPinchImmediatelyBlocksHoldDoubleTapAndPanBeforeSwiftUIRefresh \
  --test PlaybackGestureTests/testDismantleCancelsActivePinchHoldAndRemovesAllRecognizers \
  --test PlaybackLocalizationTests/testRegionLocalesSelectTheirLanguageResource

xcodebuild -jobs "$jobs" -project "$consumer_project" -scheme VideoComponentsExample \
  -destination "$destination" -derivedDataPath "$result_dir/ConsumerDerivedData" \
  -resultBundlePath "$result_dir/ConsumerTests.xcresult" \
  -parallel-testing-enabled NO -collect-test-diagnostics never CODE_SIGNING_ALLOWED=NO test \
  2>&1 | tee "$result_dir/ConsumerTests.log"

python3 "$script_dir/assert-results.py" "$result_dir/ConsumerTests.xcresult" \
  --suite VideoPlaybackRuntimeResourcesTests \
  --test VideoPlaybackRuntimeResourcesTests/testEnglishResourcesResolveFromTheConsumedPackage \
  --test VideoPlaybackRuntimeResourcesTests/testSimplifiedChineseResourcesResolveFromTheConsumedPackage \
  --test VideoPlaybackRuntimeResourcesTests/testRegionalLocalesResolveFromTheConsumedPackage

xcodebuild -jobs "$jobs" -project "$consumer_project" -scheme VideoComponentsExample \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$result_dir/ConsumerDerivedData" \
  CODE_SIGNING_ALLOWED=NO build 2>&1 | tee "$result_dir/ConsumerSimulatorBuild.log"
xcodebuild -jobs "$jobs" -project "$consumer_project" -scheme VideoComponentsExample \
  -destination 'generic/platform=iOS' -derivedDataPath "$result_dir/ConsumerDeviceDerivedData" \
  CODE_SIGNING_ALLOWED=NO build 2>&1 | tee "$result_dir/ConsumerDeviceBuild.log"

printf 'VideoComponents validation passed; results: %s\n' "$result_dir"
