// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "VideoComponents",
  defaultLocalization: "en",
  platforms: [.iOS(.v17)],
  products: [
    .library(name: "VideoResources", targets: ["VideoResources"]),
    .library(name: "VideoResourcesPlayback", targets: ["VideoResourcesPlayback"]),
    .library(name: "VideoResourcesFrames", targets: ["VideoResourcesFrames"]),
    .library(name: "VideoPlayback", targets: ["VideoPlayback"]),
    .library(name: "VideoProcessing", targets: ["VideoProcessing"]),
    .library(name: "VideoFramePicker", targets: ["VideoFramePicker"]),
  ],
  targets: [
    .target(name: "VideoResources"),
    .target(name: "VideoResourcesPlayback", dependencies: ["VideoResources", "VideoPlayback"]),
    .target(name: "VideoResourcesFrames", dependencies: ["VideoResources", "VideoPlayback", "VideoFramePicker", "VideoProcessing"]),
    .testTarget(name: "VideoResourcesFramesTests", dependencies: ["VideoResourcesFrames", "VideoResources", "VideoFramePicker", "VideoPlayback", "VideoProcessing"]),
    .testTarget(name: "VideoResourcesPlaybackTests", dependencies: ["VideoResourcesPlayback", "VideoResources", "VideoPlayback"]),
    .testTarget(name: "VideoResourcesTests", dependencies: ["VideoResources"]),
    .target(name: "VideoPlayback", resources: [.process("Resources")]),
    .target(name: "VideoProcessing"),
    .target(
      name: "VideoFramePicker",
      dependencies: ["VideoPlayback", "VideoProcessing"],
      resources: [.process("Resources")]
    ),
    .testTarget(name: "VideoPlaybackTests", dependencies: ["VideoPlayback"]),
    .testTarget(name: "VideoProcessingTests", dependencies: ["VideoProcessing"]),
    .testTarget(name: "VideoFramePickerTests", dependencies: ["VideoFramePicker"]),
  ],
  swiftLanguageModes: [.v6]
)
