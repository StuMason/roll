import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia
import QuartzCore
import AppKit
import ApplicationServices

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

let VERSION = "0.0.12"

// keyCodes that have no sensible printable character — named so the key stream
// is legible (charactersIgnoringModifiers returns control/unicode junk for these)
let NAMED_KEYS: [Int: String] = [
    36: "return", 48: "tab", 49: "space", 51: "delete", 53: "escape", 76: "enter",
    117: "fwd-delete", 115: "home", 119: "end", 116: "page-up", 121: "page-down",
    123: "left", 124: "right", 125: "down", 126: "up",
    122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7",
    100: "f8", 101: "f9", 109: "f10", 103: "f11", 111: "f12",
]

// macOS injects system "video effects" (Center Stage auto-framing, Portrait
// blur, Studio Light) into ANY camera feed. They mutate the image mid-take — a
// faithful capture for editing must not have them. Center Stage we can force
// off from the app; Portrait/Studio Light are user-only (Control Center), so we
// just warn if they're active.
func neutralizeCameraEffects(_ device: AVCaptureDevice) {
    if device.activeFormat.isCenterStageSupported {
        AVCaptureDevice.centerStageControlMode = .app
        AVCaptureDevice.isCenterStageEnabled = false
    }
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
    private var writeFrom: Double = .infinity
    private var lastPixelBuffer: CVPixelBuffer?
    private var lastAppendedPTS: Double = 0
    private(set) var ready = false
    private(set) var delivered = 0
    private(set) var written = 0
    private(set) var firstWrittenPTS: Double = 0

    func arm(display: SCDisplay, fps: Int, width: Int, height: Int, outURL: URL) async throws {
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
        writer.startWriting()

        let config = SCStreamConfiguration()
        config.width = width; config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.queueDepth = 8
        config.showsCursor = true
        config.pixelFormat = kCVPixelFormatType_32BGRA
        let filter = SCContentFilter(display: display, excludingWindows: [])
        stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: q)
        try await stream.startCapture()
    }

    func beginWriting(at t0: Double) {
        writer.startSession(atSourceTime: cmt(t0))
        writeFrom = t0
    }

    // Build a sample buffer from a pixel buffer at an explicit PTS and append it.
    private func appendImage(_ pb: CVPixelBuffer, at seconds: Double) {
        guard input.isReadyForMoreMediaData else { return }
        var fmt: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb, formatDescriptionOut: &fmt)
        guard let fmt = fmt else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: cmt(seconds), decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb,
            dataReady: true, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: fmt, sampleTiming: &timing, sampleBufferOut: &sb)
        if let sb = sb { input.append(sb); written += 1; lastAppendedPTS = seconds }
    }

    // Re-emit the last frame if the screen has been static (~2fps floor).
    func keepalive(at t: Double) {
        q.async {
            guard t >= self.writeFrom, let pb = self.lastPixelBuffer, t - self.lastAppendedPTS >= 0.4 else { return }
            self.appendImage(pb, at: t)
        }
    }

    // Hold the final frame to the stop instant so duration spans the whole take.
    func finalize(at t: Double) {
        q.sync {
            if let pb = self.lastPixelBuffer, t > self.lastAppendedPTS { self.appendImage(pb, at: t) }
        }
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
        ready = true
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.seconds >= writeFrom, let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastPixelBuffer = pb
        delivered += 1
        if firstWrittenPTS == 0 {
            // anchor the first frame at t0 so the screen spans from the very start
            firstWrittenPTS = writeFrom
            appendImage(pb, at: writeFrom)
        } else if input.isReadyForMoreMediaData {
            input.append(sampleBuffer); written += 1; lastAppendedPTS = pts.seconds
        }
    }
}

// ---- camera (AVFoundation) ----
final class CameraRecorder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private var writer: AVAssetWriter!
    private var input: AVAssetWriterInput!
    private var writeFrom: Double = .infinity
    private(set) var ready = false
    private(set) var written = 0
    private(set) var firstWrittenPTS: Double = 0

    func arm(device: AVCaptureDevice, outURL: URL) throws {
        neutralizeCameraEffects(device)   // no mid-take Center Stage zoom
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
        writer.startWriting()
        session.startRunning()   // triggers the Continuity Camera handshake NOW
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

    func start(outURL: URL, t0: Double) {
        self.t0 = t0
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        file = try? FileHandle(forWritingTo: outURL)

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
        flushScroll(at: CACurrentMediaTime())
        try? file?.synchronize(); try? file?.close()
    }

    private func emitAppFocus(_ app: NSRunningApplication?, at t: Double) {
        guard let app = app, let name = app.localizedName, name != lastApp else { return }
        lastApp = name
        let pid = app.processIdentifier, ts = stamp(t)
        q.async {
            var row: [String: Any] = ["type": "app_focus", "t_ms": ts, "app": name]
            if let w = self.focusedWindow(pid) { row["window"] = w }
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

    private func write(_ obj: [String: Any]) {
        guard let f = file, let d = try? JSONSerialization.data(withJSONObject: obj) else { return }
        f.write(d); f.write(Data([0x0a])); rows += 1
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
            q.async {
                let ctx = self.contextAt(sx, sy)
                var row: [String: Any] = moved > 8
                    ? ["type": "drag", "t_ms": self.stamp(st), "end_ms": self.stamp(now),
                       "from": [Int(sx), Int(sy)], "to": [Int(tx), Int(ty)], "button": b, "mods": m]
                    : ["type": "click", "t_ms": self.stamp(st), "x": Int(sx), "y": Int(sy), "button": b, "mods": m]
                row.merge(ctx) { a, _ in a }
                self.write(row)
            }
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged:
            if now - lastCursor >= 0.1 {
                lastCursor = now
                write(["type": "cursor", "t_ms": stamp(now), "x": Int(loc.x), "y": Int(loc.y)])
            }
        case .scrollWheel:
            // axis1 = vertical, axis2 = horizontal (point deltas)
            scrollDY += event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
            scrollDX += event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
            if now - lastScroll >= 0.1 {
                lastScroll = now
                write(["type": "scroll", "t_ms": stamp(now), "x": Int(loc.x), "y": Int(loc.y),
                       "dx": Int(scrollDX), "dy": Int(scrollDY)])
                scrollDX = 0; scrollDY = 0
            }
        case .keyDown:
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            let char = NSEvent(cgEvent: event)?.charactersIgnoringModifiers ?? ""
            // prefer a friendly name for non-printable keys; fall back to the char
            let k = NAMED_KEYS[code] ?? (char.first.map { $0.isLetter || $0.isNumber || $0.isPunctuation || $0.isSymbol || $0 == " " } == true ? char : "key\(code)")
            write(["type": "key", "t_ms": stamp(now), "key": k, "mods": mods])
        case .flagsChanged:
            mods = modNames(event.flags)
        default: break
        }
    }

    private func axCopy(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success ? v : nil
    }
    private func axString(_ el: AXUIElement, _ attr: String) -> String? {
        guard let v = axCopy(el, attr) else { return nil }
        return CFGetTypeID(v) == CFStringGetTypeID() ? ((v as! CFString) as String) : nil
    }
    private func axBounds(_ el: AXUIElement) -> [Int]? {
        guard let p = axCopy(el, kAXPositionAttribute), let s = axCopy(el, kAXSizeAttribute) else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &pt)
        AXValueGetValue(s as! AXValue, .cgSize, &sz)
        return [Int(pt.x), Int(pt.y), Int(sz.width), Int(sz.height)]
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
    for (i, d) in cameraDevices().enumerated() { print("  [\(i)] \(d.localizedName)") }
    print("mics:")
    for (i, d) in micDevices().enumerated() { print("  [\(i)] \(d.localizedName)") }
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
                             outURL: dir.appendingPathComponent("screen.mp4"))

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
        telemetry.start(outURL: dir.appendingPathComponent("metadata.jsonl"), t0: t0)
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
            screen.finalize(at: CACurrentMediaTime())
            await screen.stop()
            if let c = cam { await c.stop() }
            if let m = mic { await m.stop() }
            err("screen frames: delivered=\(screen.delivered) written=\(screen.written) dropped=\(screen.delivered - screen.written)")
            if let c = cam { err("camera frames: written=\(c.written)") }
            if let m = mic { err("mic buffers: written=\(m.written)") }
            err("metadata rows: \(telemetry.rows)\(telemetry.ok ? "" : " (telemetry off — no Accessibility)")")
            let f = display.frame
            var manifest: [String: Any] = [
                "version": VERSION, "fps": fps, "t0": t0,
                "display": ["id": display.displayID, "x": Int(f.origin.x), "y": Int(f.origin.y),
                            "w": Int(f.size.width), "h": Int(f.size.height)],
                "screen": ["file": "screen.mp4", "firstPTS": screen.firstWrittenPTS],
                "metadata": telemetry.ok ? "metadata.jsonl" : NSNull(),
            ]
            if let c = cam {
                manifest["camera"] = ["file": "camera.mp4", "firstPTS": c.firstWrittenPTS]
                manifest["cameraSyncOffsetMs"] = (c.firstWrittenPTS - screen.firstWrittenPTS) * 1000
            }
            if let m = mic {
                manifest["mic"] = ["file": "mic.m4a", "firstPTS": m.firstWrittenPTS]
                manifest["micSyncOffsetMs"] = (m.firstWrittenPTS - screen.firstWrittenPTS) * 1000
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
            // re-emit the last screen frame through static stretches so the
            // screen roll never falls behind the camera/mic clock
            screen.keepalive(at: CACurrentMediaTime())
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

// ---- entry ----
if args.contains("--help") || args.contains("-h") {
    print("""
    roll-capture \(VERSION)
      --list
      --shot <i> [--width 480]            one base64 PNG of a display on stdout
      --screen <i> [--cam <i>] [--mic <i>] --out <dir> [--fps 30] [--secs N] [--width W --height H]
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
