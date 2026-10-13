// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "T3Native",
  platforms: [.macOS(.v14)],
  products: [.executable(name: "T3Native", targets: ["T3Native"])],
  dependencies: [.package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.9.0")],
  targets: [
    .binaryTarget(name: "GhosttyKit", path: "Vendor/GhosttyKit.xcframework"),
    .target(name: "T3Core"),
    .target(
      name: "T3Markdown", dependencies: [.product(name: "Markdown", package: "swift-markdown")]),
    .executableTarget(
      name: "T3Native", dependencies: ["T3Core", "T3Markdown", "GhosttyKit"],
      resources: [.copy("Resources")],
      linkerSettings: [.linkedLibrary("c++"), .linkedFramework("Carbon")]),
    .testTarget(name: "T3CoreTests", dependencies: ["T3Core"]),
    .testTarget(name: "T3MarkdownTests", dependencies: ["T3Markdown"]),
    .testTarget(name: "T3NativeTests", dependencies: ["T3Native", "T3Core"]),
  ]
)
