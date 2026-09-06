// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ReoView",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "reoview", targets: ["reoview"]),
        .library(name: "ReolinkNVR", targets: ["ReolinkNVR"]),
        .library(name: "ReolinkVideo", targets: ["ReolinkVideo"]),
    ],
    targets: [
        // Talks to the NVR over HTTP. Must not import AppKit or SwiftUI.
        .target(name: "ReolinkNVR"),
        .binaryTarget(name: "VLCKit", path: "Vendor/VLCKit.xcframework"),
        .target(name: "ReolinkVideo", dependencies: ["VLCKit"], exclude: ["README.md"]),
        .executableTarget(
            name: "reoview",
            dependencies: ["ReolinkNVR", "ReolinkVideo"]
        ),
        .testTarget(name: "ReolinkNVRTests", dependencies: ["ReolinkNVR"]),
        // The test bundle only gets VLCKit.framework copied in when it depends on the
        // binary target directly. Without this the bundle fails to dlopen.
        .testTarget(name: "ReolinkVideoTests", dependencies: ["ReolinkVideo", "VLCKit"]),
    ],
    swiftLanguageModes: [.v6]
)
