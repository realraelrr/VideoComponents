// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "VideoComponents",
  defaultLocalization: "en",
  platforms: [.iOS(.v17)],
  products: [
    .library(name: "VideoPlayback", targets: ["VideoPlayback"]),
    .library(name: "VideoProcessing", targets: ["VideoProcessing"]),
    .library(name: "VideoFramePicker", targets: ["VideoFramePicker"]),
  ],
  targets: [
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
