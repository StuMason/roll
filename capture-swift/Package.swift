// swift-tools-version:5.7
import PackageDescription

// roll-capture — native macOS capture helper for the roll pack.
// Driven by the Tauri app as a sidecar (CaptureBackend::MacBackend), and
// runnable standalone as a CLI for fast on-device testing.
let package = Package(
    name: "roll-capture",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(name: "roll-capture", path: "Sources/roll-capture")
    ]
)
