import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia

// roll-capture — native macOS capture helper for the roll pack.
//
// Step 1 (screen): ScreenCaptureKit -> screen.mp4, HW H.264, native res, 0 drops.
// Step 2 (camera): AVFoundation AVCaptureSession -> camera.mp4, concurrently,
//   on the same host clock. A manifest records each roll's first-frame host time
//   so the cruncher can align them. Mic + telemetry + AX land next.

let VERSION = "0.0.4"

func argVal(_ name: String) -> String? {
    let a = CommandLine.arguments
    if let i = a.firstIndex(of: name), i + 1 < a.count { return a[i + 1] }
    return nil
}
func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
let args = CommandLine.arguments

func capabilityReport() {
    print("roll-capture \(VERSION)")
    if #available(macOS 13.0, *) { print("ScreenCaptureKit: available") }
    else { print("ScreenCaptureKit: needs macOS 13+"); exit(1) }
    print("AVFoundation: available")
    print("ok")
}

func cameraDevices() -> [AVCaptureDevice] {
    AVCaptureDevice.DiscoverySession(
        deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
        mediaType: .video, position: .unspecified).devices
}

// ---- screen (ScreenCaptureKit) ----
@available(macOS 13.0, *)
final class ScreenRecorder: NSObject, SCStreamOutput {
    private var writer: AVAssetWriter!
    private var input: AVAssetWriterInput!
    private var stream: SCStream!
    private var started = false
    private(set) var delivered = 0
    private(set) var written = 0
    private(set) var firstPTS: Double = 0

    func start(display: SCDisplay, fps: Int, width: Int, height: Int, outURL: URL) async throws {
        writer = try AVAssetWriter(url: outURL, fileType: .mp4)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 10_000_000,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        input.expectsMediaDataInRealTime = true
        writer.add(input)

        let config = SCStreamConfiguration()
        config.width = width; config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.queueDepth = 8
        config.showsCursor = true
        config.pixelFormat = kCVPixelFormatType_32BGRA
        let filter = SCContentFilter(display: display, excludingWindows: [])
        stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "roll.screen"))
        try await stream.startCapture()
    }

    func stop() async {
        try? await stream.stopCapture()
        input.markAsFinished()
        await writer.finishWriting()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferDataIsReady(sampleBuffer),
              let arr = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = arr.first?[.status] as? Int, statusRaw == SCFrameStatus.complete.rawValue
        else { return }
        delivered += 1
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if !started { writer.startWriting(); writer.startSession(atSourceTime: pts); firstPTS = pts.seconds; started = true }
        if input.isReadyForMoreMediaData { input.append(sampleBuffer); written += 1 }
    }
}

// ---- camera (AVFoundation) ----
final class CameraRecorder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private var writer: AVAssetWriter!
    private var input: AVAssetWriterInput!
    private var started = false
    private(set) var written = 0
    private(set) var firstPTS: Double = 0

    func start(device: AVCaptureDevice, outURL: URL) throws {
        session.beginConfiguration()
        session.sessionPreset = .hd1280x720
        let camIn = try AVCaptureDeviceInput(device: device)
        if session.canAddInput(camIn) { session.addInput(camIn) }
        let out = AVCaptureVideoDataOutput()
        out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        out.setSampleBufferDelegate(self, queue: DispatchQueue(label: "roll.cam"))
        if session.canAddOutput(out) { session.addOutput(out) }
        session.commitConfiguration()

        writer = try AVAssetWriter(url: outURL, fileType: .mp4)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 1280, AVVideoHeightKey: 720,
        ])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        session.startRunning()
    }

    func stop() async {
        session.stopRunning()
        input.markAsFinished()
        await writer.finishWriting()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if !started { writer.startWriting(); writer.startSession(atSourceTime: pts); firstPTS = pts.seconds; started = true }
        if input.isReadyForMoreMediaData { input.append(sampleBuffer); written += 1 }
    }
}

@available(macOS 13.0, *)
func listAll() async {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        print("displays:")
        for (i, d) in content.displays.enumerated() { print("  [\(i)] id=\(d.displayID)  \(d.width)x\(d.height)") }
    } catch { err("display list failed: \(error)") }
    print("cameras:")
    for (i, d) in cameraDevices().enumerated() { print("  [\(i)] \(d.localizedName)") }
}

@available(macOS 13.0, *)
func record(screenIdx: Int, camIdx: Int?, outDir: String, fps: Int, secs: Double, w: Int?, h: Int?) async {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard screenIdx < content.displays.count else { err("no display \(screenIdx)"); exit(1) }
        let display = content.displays[screenIdx]
        try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        let dir = URL(fileURLWithPath: outDir)

        let screen = ScreenRecorder()
        try await screen.start(display: display, fps: fps, width: w ?? display.width, height: h ?? display.height,
                               outURL: dir.appendingPathComponent("screen.mp4"))

        var cam: CameraRecorder?
        if let ci = camIdx {
            let devs = cameraDevices()
            guard ci < devs.count else { err("no camera \(ci)"); exit(1) }
            let c = CameraRecorder()
            try c.start(device: devs[ci], outURL: dir.appendingPathComponent("camera.mp4"))
            cam = c
            err("camera: \(devs[ci].localizedName)")
        }
        err("recording screen \(w ?? display.width)x\(h ?? display.height)@\(fps)\(camIdx != nil ? " + camera" : "")")

        func finish() async {
            await screen.stop()
            if let c = cam { await c.stop() }
            err("screen frames: delivered=\(screen.delivered) written=\(screen.written) dropped=\(screen.delivered - screen.written)")
            if let c = cam { err("camera frames: written=\(c.written)") }
            // manifest: roll start offsets on the shared host clock
            let manifest: [String: Any] = [
                "version": VERSION, "fps": fps,
                "screen": ["file": "screen.mp4", "firstPTS": screen.firstPTS],
                "camera": cam.map { ["file": "camera.mp4", "firstPTS": $0.firstPTS] } as Any,
                "syncOffsetMs": cam.map { ($0.firstPTS - screen.firstPTS) * 1000 } as Any,
            ]
            if let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted]) {
                try? data.write(to: dir.appendingPathComponent("manifest.json"))
            }
            print("done")
            exit(0)
        }

        if secs > 0 {
            try await Task.sleep(nanoseconds: UInt64(secs * 1_000_000_000))
            await finish()
        } else {
            let src = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            signal(SIGINT, SIG_IGN)
            src.setEventHandler { Task { await finish() } }
            src.resume()
            try await Task.sleep(nanoseconds: UInt64.max)
        }
    } catch { err("capture failed: \(error)"); exit(1) }
}

// ---- entry ----
if args.contains("--help") || args.contains("-h") {
    print("""
    roll-capture \(VERSION)
      --list
      --screen <i> [--cam <i>] --out <dir> [--fps 30] [--secs N] [--width W --height H]
    """)
    exit(0)
}

if #available(macOS 13.0, *) {
    if args.contains("--list") {
        let sem = DispatchSemaphore(value: 0)
        Task { await listAll(); sem.signal() }
        sem.wait(); exit(0)
    }
    if let scr = argVal("--screen"), let outDir = argVal("--out") {
        let fps = Int(argVal("--fps") ?? "30") ?? 30
        let secs = Double(argVal("--secs") ?? "0") ?? 0
        Task {
            await record(screenIdx: Int(scr) ?? 0,
                         camIdx: argVal("--cam").flatMap { Int($0) },
                         outDir: outDir, fps: fps, secs: secs,
                         w: argVal("--width").flatMap { Int($0) },
                         h: argVal("--height").flatMap { Int($0) })
        }
        RunLoop.main.run()
    }
}

capabilityReport()
