import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia

// roll-capture — native macOS capture helper for the roll pack.
//
// Step 1: ScreenCaptureKit -> screen.mp4 at real 30fps with hardware H.264
// (AVAssetWriter). This is the piece that fixes the ffmpeg 4fps problem.
// Camera, mic, input telemetry and the Accessibility layer land next, all on
// one shared clock, matching the pack contract the Python rig validated.

let VERSION = "0.0.2"

func argVal(_ name: String) -> String? {
    let a = CommandLine.arguments
    if let i = a.firstIndex(of: name), i + 1 < a.count { return a[i + 1] }
    return nil
}
func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

let args = CommandLine.arguments

// Capability report — used by CI (no capture, no permissions needed).
func capabilityReport() {
    print("roll-capture \(VERSION)")
    if #available(macOS 13.0, *) { print("ScreenCaptureKit: available") }
    else { print("ScreenCaptureKit: needs macOS 13+"); exit(1) }
    print("AVFoundation: available")
    print("ok")
}

@available(macOS 13.0, *)
final class ScreenRecorder: NSObject, SCStreamOutput {
    private var writer: AVAssetWriter!
    private var input: AVAssetWriterInput!
    private var stream: SCStream!
    private var started = false

    func start(display: SCDisplay, fps: Int, outURL: URL) async throws {
        writer = try AVAssetWriter(url: outURL, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: display.width,
            AVVideoHeightKey: display.height,
        ]
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        writer.add(input)

        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.queueDepth = 6
        config.showsCursor = true
        config.pixelFormat = kCVPixelFormatType_32BGRA

        let filter = SCContentFilter(display: display, excludingWindows: [])
        stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(self, type: .screen,
                                   sampleHandlerQueue: DispatchQueue(label: "roll.screen"))
        try await stream.startCapture()
    }

    func stop() async {
        try? await stream.stopCapture()
        input.markAsFinished()
        await writer.finishWriting()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer,
                createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let statusRaw = info[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw),
              status == .complete else { return }

        if !started {
            writer.startWriting()
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            started = true
        }
        if input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
        }
    }
}

@available(macOS 13.0, *)
func listDisplays() async {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        print("displays:")
        for (i, d) in content.displays.enumerated() {
            print("  [\(i)] id=\(d.displayID)  \(d.width)x\(d.height)")
        }
    } catch { err("list failed: \(error)"); exit(1) }
}

@available(macOS 13.0, *)
func record(index: Int, outDir: String, fps: Int, secs: Double) async {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        guard index < content.displays.count else { err("no display \(index)"); exit(1) }
        let display = content.displays[index]
        try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        let outURL = URL(fileURLWithPath: outDir).appendingPathComponent("screen.mp4")
        let rec = ScreenRecorder()
        try await rec.start(display: display, fps: fps, outURL: outURL)
        err("recording \(display.width)x\(display.height)@\(fps) -> \(outURL.path)  (Ctrl-C to stop)")
        if secs > 0 {
            try await Task.sleep(nanoseconds: UInt64(secs * 1_000_000_000))
            await rec.stop()
            print("done")
            exit(0)
        } else {
            let src = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            signal(SIGINT, SIG_IGN)
            src.setEventHandler {
                Task { await rec.stop(); print("done"); exit(0) }
            }
            src.resume()
            try await Task.sleep(nanoseconds: UInt64.max)  // park until SIGINT
        }
    } catch { err("capture failed: \(error)"); exit(1) }
}

// ---- entry ----
if args.contains("--help") || args.contains("-h") {
    print("""
    roll-capture \(VERSION)
      --list
      --screen <index> --out <dir> [--fps 30] [--secs N]
    """)
    exit(0)
}

if #available(macOS 13.0, *) {
    let sem = DispatchSemaphore(value: 0)
    if args.contains("--list") {
        Task { await listDisplays(); sem.signal() }
        sem.wait(); exit(0)
    }
    if let scr = argVal("--screen"), let outDir = argVal("--out") {
        let fps = Int(argVal("--fps") ?? "30") ?? 30
        let secs = Double(argVal("--secs") ?? "0") ?? 0
        Task { await record(index: Int(scr) ?? 0, outDir: outDir, fps: fps, secs: secs) }
        RunLoop.main.run()  // keep alive for the capture queue + signal source
    }
}

capabilityReport()
