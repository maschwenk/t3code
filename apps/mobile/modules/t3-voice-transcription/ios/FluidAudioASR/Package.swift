// swift-tools-version: 6.2
import PackageDescription

// Only a depending package can turn off FluidAudio's traits, so this shim exists to link its ASR
// without the TTS, diarization, and text-normalization subsystems the app never reaches.
let package = Package(
  name: "FluidAudioASR",
  platforms: [.iOS(.v18)],
  products: [.library(name: "FluidAudioASR", targets: ["FluidAudioASR"])],
  dependencies: [
    .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.3", traits: [])
  ],
  targets: [
    .target(
      name: "FluidAudioASR",
      dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]
    )
  ]
)
