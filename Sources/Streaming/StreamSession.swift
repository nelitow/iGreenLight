import Foundation
import QuartzCore
import WebRTC
#if os(iOS)
import UIKit
#endif

struct StreamTarget: Hashable, Codable, Identifiable {
    enum Kind: String, Codable { case home, cloud }
    let kind: Kind
    let id: String       // serverId (home) or titleId (cloud)
    let name: String
}

/// One Remote Play / xCloud session. Port of Greenlight's stream page + streammanager + player flow.
@MainActor
final class StreamSession: ObservableObject {
    enum Phase: Equatable {
        case starting
        case provisioning(String)
        case queued(String)
        case connecting(String)
        case streaming
        case ended(String)
        case failed(String)

        var isTerminal: Bool { if case .ended = self { return true }; if case .failed = self { return true }; return false }
    }

    struct Dialog: Identifiable { let id: String; let title: String; let text: String; let buttons: [String] }

    @Published var phase: Phase = .starting
    @Published var stats = StreamStats()
    @Published var dialog: Dialog?
    @Published var serverVideoSize: (Int, Int)?
    @Published var decodedSize: (Int, Int)?
    @Published var diagnosticsLines: [String] = []
    private(set) var recorder: DiagnosticsRecorder?

    let target: StreamTarget
    /// nil when Metal couldn't be set up; `run()` then fails the session with `rendererError`.
    let renderer: MetalVideoRenderer?
    /// Between the video track and the renderer; passes frames through unless frame generation is on.
    let interpolator: FrameInterpolator?
    private let rendererError: String?
    let keyboard = KeyboardInput()
    let mouse = MouseInput()
    private let auth: AuthManager
    private let settings = AppSettings.shared
    private var api: SessionAPI?
    private var rtc: WebRTCClient?
    private var runTask: Task<Void, Never>?
    private var keepaliveTask: Task<Void, Never>?
    private var statsTask: Task<Void, Never>?
    private var pathLogTask: Task<Void, Never>?
    private var freezeTask: Task<Void, Never>?
    private var inputTimer: DispatchSourceTimer?
    private var inputPump: InputPump?
    private var attachedVideo = false
    private var videoTrack: RTCVideoTrack?
    private var audioTrack: RTCAudioTrack?
    private var stopped = false
    private var holdsAWDL = false
    private var statsSampler = StatsSampler()
    /// See `StreamPace`; 0 until the stats report a frame rate.
    private var nominalFPS = 0.0
    private var freeze = FreezeDetector()
    private var sharpen = SharpenGovernor()
    private var upscalerGovernor = UpscalerGovernor()

    init(target: StreamTarget, auth: AuthManager) {
        self.target = target
        self.auth = auth
        let made = Result { try MetalVideoRenderer() }
        renderer = try? made.get()
        interpolator = renderer.map { FrameInterpolator(downstream: $0) }
        if case .failure(let error) = made { rendererError = error.localizedDescription } else { rendererError = nil }
        applySettings()
        renderer?.onFrameSize = { [weak self] w, h in self?.decodedSize = (w, h) }
    }

    func start() {
        guard runTask == nil else { return }
        Self.live.add(self)
        runTask = Task { await run() }
        applyAWDLHold()
    }

    private func run() async {
        guard renderer != nil else {
            log("Stream", "renderer setup failed: \(rendererError ?? "?")")
            fail(rendererError ?? "The stream can't be drawn on this device.")
            return
        }
        do {
            let cloud = target.kind == .cloud
            let token = try await auth.streamToken(cloud: cloud)
            try checkActive()
            let base = auth.baseURL(cloud: cloud, token: token)
            let size = settings.requestedSize
            let osName = settings.osName
            let deviceInfo = DeviceInfo.header(osName: osName, sdk: settings.sdkProfile, width: size.width, height: size.height)
            log("Stream", "Starting \(target.kind.rawValue) session for \(target.name) on \(base), quality \(settings.quality.label) (os \(osName)), requesting \(size.width)x\(size.height)")
            if settings.diagnosticsEnabled, recorder == nil {
                recorder = DiagnosticsRecorder(meta: ["target": "\(target.kind.rawValue): \(target.name)", "host": URL(string: base)?.host ?? base,
                                                      "settings": settings.experimentalSnapshot, "deviceInfo": deviceInfo])
                DiagnosticsRecorder.current = recorder
            }
            var api = SessionAPI(baseURL: base, gsToken: token.gsToken, kind: cloud ? .cloud : .home, deviceInfo: deviceInfo)
            phase = .provisioning("Starting session…")
            // In a task of its own, which stopping the session doesn't cancel: a cancelled request can still have
            // created the session on the server, and then nobody would know its path to delete it.
            let request = api, locale = settings.locale
            api = try await Task { () -> SessionAPI in
                var started = request
                _ = try await started.play(target: self.target.id, locale: locale, osName: osName)
                return started
            }.value
            self.api = api
            if stopped {
                // Closed while the play request was in flight: teardown ran before there was a session to delete.
                Self.deleteOnServer(api)
                return
            }

            try await waitForProvisioned(api)
            try checkActive()

            // Better xCloud: the session configuration includes the console's own address.
            var extra: [(String, Int)] = []
            var stun: [String] = []
            if let cfg = try? await api.configuration() {
                // Redacted: the response carries the SRTP key, and the log is readable outside the app.
                log("Stream", "configuration: \(Redact.value(cfg))")
                let sd = cfg["serverDetails"] as? [String: Any] ?? [:]
                if settings.consoleAddressCandidate { extra = extraCandidates(sd) }
                stun = ICEHelper.stunServers(sd)
                if !stun.isEmpty {
                    log("ICE", "STUN servers from serverDetails: \(stun)")
                    // Only for a console: a cloud server has a public address, which a symmetric NAT does not block.
                    if !cloud { stun.append(ICEHelper.natCheckSTUNServer) }
                }
            }
            try checkActive()

            phase = .connecting("Negotiating WebRTC…")
            let rtc = try WebRTCClient(options: .init(codec: settings.codecPreference, onlyPreferredCodec: settings.codecOnlyPreferred,
                                                  maxVideoBitrateKbps: settings.maxVideoBitrateKbps, offerRTX: settings.offerRTX,
                                                  lowLatencyPlayout: settings.lowLatencyPlayout, fastAudioCatchUp: settings.fastAudioCatchUp,
                                                  frameTimingFeedback: settings.frameTimingFeedback, stunServers: stun))
            self.rtc = rtc
            if rtc.options.offerRTX || rtc.options.lowLatencyPlayout || rtc.options.fastAudioCatchUp || rtc.options.frameTimingFeedback {
                log("Stream", "experimental transport: RTX \(rtc.options.offerRTX), low-latency playout \(rtc.options.lowLatencyPlayout), fast audio catch-up \(rtc.options.fastAudioCatchUp), frame timing feedback \(rtc.options.frameTimingFeedback)")
            }
            // The renderer calls this from its own threads for every frame shown; cleared again in teardown.
            if rtc.options.frameTimingFeedback { renderer?.onFramePresented = rtc.feedback.framePresented }
            wire(rtc)
            let offer = try await rtc.createOffer()
            try checkActive()
            recorder?.recordSDP(offer: offer)
            let answer = try await api.exchangeSDP(offer: offer)
            try checkActive()
            recorder?.recordSDP(answer: answer)
            log("Stream", "SDP answer received (\(answer.count) bytes)")
            try await rtc.setRemoteAnswer(answer)
            try checkActive()

            phase = .connecting("Exchanging ICE candidates…")
            let payload = await rtc.localCandidatePayload()
            try checkActive()
            let remote = try await api.exchangeICE(payload)
            try checkActive()
            log("Stream", "remote ICE: \(remote)")
            await addRemoteCandidates(remote, extra: extra, rtc: rtc)
            try checkActive()
            // For the log when a connection doesn't come up: the paths being tried and whether anything came back.
            pathLogTask = Task { [weak self, weak rtc] in
                do { try await Task.sleep(nanoseconds: 8_000_000_000) } catch { return }
                guard let self, let rtc, !self.stopped, case .connecting = self.phase else { return }
                let pairs = await rtc.icePairSummary()
                log("ICE", "still checking after 8 s; \(pairs.count) UDP pair(s):\n  " + pairs.joined(separator: "\n  "))
            }

            // ICE can connect while the candidates above are still being added; don't put the card back over the picture.
            if case .connecting = phase { phase = .connecting("Connecting to \(cloud ? "xCloud" : "console")…") }
            startKeepalive()
            startStats()
            startFreezeWatch()
            startConnectTimeout()
        } catch is CancellationError {
            // Our own stop, normally. Anything else that cancels (a sign-out during the token refresh) must still end the session.
            if !stopped { fail("The stream was cancelled.") }
        } catch {
            // Stopping cancels the request in flight, which surfaces as URLError.cancelled, not a failure.
            if stopped { return }
            log("Stream", "Session failed: \(error)")
            fail(error.localizedDescription)
        }
    }

    /// `run()` calls this after every suspension point: once the session is stopped (or failed) nothing
    /// further may touch `phase` or start connections, timers or tasks.
    private func checkActive() throws {
        if stopped || Task.isCancelled { throw CancellationError() }
    }

    private func waitForProvisioned(_ api: SessionAPI) async throws {
        var fetchedWait = false
        try await api.waitForProvisioned(transferToken: { try await self.auth.transferToken() }) { state in
            guard !self.stopped else { return }
            switch state {
            case "ReadyToConnect":
                self.phase = .provisioning("Authorizing with console…")
            case "WaitingForResources":
                guard !fetchedWait, self.target.kind == .cloud else { return }
                fetchedWait = true
                let w = try? await api.waitTime(titleId: self.target.id)
                guard !self.stopped else { return }
                if let secs = w?["estimatedTotalWaitTimeInSeconds"] as? Int {
                    self.phase = .queued("In queue — about \(max(1, secs / 60)) min")
                } else { self.phase = .queued("Waiting for a server…") }
            default:
                self.phase = .provisioning(state == "Provisioning" ? "Waking up \(self.target.kind == .home ? "console" : "server")…" : state)
            }
        }
        log("Stream", "Provisioned")
    }

    private func extraCandidates(_ sd: [String: Any]) -> [(String, Int)] {
        var out: [(String, Int)] = []
        func port(_ v: Any?) -> Int? { (v as? Int) ?? (v as? String).flatMap(Int.init) }
        if let ip = sd["ipV4Address"] as? String, ICEHelper.isIPv4(ip), let p = port(sd["ipV4Port"]), p > 0 { out.append((ip, p)) }
        if let ip = sd["ipAddress"] as? String, ICEHelper.isIPv4(ip) {
            if let p = port(sd["port"]), p > 0 { out.append((ip, p)) }
            out.append((ip, 9002))
        }
        var seen = Set<String>()
        out = out.filter { seen.insert("\($0.0):\($0.1)").inserted }
        log("ICE", "console address candidates from serverDetails: \(out)")
        return out
    }

    private func addRemoteCandidates(_ remote: [[String: Any]], extra: [(String, Int)], rtc: WebRTCClient) async {
        var foundation = 10
        var defaultMid = "0"
        var defaultIndex: Int32 = 0
        for c in remote {
            guard let (sdp, mid, index) = ICEHelper.remoteCandidate(c) else { continue }
            defaultMid = mid; defaultIndex = index
            let parts = sdp.split(separator: " ")
            if parts.count > 4, parts[4].hasPrefix("2001"), let t = ICEHelper.teredo(String(parts[4])) {
                log("ICE", "Teredo \(parts[4]) -> \(t.ip):\(t.port)")
                await rtc.addRemoteCandidate(ICEHelper.hostCandidate(foundation: foundation, ip: t.ip, port: 9002), mid: mid, index: index)
                await rtc.addRemoteCandidate(ICEHelper.hostCandidate(foundation: foundation + 1, ip: t.ip, port: t.port), mid: mid, index: index)
                foundation += 2
            }
            await rtc.addRemoteCandidate(sdp, mid: mid, index: index)
        }
        for (ip, port) in extra {
            await rtc.addRemoteCandidate(ICEHelper.hostCandidate(foundation: foundation, ip: ip, port: port), mid: defaultMid, index: defaultIndex)
            foundation += 1
        }
    }

    // MARK: WebRTC wiring
    private func wire(_ rtc: WebRTCClient) {
        let renderer = self.interpolator
        rtc.onVideoTrack = { [weak self] track in
            Task { @MainActor in
                guard let self, !self.stopped, !self.attachedVideo else { return }
                self.attachedVideo = true
                // RTCVideoTrack removes its renderers in dealloc, so keep the wrapper alive.
                self.videoTrack = track
                if let renderer { track.add(renderer) }
                log("Stream", "video track attached to Metal renderer")
            }
        }
        rtc.onAudioTrack = { [weak self] track in
            track.isEnabled = true
            Task { @MainActor in self?.audioTrack = track }
        }
        rtc.onIceState = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .connected, .completed:
                    if case .connecting = self.phase { self.phase = .streaming }
                case .failed:
                    if self.rtc?.behindSymmetricNAT == true {
                        log("ICE", "failed behind a symmetric NAT: this network maps every destination to a different public port")
                        self.fail("Could not connect. This network gives your device a different public address for every connection (symmetric NAT), which usually keeps the console from reaching it. Try another network or a VPN into your home network, or forward UDP port 9002 to the console on your router. If that is already set up, check that the console is on and Remote Play is enabled.")
                    } else {
                        self.fail("Could not connect (ICE failed). Check that the console is reachable and Remote Play is enabled.")
                    }
                case .disconnected:
                    log("Stream", "ICE disconnected (may recover)")
                default: break
                }
            }
        }
        rtc.onConnectionState = { [weak self] state in
            Task { @MainActor in
                if state == .closed || state == .failed, let self, !self.phase.isTerminal, !self.stopped {
                    self.fail("Connection closed")
                }
            }
        }

        rtc.message.requestedSize = settings.requestedSize
        let home = target.kind == .home, alias = settings.quality.resolutionAlias
        let registerPad = !sendsNoInput
        rtc.message.onHandshake = { [weak rtc, weak self] in
            guard let rtc else { return }
            rtc.control.sendAuthorization()
            if registerPad { rtc.control.gamepadChanged(index: 0, added: true) }
            rtc.input.sendClientMetadata()
            // Home consoles ignore the os.name profile and always start at 1440p; this is the control that works.
            if home { rtc.control.requestResolution(alias) }
            Task { @MainActor in self?.startInputLoop(padZeroRegistered: registerPad) }
        }
        rtc.message.onServerDisconnect = { [weak self] in
            Task { @MainActor in self?.end("The \(self?.target.kind == .home ? "console" : "server") ended the session.") }
        }
        rtc.message.onDialog = { [weak self] id, title, text, buttons in
            Task { @MainActor in self?.dialog = Dialog(id: id, title: title, text: text, buttons: buttons) }
        }
        rtc.input.onVibration = { v in GamepadInput.shared.vibrate(v) }
        rtc.input.onServerVideoSize = { [weak self] w, h in
            Task { @MainActor in
                self?.serverVideoSize = (w, h)
                let req = AppSettings.shared.requestedSize
                log("Stream", "server reports video \(w)x\(h); we requested \(req.width)x\(req.height)")
            }
        }
        rtc.control.onOpen = { log("Stream", "control channel open") }
    }

    func answerDialog(_ d: Dialog, result: Int) {
        rtc?.queue.async { [rtc] in rtc?.message.completeTransaction(d.id, ["Result": result]) }
        dialog = nil
    }

    // MARK: Input
    /// The controller is paired to the console itself (Remote Play only): the app is just the screen, registers
    /// no gamepad and sends the game no input.
    var sendsNoInput: Bool { target.kind == .home && settings.controllerOnConsole }

    private func startInputLoop(padZeroRegistered: Bool) {
        guard !stopped, inputTimer == nil, let rtc else { return }
        GamepadInput.shared.holdUntilReleased()
        keyboard.onKeyboardFrame = { [weak rtc] k in rtc?.queue.async { rtc?.input.send(keyboard: [k]) } }
        keyboard.start()
        mouse.start()
        let pump = InputPump(rtc: rtc, keyboard: keyboard, mouse: mouse, padZeroRegistered: padZeroRegistered)
        inputPump = pump
        applyInputMode()
        let timer = DispatchSource.makeTimerSource(queue: rtc.queue)
        // Poll at 250 Hz; send on change, with a 16 ms heartbeat (Greenlight loops every 16 ms).
        timer.schedule(deadline: .now(), repeating: .milliseconds(4), leeway: .microseconds(500))
        timer.setEventHandler { pump.tick() }
        timer.resume()
        inputTimer = timer
    }

    /// Quality changed during the stream. Remote Play: ask the console for that tier now (the same control
    /// message as at the handshake). Cloud picks its profile when the session starts, so it applies next time.
    func applyQuality() {
        guard target.kind == .home else { return }
        let alias = settings.quality.resolutionAlias
        log("Stream", "quality changed to \(settings.quality.label); requesting \(alias)")
        recorder?.event("resolution.userRequested", ["alias": alias])
        belowTargetSeconds = 0
        holdAttempts = 0
        holdLastRequest = Date()
        rtc?.queue.async { [rtc] in rtc?.control.requestResolution(alias) }
    }

    /// The mouse and keyboard settings (also changed from the stream menu): to the game as themselves, or the
    /// keyboard as a gamepad with the mouse, if asked for, as its right stick.
    func applyInputMode() {
        let passive = sendsNoInput
        if passive { releaseKeyboardAndMouse() }
        keyboard.mkbMode = !passive && settings.mouseKeyboard
        mouse.mode = passive ? .off : settings.mouseKeyboard ? .native : settings.mouseAim ? .stick : .off
        keyboard.aimLayout = mouse.mode == .stick
        if let pump = inputPump { rtc?.queue.async { pump.passive = passive } }
        log("Input", "controller on console \(passive), mouse mode \(mouse.mode) (mouse and keyboard \(settings.mouseKeyboard), mouse aim \(settings.mouseAim), keyboard as gamepad \(settings.keyboardAsGamepad))")
    }

    /// The stream menu or a console dialog took the input: nothing stays held in the game, and the pointer is free.
    func releaseKeyboardAndMouse() {
        keyboard.releaseAll()
        mouse.release()
    }

    func requestKeyframe() { rtc?.queue.async { [rtc] in rtc?.control.requestKeyframe() } }

    func sendGuideButton() { keyboard.tap("nexus") }

    // MARK: Keepalive & stats
    private func startKeepalive() {
        keepaliveTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
                guard let self, let api = self.api else { return }
                do { try await api.keepalive() } catch { log("Stream", "keepalive failed: \(error.localizedDescription)") }
            }
        }
    }

    /// ICE reports failure only once it has tried something; with nothing to try it would wait for ever.
    private func startConnectTimeout() {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard let self, !self.stopped, case .connecting = self.phase else { return }
            self.fail("Could not connect within 30 seconds. Check that the console is reachable and Remote Play is enabled.")
        }
    }

    private func startStats() {
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                guard let self, let rtc = self.rtc else { return }
                let report = await rtc.stats()
                if let rec = self.recorder {
                    rec.recordStats(report)
                    self.diagnosticsLines = rec.liveLines
                }
                self.holdResolution()
                var s = self.statsSampler.sample(report)
                self.nominalFPS = StreamPace.nominalFPS(sample: s.fps, previous: self.nominalFPS)
                // A second without a decoded frame has no decode time; the last one known stays.
                if let d = s.decodeMs { rtc.feedback.decodeMs = d }
                s.sharpenNote = self.adaptSharpening(s)
                s.frameRateNote = self.protectFrameRate()
                s.upscale = (self.renderer?.upscaleStatus ?? "-") + (self.settings.frameGeneration ? " · frame gen " + (self.interpolator?.status ?? "-") : "")
                s.serverSize = self.serverVideoSize.map { "\($0.0)x\($0.1)" }
                self.stats = s
            }
        }
    }

    /// The picture stopped while video data keeps arriving: the decoder lost its reference, and only a keyframe
    /// brings it back (the console answers within about a second). Checked every 100 ms from the renderer's own
    /// clock, which costs nothing; stats are only fetched while a frame is overdue (`FreezeDetector`).
    private func startFreezeWatch() {
        freezeTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: UInt64(FreezeDetector.tick * 1_000_000_000)) } catch { return }
                guard let self, let rtc = self.rtc, !self.stopped else { return }
                guard self.freeze.suspects(sinceLastFrame: self.renderer?.secondsSinceLastFrame, fps: self.nominalFPS,
                                           active: self.canRecoverFreeze, now: CACurrentMediaTime()) else { continue }
                let report = await rtc.stats()
                guard !self.stopped, !Task.isCancelled else { return }
                guard let v = report.statistics.values.first(where: { $0.type == "inbound-rtp" && ($0.values["kind"] as? String) == "video" })?.values,
                      let decoded = (v["framesDecoded"] as? NSNumber)?.doubleValue,
                      let bytes = (v["bytesReceived"] as? NSNumber)?.doubleValue else { continue }
                guard let stall = self.freeze.observe(.init(bytes: bytes, framesDecoded: decoded), sinceLastFrame: self.renderer?.secondsSinceLastFrame,
                                                      fps: self.nominalFPS, active: self.canRecoverFreeze, now: CACurrentMediaTime()) else { continue }
                log("Stream", "video frozen with data still arriving; requesting a keyframe" + String(format: " (no frame for %.0f ms)", stall * 1000))
                self.recorder?.event("freeze.keyframeRequested", ["stallMs": Int((stall * 1000).rounded())])
                self.requestKeyframe()
            }
        }
    }

    /// Not before the stream is up, and not while the app is in the background on iOS: the stream is only kept
    /// alive there for a grace period and nobody is looking at it.
    private var canRecoverFreeze: Bool {
        guard phase == .streaming, !stopped else { return false }
        #if os(iOS)
        return UIApplication.shared.applicationState != .background
        #else
        return true
        #endif
    }

    /// Sets the renderer's sharpening and debanding multipliers from how compressed the stream is. Returns the
    /// line for the stats overlay while the sharpening is held below the setting.
    private func adaptSharpening(_ s: StreamStats) -> String? {
        guard let renderer, settings.adaptiveSharpening else { return nil }
        let before = sharpen.applied
        sharpen.update(.init(avgQp: s.avgQp, codec: s.codec, fps: s.fps))
        renderer.sharpenScale = sharpen.sharpenScale
        renderer.debandBoost = sharpen.debandBoost
        let source = sharpen.source?.label ?? "-"
        if sharpen.applied != before {
            log("Stream", String(format: "adaptive sharpening: sharpen ×%.2f, deband ×%.2f (%@)", sharpen.sharpenScale, sharpen.debandBoost, source))
            recorder?.event("sharpen.adapted", ["sharpenScale": Double(sharpen.sharpenScale), "debandBoost": Double(sharpen.debandBoost), "source": source])
        }
        return sharpen.sharpenScale < 1 ? String(format: "sharpening at %.0f%% (%@)", sharpen.sharpenScale * 100, source) : nil
    }

    /// Sets the renderer's upscaler ceiling from the device's heat and GPU load. Returns the line for the stats
    /// overlay while the chosen upscaler is held back.
    private func protectFrameRate() -> String? {
        guard let renderer, settings.protectFrameRate else { return nil }
        // The ML scaler works outside the command buffer's GPU clock, so while it runs the load is the whole pass.
        let mlRunning = settings.upscaler.capped(by: renderer.maxUpscaler) == .videoToolbox
        let d = upscalerGovernor.update(thermal: ProcessInfo.processInfo.thermalState, gpuMs: mlRunning ? renderer.recentRenderMs : renderer.recentGPUMs,
                                        fps: nominalFPS, setting: settings.upscaler)
        renderer.maxUpscaler = d.cap
        if let change = d.change {
            log("Stream", "protect frame rate: \(change)")
            recorder?.event("upscaler.ceiling", ["ceiling": d.cap.rawValue, "reason": change])
        }
        return upscalerGovernor.status
    }

    /// AWDL is kept off from the start of the session to its end, while the setting is on (it can change mid-stream).
    func applyAWDLHold() {
        #if os(macOS)
        let wanted = settings.awdlOffWhileStreaming && runTask != nil && !stopped
        guard wanted != holdsAWDL else { return }
        holdsAWDL = wanted
        if wanted { AWDLHold.begin() } else { AWDLHold.end() }
        #endif
    }

    func applySettings() {
        renderer?.scaling = settings.scaling
        renderer?.upscaler = settings.upscaler
        renderer?.deband = settings.deband
        renderer?.sharpness = settings.sharpness
        renderer?.ambient = settings.ambientBars
        renderer?.edr = settings.edrExpansion
        renderer?.framePacing = settings.framePacing
        renderer?.drawOnArrival = settings.drawOnArrival
        renderer?.chromaUpsampling = settings.chromaUpsampling
        interpolator?.enabled = settings.frameGeneration
        // Switched off: back to the plain setting now, and start from scratch if it is switched on again.
        if !settings.adaptiveSharpening {
            sharpen = SharpenGovernor()
            renderer?.sharpenScale = 1
            renderer?.debandBoost = 1
        }
        if !settings.protectFrameRate {
            upscalerGovernor = UpscalerGovernor()
            renderer?.maxUpscaler = .videoToolbox
        }
    }

    /// The console lowers the stream resolution by itself (static screens, low bitrate). When it has stayed below
    /// the Quality setting for 5 s, ask for that tier again — at most once every 15 s. Remote Play only.
    private func holdResolution() {
        guard settings.holdResolution, target.kind == .home, let h = decodedSize?.1, h > 0 else { return }
        if h >= settings.quality.height { belowTargetSeconds = 0; holdAttempts = 0; return }
        belowTargetSeconds += 1
        // A console that never reaches the tier (it can't, or the link can't carry it) isn't asked for ever.
        guard holdAttempts < Self.holdMaxAttempts, belowTargetSeconds >= 5, Date().timeIntervalSince(holdLastRequest) > 15 else { return }
        holdLastRequest = Date()
        holdAttempts += 1
        let alias = settings.quality.resolutionAlias
        if holdAttempts == Self.holdMaxAttempts { log("Stream", "last attempt to hold \(settings.quality.label); the console keeps going back to \(h)p") }
        log("Stream", "stream at \(h)p, below the \(settings.quality.label) setting; requesting \(alias) again")
        recorder?.event("resolution.rerequested", ["decodedHeight": h, "alias": alias])
        rtc?.queue.async { [rtc] in rtc?.control.requestResolution(alias) }
    }
    private var belowTargetSeconds = 0
    /// Re-requests since the stream last reached the tier (or the Quality setting changed).
    private var holdAttempts = 0
    private static let holdMaxAttempts = 3
    private var holdLastRequest = Date.distantPast

    // MARK: Teardown
    private func fail(_ msg: String) {
        guard !phase.isTerminal else { return }
        phase = .failed(msg)
        recorder?.event("failed", ["message": msg])
        teardown()
    }

    private func end(_ msg: String) {
        guard !phase.isTerminal else { return }
        phase = .ended(msg)
        teardown()
    }

    func stop(_ reason: String = "Disconnected") {
        guard !stopped else { return }
        log("Stream", "Stopping session")
        if !phase.isTerminal { phase = .ended(reason) }
        teardown()
    }

    private func teardown() {
        stopped = true
        applyAWDLHold()
        if let rec = recorder {
            let reason: String
            switch phase {
            case .ended(let m): reason = "ended: \(m)"
            case .failed(let m): reason = "failed: \(m)"
            default: reason = "stopped"
            }
            recorder = nil
            // Keep capturing for a moment so the session DELETE and the last stats land, then close the run.
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if DiagnosticsRecorder.current === rec { DiagnosticsRecorder.current = nil }
                rec.finish(reason: reason)
            }
        }
        runTask?.cancel()
        keepaliveTask?.cancel()
        statsTask?.cancel()
        pathLogTask?.cancel()
        freezeTask?.cancel()
        renderer?.onFramePresented = nil
        inputTimer?.cancel(); inputTimer = nil
        inputPump = nil
        keyboard.stop()
        mouse.stop()
        if let t = videoTrack, let interpolator { t.remove(interpolator) }
        interpolator?.enabled = false
        videoTrack = nil; audioTrack = nil
        if let rtc {
            rtc.queue.async { rtc.control.gamepadChanged(index: 0, added: false) }
            rtc.queue.asyncAfter(deadline: .now() + 0.2) { rtc.close() }
        }
        if let api { Self.deleteOnServer(api) }
        api = nil
    }

    // MARK: Ending the server session
    /// DELETE requests still in flight, so quitting can wait for them (`stopAllForTermination`).
    private static var pendingDeletes: [UUID: Task<Void, Never>] = [:]
    private static let live = NSHashTable<StreamSession>.weakObjects()

    /// A stream that hasn't ended yet. The keyboard capture, the menu chord and the controllers are app-wide,
    /// so the Mac runs one stream at a time.
    static var hasActive: Bool { live.allObjects.contains { !$0.stopped } }

    private static func deleteOnServer(_ api: SessionAPI) {
        let id = UUID()
        pendingDeletes[id] = Task {
            await api.stop()
            pendingDeletes[id] = nil
        }
    }

    /// Stops every session and returns the server-side deletes that are still running. Without this, quitting
    /// mid-stream exits before the DELETE is sent and the console or cloud slot stays allocated until it times out.
    static func stopAllForTermination(reason: String = "Disconnected") -> [Task<Void, Never>] {
        live.allObjects.forEach { $0.stop(reason) }
        return Array(pendingDeletes.values)
    }
}
