import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia
import CoreImage
import QuartzCore
import AppKit
import ApplicationServices
import Carbon.HIToolbox   // IsSecureEventInputEnabled (skip capture in password fields)

// roll-capture — native macOS capture helper for the roll pack.
//
// Lifecycle is two-phase so multi-source heads line up and slow devices
// (Continuity Camera does a ~3s "ding" handshake) connect BEFORE recording:
//   1. arm()        — start every capture session; frames flow but aren't written
//   2. (warm wait)  — block until all sources have delivered a first frame
//   3. beginWriting(at t0) — flip all writers on at ONE shared host-clock t0
//
// Stops on: --secs deadline, SIGINT (terminal), OR a line/EOF on stdin (so the
// Tauri app can stop it gracefully — a clean finish(), not a SIGKILL that would
// truncate the mp4). Emits `progress …` lines every 0.5s for the live UI.

let VERSION = "0.0.16"

// keyCodes that have no sensible printable character — named so the key stream
// is legible (charactersIgnoringModifiers returns control/unicode junk for these)
let NAMED_KEYS: [Int: String] = [
    36: "return", 48: "tab", 49: "space", 51: "delete", 53: "escape", 76: "enter",
    117: "fwd-delete", 115: "home", 119: "end", 116: "page-up", 121: "page-down",
    123: "left", 124: "right", 125: "down", 126: "up",
    122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7",
    100: "f8", 101: "f9", 109: "f10", 103: "f11", 111: "f12",
]

// The iPhone's main Continuity Camera is ultra-wide; Center Stage is what crops
// it down to a framed face shot (per WWDC22 "Bring Continuity Camera to your
// macOS app"). Force it OFF and you get the raw ultra-wide field — which looks
// like a wide "desk view". So we DON'T override it: we leave Center Stage to the
// user's Control Center toggle (control mode `.user`, default on = framed face).
// We only surface the effects we can read but can't change.
func noteCameraEffects(_ device: AVCaptureDevice) {
    // Don't impose any framing. Respect the user's Control Center toggle (same as
    // OBS does) — no forced Center Stage / face tracking either way.
    AVCaptureDevice.centerStageControlMode = .user
    if device.isPortraitEffectActive { err("warning: Portrait effect is ON for \(device.localizedName) — turn it off in Control Center (app can't)") }
    if #available(macOS 14.0, *), device.isStudioLightActive {
        err("warning: Studio Light is ON for \(device.localizedName) — turn it off in Control Center (app can't)")
    }
}

func argVal(_ name: String) -> String? {
    let a = CommandLine.arguments
    if let i = a.firstIndex(of: name), i + 1 < a.count { return a[i + 1] }
    return nil
}
func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
let args = CommandLine.arguments

// Camera encode knobs (#12). Defaults are the committed decision: 1080p @ 6 Mbps —
// 720p was fine for the 16:9 PiP but too soft once the shorts pipeline face-crops
// into the frame for 9:16. Width is derived 16:9; the capture preset snaps to the
// nearest supported tier so a 720 request captures 720, not downscaled 1080.
let camHeight = Int(argVal("--cam-height") ?? "") ?? 1080
let camWidth = camHeight * 16 / 9
let camBitrate = Int(argVal("--cam-bitrate") ?? "") ?? 6_000_000
let camPreset: AVCaptureSession.Preset = camHeight <= 720 ? .hd1280x720 : .hd1920x1080

// Pack proxy (#13): a small analysis copy (camera.proxy.mp4) written live next to
// the master so the /pack upload can swap it in and stay under Cloudflare's 100MB
// edge cap. 480p @ 600 kbps ≈ 34MB per 7.5 min — plenty for face/presence work;
// edator keeps rendering from the full-res master.
let PROXY_W = 854, PROXY_H = 480, PROXY_BITRATE = 600_000

// manifest.camera — encode settings + proxy pointer, shared by both stop paths
func cameraManifestBlock(firstPTS: Double, proxyWritten: Int) -> [String: Any] {
    var block: [String: Any] = ["file": "camera.mp4", "firstPTS": firstPTS,
                                "encode": ["w": camWidth, "h": camHeight, "bitrate": camBitrate]]
    if proxyWritten > 0 {
        block["proxy"] = ["file": "camera.proxy.mp4", "w": PROXY_W, "h": PROXY_H, "bitrate": PROXY_BITRATE]
    }
    return block
}

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

func micDevices() -> [AVCaptureDevice] {
    AVCaptureDevice.DiscoverySession(
        deviceTypes: [.microphone, .external],
        mediaType: .audio, position: .unspecified).devices
}

func cmt(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 1_000_000) }

// One H.264 writer+input pair. Each camera runs two — the full-res master and the
// 480p pack proxy (#13) — fed the same sample buffers, so their PTS are identical
// and the proxy needs no re-timing downstream. AVAssetWriterInput scales incoming
// frames to the requested dimensions itself.
final class CamWriter {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private(set) var written = 0
    private(set) var firstWrittenPTS = 0.0

    init(outURL: URL, w: Int, h: Int, bitrate: Int, fps: Int? = nil) throws {
        writer = try AVAssetWriter(url: outURL, fileType: .mp4)
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
        ]
        if let fps = fps {
            compression[AVVideoMaxKeyFrameIntervalKey] = fps * 2
            compression[AVVideoExpectedSourceFrameRateKey] = fps
        }
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: compression,
        ])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        writer.startWriting()
    }

    func startSession(at t0: Double) { writer.startSession(atSourceTime: cmt(t0)) }

    func append(_ sb: CMSampleBuffer, pts: Double) {
        guard input.isReadyForMoreMediaData else { return }
        input.append(sb); written += 1
        if firstWrittenPTS == 0 { firstWrittenPTS = pts }
    }

    func finish() async {
        input.markAsFinished()
        await writer.finishWriting()
    }
}

// ---- screen (ScreenCaptureKit) ----
// ScreenCaptureKit is change-driven: a static screen emits almost no frames, so
// a naive recording would start late (first change) and end at the last change.
// We make screen.mp4 always span [t0, stop]: the first frame is anchored back to
// t0, and a keepalive re-emits the last frame through static stretches (and at
// stop), so the screen stays aligned with the camera/mic rolls.
@available(macOS 13.0, *)
final class ScreenRecorder: NSObject, SCStreamOutput {
    private var writer: AVAssetWriter!
    private var input: AVAssetWriterInput!
    private var stream: SCStream!
    private let q = DispatchQueue(label: "roll.screen")
    private let ci = CIContext(options: [.cacheIntermediates: false])
    private var writeFrom: Double = .infinity
    private var lastPixelBuffer: CVPixelBuffer?
    private var fps = 30
    private var slot = 0                       // next CFR slot index to emit
    private var slotTimer: DispatchSourceTimer?
    private(set) var ready = false
    private(set) var delivered = 0
    private(set) var written = 0
    private(set) var firstWrittenPTS: Double = 0

    // #7 system audio — captured on the SAME SCStream (same clock), written to its
    // own AAC track so the mic stays clean and crunch can spot app/video audio.
    private var audioWriter: AVAssetWriter?
    private var audioInput: AVAssetWriterInput?
    private var audioFrom: Double = .infinity
    private(set) var audioWritten = 0
    private(set) var audioFirstPTS: Double = 0

    func arm(display: SCDisplay, fps: Int, width: Int, height: Int, outURL: URL, sysAudioURL: URL?) async throws {
        self.fps = fps
        writer = try AVAssetWriter(url: outURL, fileType: .mp4)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 10_000_000,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                // no B-frames → DTS == PTS, strictly monotonic, frame-accurate cutting
                AVVideoAllowFrameReorderingKey: false,
            ],
        ])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        writer.startWriting()

        let config = SCStreamConfiguration()
        config.width = width; config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.queueDepth = 8
        config.showsCursor = true
        config.pixelFormat = kCVPixelFormatType_32BGRA
        if sysAudioURL != nil {
            config.capturesAudio = true
            config.sampleRate = 48000
            config.channelCount = 2
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: q)

        if let au = sysAudioURL {
            let aw = try AVAssetWriter(url: au, fileType: .m4a)
            let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2, AVSampleRateKey: 48000, AVEncoderBitRateKey: 128_000,
            ])
            ai.expectsMediaDataInRealTime = true
            aw.add(ai); aw.startWriting()
            audioWriter = aw; audioInput = ai
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: q)
        }
        try await stream.startCapture()
    }

    func beginWriting(at t0: Double) {
        writer.startSession(atSourceTime: cmt(t0))
        writeFrom = t0
        firstWrittenPTS = t0
        slot = 0
        if let aw = audioWriter { aw.startSession(atSourceTime: cmt(t0)); audioFrom = t0 }
        // ScreenCaptureKit is change-driven (VFR). We resample to a strict CFR
        // grid: a timer emits the latest frame into every 1/fps slot, holding the
        // last frame through static stretches. Output is constant-rate with
        // monotonic PTS — what a frame-accurate editor needs.
        let t = DispatchSource.makeTimerSource(queue: q)
        let interval = 1.0 / Double(fps)
        t.schedule(deadline: .now(), repeating: interval)
        t.setEventHandler { [weak self] in self?.pump(upTo: CACurrentMediaTime()) }
        t.resume()
        slotTimer = t
    }

    private func slotTime(_ n: Int) -> Double { writeFrom + Double(n) / Double(fps) }

    // Emit the held frame into every CFR slot whose time has arrived (≤ `now`).
    private func pump(upTo now: Double) {
        guard let pb = lastPixelBuffer else { return }
        var emitted = 0
        while slotTime(slot) <= now, emitted < fps {           // cap catch-up to ~1s/tick
            guard input.isReadyForMoreMediaData else { break }  // retry this slot next tick
            appendImage(pb, at: slotTime(slot))
            slot += 1; emitted += 1
        }
    }

    // Build a constant-duration sample buffer at an explicit CFR PTS and append it.
    private func appendImage(_ pb: CVPixelBuffer, at seconds: Double) {
        var fmt: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb, formatDescriptionOut: &fmt)
        guard let fmt = fmt else { return }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(fps)),
            presentationTimeStamp: cmt(seconds), decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb,
            dataReady: true, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: fmt, sampleTiming: &timing, sampleBufferOut: &sb)
        if let sb = sb { input.append(sb); written += 1 }
    }

    // Fill CFR slots up to the stop instant so duration spans the whole take.
    func finalize(at t: Double) {
        q.sync {
            self.slotTimer?.cancel(); self.slotTimer = nil
            guard let pb = self.lastPixelBuffer else { return }
            while self.slotTime(self.slot) <= t, self.input.isReadyForMoreMediaData {
                self.appendImage(pb, at: self.slotTime(self.slot)); self.slot += 1
            }
        }
    }

    func stop() async {
        slotTimer?.cancel(); slotTimer = nil
        try? await stream.stopCapture()
        input.markAsFinished()
        await writer.finishWriting()
        if let aw = audioWriter { audioInput?.markAsFinished(); await aw.finishWriting() }
    }

    // #5 pristine full-res PNG of the current frame (clean OCR input, no H.264
    // motion blur / server-side decode). Runs on the capture queue.
    func snapshotPNG(to url: URL) {
        q.async {
            guard let pb = self.lastPixelBuffer else { return }
            let img = CIImage(cvPixelBuffer: pb)
            guard let data = self.ci.pngRepresentation(of: img, format: .RGBA8,
                colorSpace: CGColorSpaceCreateDeviceRGB()) else { return }
            try? data.write(to: url)
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio {
            guard let ai = audioInput, CMSampleBufferDataIsReady(sampleBuffer),
                  CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds >= audioFrom,
                  ai.isReadyForMoreMediaData else { return }
            ai.append(sampleBuffer); audioWritten += 1
            if audioFirstPTS == 0 { audioFirstPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds }
            return
        }
        guard type == .screen, CMSampleBufferDataIsReady(sampleBuffer),
              let arr = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = arr.first?[.status] as? Int, statusRaw == SCFrameStatus.complete.rawValue
        else { return }
        ready = true
        // just hold the latest frame; the CFR timer owns all writing
        if let pb = CMSampleBufferGetImageBuffer(sampleBuffer) {
            lastPixelBuffer = pb
            delivered += 1
        }
    }
}

// ---- camera (AVFoundation) ----
final class CameraRecorder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private var master: CamWriter!
    private var proxy: CamWriter?
    private var writeFrom: Double = .infinity
    private(set) var ready = false
    var written: Int { master?.written ?? 0 }
    var firstWrittenPTS: Double { master?.firstWrittenPTS ?? 0 }
    var proxyWritten: Int { proxy?.written ?? 0 }
    private weak var device: AVCaptureDevice?
    private var observers: [NSObjectProtocol] = []
    private var loggedFirstFrame = false

    // Watch the capture session for the failure modes that silently kill a
    // Continuity Camera mid-take (runtime errors, interruptions, disconnects).
    // These all land in stderr → roll://log so we can see them in Console / the app.
    private func installObservers(_ device: AVCaptureDevice) {
        let nc = NotificationCenter.default
        func obs(_ name: NSNotification.Name, _ handler: @escaping (Notification) -> Void) {
            observers.append(nc.addObserver(forName: name, object: nil, queue: nil, using: handler))
        }
        obs(.AVCaptureSessionRuntimeError) { n in
            let e = n.userInfo?[AVCaptureSessionErrorKey] as? NSError
            err("📷 camera RUNTIME ERROR: \(e?.localizedDescription ?? "?") code=\(e?.code ?? -1)")
        }
        // NB: AVCaptureSessionInterruptionReasonKey / InterruptionReason are
        // iOS-only — unavailable on macOS — so just dump the raw userInfo.
        obs(.AVCaptureSessionWasInterrupted) { n in
            err("📷 camera INTERRUPTED: userInfo=\(n.userInfo ?? [:])")
        }
        obs(.AVCaptureSessionInterruptionEnded) { _ in
            err("📷 camera interruption ENDED")
        }
        obs(.AVCaptureSessionDidStopRunning) { _ in
            err("📷 camera session STOPPED running (suspended=\(device.isSuspended) connected=\(device.isConnected))")
        }
        obs(.AVCaptureDeviceWasDisconnected) { n in
            if let d = n.object as? AVCaptureDevice {
                err("📷 device DISCONNECTED: \(d.localizedName)")
            }
        }
    }

    func arm(device: AVCaptureDevice, outURL: URL) throws {
        self.device = device
        noteCameraEffects(device)   // respect the user's Center Stage setting
        installObservers(device)
        session.beginConfiguration()
        session.sessionPreset = camPreset
        let camIn = try AVCaptureDeviceInput(device: device)
        if session.canAddInput(camIn) { session.addInput(camIn) }
        let out = AVCaptureVideoDataOutput()
        out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        out.setSampleBufferDelegate(self, queue: DispatchQueue(label: "roll.cam"))
        if session.canAddOutput(out) { session.addOutput(out) }
        session.commitConfiguration()
        let af = device.activeFormat
        err("📷 armed: device=\(device.localizedName) suspended=\(device.isSuspended) activeFormat=\(af.formatDescription.dimensions.width)x\(af.formatDescription.dimensions.height) centerStageEnabled=\(AVCaptureDevice.isCenterStageEnabled) activeFormatSupportsCenterStage=\(af.isCenterStageSupported)")

        master = try CamWriter(outURL: outURL, w: camWidth, h: camHeight, bitrate: camBitrate)
        let proxyURL = outURL.deletingLastPathComponent().appendingPathComponent("camera.proxy.mp4")
        do { proxy = try CamWriter(outURL: proxyURL, w: PROXY_W, h: PROXY_H, bitrate: PROXY_BITRATE) }
        catch { err("camera proxy writer failed (take continues without it): \(error)") }
        session.startRunning()   // triggers the Continuity Camera handshake NOW
    }

    func beginWriting(at t0: Double) {
        master.startSession(at: t0)
        proxy?.startSession(at: t0)
        writeFrom = t0
    }

    func stop() async {
        session.stopRunning()
        await master.finish()
        await proxy?.finish()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        ready = true
        if !loggedFirstFrame, let px = CMSampleBufferGetImageBuffer(sampleBuffer) {
            loggedFirstFrame = true
            let dims = "\(CVPixelBufferGetWidth(px))x\(CVPixelBufferGetHeight(px))"
            err("📷 first frame delivered: \(dims) active=\(connection.isActive) suspended=\(device?.isSuspended ?? false)")
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.seconds >= writeFrom else { return }
        master.append(sampleBuffer, pts: pts.seconds)
        proxy?.append(sampleBuffer, pts: pts.seconds)
    }
}

// ---- microphone (AVFoundation) ----
final class MicRecorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private var writer: AVAssetWriter!
    private var input: AVAssetWriterInput!
    private var writeFrom: Double = .infinity
    private(set) var ready = false
    private(set) var written = 0
    private(set) var firstWrittenPTS: Double = 0

    func arm(device: AVCaptureDevice, outURL: URL) throws {
        session.beginConfiguration()
        let micIn = try AVCaptureDeviceInput(device: device)
        if session.canAddInput(micIn) { session.addInput(micIn) }
        let out = AVCaptureAudioDataOutput()
        out.setSampleBufferDelegate(self, queue: DispatchQueue(label: "roll.mic"))
        if session.canAddOutput(out) { session.addOutput(out) }
        session.commitConfiguration()

        writer = try AVAssetWriter(url: outURL, fileType: .m4a)
        input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 48000,
            AVEncoderBitRateKey: 128_000,
        ])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        writer.startWriting()
        session.startRunning()
    }

    func beginWriting(at t0: Double) {
        writer.startSession(atSourceTime: cmt(t0))
        writeFrom = t0
    }

    func stop() async {
        session.stopRunning()
        input.markAsFinished()
        await writer.finishWriting()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        ready = true
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.seconds >= writeFrom else { return }
        if input.isReadyForMoreMediaData {
            input.append(sampleBuffer); written += 1
            if firstWrittenPTS == 0 { firstWrittenPTS = pts.seconds }
        }
    }
}

// ---- telemetry (CGEventTap input + Accessibility semantics) ----
final class Telemetry {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var file: FileHandle?
    private var t0: Double = 0
    private let sys = AXUIElementCreateSystemWide()
    private var mods: [String] = []
    private var down: [String: (x: Double, y: Double, t: Double)] = [:]
    private var lastCursor: Double = 0
    private var lastScroll: Double = 0
    private var scrollDX: Double = 0
    private var scrollDY: Double = 0
    private var focusObserver: NSObjectProtocol?
    private var lastApp: String = ""
    private let q = DispatchQueue(label: "roll.telemetry.enrich")
    private(set) var rows = 0
    private(set) var clicks = 0
    private(set) var ok = false

    // #3 typed-text: accumulate printable keystrokes into words, flushed as a
    // `text` event on Enter/Tab, focus change, or stop. Skipped entirely while
    // macOS secure input is active (password/secure fields).
    private var typed = ""
    private var typedStart = 0.0
    private var lastFocusApp = "", lastFocusWin = ""

    // #4 clipboard: poll the pasteboard change counter; emit copied text
    // (size-capped, skipping concealed/secure payloads).
    private var pbTimer: DispatchSourceTimer?
    private var pbCount = 0

    // #5 keyframes: the orchestrator wires this to snapshot screen.mp4's current
    // frame to a PNG at click / app-switch moments (pristine OCR input).
    var keyframe: ((_ tMs: Int) -> Void)?

    // Captured-display geometry, so every coordinate we emit is in the SAME space
    // as screen.mp4: display-local, top-left origin, screen PIXELS. AX/CGEvent give
    // GLOBAL POINTS, so we subtract the display origin and multiply by the
    // pixels-per-point scale (2 on Retina). Without this, coords on a non-primary
    // or Retina display don't line up with screen.mp4 at all.
    private var ox = 0.0, oy = 0.0   // display origin in global points
    private var sc = 1.0             // screen pixels per point
    private var pw = 0, ph = 0       // screen.mp4 pixel dimensions
    private func px(_ gx: Double) -> Int { Int((gx - ox) * sc) }
    private func py(_ gy: Double) -> Int { Int((gy - oy) * sc) }

    func start(outURL: URL, t0: Double, originXpt: Double, originYpt: Double, scalePx: Double, pixelW: Int, pixelH: Int) {
        self.t0 = t0
        ox = originXpt; oy = originYpt; sc = scalePx; pw = pixelW; ph = pixelH
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        file = try? FileHandle(forWritingTo: outURL)

        pbCount = NSPasteboard.general.changeCount   // ignore whatever's already on the clipboard
        startClipboardPoll()

        // baseline foreground app at t0, then a row on every app switch — gives a
        // continuous app/window context timeline, not just context at click time
        emitAppFocus(NSWorkspace.shared.frontmostApplication, at: t0)
        focusObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.emitAppFocus(app, at: CACurrentMediaTime())
        }

        let types: [CGEventType] = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                                    .otherMouseDown, .otherMouseUp, .mouseMoved,
                                    .leftMouseDragged, .rightMouseDragged, .scrollWheel,
                                    .keyDown, .flagsChanged]
        var mask: CGEventMask = 0
        for t in types { mask |= (CGEventMask(1) << t.rawValue) }

        let ptr = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                if let refcon = refcon {
                    Unmanaged<Telemetry>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
                }
                return Unmanaged.passUnretained(event)
            }, userInfo: ptr)
        else {
            err("⚠︎ telemetry: event tap failed — grant Accessibility to this app (recording continues without metadata)")
            return
        }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        ok = true
    }

    func stop() {
        if let tap = tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let o = focusObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        pbTimer?.cancel(); pbTimer = nil
        flushScroll(at: CACurrentMediaTime())
        flushTyped(at: CACurrentMediaTime())
        // close on the write queue so it runs AFTER any pending enrichment writes,
        // and synchronously so the caller knows metadata.jsonl is fully flushed.
        // (Previously closing here raced async enrichment blocks still writing to
        // the handle → NSFileHandle exception that crashed the persistent daemon.)
        q.sync {
            try? file?.synchronize(); try? file?.close()
            file = nil
        }
    }

    private func emitAppFocus(_ app: NSRunningApplication?, at t: Double) {
        guard let app = app, let name = app.localizedName, name != lastApp else { return }
        flushTyped(at: t)                 // text belongs to the app it was typed in
        lastApp = name
        let pid = app.processIdentifier, ts = stamp(t)
        keyframe?(ts)                     // #5 snapshot on app switch
        q.async {
            let w = self.focusedWindow(pid)
            self.lastFocusApp = name; self.lastFocusWin = w ?? ""
            var row: [String: Any] = ["type": "app_focus", "t_ms": ts, "app": name]
            if let w = w { row["window"] = w }
            self.write(row)
        }
    }

    // scroll fires in dense momentum bursts — accumulate deltas and emit at 10Hz
    private func flushScroll(at t: Double) {
        if scrollDX != 0 || scrollDY != 0 {
            write(["type": "scroll", "t_ms": stamp(t), "dx": Int(scrollDX), "dy": Int(scrollDY)])
            scrollDX = 0; scrollDY = 0
        }
    }

    private func stamp(_ t: Double) -> Int { Int((t - t0) * 1000) }

    // Safe to call from any thread: all file I/O is funnelled onto the serial
    // write queue, and skipped once the file has been closed (see stop()).
    private func write(_ obj: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj) else { return }
        q.async { [weak self] in
            guard let self = self, let f = self.file else { return }
            f.write(d); f.write(Data([0x0a])); self.rows += 1
        }
    }

    private func button(_ type: CGEventType) -> String {
        switch type {
        case .leftMouseDown, .leftMouseUp: return "left"
        case .rightMouseDown, .rightMouseUp: return "right"
        default: return "other"
        }
    }

    private func modNames(_ f: CGEventFlags) -> [String] {
        var m: [String] = []
        if f.contains(.maskCommand) { m.append("cmd") }
        if f.contains(.maskShift) { m.append("shift") }
        if f.contains(.maskControl) { m.append("ctrl") }
        if f.contains(.maskAlternate) { m.append("alt") }
        return m
    }

    private func handle(type: CGEventType, event: CGEvent) {
        let now = CACurrentMediaTime()
        let loc = event.location
        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            down[button(type)] = (Double(loc.x), Double(loc.y), now)
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            let b = button(type)
            guard let d = down.removeValue(forKey: b) else { break }
            clicks += 1
            let moved = hypot(loc.x - d.x, loc.y - d.y)
            let sx = d.x, sy = d.y, st = d.t, tx = loc.x, ty = loc.y, m = mods
            if moved <= 8 { keyframe?(stamp(st)) }   // #5 pristine snapshot on click
            q.async {
                // contextAt needs RAW global points (AX hit-test); coords are
                // written in screen-pixel space via px()/py().
                let ctx = self.contextAt(sx, sy)
                var row: [String: Any] = moved > 8
                    ? ["type": "drag", "t_ms": self.stamp(st), "end_ms": self.stamp(now),
                       "from": [self.px(sx), self.py(sy)], "to": [self.px(tx), self.py(ty)], "button": b, "mods": m]
                    : ["type": "click", "t_ms": self.stamp(st), "x": self.px(sx), "y": self.py(sy), "button": b, "mods": m]
                row.merge(ctx) { a, _ in a }
                self.write(row)
            }
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged:
            if now - lastCursor >= 0.1 {
                lastCursor = now
                write(["type": "cursor", "t_ms": stamp(now), "x": px(loc.x), "y": py(loc.y)])
            }
        case .scrollWheel:
            // axis1 = vertical, axis2 = horizontal (point deltas)
            scrollDY += event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
            scrollDX += event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
            if now - lastScroll >= 0.1 {
                lastScroll = now
                write(["type": "scroll", "t_ms": stamp(now), "x": px(loc.x), "y": py(loc.y),
                       "dx": Int(scrollDX), "dy": Int(scrollDY)])
                scrollDX = 0; scrollDY = 0
            }
        case .keyDown:
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            let f = event.flags
            let cmd = f.contains(.maskCommand), ctrl = f.contains(.maskControl), alt = f.contains(.maskAlternate)
            // #3 typed-text: NEVER capture while macOS secure input is on (passwords)
            if IsSecureEventInputEnabled() { flushTyped(at: now); break }
            let char = NSEvent(cgEvent: event)?.charactersIgnoringModifiers ?? ""
            let printable = char.count == 1 && (char.first.map { $0.isLetter || $0.isNumber || $0.isPunctuation || $0.isSymbol || $0 == " " } ?? false)
            if printable && !cmd && !ctrl && !alt {
                // plain typing accumulates into a text run
                if typed.isEmpty { typedStart = now }
                typed.append(char)
                if typed.count >= 500 { flushTyped(at: now) }
            } else if code == 51, !typed.isEmpty {   // backspace edits the run in place
                typed.removeLast()
            } else {
                // shortcut / special key: flush the run, then log the key
                flushTyped(at: now)
                let k = NAMED_KEYS[code] ?? (printable ? char : "key\(code)")
                write(["type": "key", "t_ms": stamp(now), "key": k, "mods": mods])
            }
        case .flagsChanged:
            mods = modNames(event.flags)
        default: break
        }
    }

    // #3 emit the accumulated keystrokes as one `text` event, tagged with the app
    // it was typed in. Cleared after flush.
    private func flushTyped(at t: Double) {
        guard !typed.isEmpty else { return }
        let text = typed; typed = ""
        var row: [String: Any] = ["type": "text", "t_ms": stamp(typedStart), "end_ms": stamp(t), "text": text]
        if !lastFocusApp.isEmpty { row["app"] = lastFocusApp }
        if !lastFocusWin.isEmpty { row["window"] = lastFocusWin }
        write(row)
    }

    // #4 poll the pasteboard; emit copied text (capped), skipping concealed/secure.
    private func startClipboardPoll() {
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 0.5, repeating: 0.5)
        t.setEventHandler { [weak self] in self?.pollClipboard() }
        t.resume()
        pbTimer = t
    }
    private func pollClipboard() {
        let pb = NSPasteboard.general
        guard pb.changeCount != pbCount else { return }
        pbCount = pb.changeCount
        if IsSecureEventInputEnabled() { return }
        let types = (pb.types ?? []).map { $0.rawValue }
        if types.contains("org.nspasteboard.ConcealedType") || types.contains("org.nspasteboard.TransientType") { return }
        guard let s = pb.string(forType: .string), !s.isEmpty else { return }
        write(["type": "clipboard", "t_ms": stamp(CACurrentMediaTime()), "chars": s.count, "text": String(s.prefix(2000))])
    }

    private func axCopy(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success ? v : nil
    }
    private func axString(_ el: AXUIElement, _ attr: String) -> String? {
        guard let v = axCopy(el, attr) else { return nil }
        return CFGetTypeID(v) == CFStringGetTypeID() ? ((v as! CFString) as String) : nil
    }
    // Element frame in screen.mp4 pixel space (display-local, top-left), clipped to
    // the visible viewport — AX returns the full element frame in global points,
    // which can extend off-screen (scrollable content) and sit on another display.
    private func axBounds(_ el: AXUIElement) -> [Int]? {
        guard let p = axCopy(el, kAXPositionAttribute), let s = axCopy(el, kAXSizeAttribute) else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &pt)
        AXValueGetValue(s as! AXValue, .cgSize, &sz)
        let x = (pt.x - ox) * sc, y = (pt.y - oy) * sc
        let x0 = max(0.0, x), y0 = max(0.0, y)
        let x1 = min(Double(pw), x + sz.width * sc), y1 = min(Double(ph), y + sz.height * sc)
        return [Int(x0), Int(y0), Int(max(0, x1 - x0)), Int(max(0, y1 - y0))]
    }
    private func focusedWindow(_ pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        guard let w = axCopy(app, kAXFocusedWindowAttribute) else { return nil }
        return axString(w as! AXUIElement, kAXTitleAttribute)
    }
    private func contextAt(_ x: Double, _ y: Double) -> [String: Any] {
        var out: [String: Any] = [:]
        if let app = NSWorkspace.shared.frontmostApplication {
            out["app"] = app.localizedName ?? ""
            if let t = focusedWindow(app.processIdentifier) { out["window"] = t }
        }
        var el: AXUIElement?
        if AXUIElementCopyElementAtPosition(sys, Float(x), Float(y), &el) == .success, let el = el {
            var ax: [String: Any] = [:]
            if let r = axString(el, kAXRoleAttribute) { ax["role"] = r }
            if let l = axString(el, kAXTitleAttribute) ?? axString(el, kAXDescriptionAttribute) ?? axString(el, kAXValueAttribute) {
                ax["label"] = String(l.prefix(90))
            }
            if let b = axBounds(el) { ax["bounds"] = b }
            out["ax"] = ax
        }
        return out
    }
}

@available(macOS 13.0, *)
func listAll() async {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        print("displays:")
        for (i, d) in content.displays.enumerated() {
            let f = d.frame
            print("  [\(i)] id=\(d.displayID) x=\(Int(f.origin.x)) y=\(Int(f.origin.y)) w=\(Int(f.size.width)) h=\(Int(f.size.height))")
        }
    } catch { err("display list failed: \(error)") }
    print("cameras:")
    for (i, d) in cameraDevices().enumerated() { print("  [\(i)] \(d.localizedName)\(camInfo(d))") }
    print("mics:")
    for (i, d) in micDevices().enumerated() { print("  [\(i)] \(d.localizedName)") }
}

// Ground-truth a camera using the Continuity Camera / Desk View APIs: its
// device type, whether it's a Continuity Camera, whether it carries a Desk View
// companion (companion!=nil ⇒ this IS the main camera), and its format sizes.
func camInfo(_ d: AVCaptureDevice) -> String {
    var bits = ["type=\(d.deviceType.rawValue.replacingOccurrences(of: "AVCaptureDeviceType", with: ""))"]
    if #available(macOS 13.0, *) {
        bits.append("continuity=\(d.isContinuityCamera)")
        bits.append("deskCompanion=\(d.companionDeskViewCamera != nil)")
    }
    let dims = d.formats.map { f -> String in
        let dm = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
        return "\(dm.width)x\(dm.height)"
    }
    let active = CMVideoFormatDescriptionGetDimensions(d.activeFormat.formatDescription)
    bits.append("active=\(active.width)x\(active.height)")
    bits.append("fmts=[\(Array(Set(dims)).sorted().joined(separator: ","))]")
    return "  (" + bits.joined(separator: " ") + ")"
}

// One-shot screenshot of a display, downscaled, as a base64 PNG on stdout.
// Drives the in-app screen thumbnail so you can see which monitor you picked.
@available(macOS 14.0, *)
func captureShot(index: Int, maxW: Int) async {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard index < content.displays.count else { err("no display \(index)"); exit(1) }
        let display = content.displays[index]
        let scale = min(1.0, Double(maxW) / Double(display.width))
        let cfg = SCStreamConfiguration()
        cfg.width = max(1, Int(Double(display.width) * scale))
        cfg.height = max(1, Int(Double(display.height) * scale))
        cfg.showsCursor = false
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let cg = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let png = rep.representation(using: .png, properties: [:]) else { err("encode failed"); exit(1) }
        print(png.base64EncodedString())
        exit(0)
    } catch { err("shot failed: \(error)"); exit(1) }
}

@available(macOS 13.0, *)
func record(screenIdx: Int, camIdx: Int?, micIdx: Int?, outDir: String, fps: Int, secs: Double, w: Int?, h: Int?) async {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard screenIdx < content.displays.count else { err("no display \(screenIdx)"); exit(1) }
        let display = content.displays[screenIdx]
        try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        let dir = URL(fileURLWithPath: outDir)

        // ---- phase 1: ARM all sources (phone connects here) ----
        let screen = ScreenRecorder()
        try await screen.arm(display: display, fps: fps, width: w ?? display.width, height: h ?? display.height,
                             outURL: dir.appendingPathComponent("screen.mp4"),
                             sysAudioURL: dir.appendingPathComponent("sysaudio.m4a"))

        var cam: CameraRecorder?
        if let ci = camIdx {
            let devs = cameraDevices()
            guard ci < devs.count else { err("no camera \(ci)"); exit(1) }
            let c = CameraRecorder()
            try c.arm(device: devs[ci], outURL: dir.appendingPathComponent("camera.mp4"))
            cam = c
            err("camera: \(devs[ci].localizedName)")
        }

        var mic: MicRecorder?
        if let mi = micIdx {
            let devs = micDevices()
            guard mi < devs.count else { err("no mic \(mi)"); exit(1) }
            let m = MicRecorder()
            try m.arm(device: devs[mi], outURL: dir.appendingPathComponent("mic.m4a"))
            mic = m
            err("mic: \(devs[mi].localizedName)")
        }

        // ---- phase 2: WARM wait — block until every source delivers a frame ----
        err("warming up (waiting for sources to connect)…")
        let warmStart = CACurrentMediaTime()
        let warmDeadline = warmStart + 15
        while CACurrentMediaTime() < warmDeadline {
            if screen.ready && (cam?.ready ?? true) && (mic?.ready ?? true) { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let warmed = CACurrentMediaTime() - warmStart
        if !screen.ready { err("⚠︎ screen not warm after \(String(format: "%.1f", warmed))s") }
        if let c = cam, !c.ready { err("⚠︎ camera not warm after \(String(format: "%.1f", warmed))s (phone connected?)") }
        if let m = mic, !m.ready { err("⚠︎ mic not warm after \(String(format: "%.1f", warmed))s") }

        // ---- phase 3: GO — one shared t0, all writers start together ----
        let t0 = CACurrentMediaTime()
        screen.beginWriting(at: t0)
        cam?.beginWriting(at: t0)
        mic?.beginWriting(at: t0)
        let telemetry = Telemetry()
        let scrW = w ?? display.width, scrH = h ?? display.height
        let kfDir = dir.appendingPathComponent("keyframes")
        try? FileManager.default.createDirectory(at: kfDir, withIntermediateDirectories: true)
        telemetry.keyframe = { [weak screen] tMs in screen?.snapshotPNG(to: kfDir.appendingPathComponent("\(tMs).png")) }
        telemetry.start(outURL: dir.appendingPathComponent("metadata.jsonl"), t0: t0,
                        originXpt: display.frame.origin.x, originYpt: display.frame.origin.y,
                        scalePx: Double(scrW) / display.frame.width, pixelW: scrW, pixelH: scrH)
        err("● recording \(w ?? display.width)x\(h ?? display.height)@\(fps)"
            + "\(camIdx != nil ? " + camera" : "")\(micIdx != nil ? " + mic" : "")"
            + "\(telemetry.ok ? " + meta" : "")  (warmed in \(String(format: "%.1f", warmed))s)")

        var finishing = false
        let progress = DispatchSource.makeTimerSource(queue: .main)
        let stdinSrc = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .main)

        func finish() async {
            if finishing { return }
            finishing = true
            progress.cancel()
            stdinSrc.cancel()
            telemetry.stop()
            // hold the screen's final frame out to the stop instant so screen.mp4
            // spans the whole take even if the screen was static at the end
            let stopT = CACurrentMediaTime()
            screen.finalize(at: stopT)
            await screen.stop()
            if let c = cam { await c.stop() }
            if let m = mic { await m.stop() }
            err("screen frames: delivered=\(screen.delivered) written=\(screen.written) dropped=\(screen.delivered - screen.written)")
            if let c = cam { err("camera frames: written=\(c.written)") }
            if let m = mic { err("mic buffers: written=\(m.written)") }
            err("metadata rows: \(telemetry.rows)\(telemetry.ok ? "" : " (telemetry off — no Accessibility)")")
            let f = display.frame
            var manifest: [String: Any] = [
                "version": VERSION, "fps": fps, "t0": t0, "durationMs": (stopT - t0) * 1000,
                "display": ["id": display.displayID, "x": Int(f.origin.x), "y": Int(f.origin.y),
                            "w": Int(f.size.width), "h": Int(f.size.height)],
                "screen": ["file": "screen.mp4", "firstPTS": screen.firstWrittenPTS],
                "metadata": telemetry.ok ? "metadata.jsonl" : NSNull(),
            ]
            if let c = cam {
                manifest["camera"] = cameraManifestBlock(firstPTS: c.firstWrittenPTS, proxyWritten: c.proxyWritten)
                manifest["cameraSyncOffsetMs"] = (c.firstWrittenPTS - screen.firstWrittenPTS) * 1000
            }
            if let m = mic {
                manifest["mic"] = ["file": "mic.m4a", "firstPTS": m.firstWrittenPTS]
                manifest["micSyncOffsetMs"] = (m.firstWrittenPTS - screen.firstWrittenPTS) * 1000
            }
            if screen.audioWritten > 0 {
                manifest["sysaudio"] = ["file": "sysaudio.m4a", "firstPTS": screen.audioFirstPTS]
                manifest["sysAudioSyncOffsetMs"] = (screen.audioFirstPTS - screen.firstWrittenPTS) * 1000
            }
            if let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted]) {
                try? data.write(to: dir.appendingPathComponent("manifest.json"))
            }
            print("done")
            exit(0)
        }

        // live progress for the UI — elapsed/frames/clicks every 0.5s
        progress.schedule(deadline: .now() + 0.5, repeating: 0.5)
        progress.setEventHandler {
            // screen writing is now driven by the recorder's own CFR timer
            let el = Int((CACurrentMediaTime() - t0) * 1000)
            err("progress elapsed=\(el) screen=\(screen.written) camera=\(cam?.written ?? 0) clicks=\(telemetry.clicks) rows=\(telemetry.rows)")
        }
        progress.resume()

        // graceful stop when the parent (Tauri) writes a line or closes stdin
        stdinSrc.setEventHandler { Task { await finish() } }
        stdinSrc.resume()

        if secs > 0 {
            try await Task.sleep(nanoseconds: UInt64(secs * 1_000_000_000))
            await finish()
        } else {
            let sig = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            signal(SIGINT, SIG_IGN)
            sig.setEventHandler { Task { await finish() } }
            sig.resume()
            try await Task.sleep(nanoseconds: UInt64.max)
        }
    } catch { err("capture failed: \(error)"); exit(1) }
}

// ============================================================================
// Daemon mode (`--serve`): ONE persistent process owns the camera the whole time
// — the OBS model. The camera session opens once and stays open, feeding a live
// preview to stdout continuously; recording just taps the SAME session (so there
// is never a second client fighting the Continuity Camera, and no re-handshake
// when you hit record). Screen + mic + telemetry are created per-recording.
//
//   stdin commands (one per line):
//     cam <idx|none>                              select/clear the preview camera
//     rec <screen> <cam|-> <mic|-> <fps> <dir>    start recording (camera tapped live)
//     stop                                        finalize the take, keep previewing
//     quit                                        clean shutdown
//   stdout: `FRAME <base64 jpeg>` preview frames (nothing else)
//   stderr: state/log/progress lines (same format the Tauri reader already parses)
// ============================================================================

let stdoutHandle = FileHandle.standardOutput
func outLine(_ s: String) { stdoutHandle.write((s + "\n").data(using: .utf8)!) }

// The single, persistent camera session: live preview + optional recording tap.
final class CameraStation: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let q = DispatchQueue(label: "roll.camstation")
    private let ci = CIContext(options: [.cacheIntermediates: false])
    private let rgb = CGColorSpaceCreateDeviceRGB()
    private var currentInput: AVCaptureDeviceInput?
    private let output = AVCaptureVideoDataOutput()
    private(set) var device: AVCaptureDevice?

    // preview throttle
    private var lastPreview = 0.0
    private let previewInterval = 1.0 / 12.0
    private let previewWidth = 480.0

    // recording tap (set between beginRecording/finishRecording)
    private var master: CamWriter?
    private var proxy: CamWriter?
    private var recFrom = Double.infinity
    private(set) var ready = false
    var written: Int { master?.written ?? 0 }
    var firstWrittenPTS: Double { master?.firstWrittenPTS ?? 0 }
    var proxyWritten: Int { proxy?.written ?? 0 }

    override init() {
        super.init()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: q)
    }

    // Open (or switch to) a camera and start previewing. Safe to call repeatedly.
    func open(_ dev: AVCaptureDevice) {
        noteCameraEffects(dev)
        session.beginConfiguration()
        session.sessionPreset = camPreset
        if let ci = currentInput { session.removeInput(ci); currentInput = nil }
        if let input = try? AVCaptureDeviceInput(device: dev), session.canAddInput(input) {
            session.addInput(input); currentInput = input
        }
        if session.canAddOutput(output), !session.outputs.contains(output) { session.addOutput(output) }
        session.commitConfiguration()
        device = dev
        ready = false
        if !session.isRunning { session.startRunning() }
        err("📷 preview camera: \(dev.localizedName)")
    }

    func close() {
        if session.isRunning { session.stopRunning() }
        if let ci = currentInput { session.beginConfiguration(); session.removeInput(ci); session.commitConfiguration(); currentInput = nil }
        device = nil; ready = false
    }

    // Begin tapping the live session into a file at the shared t0.
    func beginRecording(outURL: URL, at t0: Double, fps: Int) throws {
        let m = try CamWriter(outURL: outURL, w: camWidth, h: camHeight, bitrate: camBitrate, fps: fps)
        m.startSession(at: t0)
        let proxyURL = outURL.deletingLastPathComponent().appendingPathComponent("camera.proxy.mp4")
        do {
            let p = try CamWriter(outURL: proxyURL, w: PROXY_W, h: PROXY_H, bitrate: PROXY_BITRATE, fps: fps)
            p.startSession(at: t0)
            proxy = p
        } catch { err("camera proxy writer failed (take continues without it): \(error)"); proxy = nil }
        master = m; recFrom = t0
    }

    func finishRecording() async {
        recFrom = .infinity
        await master?.finish()
        await proxy?.finish()
        // keep the refs — written/firstWrittenPTS still feed the manifest after close;
        // the next beginRecording replaces them
    }

    private func emitPreview(_ pb: CVPixelBuffer) {
        let img = CIImage(cvPixelBuffer: pb)
        let scale = previewWidth / max(img.extent.width, 1)
        let small = img.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let data = ci.jpegRepresentation(of: small, colorSpace: rgb,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.5]) else { return }
        outLine("FRAME " + data.base64EncodedString())
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        ready = true
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        if pts >= recFrom {
            master?.append(sampleBuffer, pts: pts)
            proxy?.append(sampleBuffer, pts: pts)
        }
        let now = CACurrentMediaTime()
        if now - lastPreview >= previewInterval, let pb = CMSampleBufferGetImageBuffer(sampleBuffer) {
            lastPreview = now
            emitPreview(pb)
        }
    }
}

// A metering-only mic session: streams RMS level (0..1) to stdout as `LEVEL <v>`
// so the UI can show a live VU bar whenever a mic is selected — idle and during
// recording. Independent of MicRecorder (audio devices allow multiple clients).
final class MicMeter: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let q = DispatchQueue(label: "roll.micmeter")
    private var currentInput: AVCaptureDeviceInput?
    private let output = AVCaptureAudioDataOutput()
    private var lastEmit = 0.0
    private let interval = 1.0 / 15.0

    override init() {
        super.init()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        output.setSampleBufferDelegate(self, queue: q)
    }

    func open(_ dev: AVCaptureDevice) {
        session.beginConfiguration()
        if let ci = currentInput { session.removeInput(ci); currentInput = nil }
        if let input = try? AVCaptureDeviceInput(device: dev), session.canAddInput(input) {
            session.addInput(input); currentInput = input
        }
        if session.canAddOutput(output), !session.outputs.contains(output) { session.addOutput(output) }
        session.commitConfiguration()
        if !session.isRunning { session.startRunning() }
        err("🎙 meter: \(dev.localizedName)")
    }

    func close() {
        if session.isRunning { session.stopRunning() }
        if let ci = currentInput { session.beginConfiguration(); session.removeInput(ci); session.commitConfiguration(); currentInput = nil }
        outLine("LEVEL 0")
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = CACurrentMediaTime()
        guard now - lastEmit >= interval, let bb = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var length = 0
        var dataPtr: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPtr) == kCMBlockBufferNoErr,
              let dp = dataPtr, length >= MemoryLayout<Float>.size else { return }
        let count = length / MemoryLayout<Float>.size
        let samples = UnsafeRawPointer(dp).assumingMemoryBound(to: Float.self)
        var sum: Float = 0
        for i in 0..<count { let s = samples[i]; sum += s * s }
        let rms = sqrtf(sum / Float(count))
        lastEmit = now
        outLine("LEVEL \(String(format: "%.4f", min(1.0, rms)))")
    }
}

@available(macOS 13.0, *)
final class Daemon {
    let station = CameraStation()
    let micMeter = MicMeter()
    private var screen: ScreenRecorder?
    private var mic: MicRecorder?
    private var telemetry: Telemetry?
    private var dir: URL?
    private var display: SCDisplay?
    private var fps = 30
    private var t0 = 0.0
    private var progress: DispatchSourceTimer?
    private(set) var recording = false

    func handle(_ raw: String) async {
        let parts = raw.split(separator: " ").map(String.init)
        guard let cmd = parts.first else { return }
        switch cmd {
        case "cam":
            let arg = parts.count > 1 ? parts[1] : "none"
            if arg == "none" { station.close() }
            else if let i = Int(arg) {
                let devs = cameraDevices()
                if i < devs.count { station.open(devs[i]) } else { err("no camera \(i)") }
            }
        case "mic":
            let arg = parts.count > 1 ? parts[1] : "none"
            if arg == "none" { micMeter.close() }
            else if let i = Int(arg) {
                let devs = micDevices()
                if i < devs.count { micMeter.open(devs[i]) } else { err("no mic \(i)") }
            }
        case "rec":
            guard !recording, parts.count >= 6,
                  let s = Int(parts[1]), let f = Int(parts[4]) else { err("bad rec command"); return }
            let cam = Int(parts[2]); let micI = Int(parts[3])
            await startRec(screenIdx: s, camIdx: cam, micIdx: micI, fps: f, outDir: parts[5...].joined(separator: " "))
        case "stop":
            await stopRec()
        case "quit":
            if recording { await stopRec() }
            station.close()
            micMeter.close()
            exit(0)
        default:
            err("unknown command: \(cmd)")
        }
    }

    private func startRec(screenIdx: Int, camIdx: Int?, micIdx: Int?, fps: Int, outDir: String) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard screenIdx < content.displays.count else { err("no display \(screenIdx)"); return }
            let disp = content.displays[screenIdx]
            try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
            let d = URL(fileURLWithPath: outDir)

            // ARM the per-take sources (camera is already live in the station)
            let scr = ScreenRecorder()
            try await scr.arm(display: disp, fps: fps, width: disp.width, height: disp.height,
                              outURL: d.appendingPathComponent("screen.mp4"),
                              sysAudioURL: d.appendingPathComponent("sysaudio.m4a"))
            var m: MicRecorder?
            if let mi = micIdx {
                let devs = micDevices()
                if mi < devs.count { let r = MicRecorder(); try r.arm(device: devs[mi], outURL: d.appendingPathComponent("mic.m4a")); m = r }
            }
            // If a camera index was given but isn't the one we're previewing, switch.
            if let cidx = camIdx { let devs = cameraDevices(); if cidx < devs.count, station.device?.uniqueID != devs[cidx].uniqueID { station.open(devs[cidx]) } }

            // WARM — wait for screen + mic + (already-running) camera to be ready
            err("warming up (waiting for sources to connect)…")
            let warmStart = CACurrentMediaTime()
            while CACurrentMediaTime() - warmStart < 15 {
                if scr.ready && (m?.ready ?? true) && (camIdx == nil || station.ready) { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            let warmed = CACurrentMediaTime() - warmStart

            // GO — one shared t0 across screen + camera tap + mic + telemetry
            let start = CACurrentMediaTime()
            scr.beginWriting(at: start)
            if camIdx != nil { try station.beginRecording(outURL: d.appendingPathComponent("camera.mp4"), at: start, fps: fps) }
            m?.beginWriting(at: start)
            let tel = Telemetry()
            let kfDir = d.appendingPathComponent("keyframes")
            try? FileManager.default.createDirectory(at: kfDir, withIntermediateDirectories: true)
            tel.keyframe = { [weak scr] tMs in scr?.snapshotPNG(to: kfDir.appendingPathComponent("\(tMs).png")) }
            tel.start(outURL: d.appendingPathComponent("metadata.jsonl"), t0: start,
                      originXpt: disp.frame.origin.x, originYpt: disp.frame.origin.y,
                      scalePx: Double(disp.width) / disp.frame.width, pixelW: disp.width, pixelH: disp.height)

            screen = scr; mic = m; telemetry = tel; dir = d; display = disp; self.fps = fps; t0 = start; recording = true
            err("● recording \(disp.width)x\(disp.height)@\(fps)\(camIdx != nil ? " + camera" : "")\(micIdx != nil ? " + mic" : "")\(tel.ok ? " + meta" : "")  (warmed in \(String(format: "%.1f", warmed))s)")

            let p = DispatchSource.makeTimerSource(queue: .main)
            p.schedule(deadline: .now() + 0.5, repeating: 0.5)
            p.setEventHandler { [weak self] in
                guard let self = self, let scr = self.screen else { return }
                let el = Int((CACurrentMediaTime() - self.t0) * 1000)
                err("progress elapsed=\(el) screen=\(scr.written) camera=\(self.station.written) clicks=\(self.telemetry?.clicks ?? 0) rows=\(self.telemetry?.rows ?? 0)")
            }
            p.resume()
            progress = p
        } catch { err("capture failed: \(error)") }
    }

    private func stopRec() async {
        guard recording, let scr = screen, let d = dir, let disp = display else { return }
        recording = false
        progress?.cancel(); progress = nil
        telemetry?.stop()
        let stopT = CACurrentMediaTime()
        scr.finalize(at: stopT)
        await scr.stop()
        await station.finishRecording()   // camera keeps previewing — only the writer closes
        await mic?.stop()

        let f = disp.frame
        var manifest: [String: Any] = [
            "version": VERSION, "fps": fps, "t0": t0, "durationMs": (stopT - t0) * 1000,
            "display": ["id": disp.displayID, "x": Int(f.origin.x), "y": Int(f.origin.y),
                        "w": Int(f.size.width), "h": Int(f.size.height)],
            "screen": ["file": "screen.mp4", "firstPTS": scr.firstWrittenPTS],
            "metadata": (telemetry?.ok ?? false) ? "metadata.jsonl" : NSNull(),
        ]
        if station.written > 0 {
            manifest["camera"] = cameraManifestBlock(firstPTS: station.firstWrittenPTS, proxyWritten: station.proxyWritten)
            manifest["cameraSyncOffsetMs"] = (station.firstWrittenPTS - scr.firstWrittenPTS) * 1000
        }
        if let m = mic, m.written > 0 {
            manifest["mic"] = ["file": "mic.m4a", "firstPTS": m.firstWrittenPTS]
            manifest["micSyncOffsetMs"] = (m.firstWrittenPTS - scr.firstWrittenPTS) * 1000
        }
        if scr.audioWritten > 0 {
            manifest["sysaudio"] = ["file": "sysaudio.m4a", "firstPTS": scr.audioFirstPTS]
            manifest["sysAudioSyncOffsetMs"] = (scr.audioFirstPTS - scr.firstWrittenPTS) * 1000
        }
        if let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted]) {
            try? data.write(to: d.appendingPathComponent("manifest.json"))
        }
        err("saved \(d.path)")   // Tauri reads this to build the pack + go idle
        screen = nil; mic = nil; telemetry = nil; dir = nil; display = nil
    }
}

@available(macOS 13.0, *)
func serve() {
    let daemon = Daemon()
    // graceful shutdown so a finalize-in-flight isn't truncated by a signal
    for sig in [SIGTERM, SIGINT, SIGHUP] {
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        src.setEventHandler { Task { await daemon.handle("quit") } }
        src.resume()
        // keep the source alive for the process lifetime
        signalSources.append(src)
    }
    // read stdin commands on a background thread; run each on the main queue
    Thread.detachNewThread {
        while let line = readLine(strippingNewline: true) {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.isEmpty { continue }
            DispatchQueue.main.async { Task { await daemon.handle(l) } }
        }
        // stdin closed (parent gone) — shut down cleanly
        DispatchQueue.main.async { Task { await daemon.handle("quit") } }
    }
    err("roll-capture \(VERSION) serving")
    RunLoop.main.run()
}
var signalSources: [DispatchSourceSignal] = []

// ---- entry ----
if args.contains("--help") || args.contains("-h") {
    print("""
    roll-capture \(VERSION)
      --list
      --shot <i> [--width 480]            one base64 PNG of a display on stdout
      --screen <i> [--cam <i>] [--mic <i>] --out <dir> [--fps 30] [--secs N] [--width W --height H]
      --serve                              persistent daemon: one camera session for
                                           live preview (FRAME lines on stdout) + recording
                                           (stdin: cam/rec/stop/quit)
      --cam-height <720|1080> --cam-bitrate <bps>
                                           camera encode (default 1080 @ 6000000);
                                           applies to --screen and --serve
    stop: --secs deadline, SIGINT, or a line / EOF on stdin
    """)
    exit(0)
}

if #available(macOS 13.0, *) {
    if args.contains("--list") {
        let sem = DispatchSemaphore(value: 0)
        Task { await listAll(); sem.signal() }
        sem.wait(); exit(0)
    }
    if args.contains("--serve") {
        serve()   // never returns (runs the main run loop)
    }
    if let shot = argVal("--shot") {
        if #available(macOS 14.0, *) {
            let maxW = Int(argVal("--width") ?? "480") ?? 480
            Task { await captureShot(index: Int(shot) ?? 0, maxW: maxW) }
            RunLoop.main.run()
        } else { err("--shot needs macOS 14"); exit(1) }
    }
    if let scr = argVal("--screen"), let outDir = argVal("--out") {
        let fps = Int(argVal("--fps") ?? "30") ?? 30
        let secs = Double(argVal("--secs") ?? "0") ?? 0
        Task {
            await record(screenIdx: Int(scr) ?? 0,
                         camIdx: argVal("--cam").flatMap { Int($0) },
                         micIdx: argVal("--mic").flatMap { Int($0) },
                         outDir: outDir, fps: fps, secs: secs,
                         w: argVal("--width").flatMap { Int($0) },
                         h: argVal("--height").flatMap { Int($0) })
        }
        RunLoop.main.run()
    }
}

capabilityReport()
