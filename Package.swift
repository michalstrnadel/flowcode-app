// swift-tools-version: 6.0
import PackageDescription

// flowcode — native macOS menu-bar control app for the voicemode real-time voice core.
//
// Layout (mirrors CodexBar's Core/app split):
//   flowcodeKit  — testable library: models, IPC client, stores, status-item UI
//   flowcode     — thin executable: wires it together and runs the menu-bar app
//   flowcodeTests — unit/integration tests against flowcodeKit
//
// External deps (Sparkle, KeyboardShortcuts, DynamicNotchKit) are added in later phases.
let package = Package(
    name: "flowcode",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "flowcode", targets: ["flowcode"]),
        .library(name: "flowcodeKit", targets: ["flowcodeKit"]),
    ],
    targets: [
        .target(name: "flowcodeKit", path: "Sources/flowcodeKit"),
        .executableTarget(
            name: "flowcode",
            dependencies: ["flowcodeKit"],
            path: "Sources/flowcode"
        ),
        // Runnable verification harness (works under Command Line Tools, where
        // `swift test`/XCTest is unavailable). Run with: swift run flowcode-selftest
        .executableTarget(
            name: "flowcode-selftest",
            dependencies: ["flowcodeKit"],
            path: "Sources/flowcodeSelfTest"
        ),
    ]
)
