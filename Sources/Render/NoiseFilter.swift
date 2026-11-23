import Foundation
import VideoToolbox
import CoreVideo
import CoreMedia
import QuartzCore
import WebRTC

enum NoiseReduction: String, CaseIterable, Identifiable, Codable {
    case off, light, medium, strong
    var id: String { rawValue }
    var label: String {
        switch self { case .off: "Off"; case .light: "Light"; case .medium: "Medium"; case .strong: "Strong" }
    }
    var strength: Float {
        switch self { case .off: 0; case .light: 0.3; case .medium: 0.6; case .strong: 0.9 }
    }
}

/// Compression-noise reduction with VideoToolbox's ML temporal noise filter (macOS/iOS 26). Sits in front of the
/// frame interpolator. Each game frame is filtered with the previous ones as reference and no future ones, so it
/// adds no frame of latency, only the model's time.
///
/// Repeats of a game frame (a 30 fps game in a 60 fps stream) get the last filtered picture again, unchanged, so the
/// interpolator still recognises them. With `compare` on, the left half of every filtered frame is the original,
/// for judging the effect side by side.
///
/// Off, until the model is loaded, and for formats the model doesn't take (10-bit), frames pass straight through.
final class NoiseFilter: NSObject, RTCVideoRenderer, @unchecked Sendable {
    private let downstream: RTCVideoRenderer
    private let queue = DispatchQueue(label: "app.igreenlight.denoise", qos: .userInteractive)
    private let lock = NSLock()
    private var level: NoiseReduction = .off
    private var compareOn = false
    private var statusText = "off"

    // Queue state.
    private var engine: AnyObject?
    private var lastSignature: [UInt8]?
    private var lastOutput: CVPixelBuffer?
    private var lastRTP: UInt32?
    private var processEMA: Double?

    init(downstream: RTCVideoRenderer) { self.downstream = downstream }

    static var isSupported: Bool {
        #if !targetEnvironment(simulator)
        if #available(macOS 26.0, iOS 26.0, *) { return VTTemporalNoiseFilterConfiguration.isSupported }
        #endif
        return false
    }

    var reduction: NoiseReduction {
        get { lock.lock(); defer { lock.unlock() }; return level }
        set {
            lock.lock(); let changed = newValue != level; level = newValue; lock.unlock()
            if changed { queue.async { [weak self] in self?.reset() } }
        }
    }

    var compare: Bool {
        get { lock.lock(); defer { lock.unlock() }; return compareOn }
        set { lock.lock(); compareOn = newValue; lock.unlock() }
    }

    var status: String { lock.lock(); defer { lock.unlock() }; return statusText }

    // MARK: RTCVideoRenderer (decoder thread)
    func setSize(_ size: CGSize) { downstream.setSize(size) }

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        guard reduction != .off else { downstream.renderFrame(frame); return }
        queue.async { [weak self] in self?.ingest(frame) }
    }

    // MARK: Queue
    private func setStatus(_ s: String) { lock.lock(); statusText = s; lock.unlock() }

    private func reset() {
        lastSignature = nil
        lastOutput = nil
        lastRTP = nil
        #if !targetEnvironment(simulator)
        if #available(macOS 26.0, iOS 26.0, *) { (engine as? VTNoiseEngine)?.discontinuity() }
        #endif
        setStatus(reduction == .off ? "off" : "waiting for frames")
    }

    private func ingest(_ frame: RTCVideoFrame) {
        let level = reduction
        guard level != .off else { downstream.renderFrame(frame); return }
        guard Self.isSupported else { setStatus("needs macOS 26 on Apple silicon"); downstream.renderFrame(frame); return }
        guard let pb = (frame.buffer as? RTCCVPixelBuffer)?.pixelBuffer else { downstream.renderFrame(frame); return }
        let fmt = CVPixelBufferGetPixelFormatType(pb)
        guard fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange || fmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else {
            setStatus("off for this format (10-bit)"); downstream.renderFrame(frame); return
        }

        // A repeat gets the last filtered picture again.
        let sig = FrameInterpolator.signature(pb)
        if let last = lastSignature, FrameInterpolator.same(last, sig), let out = lastOutput {
            downstream.renderFrame(Self.wrap(out, like: frame))
            return
        }
        lastSignature = sig

        let rtp = UInt32(bitPattern: frame.timeStamp)
        let gap = lastRTP.map { Double(rtp &- $0) / 90_000 } ?? 1
        lastRTP = rtp

        #if !targetEnvironment(simulator)
        if #available(macOS 26.0, iOS 26.0, *) {
            let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
            var eng = engine as? VTNoiseEngine
            if eng == nil || eng!.width != w || eng!.height != h {
                eng = VTNoiseEngine(width: w, height: h)
                engine = eng
            }
            if let eng {
                switch eng.state {
                case .loading: setStatus("loading model for \(w)x\(h)…")
                case .failed(let why): setStatus("unavailable: \(why)")
                case .ready:
                    // A stall or a jump back in time: start the reference frames over.
                    if gap <= 0 || gap > 0.2 { eng.discontinuity() }
                    let t0 = CACurrentMediaTime()
                    if let out = eng.filter(pb, pts: Int64(rtp), strength: level.strength, compare: compare) {
                        let took = CACurrentMediaTime() - t0
                        processEMA = processEMA.map { $0 * 0.9 + took * 0.1 } ?? took
                        lastOutput = out
                        setStatus(String(format: "%@ · %.1f ms", level.label.lowercased(), (processEMA ?? 0) * 1000))
                        downstream.renderFrame(Self.wrap(out, like: frame))
                        return
                    }
                }
            }
        }
        #endif
        lastOutput = nil
        lastSignature = nil
        downstream.renderFrame(frame)
    }

    private static func wrap(_ pb: CVPixelBuffer, like frame: RTCVideoFrame) -> RTCVideoFrame {
        let f = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: pb), rotation: frame.rotation, timeStampNs: frame.timeStampNs)
        f.timeStamp = frame.timeStamp
        return f
    }
}

#if !targetEnvironment(simulator)
/// One VideoToolbox temporal noise filter session for a frame size, with the previous source frames it uses as
/// reference. The model loads off the caller's thread.
@available(macOS 26.0, iOS 26.0, *)
final class VTNoiseEngine: @unchecked Sendable {
    enum State { case loading, ready, failed(String) }
    let width: Int, height: Int
    private let lock = NSLock()
    private var _state: State = .loading
    var state: State { lock.lock(); defer { lock.unlock() }; return _state }

    private let processor = VTFrameProcessor()
    private var srcPool: CVPixelBufferPool?
    private var dstPool: CVPixelBufferPool?
    /// Plain (uncompressed, CPU-readable) video-range NV12: the filter works in Apple's lossless-compressed
    /// formats, which the frame interpolator's repeat check and the comparison copy can't read.
    private var plainPool: CVPixelBufferPool?
    private var transfer: VTPixelTransferSession?
    private var previousCount = 0
    /// Converted source frames, newest last.
    private var history: [(pts: Int64, buffer: CVPixelBuffer)] = []
    private var restart = true

    init(width: Int, height: Int) {
        self.width = width; self.height = height
        DispatchQueue.global(qos: .userInitiated).async { [self] in start() }
    }

    deinit { processor.endSession() }

    private func start() {
        let t0 = Date()
        let supported = VTTemporalNoiseFilterConfiguration.supportedSourcePixelFormats
        let format = supported.contains(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange : (supported.first ?? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        guard let cfg = VTTemporalNoiseFilterConfiguration(frameWidth: width, frameHeight: height, sourcePixelFormat: format) else {
            set(.failed("\(width)x\(height) not supported")); return
        }
        do {
            try processor.startSession(configuration: cfg)
            previousCount = max(1, cfg.previousFrameCount ?? 1)
            srcPool = Self.pool(cfg.sourcePixelBufferAttributes, count: previousCount + 4)
            dstPool = Self.pool(cfg.destinationPixelBufferAttributes, count: 4)
            plainPool = Self.pool([kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                   kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
                                   kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()], count: 8)
            VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer)
            guard srcPool != nil, dstPool != nil, plainPool != nil, transfer != nil else { set(.failed("buffer setup")); return }
            log("Render", "VT temporal noise filter ready for \(width)x\(height) (\(previousCount) previous frames, format \(format)) in \(String(format: "%.0f", Date().timeIntervalSince(t0) * 1000)) ms")
            set(.ready)
        } catch {
            log("Render", "VT temporal noise filter failed for \(width)x\(height): \(error)")
            set(.failed(error.localizedDescription))
        }
    }

    private func set(_ s: State) { lock.lock(); _state = s; lock.unlock() }

    private static func pool(_ attrs: [String: Any], count: Int) -> CVPixelBufferPool? {
        var attrs = attrs
        attrs[kCVPixelBufferMetalCompatibilityKey as String] = true
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: count] as CFDictionary, attrs as CFDictionary, &pool)
        return pool
    }

    private func make(_ pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        guard let pool else { return nil }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        return pb
    }

    func discontinuity() { restart = true; history.removeAll() }

    /// Synchronous; called on the filter's queue.
    func filter(_ source: CVPixelBuffer, pts: Int64, strength: Float, compare: Bool) -> CVPixelBuffer? {
        guard case .ready = state, let transfer, let src = make(srcPool), let dst = make(dstPool),
              VTPixelTransferSessionTransferImage(transfer, from: source, to: src) == noErr else { return nil }
        let t = { (v: Int64) in CMTime(value: v, timescale: 90_000) }
        // It needs at least one reference frame: the first after a (re)start is only kept as one.
        if history.isEmpty {
            history.append((pts, src))
            return nil
        }
        // Reference frames in presentation order, oldest first.
        let previous = history.compactMap { VTFrameProcessorFrame(buffer: $0.buffer, presentationTimeStamp: t($0.pts)) }
        guard let srcFrame = VTFrameProcessorFrame(buffer: src, presentationTimeStamp: t(pts)),
              let dstFrame = VTFrameProcessorFrame(buffer: dst, presentationTimeStamp: t(pts)),
              let params = VTTemporalNoiseFilterParameters(sourceFrame: srcFrame, nextFrames: [], previousFrames: previous,
                                                           destinationFrame: dstFrame, filterStrength: strength, hasDiscontinuity: restart)
        else { return nil }
        do {
            try processor.process(parameters: params)
        } catch {
            log("Render", "VT temporal noise filter: \(error)")
            discontinuity()
            return nil
        }
        restart = false
        history.append((pts, src))
        if history.count > previousCount { history.removeFirst(history.count - previousCount) }
        guard let out = make(plainPool), VTPixelTransferSessionTransferImage(transfer, from: dst, to: out) == noErr else { return nil }
        if compare, let original = make(plainPool), VTPixelTransferSessionTransferImage(transfer, from: source, to: original) == noErr {
            Self.copyLeftHalf(from: original, to: out)
        }
        return out
    }

    /// Left half of both planes from the unfiltered frame, for the side-by-side comparison.
    private static func copyLeftHalf(from a: CVPixelBuffer, to b: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(a, .readOnly); CVPixelBufferLockBaseAddress(b, [])
        defer { CVPixelBufferUnlockBaseAddress(a, .readOnly); CVPixelBufferUnlockBaseAddress(b, []) }
        guard CVPixelBufferGetPlaneCount(a) == 2, CVPixelBufferGetPlaneCount(b) == 2 else { return }
        for plane in 0..<2 {
            guard let pa = CVPixelBufferGetBaseAddressOfPlane(a, plane), let pb = CVPixelBufferGetBaseAddressOfPlane(b, plane) else { continue }
            let rows = min(CVPixelBufferGetHeightOfPlane(a, plane), CVPixelBufferGetHeightOfPlane(b, plane))
            // Y: one byte a pixel; CbCr: two bytes for every two pixels. Either way half the width in bytes, kept even.
            let bytes = (CVPixelBufferGetWidth(a) / 2) & ~1
            let ra = CVPixelBufferGetBytesPerRowOfPlane(a, plane), rb = CVPixelBufferGetBytesPerRowOfPlane(b, plane)
            for r in 0..<rows { memcpy(pb + r * rb, pa + r * ra, bytes) }
        }
    }
}
#endif
