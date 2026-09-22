// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "VideoComponents",
  defaultLocalization: "en",
  platforms: [.iOS(.v17)],
  products: [
    .library(name: "VideoPlayback", targets: ["VideoPlayback"]),
    .library(name: "VideoProcessing", targets: ["VideoProcessing"]),
  ],
  targets: [
    .target(name: "VideoPlayback", resources: [.process("Resources")]),
    .target(name: "VideoProcessing"),
    .testTarget(name: "VideoPlaybackTests", dependencies: ["VideoPlayback"]),
    .testTarget(name: "VideoProcessingTests", dependencies: ["VideoProcessing"]),
  ],
  swiftLanguageModes: [.v6]
)
