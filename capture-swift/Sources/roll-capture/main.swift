import Foundation
import AVFoundation
import CoreGraphics

// roll-capture — native macOS capture helper for the roll pack.
//
// Skeleton: this first version only proves the toolchain + framework
// availability so the remote (CI) compile loop is green before the real
// engine lands. The engine grows from here:
//   - ScreenCaptureKit  -> screen.mp4 (HW encode via AVAssetWriter, real 30fps)
//   - AVFoundation      -> camera.mp4
//   - CoreAudio / AVF   -> mic (muxed into screen.mp4)
//   - CGEventTap        -> clicks / keys / drags / cursor path
//   - Accessibility     -> AX element under cursor (role/label/bounds) + app/window
// all stamped on one shared clock -> metadata.jsonl + manifest.json,
// matching the pack contract the Python rig validated.

let version = "0.0.1"

func capabilityReport() {
    print("roll-capture \(version)")
    if #available(macOS 12.3, *) {
        print("ScreenCaptureKit: available (macOS 12.3+)")
    } else {
        print("ScreenCaptureKit: UNAVAILABLE — needs macOS 12.3+")
        exit(1)
    }
    print("AVFoundation: available")
    // Accessibility trust is a runtime/permission check, reported at capture time.
    print("ok")
}

// CLI surface mirrors capture.py so muscle memory carries over:
//   roll-capture --list
//   roll-capture --screen <n> --cam <n> --mic <n> --out <dir>
let args = CommandLine.arguments
if args.contains("--help") || args.contains("-h") {
    print("""
    roll-capture \(version)
      --list                       list capture devices
      --screen <id> --cam <id> --mic <id> --out <dir>
      (engine not wired yet — this build reports capabilities only)
    """)
    exit(0)
}

capabilityReport()
