// swift-tools-version: 6.0
import PackageDescription

// flowcode — native macOS menu-bar control app for the voicemode real-time voice core.
// Skeleton: minimal accessory menu-bar executable. External deps (Sparkle, KeyboardShortcuts,
// DynamicNotchKit) are added in Phase 1+ once the shell stabilizes.
let package = Package(
    name: "flowcode",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "flowcode", targets: ["flowcode"])
    ],
    targets: [
        // swift-tools-version 6.0 selects the Swift 6 language mode, so full
        // strict-concurrency checking is already on — no extra swiftSettings needed.
        .executableTarget(
            name: "flowcode",
            path: "Sources/flowcode"
        )
    ]
)
