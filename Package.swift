// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ReoView",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "reoview", targets: ["reoview"]),
        .library(name: "ReolinkNVR", targets: ["ReolinkNVR"]),
        .library(name: "ReolinkVideo", targets: ["ReolinkVideo"]),
        .library(name: "ReolinkBaichuan", targets: ["ReolinkBaichuan"]),
        .library(name: "ReolinkAudio", targets: ["ReolinkAudio"]),
    ],
    targets: [
        // Talks to the NVR over HTTP. Must not import AppKit or SwiftUI.
        .target(name: "ReolinkNVR"),
        .binaryTarget(name: "VLCKit", path: "Vendor/VLCKit.xcframework"),
        .target(name: "ReolinkVideo", dependencies: ["VLCKit"], exclude: ["README.md"]),
        // The Baichuan protocol on TCP port 9000. Two-way talk only; the HTTP
        // API in ReolinkNVR covers everything else. No AppKit, no AVFoundation.
        .target(name: "ReolinkBaichuan"),
        // Audio sources and the encoder the camera asks for. No networking.
        .target(name: "ReolinkAudio"),
        .executableTarget(
            name: "reoview",
            dependencies: ["ReolinkNVR", "ReolinkVideo", "ReolinkBaichuan", "ReolinkAudio"]
        ),
        .testTarget(name: "ReolinkNVRTests", dependencies: ["ReolinkNVR"]),
        .testTarget(name: "ReolinkBaichuanTests", dependencies: ["ReolinkBaichuan"]),
        .testTarget(name: "ReolinkAudioTests", dependencies: ["ReolinkAudio"]),
        // The test bundle only gets VLCKit.framework copied in when it depends on the
        // binary target directly. Without this the bundle fails to dlopen.
        .testTarget(name: "ReolinkVideoTests", dependencies: ["ReolinkVideo", "VLCKit"]),
    ],
    swiftLanguageModes: [.v6]
)
