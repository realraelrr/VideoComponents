#!/usr/bin/env python3
"""Copy the package and build public consumers outside the source package."""

import json
from pathlib import Path
import re
import shutil
import sys


def discover_tests(root):
    suites, tests = set(), set()
    for file in sorted(root.rglob("*.swift")):
        current = None
        for line in file.read_text().splitlines():
            declaration = re.search(r"\bclass\s+(\w+)\s*:\s*([^\{]+)", line)
            if declaration:
                current = declaration[1] if "XCTestCase" in declaration[2] else None
            # XCTest discovery excludes private helpers and methods with parameters.
            test = re.search(r"^\s*(?:public\s+|internal\s+)?func\s+(test\w+)\s*\(\s*\)", line)
            if current and test:
                suites.add(current)
                tests.add(current + "/" + test[1])
    if not suites or not tests:
        raise ValueError(f"no discoverable XCTest cases in {root}")
    return {"suites": sorted(suites), "tests": sorted(tests)}


def copy_validation(source, isolated):
    if isolated.is_relative_to(source):
        raise ValueError("validation consumers must live outside the package")
    package = isolated / "VideoComponents"
    package.mkdir(parents=True, exist_ok=False)
    shutil.copy2(source / "Package.swift", package / "Package.swift")
    for directory in ("Sources", "Tests"):
        shutil.copytree(source / directory, package / directory)
    shutil.copytree(source / "Example", isolated / "Consumer",
                    ignore=shutil.ignore_patterns("xcuserdata", ".DS_Store"))
    project = isolated / "Consumer/VideoComponentsExample.xcodeproj/project.pbxproj"
    project_text = project.read_text()
    references = {
        'relativePath = "..";': 'relativePath = "../VideoComponents";',
        'path = "../Tests/VideoFramePickerTests/VideoFramePickerTestSupport.swift";':
            'path = "../VideoComponents/Tests/VideoFramePickerTests/VideoFramePickerTestSupport.swift";',
    }
    for original, replacement in references.items():
        if project_text.count(original) != 1:
            raise ValueError(f"expected exactly one project reference: {original}")
        project_text = project_text.replace(original, replacement)
    project.write_text(project_text)

    package_tests = discover_tests(package / "Tests")
    consumer_tests = discover_tests(isolated / "Consumer/VideoComponentsExampleTests")
    for name, expectations in [("Package", package_tests), ("Consumer", consumer_tests)]:
        (isolated / f"Expected{name}Tests.json").write_text(json.dumps(expectations, indent=2) + "\n")

    consumers = {
        "PlaybackOnlyConsumer": ("VideoPlayback", """import AVFoundation
import SwiftUI
import VideoPlayback

@MainActor
public enum PlaybackOnlyConsumer {
  public static func session(for asset: AVAsset) -> PlaybackSession {
    let session = PlaybackSession()
    session.load(source: PlaybackSource(identity: "fixture", load: { PlaybackLoadedMedia(asset: asset) }),
      playbackRate: 1, isLooping: false, autoplayWhenReady: false)
    return session
  }

  public static func view(session: PlaybackSession) -> some View {
    InlinePlaybackView(playbackSession: session, topTrailingAccessory: { EmptyView() },
      statusOverlay: { PlaybackStatusOverlay(status: session.status) })
  }

  public static func labels() -> VideoPlaybackLabels { .init(locale: Locale(identifier: "en")) }
}
"""),
        "ProcessingOnlyConsumer": ("VideoProcessing", """import AVFoundation
import VideoProcessing

@MainActor
public enum ProcessingOnlyConsumer {
  public static func poster(for asset: AVAsset) async throws -> SelectedVideoPoster {
    try await AutomaticVideoPosterSelector.select(from: asset)
  }

  public static func frame(for asset: AVAsset) async throws -> ExtractedVideoFrame {
    try await VideoFrameExtractor.frame(for: asset, at: 0,
      maximumSize: CGSize(width: 320, height: 320), exact: true)
  }

  public static func export(_ asset: AVAsset) async throws -> URL {
    try await SlowVideoExporter.exportSlowedVideo(asset: asset, rate: 0.5, onProgress: { _ in })
  }
}
"""),
        "FramePickerOnlyConsumer": ("VideoFramePicker", """import AVFoundation
import SwiftUI
import VideoFramePicker

@MainActor
public enum FramePickerOnlyConsumer {
  public static func view(
    asset: AVAsset,
    onSelection: @escaping @MainActor (VideoFrameSelection) async throws -> Void
  ) -> some View {
    VideoFramePickerView(
      source: VideoFramePickerSource(identity: "fixture", load: { .init(asset: asset) }),
      initialTime: 0,
      maximumFrameSize: CGSize(width: 640, height: 640),
      labels: VideoFramePickerLabels(locale: Locale(identifier: "en")),
      style: VideoFramePickerStyle(tint: .blue),
      onSelectionActivityChanged: { _ in },
      onFailure: { _ in },
      onSelection: { selection in
        try Task.checkCancellation()
        try await onSelection(selection)
      }
    )
  }

  public static func labels() -> VideoFramePickerLabels { .init(locale: Locale(identifier: "zh_CN")) }
}
"""),
        "ResourcesOnlyConsumer": ("VideoResources", """import VideoResources

@MainActor
public enum ResourcesOnlyConsumer {
  public static func source(resources: VideoResources, cloudID: String) -> VideoSource {
    resources.photosSource(serializedCloudIdentifier: cloudID)
  }
}
"""),
        "ResourcesPlaybackOnlyConsumer": ("VideoResourcesPlayback", """import VideoResources
import VideoResourcesPlayback

@MainActor
public enum ResourcesPlaybackOnlyConsumer {
  public static func playback(source: VideoSource) -> VideoResourcePlayback {
    let playback = VideoResourcePlayback()
    playback.load(source: source)
    return playback
  }
}
"""),
        "ResourcesFramesOnlyConsumer": ("VideoResourcesFrames", """import AVFoundation
import VideoFramePicker
import VideoResources
import VideoResourcesFrames
import VideoProcessing

@MainActor
public enum ResourcesFramesOnlyConsumer {
  public static func picker(source: VideoSource) -> VideoFramePickerSource {
    VideoResourcesFrames.pickerSource(source: source, identity: "row-video")
  }

  public static func frame(source: VideoSource) async throws -> ExtractedVideoFrame {
    let result = try await VideoResourcesFrames.frame(source: source, at: 0,
      maximumSize: CGSize(width: 320, height: 320), exact: true)
    guard result.receipt.isCurrent else { throw VideoResourceFailure.sourceChanged }
    return result.frame
  }

  public static func export(source: VideoSource) async throws -> URL {
    let result = try await VideoResourcesFrames.export(source: source, rate: 0.5, onProgress: { _ in })
    // Ownership has transferred to this host; reject its own late output safely.
    guard result.receipt.isCurrent else {
      try? FileManager.default.removeItem(at: result.url)
      throw VideoResourceFailure.sourceChanged
    }
    return result.url
  }
}
"""),
    }
    for name, (product, code) in consumers.items():
        root = isolated / name
        target = root / "Sources" / name
        target.mkdir(parents=True)
        (root / "Package.swift").write_text(f'''// swift-tools-version: 6.2
import PackageDescription
let package = Package(
  name: "{name}", platforms: [.iOS(.v17)],
  products: [.library(name: "{name}", targets: ["{name}"])],
  dependencies: [.package(path: "../VideoComponents")],
  targets: [.target(name: "{name}", dependencies: [.product(name: "{product}", package: "VideoComponents")])],
  swiftLanguageModes: [.v6]
)
''')
        (target / (name + ".swift")).write_text(code)
    print(f"prepared independent consumers and {len(package_tests['tests'])} package / "
          f"{len(consumer_tests['tests'])} consumer required tests in {isolated}")


if __name__ == "__main__":
    try:
        if len(sys.argv) != 3:
            raise ValueError("usage: prepare-validation.py PACKAGE_ROOT NEW_ISOLATED_DIRECTORY")
        copy_validation(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve())
    except (ValueError, OSError) as error:
        sys.exit("error: " + str(error))
