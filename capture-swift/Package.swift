// swift-tools-version:5.9
import PackageDescription

// roll-capture — native macOS capture helper for the roll pack.
// Driven by the Tauri app as a sidecar (CaptureBackend::MacBackend), and
// runnable standalone as a CLI for fast on-device testing.
let package = Package(
    name: "roll-capture",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "roll-capture",
            path: "Sources/roll-capture",
            // embed Info.plist into the binary's __TEXT,__info_plist section so a
            // bare CLI helper still declares Continuity Camera + usage strings
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Info.plist",
                ])
            ]
        )
    ]
)
