import Foundation
import Metal
import MetalKit
// The iOS Simulator SDK has no MetalFX; there the renderer falls back to bilinear.
#if canImport(MetalFX)
import MetalFX
#endif
import CoreVideo
import WebRTC
import simd
import CoreMedia
import QuartzCore
#if os(iOS)
import UIKit
#endif

/// Receives decoded frames from libwebrtc, converts YUV→RGB on the GPU and upscales with MetalFX Spatial.
///
/// Pipeline: CVPixelBuffer (NV12 from VideoToolbox) → CVMetalTexture planes → RGB texture at
/// source size → MTLFXSpatialScaler to the on-screen content size → present pass (fit/zoom/stretch).
///
/// Who draws. Unpaced with `drawOnArrival` (the default), a frame is drawn the moment the decoder hands it
/// over: `renderFrame` wakes a render queue of its own, which takes a drawable straight from the view's
/// `CAMetalLayer`. The MTKView's display tick (main thread) then only does what needs the main thread
/// (the EDR switch, the display's headroom), notices layout and settings changes, and counts for the pacing
/// numbers. With `drawOnArrival` off, or with frame pacing on, the tick draws, as it always did.
/// A render queue rather than drawing on the decoder thread, because `nextDrawable()` can block until the
/// display gives a drawable back and that must not hold up the decoder; rather than the main thread, because
/// the hop there waits behind whatever the UI is doing; and rather than `CAMetalDisplayLink`, which is one
/// more tick to wait for: the wait this path exists to remove.
///
/// Two locks: `lock` guards what the threads hand each other (the waiting frame, the pacer, the settings,
/// the status strings); `renderLock` is held for one whole pass by whichever thread draws and guards the
/// textures, the scaler and the rest of the GPU state.
final class MetalVideoRenderer: NSObject, RTCVideoRenderer, MTKViewDelegate {
    /// Format of the RGB picture between the passes (source-size RGB and the MetalFX output). Ten bits: the
    /// 219 levels of limited-range 8-bit video, expanded to full range, don't land on 8-bit codes, and
    /// rounding them there (and once more after upscaling) is what bands; a 10-bit stream needs its 876.
    /// Same memory and bandwidth as BGRA8, unlike a float format, which matters on an iPhone. Only the SDR
    /// drawable is 8-bit, written once, by the present pass.
    static let intermediateFormat: MTLPixelFormat = .rgb10a2Unorm

    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var textureCache: CVMetalTextureCache?
    private var nv12Pipeline: MTLRenderPipelineState!
    private var i420Pipeline: MTLRenderPipelineState!
    private var presentPipeline: MTLRenderPipelineState!
    private var presentPipelineEDR: MTLRenderPipelineState!
    private var downsamplePipeline: MTLRenderPipelineState!
    private var ambientPipeline: MTLRenderPipelineState!

    /// A decoded frame with what is known about it when it arrives.
    private struct Arrived {
        let frame: RTCVideoFrame
        let rtp: UInt32
        let at: CFTimeInterval
    }

    /// Everything that can be set from outside, read as one snapshot per pass.
    private struct Config: Equatable {
        var scaling: ScalingMode = .fit
        var upscaler: Upscaler = .metalFX
        var maxUpscaler: Upscaler = .videoToolbox
        var deband = true
        var debandBoost: Float = 1
        var sharpness = 3
        var sharpenScale: Float = 1
        var edr: EDRExpansion = .off
        var ambient = true
        var pictureAnchorY = 0.5
        var chromaUpsampling = true
        var drawOnArrival = true
        var compare = false
        var effectiveUpscaler: Upscaler { upscaler.capped(by: maxUpscaler) }
    }

    /// What decides how the last frame is laid out on the drawable: a change means it has to be drawn again.
    private struct LayoutKey: Equatable {
        var config: Config
        var width: Int, height: Int
        var edrDrawable: Bool
    }

    // MARK: Shared between threads (guarded by `lock`)
    private let lock = NSLock()
    private var config = Config()
    /// The newest frame nobody has drawn yet (unpaced).
    private var pending: Arrived?
    private var paced = false
    private var pacer = FramePacer<Arrived>()
    private var pacerDroppedSeen = 0
    private var lastArrival: CFTimeInterval?
    /// The layer the render queue draws to; refreshed by every display tick.
    private weak var layer: CAMetalLayer?
    /// Headroom the display can show right now, as the main thread last saw it.
    private var headroom: Float = 1
    /// The render queue has a pass scheduled or running, so there is no need to wake it again.
    private var renderScheduled = false
    /// The last frame has to be drawn again (layout or settings changed).
    private var redrawRequested = false
    /// A new frame was drawn on arrival since the last display tick.
    private var drawnSinceTick = false
    /// A drawable presented from the render queue that the display hasn't shown yet, and when it was handed
    /// over. While one waits nothing more is presented: a second one would be shown a refresh later, and on
    /// a display no faster than the stream that queue never drains, so every later frame would be a refresh
    /// or two late. The waiting frame stays in `pending`, where a newer one replaces it.
    private var presentInFlight = false
    private var presentInFlightSince: CFTimeInterval = 0
    /// A drawable the display never reports (the window is covered) must not hold the next one back for ever.
    private static let presentTimeout: CFTimeInterval = 0.05
    /// Layout the display tick last saw while drawing on arrival.
    private var tickKey: LayoutKey?
    /// No drawing off the main thread while the app is in the background (iOS doesn't allow GPU work there).
    private var suspended = false
    private var status = "-"
    private var rendered = 0
    private var presentedCallback: ((UInt32, CFTimeInterval, CFTimeInterval) -> Void)?

    private func read<T>(_ key: KeyPath<Config, T>) -> T { lock.lock(); defer { lock.unlock() }; return config[keyPath: key] }
    private func write<T>(_ key: WritableKeyPath<Config, T>, _ value: T) { lock.lock(); config[keyPath: key] = value; lock.unlock() }

    // MARK: Settings (any thread; a change redraws the last frame at the next display tick)
    var scaling: ScalingMode { get { read(\.scaling) } set { write(\.scaling, newValue) } }
    var upscaler: Upscaler { get { read(\.upscaler) } set { write(\.upscaler, newValue) } }
    /// A ceiling on the upscaler (off < metalFX < videoToolbox): what runs is the lower of `upscaler` and this.
    var maxUpscaler: Upscaler { get { read(\.maxUpscaler) } set { write(\.maxUpscaler, newValue) } }
    /// Smooth 8-bit banding in flat gradients (present pass).
    var deband: Bool { get { read(\.deband) } set { write(\.deband, newValue) } }
    /// Multiplier (1…2) on the deband threshold, for a stream so starved of bits that its steps are coarser.
    var debandBoost: Float { get { read(\.debandBoost) } set { write(\.debandBoost, newValue) } }
    /// Contrast-adaptive sharpening of the picture in the present pass: 0 off … 10 strongest.
    var sharpness: Int { get { read(\.sharpness) } set { write(\.sharpness, newValue) } }
    /// Multiplier (0…1) on `sharpness`, to back the sharpening off without touching the setting.
    var sharpenScale: Float { get { read(\.sharpenScale) } set { write(\.sharpenScale, newValue) } }
    /// SDR→EDR highlight expansion. `.off` keeps the 8-bit SDR drawable.
    var edr: EDRExpansion { get { read(\.edr) } set { write(\.edr, newValue) } }
    /// Fill the letterbox bars (Fit mode) with a glow in the colours of the picture's edge instead of black.
    var ambient: Bool { get { read(\.ambient) } set { write(\.ambient, newValue) } }
    /// Where a picture shorter than the view sits vertically: 0.5 centred, 0 at the top (a tall window with the
    /// on-screen gamepad below the picture).
    var pictureAnchorY: Double { get { read(\.pictureAnchorY) } set { write(\.pictureAnchorY, newValue) } }
    /// Luma-guided chroma upsampling in the YUV→RGB pass (see `nv12_fragment`). Off: one bilinear tap.
    var chromaUpsampling: Bool { get { read(\.chromaUpsampling) } set { write(\.chromaUpsampling, newValue) } }
    /// Unpaced only: draw each frame as soon as the decoder delivers it instead of at the next display tick.
    /// Off is the old polling path, kept selectable so the two can be compared on the same stream.
    var drawOnArrival: Bool { get { read(\.drawOnArrival) } set { write(\.drawOnArrival, newValue) } }
    /// Side by side: the left half of the picture without upscaling, sharpening or debanding, the right half as set.
    var compare: Bool { get { read(\.compare) } set { write(\.compare, newValue) } }
    /// Release frames on an even cadence from a short queue instead of showing each at the first tick after it
    /// arrives (`FramePacer`; adds about half a stream frame of latency). Off: exactly the unpaced path.
    var framePacing: Bool {
        get { lock.lock(); defer { lock.unlock() }; return paced }
        set {
            lock.lock(); defer { lock.unlock() }
            guard newValue != paced else { return }
            paced = newValue
            // Whatever waited in the other path is at most a frame or two old; the next one is 16 ms away.
            pacer.reset(); pacerDroppedSeen = 0
            pending = nil
        }
    }
    /// Called (on any thread) once per new frame that reached the screen: its 90 kHz RTP timestamp, when it
    /// arrived from the decoder and when the display showed it (the time it was drawn when the system reports
    /// none), both on the `CACurrentMediaTime()` clock.
    var onFramePresented: ((_ rtpTimestamp: UInt32, _ arrivedAt: CFTimeInterval, _ presentedAt: CFTimeInterval) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return presentedCallback }
        set { lock.lock(); presentedCallback = newValue; lock.unlock() }
    }

    // MARK: Read-outs (any thread)
    /// Human-readable description of the upscaling chain that ran for the last frame (for the stats overlay).
    var upscaleStatus: String { lock.lock(); defer { lock.unlock() }; return status }
    var timingSummary: String { timing.current }
    /// Average GPU time per frame (ms) over the last reporting window of `FrameTiming`; nil until one has closed.
    var recentGPUMs: Double? { timing.recentGPU }
    /// Average time from the start of a frame's pass until the GPU was done with it (ms), same window. Unlike
    /// the GPU time this includes the VideoToolbox ML scaler, which works outside the command buffer's own clock.
    var recentRenderMs: Double? { timing.recentTotal }
    /// Frame pacing of the last few seconds: arrival jitter, intervals on screen, drops and repeats.
    var pacingSummary: String { pacing.current }
    /// Seconds since the decoder last delivered a frame; nil before the first.
    var secondsSinceLastFrame: Double? {
        lock.lock(); defer { lock.unlock() }
        return lastArrival.map { CACurrentMediaTime() - $0 }
    }
    var framesRendered: Int { lock.lock(); defer { lock.unlock() }; return rendered }
    /// Reported on the main queue when the decoded frame size changes.
    var onFrameSize: ((_ width: Int, _ height: Int) -> Void)?

    // MARK: GPU state (guarded by `renderLock`)
    private let renderLock = NSLock()
    private let renderQueue = DispatchQueue(label: "app.igreenlight.render", qos: .userInteractive)
    private var rgbTexture: MTLTexture?
    private var upscaledTexture: MTLTexture?
    #if canImport(MetalFX)
    private var scaler: MTLFXSpatialScaler?
    #endif
    private var scalerKey: (Int, Int, Int, Int) = (0, 0, 0, 0)
    private var i420Textures: [MTLTexture] = []
    /// Quarter-size copy of the frame with a full mip chain; source for `ambientTexture`.
    private var ambientMips: MTLTexture?
    /// 32 px wide, temporally smoothed copy of the frame that the bars are drawn from, with mips for the
    /// wider blur further from the picture. Float so the running average converges instead of sticking a
    /// few 8-bit steps short.
    private var ambientTexture: MTLTexture?
    private var ambientPrimed = false
    private var ambientUpdatedAt: CFTimeInterval = 0
    private var frameSeed: Float = 0
    private var frameCount = 0
    private var metalFXActive = false
    private var lastUpscaler: Upscaler = .off
    private var lastSize = (0, 0)
    private var lastLayoutKey: LayoutKey?
    private var loggedFormat = false
    private var loggedSiting: String? = "?"
    /// `VTSuperResolution` on macOS 26+, nil otherwise (stored untyped because of availability).
    private let vtsrBox: AnyObject? = {
        if #available(macOS 26.0, iOS 26.0, *) { return VTSuperResolution() }
        return nil
    }()
    @available(macOS 26.0, iOS 26.0, *)
    private var vtsr: VTSuperResolution? { vtsrBox as? VTSuperResolution }
    private var vtStatus: String {
        if #available(macOS 26.0, iOS 26.0, *) { return vtsr?.lastStatus ?? "-" }
        #if os(macOS)
        return "needs macOS 26"
        #else
        return "needs iOS 26"
        #endif
    }

    /// Which colour space the layer was last tagged for (nil: not yet, so the first draw sets it). Main thread.
    private var colorTaggedEDR: Bool?
    private var loggedFirstFrame = false
    private var loggedFirstDraw = false
    private let pacing = PacingMeter()
    private let timing = FrameTiming()

    struct SetupError: LocalizedError {
        let errorDescription: String?
    }

    /// Throws when Metal or the app's shaders can't be set up, so the stream can say so instead of crashing.
    init(_: Void = ()) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw SetupError(errorDescription: "Metal isn't available on this device, so the stream can't be drawn.")
        }
        self.device = device
        commandQueue = queue
        super.init()
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
        let lib = try device.makeDefaultLibrary(bundle: .main)
        func pipeline(_ frag: String, _ fmt: MTLPixelFormat, blend: Bool = false) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: "fullscreen_vertex")
            d.fragmentFunction = lib.makeFunction(name: frag)
            d.colorAttachments[0].pixelFormat = fmt
            if blend {
                d.colorAttachments[0].isBlendingEnabled = true
                d.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
                d.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            }
            return try device.makeRenderPipelineState(descriptor: d)
        }
        nv12Pipeline = try pipeline("nv12_fragment", Self.intermediateFormat)
        i420Pipeline = try pipeline("i420_fragment", Self.intermediateFormat)
        presentPipeline = try pipeline("present_fragment", .bgra8Unorm)
        presentPipelineEDR = try pipeline("present_fragment", .rgba16Float)
        // The quarter-size source of the bars stays 8-bit: it is only ever read through two blurs.
        downsamplePipeline = try pipeline("downsample_fragment", .bgra8Unorm)
        ambientPipeline = try pipeline("ambient_fragment", .rgba16Float, blend: true)
        #if os(iOS)
        NotificationCenter.default.addObserver(self, selector: #selector(appDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appWillEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
        #endif
    }

    #if os(iOS)
    @objc private func appDidEnterBackground() { lock.lock(); suspended = true; lock.unlock() }
    // The picture on screen may be gone after a spell in the background: have the next tick draw it again.
    @objc private func appWillEnterForeground() { lock.lock(); suspended = false; tickKey = nil; lock.unlock() }
    #endif

    func configure(_ view: MTKView) {
        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        colorTaggedEDR = nil   // a new view's layer is untagged
        view.framebufferOnly = true
        // Also when frames are drawn on arrival: the tick is then the main thread's share of the work.
        view.preferredFramesPerSecond = 120
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.delegate = self
        view.autoResizeDrawable = true
        // A new view has nothing on it yet: the first tick asks for the last frame.
        lock.lock(); tickKey = nil; lock.unlock()
    }

    // MARK: RTCVideoRenderer (called on the decoder thread)
    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        if !loggedFirstFrame { loggedFirstFrame = true; log("Render", "first frame from WebRTC: \(frame.width)x\(frame.height) \(type(of: frame.buffer))") }
        DiagnosticsRecorder.current?.recordFrame(frame)
        let now = CACurrentMediaTime(), rtp = UInt32(bitPattern: frame.timeStamp)
        let item = Arrived(frame: frame, rtp: rtp, at: now)
        lock.lock()
        lastArrival = now
        var overwritten = 0, wake = false
        if paced {
            pacer.enqueue(item, rtp: rtp, at: now)
        } else {
            if pending != nil { overwritten = 1 }
            pending = item
            wake = scheduleRenderLocked()
        }
        lock.unlock()
        pacing.arrived(at: now, rtp: rtp, dropped: overwritten)
        if wake { renderQueue.async { [weak self] in self?.drawArrivals() } }
    }

    // MARK: Drawing on arrival (render queue)
    private var drawsOnArrivalLocked: Bool { config.drawOnArrival && !paced && !suspended && layer != nil }

    /// With `lock` held: true when the caller has to put `drawArrivals` on the render queue.
    private func scheduleRenderLocked() -> Bool {
        guard drawsOnArrivalLocked, !renderScheduled else { return false }
        renderScheduled = true
        return true
    }

    /// Draws what is waiting, and again for as long as something new turned up meanwhile.
    private func drawArrivals() {
        // The pool: a drawable left in one that drains whenever the queue feels like it is a drawable the
        // layer can't hand out again, and it only has three.
        while autoreleasepool(invoking: drawArrival) {}
    }

    /// One pass on the render queue. False when there is nothing (more) to do.
    private func drawArrival() -> Bool {
        lock.lock()
        guard drawsOnArrivalLocked, let layer, pending != nil || redrawRequested else {
            renderScheduled = false
            lock.unlock()
            return false
        }
        // The last drawable is still on its way to the screen: `presentDone` (or the next tick, once the
        // timeout has passed) comes back for what is waiting.
        if presentInFlight, CACurrentMediaTime() - presentInFlightSince < Self.presentTimeout {
            renderScheduled = false
            lock.unlock()
            return false
        }
        lock.unlock()
        // The drawable first, the frame second: when the display has none free this waits, and what is then
        // drawn is the newest frame there is by the time one comes back, not the one that started the wait.
        // Nil when the layer has no size yet or the wait timed out: the frame stays where it is and the next
        // arrival, or the next tick, tries again.
        guard let drawable = layer.nextDrawable() else {
            lock.lock(); renderScheduled = false; lock.unlock()
            return false
        }
        lock.lock()
        guard drawsOnArrivalLocked else {   // switched to the tick meanwhile: the frame is the tick's to draw
            renderScheduled = false
            lock.unlock()
            return false
        }
        let item = pending
        pending = nil
        redrawRequested = false
        let config = self.config, headroom = self.headroom
        presentInFlight = true
        presentInFlightSince = CACurrentMediaTime()
        lock.unlock()

        renderLock.lock()
        // What the present pass writes follows the drawable it got, not the setting: the main thread switches
        // the layer's format a tick after the setting changes.
        let shown = render(item, width: drawable.texture.width, height: drawable.texture.height, edrDrawable: drawable.texture.pixelFormat == .rgba16Float,
                           config: config, headroom: headroom, at: CACurrentMediaTime(), force: true,
                           presentedHook: { [weak self] in self?.presentDone() }) { drawable }
        renderLock.unlock()
        lock.lock()
        if !shown { presentInFlight = false }   // nothing was presented, so nothing will report back
        if item != nil, shown { drawnSinceTick = true }
        lock.unlock()
        return true
    }

    /// The display showed the drawable the render queue presented: whatever arrived meanwhile can go now.
    private func presentDone() {
        lock.lock()
        presentInFlight = false
        let wake = (pending != nil || redrawRequested) && scheduleRenderLocked()
        lock.unlock()
        if wake { renderQueue.async { [weak self] in self?.drawArrivals() } }
    }

    // MARK: MTKViewDelegate
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    /// The display tick, on the main thread. Draws in the polled and the paced mode; when frames are drawn on
    /// arrival it only keeps the layer's format, the headroom and the pacing numbers up to date and asks for
    /// the last frame again when the layout changed.
    func draw(in view: MTKView) {
        if !loggedFirstDraw { loggedFirstDraw = true; log("Render", "first draw, drawable \(view.drawableSize)") }
        let tickTime = CACurrentMediaTime()
        lock.lock()
        let config = self.config
        lock.unlock()

        // Switch the drawable between 8-bit SDR and float extended-linear sRGB when the EDR setting changes.
        let wantEDR = config.edr != .off
        // The SDR drawable is tagged sRGB: an untagged (nil) layer is not colour-matched, so a P3 display would
        // show the BT.709 picture in its own wider gamut, oversaturated. `colorTaggedEDR` starts nil so the tag
        // is also set on the first draw with EDR off, when the pixel format never changes. The layer is set
        // directly: MTKView's own `colorspace` (macOS only) is just an alias of the layer's.
        let metalLayer = view.layer as? CAMetalLayer
        if wantEDR != (view.colorPixelFormat == .rgba16Float) { view.colorPixelFormat = wantEDR ? .rgba16Float : .bgra8Unorm }
        if colorTaggedEDR != wantEDR, let metalLayer {
            colorTaggedEDR = wantEDR
            metalLayer.wantsExtendedDynamicRangeContent = wantEDR
            metalLayer.colorspace = CGColorSpace(name: wantEDR ? CGColorSpace.extendedLinearSRGB : CGColorSpace.sRGB)
            log("Render", "drawable \(wantEDR ? "rgba16Float, extended linear sRGB (EDR)" : "bgra8Unorm, sRGB (SDR, colour-matched)")")
        }
        // Headroom the display can show right now (1 = none; it moves with brightness and ambient light).
        #if os(macOS)
        let headroom = Float(view.window?.screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1)
        #else
        let headroom = Float(view.window?.windowScene?.screen.currentEDRHeadroom ?? 1)
        #endif
        let width = Int(view.drawableSize.width), height = Int(view.drawableSize.height)
        let key = LayoutKey(config: config, width: width, height: height, edrDrawable: wantEDR)

        lock.lock()
        layer = metalLayer
        self.headroom = headroom
        let isPaced = paced, onArrival = drawsOnArrivalLocked
        var item: Arrived?, newFrame = false, wake = false
        if onArrival {
            newFrame = drawnSinceTick
            drawnSinceTick = false
            // Redraw the last frame on resize / mode change too, so letterboxing stays correct.
            if key != tickKey { tickKey = key; redrawRequested = true }
            // A frame can also be waiting here: one that arrived before there was a layer or a free drawable.
            wake = (pending != nil || redrawRequested) && scheduleRenderLocked()
        } else {
            item = isPaced ? pacer.dequeue(at: tickTime) : pending
            pending = nil
            newFrame = item != nil
            tickKey = nil
        }
        let pacerDropped = pacer.dropped - pacerDroppedSeen
        pacerDroppedSeen = pacer.dropped
        lock.unlock()
        // The same count in every mode, so they can be compared: display ticks, and those since the last of
        // which no new frame was drawn.
        if let w = pacing.tick(at: tickTime, newFrame: newFrame, dropped: pacerDropped, paced: isPaced) {
            log("Pacing", "\(w.summary); stream step \(String(format: "%.2f ±%.2f ms", w.stream.mean, w.stream.sd))"
                + (w.shownFromDrawTime > 0 ? "; \(w.shownFromDrawTime) intervals from draw times" : "")
                + (onArrival ? "; drawn on arrival" : ""))
            DiagnosticsRecorder.current?.recordPacing(w)
        }
        if onArrival {
            if wake { renderQueue.async { [weak self] in self?.drawArrivals() } }
            return
        }
        renderLock.lock()
        render(item, width: width, height: height, edrDrawable: wantEDR, config: config, headroom: headroom, at: tickTime, force: false) { view.currentDrawable }
        renderLock.unlock()
    }

    static func sharpenLobe(sharpness: Int, scale: Float) -> Float {
        // 10 = a negative lobe of 0.2 per neighbour, the most the filter takes before it rings; linear below.
        0.02 * Float(min(max(sharpness, 0), 10)) * min(max(scale, 0), 1)
    }

    static func debandThreshold(boost: Float) -> Float {
        // ≈ 1.5 steps of 8-bit: above one step of limited-range video (255/219 of a full-range step), below two.
        1.5 / 255 * min(max(boost, 1), 2)
    }

    /// One pass, with `renderLock` held: converts `item` (nil: the last frame again) and draws the picture
    /// into the drawable that `nextDrawable` gives, `width` × `height` pixels. Without a new frame it only
    /// draws when the layout changed, or always with `force`. True when a drawable was presented.
    @discardableResult
    private func render(_ item: Arrived?, width: Int, height: Int, edrDrawable: Bool, config: Config, headroom: Float,
                        at tickTime: CFTimeInterval, force: Bool, presentedHook: (() -> Void)? = nil,
                        nextDrawable: () -> CAMetalDrawable?) -> Bool {
        let frame = item?.frame
        let layoutKey = LayoutKey(config: config, width: width, height: height, edrDrawable: edrDrawable)
        if frame == nil && (rgbTexture == nil || (!force && layoutKey == lastLayoutKey)) { return false }
        lastLayoutKey = layoutKey
        guard width > 0, height > 0, let cmd = commandQueue.makeCommandBuffer() else { return false }
        let upscaler = config.effectiveUpscaler
        // The ML scaler's session holds a model: let go of it when it is no longer the one in use.
        if upscaler != lastUpscaler {
            if lastUpscaler == .videoToolbox, #available(macOS 26.0, iOS 26.0, *) { vtsr?.reset() }
            lastUpscaler = upscaler
        }
        let peak = edrDrawable && config.edr != .off ? max(1, min(config.edr.peak, headroom)) : 1

        // Content rect in drawable pixels (aspect from the decoded frame).
        let dw = Double(width), dh = Double(height)
        let sw = Double(frame.map { Int($0.width) } ?? rgbTexture?.width ?? 1)
        let sh = Double(frame.map { Int($0.height) } ?? rgbTexture?.height ?? 1)
        var cw = dw, ch = dh
        switch config.scaling {
        case .stretch: break
        case .fit: let s = min(dw / sw, dh / sh); cw = sw * s; ch = sh * s
        case .zoom: let s = max(dw / sw, dh / sh); cw = sw * s; ch = sh * s
        }
        let outW = Int(cw.rounded()), outH = Int(ch.rounded())

        let encodeStart = CACurrentMediaTime()
        var vtActive = false
        if let f = frame {
            vtActive = convert(f, cmd, targetWidth: outW, targetHeight: outH, upscaler: upscaler, chromaUpsampling: config.chromaUpsampling)
        }
        guard let rgb = rgbTexture, let drawable = nextDrawable() else {
            // No drawable to show it on, but the picture is converted: keep it, a redraw may want it.
            if frame != nil { cmd.commit() }
            return false
        }

        // Ambient bars: only when Fit leaves at least a pixel of bar. Updated per decoded frame (and once when just enabled).
        let wantAmbient = config.ambient && config.scaling == .fit && (dw - cw >= 1 || dh - ch >= 1)
        if !wantAmbient { ambientPrimed = false }
        else if frame != nil || !ambientPrimed { updateAmbient(from: rgb, cmd, at: tickTime) }
        let ambientSource = wantAmbient && ambientPrimed ? ambientTexture : nil

        var source: MTLTexture = rgb
        if upscaler != .off, outW >= rgb.width, outH >= rgb.height, outW * outH > rgb.width * rgb.height, outW <= 16384, outH <= 16384 {
            if let up = upscale(rgb, to: outW, outH, cmd) { source = up; metalFXActive = true } else { metalFXActive = false }
        } else { metalFXActive = false }
        let lobe = Self.sharpenLobe(sharpness: config.sharpness, scale: config.sharpenScale)
        let threshold = config.deband ? Self.debandThreshold(boost: config.debandBoost) : 0
        var label = ""
        if frame != nil {
            // What ran for this frame, not what was asked for: the ceiling and the fallbacks are already in.
            var parts: [String] = []
            if upscaler == .videoToolbox { parts.append(vtActive ? "VT ML \(vtStatus)" : "VT ML: \(vtStatus)") }
            parts.append(metalFXActive ? "MetalFX \(rgb.width)x\(rgb.height)→\(outW)x\(outH)" : "bilinear \(rgb.width)x\(rgb.height)→\(outW)x\(outH)")
            if upscaler != config.upscaler { parts.append("capped at \(upscaler.rawValue)") }
            if lobe > 0 { parts.append("sharpen \(config.sharpness)" + (config.sharpenScale < 1 ? String(format: " ×%.2f", max(config.sharpenScale, 0)) : "")) }
            if config.deband { parts.append("deband" + (config.debandBoost > 1 ? String(format: " ×%.2f", min(config.debandBoost, 2)) : "")) }
            if wantAmbient { parts.append("ambient bars") }
            if edrDrawable && config.edr != .off { parts.append(String(format: "EDR ×%.1f (headroom %.1f)", peak, headroom)) }
            if config.compare { parts.append("compare: left original") }
            label = parts.joined(separator: ", ")
            frameSeed = Float((frameCount &* 37) % 1024)
        }

        // Map drawable uv -> content uv.
        // Deband radius is 16 pixels of the decoded frame, whatever the upscale; grain is ±0.5 of an 8-bit step,
        // enough to dither the smoothed gradient (and the 10-bit picture under it) back into the 8-bit drawable.
        var params = PresentParams(
            uv: SIMD4(Float(dw / cw), Float(dh / ch), Float(-(dw - cw) / 2 / cw), Float(-(dh - ch) * (ch < dh ? config.pictureAnchorY : 0.5) / ch)),
            deband: SIMD4(16 / Float(rgb.width), 16 / Float(rgb.height), threshold, 1.0 / 255),
            edr: SIMD4(peak, 0.5, frameSeed, edrDrawable ? 1 : 0),
            // 75 % of the picture's brightness at its edge, down to 1/e of that 0.3 picture heights away.
            ambient: SIMD4(ambientSource != nil ? 1 : 0, 0.75, 0.3, 1.15),
            sharpen: SIMD4(lobe, 0, 0, 0))
        // The same pass MTKView would describe: the drawable, cleared to black.
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = drawable.texture
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        rpd.colorAttachments[0].storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return false }
        enc.setRenderPipelineState(edrDrawable ? presentPipelineEDR : presentPipeline)
        enc.setFragmentTexture(source, index: 0)
        enc.setFragmentTexture(ambientSource ?? source, index: 1)
        enc.setFragmentBytes(&params, length: MemoryLayout<PresentParams>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        if config.compare {
            // Left of the picture's middle: the converted frame drawn plainly (bilinear, no sharpening or
            // debanding), then a 2 px black divider.
            let mid = Int(((dw - cw) / 2 + cw / 2).rounded())
            if mid > 2 && mid < width - 2 {
                var plain = params
                plain.sharpen.x = 0
                plain.deband.z = 0
                enc.setScissorRect(MTLScissorRect(x: 0, y: 0, width: mid - 1, height: height))
                enc.setFragmentTexture(rgb, index: 0)
                enc.setFragmentBytes(&plain, length: MemoryLayout<PresentParams>.stride, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                var divider = params
                divider.uv = SIMD4(0, 0, -10, -10)
                divider.ambient.x = 0
                enc.setScissorRect(MTLScissorRect(x: mid - 1, y: 0, width: 2, height: height))
                enc.setFragmentBytes(&divider, length: MemoryLayout<PresentParams>.stride, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
        }
        enc.endEncoding()
        if let item {
            // When this frame really reaches the glass, for the pacing numbers and whoever else wants to know.
            let presented = onFramePresented, rtp = item.rtp, arrivedAt = item.at
            Self.whenPresented(drawable, cmd) { [pacing] time in
                pacing.presented(at: time, drawn: tickTime)
                presented?(rtp, arrivedAt, time > 0 ? time : tickTime)
            }
        }
        if let presentedHook { Self.whenPresented(drawable, cmd) { _ in presentedHook() } }
        cmd.present(drawable)
        if frame != nil {
            cmd.addCompletedHandler { [timing] cb in
                timing.add(gpu: (cb.gpuEndTime - cb.gpuStartTime) * 1000, total: (CACurrentMediaTime() - encodeStart) * 1000, label: label)
            }
        }
        cmd.commit()
        if frame != nil {
            frameCount += 1
            lock.lock(); status = label; rendered = frameCount; lock.unlock()
        }
        return true
    }

    /// Calls `body` when the display has shown the drawable, with the time it did (0 when the system gives none).
    private static func whenPresented(_ drawable: CAMetalDrawable, _ cmd: MTLCommandBuffer, _ body: @escaping (CFTimeInterval) -> Void) {
        #if targetEnvironment(simulator)
        // The Simulator's drawables don't report being shown: the end of the GPU work stands in, without a time.
        cmd.addCompletedHandler { _ in body(0) }
        #else
        drawable.addPresentedHandler { body($0.presentedTime) }
        #endif
    }

    /// Mirrors `PresentParams` in Shaders.metal.
    private struct PresentParams {
        var uv: SIMD4<Float>
        var deband: SIMD4<Float>
        var edr: SIMD4<Float>
        var ambient: SIMD4<Float>
        var sharpen: SIMD4<Float>
    }

    // MARK: Ambient bars
    /// rgb → quarter size (box) → mip chain → 32 px texture, blended over the previous result with a 60 ms
    /// time constant (by the clock, so 30 and 60 fps streams settle equally fast), then its own mips.
    private func updateAmbient(from rgb: MTLTexture, _ cmd: MTLCommandBuffer, at now: CFTimeInterval) {
        let mw = max(1, rgb.width / 4), mh = max(1, rgb.height / 4)
        if ambientMips?.width != mw || ambientMips?.height != mh || ambientTexture == nil {
            let md = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: mw, height: mh, mipmapped: true)
            md.usage = [.renderTarget, .shaderRead]
            md.storageMode = .private
            ambientMips = device.makeTexture(descriptor: md)
            let aw = min(32, mw), ah = max(1, Int((Double(aw) * Double(mh) / Double(mw)).rounded()))
            let ad = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: aw, height: ah, mipmapped: true)
            ad.usage = [.renderTarget, .shaderRead]
            ad.storageMode = .private
            ambientTexture = device.makeTexture(descriptor: ad)
            ambientPrimed = false
        }
        guard let mips = ambientMips, let target = ambientTexture else { return }

        let down = MTLRenderPassDescriptor()
        down.colorAttachments[0].texture = mips
        down.colorAttachments[0].loadAction = .dontCare
        down.colorAttachments[0].storeAction = .store
        guard let e1 = cmd.makeRenderCommandEncoder(descriptor: down) else { return }
        e1.setRenderPipelineState(downsamplePipeline)
        e1.setFragmentTexture(rgb, index: 0)
        e1.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        e1.endEncoding()
        if mips.mipmapLevelCount > 1, let blit = cmd.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: mips)
            blit.endEncoding()
        }

        let acc = MTLRenderPassDescriptor()
        acc.colorAttachments[0].texture = target
        // Clear, not dontCare: the blend multiplies the old contents by 0 on the first frame, and stale
        // float memory can hold NaN (NaN × 0 = NaN), which would stay in the running average for good.
        acc.colorAttachments[0].loadAction = ambientPrimed ? .load : .clear
        acc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        acc.colorAttachments[0].storeAction = .store
        guard let e2 = cmd.makeRenderCommandEncoder(descriptor: acc) else { return }
        var p = SIMD4<Float>(ambientPrimed ? Float(1 - exp(-max(0, now - ambientUpdatedAt) / 0.06)) : 1, 0, 0, 0)
        ambientUpdatedAt = now
        e2.setRenderPipelineState(ambientPipeline)
        e2.setFragmentTexture(mips, index: 0)
        e2.setFragmentBytes(&p, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        e2.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        e2.endEncoding()
        if target.mipmapLevelCount > 1, let blit = cmd.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: target)
            blit.endEncoding()
        }
        ambientPrimed = true
    }

    // MARK: YUV -> RGB
    /// Mirrors `YUVParams` in Shaders.metal.
    struct YUVParams {
        var matrix: simd_float3x3
        var offset: SIMD3<Float>
        var scale: SIMD3<Float>
        /// xy: uv offset of the chroma sample (siting correction, NV12 path); z: 1 = luma-guided upsampling;
        /// w: 1 / the luma difference at which a neighbour stops counting. SIMD4 so the layout matches Metal's float4.
        var chroma: SIMD4<Float> = .zero
    }

    /// A chroma neighbour whose luma is this far (of the full code range) from the pixel's own counts for 1/e:
    /// several times the noise of a flat area, a fraction of the step at the edge of a letter.
    static let chromaLumaSigma: Float = 0.05

    /// Offset and scale that take what the sampler returns for a plane to Y′ in 0…1 and Cb/Cr in ±0.5, with the
    /// YCbCr→RGB matrix. All in code values: black, the chroma midpoint and the spans are 16, 128, 219 and 224
    /// of 255 for 8 bits, and 64, 512, 876 and 896 of 1023 for 10. The sampler returns code / 255 for an 8-bit
    /// plane; a 10-bit plane is 16 bits with the value in the top ten, so it returns code · 64 / 65535, which
    /// is not code / 1023 (it is 0.09 % more).
    static func yuvParams(fullRange: Bool, matrix709: Bool, tenBit: Bool = false) -> YUVParams {
        // BT.709 or BT.601 YCbCr→RGB.
        let m: simd_float3x3 = matrix709
            ? simd_float3x3(columns: (SIMD3(1, 1, 1), SIMD3(0, -0.1873, 1.8556), SIMD3(1.5748, -0.4681, 0)))
            : simd_float3x3(columns: (SIMD3(1, 1, 1), SIMD3(0, -0.3441, 1.772), SIMD3(1.402, -0.7141, 0)))
        // Codes per 1.0 of the sampled value, and the code values of the format.
        let unit: Double = tenBit ? 65535.0 / 64 : 255
        let peak: Double = tenBit ? 1023 : 255, black: Double = tenBit ? 64 : 16, mid: Double = tenBit ? 512 : 128
        let ySpan: Double = tenBit ? 876 : 219, cSpan: Double = tenBit ? 896 : 224
        if fullRange {
            return YUVParams(matrix: m, offset: SIMD3(0, Float(mid / unit), Float(mid / unit)), scale: SIMD3(repeating: Float(unit / peak)))
        }
        return YUVParams(matrix: m, offset: SIMD3(Float(black / unit), Float(mid / unit), Float(mid / unit)),
                         scale: SIMD3(Float(unit / ySpan), Float(unit / cSpan), Float(unit / cSpan)))
    }

    private func ensureRGB(_ w: Int, _ h: Int) -> MTLTexture {
        if let t = rgbTexture, t.width == w, t.height == h { return t }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.intermediateFormat, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        let t = device.makeTexture(descriptor: d)!
        rgbTexture = t
        return t
    }

    /// Converts the frame to RGB in `rgbTexture`. Returns true when VideoToolbox ML upscaling was applied.
    private func convert(_ frame: RTCVideoFrame, _ cmd: MTLCommandBuffer, targetWidth: Int, targetHeight: Int,
                         upscaler: Upscaler, chromaUpsampling: Bool) -> Bool {
        var vtApplied = false
        let w = Int(frame.width), h = Int(frame.height)
        if (w, h) != lastSize {
            lastSize = (w, h)
            log("Render", "decoded frame size \(w)x\(h) (buffer \(type(of: frame.buffer)))")
            let cb = onFrameSize
            DispatchQueue.main.async { cb?(w, h) }
        }
        if let base = (frame.buffer as? RTCCVPixelBuffer)?.pixelBuffer {
            var pb = base
            if !loggedFormat {
                loggedFormat = true
                log("Render", "decoder pixel format \(fourCC(CVPixelBufferGetPixelFormatType(pb)))")
            }
            let srcFmt = CVPixelBufferGetPixelFormatType(pb)
            let eightBit = srcFmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || srcFmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            if eightBit, upscaler == .videoToolbox, #available(macOS 26.0, iOS 26.0, *), VTSuperResolution.isSupported,
               // The RTP timestamp, not the render time: libwebrtc reports that as 0 for every frame when the
               // playout delay is forced to zero, and the scaler is owed a time that moves.
               let up = vtsr?.process(pb, pts: CMTime(value: Int64(UInt32(bitPattern: frame.timeStamp)), timescale: 90_000),
                                      targetWidth: targetWidth, targetHeight: targetHeight, cmd: cmd) {
                pb = up
                vtApplied = true
            }
            let target = ensureRGB(CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb))
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = target
            rpd.colorAttachments[0].loadAction = .dontCare
            rpd.colorAttachments[0].storeAction = .store
            let fmt = CVPixelBufferGetPixelFormatType(pb)
            let full = fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange || fmt == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
            // 10-bit biplanar (x420/xf20, from HEVC Main 10) samples as 16-bit planes with the value in the top
            // ten bits; `yuvParams` has the constants for that.
            let tenBit = fmt == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange || fmt == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
            var is709 = true
            if let m = CVBufferCopyAttachment(pb, kCVImageBufferYCbCrMatrixKey, nil) as? String {
                is709 = m != (kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String)
            }
            guard let y = cvTexture(pb, plane: 0, tenBit ? .r16Unorm : .r8Unorm), let uv = cvTexture(pb, plane: 1, tenBit ? .rg16Unorm : .rg8Unorm),
                  let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return vtApplied }
            var p = Self.yuvParams(fullRange: full, matrix709: is709, tenBit: tenBit)
            // Left-sited chroma (H.264's default, also assumed when the buffer says nothing) is sampled a quarter
            // of a chroma texel to the right; see nv12_fragment. Centre needs nothing, and other sitings are left
            // uncorrected rather than guessed at. The VT upscaler's output is asked first, then the decoded buffer.
            let siting = (CVBufferCopyAttachment(pb, kCVImageBufferChromaLocationTopFieldKey, nil)
                ?? CVBufferCopyAttachment(base, kCVImageBufferChromaLocationTopFieldKey, nil)) as? String
            if siting == nil || siting == (kCVImageBufferChromaLocation_Left as String) {
                p.chroma.x = 0.25 / Float(max(1, CVPixelBufferGetWidthOfPlane(pb, 1)))
            }
            if chromaUpsampling { p.chroma.z = 1; p.chroma.w = 1 / Self.chromaLumaSigma }
            if siting != loggedSiting { loggedSiting = siting; log("Render", "chroma siting \(siting ?? "not tagged (assuming Left)")") }
            enc.setRenderPipelineState(nv12Pipeline)
            enc.setFragmentTexture(CVMetalTextureGetTexture(y), index: 0)
            enc.setFragmentTexture(CVMetalTextureGetTexture(uv), index: 1)
            enc.setFragmentBytes(&p, length: MemoryLayout<YUVParams>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
            // Keep the CVMetalTextures alive until the GPU is done.
            let keep = pb
            cmd.addCompletedHandler { _ in _ = y; _ = uv; _ = keep }
        } else {
            let target = ensureRGB(w, h)
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = target
            rpd.colorAttachments[0].loadAction = .dontCare
            rpd.colorAttachments[0].storeAction = .store
            let i420 = frame.buffer.toI420()
            let cw = Int(i420.chromaWidth), ch = Int(i420.chromaHeight)
            if i420Textures.count != 3 || i420Textures[0].width != w || i420Textures[0].height != h {
                i420Textures = [(w, h), (cw, ch), (cw, ch)].map { size in
                    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: size.0, height: size.1, mipmapped: false)
                    d.usage = .shaderRead
                    return device.makeTexture(descriptor: d)!
                }
            }
            i420Textures[0].replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: i420.dataY, bytesPerRow: Int(i420.strideY))
            i420Textures[1].replace(region: MTLRegionMake2D(0, 0, cw, ch), mipmapLevel: 0, withBytes: i420.dataU, bytesPerRow: Int(i420.strideU))
            i420Textures[2].replace(region: MTLRegionMake2D(0, 0, cw, ch), mipmapLevel: 0, withBytes: i420.dataV, bytesPerRow: Int(i420.strideV))
            guard let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return false }
            var p = Self.yuvParams(fullRange: false, matrix709: true)
            enc.setRenderPipelineState(i420Pipeline)
            for (i, t) in i420Textures.enumerated() { enc.setFragmentTexture(t, index: i) }
            enc.setFragmentBytes(&p, length: MemoryLayout<YUVParams>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }
        return vtApplied
    }

    private func fourCC(_ t: OSType) -> String {
        String(bytes: [UInt8(t >> 24 & 0xff), UInt8(t >> 16 & 0xff), UInt8(t >> 8 & 0xff), UInt8(t & 0xff)], encoding: .ascii) ?? "\(t)"
    }

    private func cvTexture(_ pb: CVPixelBuffer, plane: Int, _ fmt: MTLPixelFormat) -> CVMetalTexture? {
        guard let cache = textureCache else { return nil }
        var tex: CVMetalTexture?
        let w = CVPixelBufferGetWidthOfPlane(pb, plane), h = CVPixelBufferGetHeightOfPlane(pb, plane)
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, fmt, w, h, plane, &tex)
        return tex
    }

    // MARK: MetalFX
    private func upscale(_ input: MTLTexture, to w: Int, _ h: Int, _ cmd: MTLCommandBuffer) -> MTLTexture? {
        #if canImport(MetalFX)
        let key = (input.width, input.height, w, h)
        if scaler == nil || scalerKey != key {
            let d = MTLFXSpatialScalerDescriptor()
            d.inputWidth = input.width; d.inputHeight = input.height
            d.outputWidth = w; d.outputHeight = h
            d.colorTextureFormat = input.pixelFormat
            d.outputTextureFormat = Self.intermediateFormat
            d.colorProcessingMode = .perceptual
            guard MTLFXSpatialScalerDescriptor.supportsDevice(device), let s = d.makeSpatialScaler(device: device) else {
                log("Render", "MetalFX spatial scaler unavailable for \(input.width)x\(input.height) \(input.pixelFormat.rawValue)")
                return nil
            }
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.intermediateFormat, width: w, height: h, mipmapped: false)
            td.usage = s.outputTextureUsage.union(.shaderRead)
            td.storageMode = .private
            upscaledTexture = device.makeTexture(descriptor: td)
            scaler = s
            scalerKey = key
            log("Render", "MetalFX spatial \(input.width)x\(input.height) -> \(w)x\(h)")
        }
        guard let s = scaler, let out = upscaledTexture else { return nil }
        s.colorTexture = input
        s.outputTexture = out
        s.encode(commandBuffer: cmd)
        return out
        #else
        return nil
        #endif
    }
}

/// Rolling per-frame render cost: GPU time of the command buffer, and wall time from the start of
/// encoding (incl. the CPU-side 420f→420v transfer for VT) until the GPU finished.
final class FrameTiming: @unchecked Sendable {
    private let lock = NSLock()
    private var gpu: [Double] = [], total: [Double] = []
    private(set) var summary = "-"
    private var windowGPU: Double?, windowTotal: Double?

    func add(gpu g: Double, total t: Double, label: String) {
        lock.lock(); defer { lock.unlock() }
        gpu.append(g); total.append(t)
        guard gpu.count >= 120 else { return }
        func avg(_ a: [Double]) -> Double { a.reduce(0, +) / Double(a.count) }
        let sorted = total.sorted()
        windowGPU = avg(gpu); windowTotal = avg(total)
        summary = String(format: "gpu %.2f ms (max %.2f), encode→done %.2f ms (p95 %.2f)",
                         avg(gpu), gpu.max() ?? 0, avg(total), sorted[Int(Double(sorted.count) * 0.95)])
        log("Timing", "\(label): \(summary)")
        gpu.removeAll(); total.removeAll()
    }

    var current: String { lock.lock(); defer { lock.unlock() }; return summary }
    /// Average GPU ms per frame of the last full window; nil until the first one closes.
    var recentGPU: Double? { lock.lock(); defer { lock.unlock() }; return windowGPU }
    var recentTotal: Double? { lock.lock(); defer { lock.unlock() }; return windowTotal }
}

extension Upscaler {
    /// How much each one does: off < MetalFX < VideoToolbox ML (which runs MetalFX after it).
    private var rank: Int { switch self { case .off: 0; case .metalFX: 1; case .videoToolbox: 2 } }
    /// The lower of this and `ceiling`.
    func capped(by ceiling: Upscaler) -> Upscaler { rank <= ceiling.rank ? self : ceiling }
}

// MARK: - Frame pacing

/// Mean, spread and tail of a set of intervals (ms): the numbers the pacing lines report.
struct IntervalStats: Equatable {
    var count = 0
    var mean = 0.0, sd = 0.0, p95 = 0.0, max = 0.0

    init() {}
    init(_ values: [Double]) {
        guard !values.isEmpty else { return }
        count = values.count
        mean = values.reduce(0, +) / Double(count)
        sd = (values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(count)).squareRoot()
        let sorted = values.sorted()
        // Nearest rank: the smallest value with at least 95 % of the samples at or below it.
        p95 = sorted[Swift.max(0, Int((Double(count) * 0.95).rounded(.up)) - 1)]
        max = sorted[count - 1]
    }

    /// Several windows as one: mean, sd and max are exact; p95 is the worst window's, which is the most that
    /// can be said without the samples.
    static func pooled(_ parts: [IntervalStats]) -> IntervalStats {
        var r = IntervalStats()
        r.count = parts.reduce(0) { $0 + $1.count }
        guard r.count > 0 else { return r }
        let n = Double(r.count)
        r.mean = parts.reduce(0) { $0 + $1.mean * Double($1.count) } / n
        let squares = parts.reduce(0) { $0 + ($1.sd * $1.sd + $1.mean * $1.mean) * Double($1.count) } / n
        r.sd = Swift.max(0, squares - r.mean * r.mean).squareRoot()
        r.p95 = parts.map(\.p95).max() ?? 0
        r.max = parts.map(\.max).max() ?? 0
        return r
    }

    var json: [String: Any] {
        func r(_ v: Double) -> Double { (v * 100).rounded() / 100 }
        return ["count": count, "meanMs": r(mean), "sdMs": r(sd), "p95Ms": r(p95), "maxMs": r(max)]
    }
}

/// What happened to the frames of one reporting window, between the decoder and the screen.
struct PacingWindow {
    var seconds = 0.0
    /// Frames from the decoder, and those replaced before a display tick took them (or dropped by the pacer).
    var received = 0, dropped = 0
    /// Display ticks, and those with no new frame to show.
    var ticks = 0, repeats = 0
    /// Intervals between decoded frames arriving, between their RTP timestamps (the server's cadence) and
    /// between new frames reaching the screen.
    var arrival = IntervalStats(), stream = IntervalStats(), shown = IntervalStats()
    /// How many of `shown` come from draw times because the drawable reported no presentation time.
    var shownFromDrawTime = 0
    var paced = false

    var summary: String {
        guard received > 0 || ticks > 0 else { return "-" }
        return String(format: "%.1f fps in (arrival ±%.1f ms), on screen every %.1f ±%.1f ms (p95 %.1f, max %.1f), %d dropped, %d of %d ticks repeat",
                      seconds > 0 ? Double(received) / seconds : 0, arrival.sd, shown.mean, shown.sd, shown.p95, shown.max, dropped, repeats, ticks)
            + (paced ? ", paced" : "")
    }

    var json: [String: Any] {
        ["seconds": (seconds * 100).rounded() / 100, "received": received, "dropped": dropped, "ticks": ticks, "repeats": repeats,
         "arrival": arrival.json, "stream": stream.json, "shown": shown.json, "shownFromDrawTime": shownFromDrawTime, "paced": paced]
    }
}

/// Counts and times frames on their way to the screen. `arrived` is called on the decoder thread, `tick` on
/// the display thread and `presented` wherever Metal calls back, hence the lock.
final class PacingMeter: @unchecked Sendable {
    static let windowSeconds = 5.0
    private let lock = NSLock()
    private var window = PacingWindow()
    private var windowStart: Double?
    private var arrivals: [Double] = [], streamSteps: [Double] = [], shown: [Double] = []
    private var lastArrival: Double?, lastRTP: UInt32?
    private var lastShown: (time: Double, presented: Bool)?
    private var lastReceived = 0
    private var summary = "-"

    var current: String { lock.lock(); defer { lock.unlock() }; return summary }

    /// A decoded frame arrived; `dropped` frames were given up to make room for it.
    func arrived(at now: Double, rtp: UInt32, dropped: Int) {
        lock.lock(); defer { lock.unlock() }
        if windowStart == nil { windowStart = now }
        window.received += 1
        window.dropped += dropped
        if let last = lastArrival { arrivals.append((now - last) * 1000) }
        if let last = lastRTP { streamSteps.append(Double(Int32(truncatingIfNeeded: rtp &- last)) / 90) }
        lastArrival = now; lastRTP = rtp
    }

    /// A display tick. Closes the window when it is due and returns it.
    @discardableResult
    func tick(at now: Double, newFrame: Bool, dropped: Int, paced: Bool) -> PacingWindow? {
        lock.lock(); defer { lock.unlock() }
        // Before the first frame there is no stream to repeat.
        guard let start = windowStart else { return nil }
        window.ticks += 1
        window.dropped += dropped
        if !newFrame { window.repeats += 1 }
        guard now - start >= Self.windowSeconds else { return nil }
        var w = window
        w.seconds = now - start
        w.arrival = IntervalStats(arrivals); w.stream = IntervalStats(streamSteps); w.shown = IntervalStats(shown)
        w.paced = paced
        window = PacingWindow(); windowStart = now
        arrivals.removeAll(keepingCapacity: true); streamSteps.removeAll(keepingCapacity: true); shown.removeAll(keepingCapacity: true)
        // A view left up after the stream ended keeps ticking: one empty window is news, the rest are not.
        defer { lastReceived = w.received }
        guard w.received > 0 || lastReceived > 0 else { return nil }
        summary = w.summary
        return w
    }

    /// A new frame reached the screen. `presented` is the drawable's presentation time, 0 when the system
    /// didn't report one (not shown, or not supported); then the time it was drawn stands in. The two clocks
    /// differ by the wait for the display, so an interval is only taken between two times of the same kind.
    func presented(at presented: Double, drawn: Double) {
        lock.lock(); defer { lock.unlock() }
        let now = (time: presented > 0 ? presented : drawn, presented: presented > 0)
        if let last = lastShown, last.presented == now.presented, now.time > last.time {
            shown.append((now.time - last.time) * 1000)
            if !now.presented { window.shownFromDrawTime += 1 }
        }
        lastShown = now
    }
}

/// Smooth frame pacing: decides on which display tick each decoded frame is shown.
///
/// Frames arrive from the decoder with several ms of jitter, so "show the newest at every tick" puts them on
/// uneven ticks, or two in one tick and none in the next. Here each frame gets a due time on a steady clock:
/// its RTP timestamp (the server's own cadence) plus the smoothed difference between arrival and RTP time,
/// plus half a stream frame of margin so that a frame arriving a little late still makes its tick.
///
/// Added latency: that margin, half a stream frame (8 ms at 60 fps) on average. Where the stream's cadence
/// falls between display ticks moves it a few ms either way (simulated with 7 ms of arrival jitter: 8 to 11 ms
/// over unpaced on a 120 Hz display, 5 to 15 ms on 60 Hz). A frame is never held behind one that is due
/// (`dequeue` skips ahead), and the queue holds 3, so a burst can't add more than that.
struct FramePacer<Frame> {
    static var capacity: Int { 3 }
    /// Share of each frame's arrival error that moves the clock: about 20 frames to follow a change, and what
    /// is left of the arrival jitter is a sixth of it.
    static var gain: Double { 0.05 }
    /// No frame for this long is a stall (or the start): the clock starts again from the next frame.
    static var stall: Double { 0.25 }

    private var queue: [(frame: Frame, due: Double)] = []
    private var lastRTP: UInt32?
    private var lastArrival = -Double.infinity
    /// Stream time in seconds: RTP timestamps unwrapped from their 32 bits.
    private var media = 0.0
    /// Smoothed arrival time − stream time; nil until a frame sets it.
    private var offset: Double?
    private var synced = 0
    private var mediaSteps: [Double] = []
    private var lastTick: Double?
    private var tickSteps: [Double] = []
    private var lastRelease = -Double.infinity
    /// Stream frame interval (median RTP step) and display tick interval (median tick step), in seconds;
    /// 0 until known.
    private(set) var interval = 0.0
    private(set) var refresh = 0.0
    /// Frames dropped to keep latency down, and times the clock started again.
    private(set) var dropped = 0
    private(set) var resyncs = 0
    var count: Int { queue.count }

    /// A decoded frame arrived. `rtp` is its 90 kHz RTP timestamp.
    mutating func enqueue(_ frame: Frame, rtp: UInt32, at now: Double) {
        let step = lastRTP.map { Double(Int32(truncatingIfNeeded: rtp &- $0)) / 90_000 }
        let stalled = now - lastArrival > Self.stall
        lastRTP = rtp; lastArrival = now
        if let step, step > 0, step < Self.stall {
            media += step
            mediaSteps.append(step)
            if mediaSteps.count > 15 { mediaSteps.removeFirst() }
            interval = mediaSteps.sorted()[mediaSteps.count / 2]
        } else {
            // The first frame, or timestamps that stand still or jump: no cadence to follow. Such frames are
            // due at once, which makes a stream without usable timestamps behave exactly as unpaced.
            offset = nil
            if step != nil { mediaSteps.removeAll(); interval = 0 }
        }
        let raw = now - media
        // A frame two intervals off the clock is not jitter: the delay itself changed.
        if !stalled, let o = offset, abs(raw - o) <= 2 * interval {
            synced += 1
            // A plain average over the first frames, so that one late frame doesn't set the clock.
            offset = o + (raw - o) * max(Self.gain, 1 / Double(synced))
        } else {
            offset = raw; synced = 1; resyncs += 1
        }
        queue.append((frame, media + (offset ?? raw) + interval / 2))
        if queue.count > Self.capacity { queue.removeFirst(); dropped += 1 }
    }

    /// A display tick: the frame to show now, or nil to keep the one on screen.
    mutating func dequeue(at now: Double) -> Frame? {
        if let last = lastTick, now > last {
            tickSteps.append(now - last)
            if tickSteps.count > 9 { tickSteps.removeFirst() }
            refresh = tickSteps.sorted()[tickSteps.count / 2]
        }
        lastTick = now
        guard let head = queue.first else { return nil }
        // Hysteresis in favour of an even cadence on screen: on the tick one stream frame after the last
        // release a frame may go a little early. Without it a due time that falls near a tick boundary flips
        // between the two ticks. (With a display no faster than the stream every tick is that tick.)
        let onCadence = now - lastRelease >= interval - refresh / 2
        guard head.due <= now + (onCadence ? min(refresh / 2, interval / 4) : 0) else { return nil }
        // Catch up: when the next frame is due as well, showing this one first would only carry the delay forward.
        while queue.count > 1, queue[1].due <= now { queue.removeFirst(); dropped += 1 }
        lastRelease = now
        return queue.removeFirst().frame
    }

    mutating func reset() { self = FramePacer() }
}
