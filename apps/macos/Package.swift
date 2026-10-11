// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "T3Native",
  platforms: [.macOS(.v14)],
  products: [.executable(name: "T3Native", targets: ["T3Native"])],
  targets: [
    .target(name: "T3Core"),
    .executableTarget(name: "T3Native", dependencies: ["T3Core"]),
    .testTarget(name: "T3CoreTests", dependencies: ["T3Core"]),
  ]
)
