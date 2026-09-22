#!/usr/bin/env python3
"""Copy the package and build public consumers outside the source package."""

import json
from pathlib import Path
import re
import shutil
import sys


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
    reference = 'relativePath = "..";'
    if project_text.count(reference) != 1:
        raise ValueError("expected exactly one local package reference")
    project.write_text(project_text.replace(reference, 'relativePath = "../VideoComponents";'))

    suites, tests = set(), set()
    for file in sorted((package / "Tests").rglob("*.swift")):
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
        raise ValueError("the isolated package contains no discoverable XCTest cases")
    (isolated / "ExpectedPackageTests.json").write_text(json.dumps({
        "suites": sorted(suites), "tests": sorted(tests),
    }, indent=2) + "\n")

    consumers = {
        "PlaybackOnlyConsumer": ("VideoPlayback", """import AVFoundation
import SwiftUI
import VideoPlayback

@MainActor
public enum PlaybackOnlyConsumer {
  public static func session(for asset: AVAsset) -> PlaybackSession {
    let session = PlaybackSession()
    session.load(source: PlaybackSource(identity: "fixture", load: { asset }),
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
    print(f"prepared independent consumers and {len(tests)} required tests in {isolated}")


if __name__ == "__main__":
    try:
        if len(sys.argv) != 3:
            raise ValueError("usage: prepare-validation.py PACKAGE_ROOT NEW_ISOLATED_DIRECTORY")
        copy_validation(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve())
    except (ValueError, OSError) as error:
        sys.exit("error: " + str(error))
