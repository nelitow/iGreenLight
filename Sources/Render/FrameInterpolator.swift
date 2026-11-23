import Foundation
import VideoToolbox
import CoreVideo
import CoreMedia
import QuartzCore
import WebRTC

/// Frame generation: sits between the video track and the renderer and, when enabled, inserts one frame made by
/// VideoToolbox's ML frame interpolation (`VTLowLatencyFrameInterpolation`, macOS 26+) between each pair of game
/// frames.
///
/// A console stream is usually 60 fps on the wire even when the game renders 30: every other frame is a repeat.
/// Repeats are recognised by comparing a grid of luma samples and dropped; for each new game frame N the
/// interpolated frame between N-1 and N is shown as soon as it is ready, and N itself half a game-frame interval
/// later. The interval comes from the RTP timestamps (the console's clock), not from arrival times, so network
/// jitter doesn't make the two halves uneven. Cost: one game-frame interval of extra latency plus the model's time.
///
/// Off, or until the model is loaded, or for formats the model doesn't take (10-bit), frames pass straight through.
/// Nothing is generated across a stall, so the freeze detector downstream still sees the stream stop.
final class FrameInterpolator: NSObject, RTCVideoRenderer, @unchecked Sendable {
    private let downstream: RTCVideoRenderer
    private let queue = DispatchQueue(label: "app.igreenlight.framegen", qos: .userInteractive)
    private let lock = NSLock()
    private var isEnabled = false
    private var statusText = "off"

    // Queue state.
    private var engine: AnyObject?
    private var previous: (frame: RTCVideoFrame, rtp: UInt32, signature: [UInt8])?
    private var lastSignature: [UInt8]?
    private var held: RTCVideoFrame?
    private var holdGeneration = 0
    private var intervalEMA: Double?
    private var processEMA: Double?
    private var uniqueCount = 0, generatedCount = 0, windowStart = CACurrentMediaTime()
    private var rateText = ""

    init(downstream: RTCVideoRenderer) {
        self.downstream = downstream
    }

    static var isSupported: Bool {
        #if !targetEnvironment(simulator)
        if #available(macOS 26.0, iOS 26.0, *) { return VTLowLatencyFrameInterpolationConfiguration.isSupported }
        #endif
        return false
    }

    var enabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return isEnabled }
        set {
            lock.lock(); let changed = newValue != isEnabled; isEnabled = newValue; lock.unlock()
            guard changed else { return }
            queue.async { [weak self] in self?.resetLocked(status: newValue ? "waiting for frames" : "off") }
        }
    }

    /// For the stats overlay.
    var status: String { lock.lock(); defer { lock.unlock() }; return statusText }

    // MARK: RTCVideoRenderer (decoder thread)
    func setSize(_ size: CGSize) { downstream.setSize(size) }

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        guard enabled else { downstream.renderFrame(frame); return }
        queue.async { [weak self] in self?.ingest(frame) }
    }

    // MARK: Queue
    private func setStatus(_ s: String) { lock.lock(); statusText = s; lock.unlock() }

    private func resetLocked(status: String) {
        flushHeld()
        previous = nil
        lastSignature = nil
        intervalEMA = nil
        setStatus(status)
    }

    private func flushHeld() {
        holdGeneration += 1
        if let h = held { held = nil; downstream.renderFrame(h) }
    }

    private func passThrough(_ frame: RTCVideoFrame, status: String) {
        flushHeld()
        previous = nil
        setStatus(status)
        downstream.renderFrame(frame)
    }

    private func ingest(_ frame: RTCVideoFrame) {
        guard enabled else { flushHeld(); downstream.renderFrame(frame); return }
        guard Self.isSupported else { passThrough(frame, status: "needs macOS 26 on Apple silicon"); return }
        guard let pb = (frame.buffer as? RTCCVPixelBuffer)?.pixelBuffer else { passThrough(frame, status: "not a pixel buffer"); return }
        let fmt = CVPixelBufferGetPixelFormatType(pb)
        guard fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange || fmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else {
            passThrough(frame, status: "off for this format (10-bit)"); return
        }

        // A repeat of the last game frame is dropped while the real frame is still held back: the held frame
        // takes its slot. Otherwise (a still scene, a menu, a low frame rate) it is passed on, so the renderer
        // keeps receiving frames and its freeze detector doesn't mistake a still picture for a frozen stream.
        let sig = Self.signature(pb)
        if let last = lastSignature, Self.same(last, sig) {
            if held == nil { downstream.renderFrame(frame) }
            return
        }
        lastSignature = sig

        let rtp = UInt32(bitPattern: frame.timeStamp)
        let now = CACurrentMediaTime()
        countRates(now)

        guard let prev = previous else {
            previous = (frame, rtp, sig)
            flushHeld()
            downstream.renderFrame(frame)
            return
        }
        let dt = Double(rtp &- prev.rtp) / 90_000
        previous = (frame, rtp, sig)
        // A stall, a scene that stood still, or timestamps going backwards: show it, nothing to blend.
        guard dt > 0.004, dt < 0.1 else { flushHeld(); downstream.renderFrame(frame); return }
        intervalEMA = intervalEMA.map { $0 * 0.9 + dt * 0.1 } ?? dt
        let interval = intervalEMA!

        // The model can't keep up with a game this fast (its time plus the wait would exceed the gap).
        if let p = processEMA, p > interval * 0.8 {
            flushHeld()
            downstream.renderFrame(frame)
            setStatus(String(format: "paused: %.0f ms per frame is too slow for %.0f fps", p * 1000, 1 / interval))
            processEMA = p * 0.98   // try again now and then
            return
        }

        // The previous game frame still waiting means this one came early: show it now, then carry on.
        flushHeld()

        guard let mid = interpolate(prev.frame, frame, prevRTP: prev.rtp, rtp: rtp) else {
            downstream.renderFrame(frame)
            return
        }
        let took = CACurrentMediaTime() - now
        processEMA = processEMA.map { $0 * 0.9 + took * 0.1 } ?? took
        generatedCount += 1
        downstream.renderFrame(mid)

        // The real frame half a game interval after the generated one.
        held = frame
        holdGeneration += 1
        let gen = holdGeneration
        queue.asyncAfter(deadline: .now() + interval / 2) { [weak self] in
            guard let self, self.holdGeneration == gen, let h = self.held else { return }
            self.held = nil
            self.downstream.renderFrame(h)
        }
        setStatus(String(format: "on: game %@ → shown ×2 · %.1f ms · +%.0f ms delay", rateText, (processEMA ?? 0) * 1000, (interval / 2 + (processEMA ?? 0)) * 1000))
    }

    private func countRates(_ now: CFTimeInterval) {
        uniqueCount += 1
        if now - windowStart >= 1 {
            rateText = String(format: "%.0f fps", Double(uniqueCount) / (now - windowStart))
            uniqueCount = 0; generatedCount = 0; windowStart = now
        }
    }

    private func interpolate(_ a: RTCVideoFrame, _ b: RTCVideoFrame, prevRTP: UInt32, rtp: UInt32) -> RTCVideoFrame? {
        #if !targetEnvironment(simulator)
        if #available(macOS 26.0, iOS 26.0, *) {
            guard let pa = (a.buffer as? RTCCVPixelBuffer)?.pixelBuffer, let pb = (b.buffer as? RTCCVPixelBuffer)?.pixelBuffer else { return nil }
            let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
            var eng = engine as? VTInterpolationEngine
            if eng == nil || eng!.width != w || eng!.height != h {
                eng = VTInterpolationEngine(width: w, height: h)
                engine = eng
            }
            guard let eng else { return nil }
            switch eng.state {
            case .loading: setStatus("loading model for \(w)x\(h)…"); return nil
            case .failed(let why): setStatus("unavailable: \(why)"); return nil
            case .ready: break
            }
            let midRTP = prevRTP &+ (rtp &- prevRTP) / 2
            guard let out = eng.interpolate(pa, pb, prevPTS: Int64(prevRTP), pts: Int64(prevRTP) + Int64(rtp &- prevRTP)) else { return nil }
            let ns = a.timeStampNs + (b.timeStampNs - a.timeStampNs) / 2
            let f = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: out), rotation: b.rotation, timeStampNs: ns)
            f.timeStamp = Int32(bitPattern: midRTP)
            return f
        }
        #endif
        return nil
    }

    // MARK: Repeat detection
    private static let gridW = 160, gridH = 90

    /// Luma at a 160x90 grid, each a 2x2 average. Dense enough that a small object moving doesn't slip between
    /// samples and get its frame mistaken for a repeat.
    static func signature(_ pb: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return [] }
        let p = base.assumingMemoryBound(to: UInt8.self)
        let w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0), bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        var out = [UInt8](repeating: 0, count: gridW * gridH)
        for gy in 0..<gridH {
            let y = min(h - 2, (gy * 2 + 1) * h / (gridH * 2))
            for gx in 0..<gridW {
                let x = min(w - 2, (gx * 2 + 1) * w / (gridW * 2))
                let o = y * bpr + x
                out[gy * gridW + gx] = UInt8((Int(p[o]) + Int(p[o + 1]) + Int(p[o + bpr]) + Int(p[o + bpr + 1])) / 4)
            }
        }
        return out
    }

    static func same(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count, !a.isEmpty else { return false }
        var sum = 0, mx = 0
        for i in 0..<a.count {
            let d = abs(Int(a[i]) - Int(b[i]))
            sum += d; if d > mx { mx = d }
        }
        return Double(sum) / Double(a.count) < 0.6 && mx < 6
    }
}

#if !targetEnvironment(simulator)
/// One VideoToolbox low-latency frame-interpolation session for a frame size. The model loads off the caller's
/// thread; `state` says when it's usable.
@available(macOS 26.0, iOS 26.0, *)
final class VTInterpolationEngine: @unchecked Sendable {
    enum State { case loading, ready, failed(String) }
    let width: Int, height: Int
    private let lock = NSLock()
    private var _state: State = .loading
    var state: State { lock.lock(); defer { lock.unlock() }; return _state }

    private let processor = VTFrameProcessor()
    private var srcPool: CVPixelBufferPool?
    private var dstPool: CVPixelBufferPool?
    private var transfer: VTPixelTransferSession?
    private var lastConverted: (pts: Int64, buffer: CVPixelBuffer)?

    init(width: Int, height: Int) {
        self.width = width; self.height = height
        DispatchQueue.global(qos: .userInitiated).async { [self] in start() }
    }

    deinit { processor.endSession() }

    private func start() {
        let t0 = Date()
        guard let cfg = VTLowLatencyFrameInterpolationConfiguration(frameWidth: width, frameHeight: height, numberOfInterpolatedFrames: 1) else {
            set(.failed("\(width)x\(height) not supported")); return
        }
        do {
            try processor.startSession(configuration: cfg)
            srcPool = Self.pool(cfg.sourcePixelBufferAttributes)
            dstPool = Self.pool(cfg.destinationPixelBufferAttributes)
            VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer)
            guard srcPool != nil, dstPool != nil, transfer != nil else { set(.failed("buffer setup")); return }
            log("Render", "VT frame interpolation ready for \(width)x\(height) in \(String(format: "%.0f", Date().timeIntervalSince(t0) * 1000)) ms")
            set(.ready)
        } catch {
            log("Render", "VT frame interpolation failed for \(width)x\(height): \(error)")
            set(.failed("\(error.localizedDescription)"))
        }
    }

    private func set(_ s: State) { lock.lock(); _state = s; lock.unlock() }

    private static func pool(_ attrs: [String: Any]) -> CVPixelBufferPool? {
        var attrs = attrs
        attrs[kCVPixelBufferMetalCompatibilityKey as String] = true
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 6] as CFDictionary, attrs as CFDictionary, &pool)
        return pool
    }

    private func make(_ pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        guard let pool else { return nil }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        return pb
    }

    /// The decoder's full-range NV12 into the model's own format and buffers; the newer frame is kept so it
    /// isn't converted again as the next pair's older one.
    private func converted(_ source: CVPixelBuffer, pts: Int64) -> CVPixelBuffer? {
        if let c = lastConverted, c.pts == pts { return c.buffer }
        guard let out = make(srcPool), let transfer, VTPixelTransferSessionTransferImage(transfer, from: source, to: out) == noErr else { return nil }
        return out
    }

    /// Synchronous; called on the interpolator's queue.
    func interpolate(_ a: CVPixelBuffer, _ b: CVPixelBuffer, prevPTS: Int64, pts: Int64) -> CVPixelBuffer? {
        guard case .ready = state, let ca = converted(a, pts: prevPTS), let cb = converted(b, pts: pts), let dst = make(dstPool) else { return nil }
        lastConverted = (pts, cb)
        let t = { (v: Int64) in CMTime(value: v, timescale: 90_000) }
        guard let src = VTFrameProcessorFrame(buffer: cb, presentationTimeStamp: t(pts)),
              let prev = VTFrameProcessorFrame(buffer: ca, presentationTimeStamp: t(prevPTS)),
              let out = VTFrameProcessorFrame(buffer: dst, presentationTimeStamp: t(prevPTS + (pts - prevPTS) / 2)),
              let params = VTLowLatencyFrameInterpolationParameters(sourceFrame: src, previousFrame: prev, interpolationPhase: [0.5], destinationFrames: [out])
        else { return nil }
        do {
            try processor.process(parameters: params)
        } catch {
            log("Render", "VT frame interpolation: \(error)")
            return nil
        }
        return dst
    }
}
#endif
