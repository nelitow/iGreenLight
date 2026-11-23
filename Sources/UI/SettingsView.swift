import SwiftUI
#if os(macOS)
import ServiceManagement
#endif

/// Settings as a console-style list: every row can be reached with the controller; A toggles or steps a value,
/// left / right step it either way.
struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var auth: AuthManager
    @State private var showLog = false
    @State private var showLicenses = false
    #if os(iOS)
    @State private var tryingTouchControls = false
    #else
    @State private var awdlHelper: AWDLHelperStatus?
    @State private var awdlService = SMAppService.Status.notRegistered
    @State private var awdlNote: String?
    #endif

    var body: some View {
        if showLog {
            LogView { showLog = false }
        } else if showLicenses {
            LicensesView { showLicenses = false }
        } else {
            list
        }
    }

    private var list: some View {
        PadScrollView {
            VStack(alignment: .leading, spacing: 6) {
                PageHeader(title: "Settings") { EmptyView() }

                XboxSection(title: "Account") {
                    XboxRow(id: "set-account", title: auth.gamertag ?? "Signed in", detail: "Refresh the Xbox tokens", action: { Task { await auth.refreshAll() } }) {
                        Image(systemName: "arrow.clockwise").foregroundStyle(Xbox.secondaryText)
                    }
                    XboxRow(id: "set-signout", title: "Sign out", action: { auth.signOut() }) {
                        Image(systemName: "rectangle.portrait.and.arrow.right").foregroundStyle(Color(red: 1, green: 0.45, blue: 0.42))
                    }
                }

                XboxSection(title: "Stream") {
                    XboxChoiceRow(id: "set-quality", title: "Quality",
                                  detail: "Remote Play asks the console for this resolution (1440p is its maximum, about 17–28 Mbps; 1080p HQ about 12, 1080p about 9, 720p about 2). 720p HQ is 720p with more bitrate, and the tier the VideoToolbox ML upscaler can take to 1080p: it accepts sources up to 1280 px wide. Cloud gaming picks the server profile, which tops out at 1080p HQ; 720p HQ uses the 720p profile there.",
                                  options: StreamQuality.allCases, label: \.label, selection: $settings.quality)
                    XboxToggleRow(id: "set-1610", title: "Request 16:10 (experimental)",
                                  detail: "Sends \(settings.requestedSize.width)x\(settings.requestedSize.height) in dimensionschanged and displayInfo. The size the server actually sends is in the stats overlay.",
                                  isOn: $settings.request1610)
                    XboxToggleRow(id: "set-hold", title: "Hold this resolution on Remote Play",
                                  detail: "The console drops to a lower resolution on its own; this asks for the Quality tier again after 5 seconds below it.",
                                  isOn: $settings.holdResolution)
                    XboxVolumeRow(id: "set-volume", detail: "Game audio only, on top of the system volume. Also in the in-stream menu.", volume: $settings.volume)
                    HStack {
                        Text("Game language").font(.body.weight(.medium)).foregroundStyle(.white)
                        Spacer()
                        TextField("en-US", text: $settings.locale).textFieldStyle(.plain).multilineTextAlignment(.trailing)
                            .foregroundStyle(Xbox.brightGreen).font(.callout.weight(.semibold)).autocorrectionDisabled()
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                            .frame(maxWidth: 140)
                    }
                    .padding(.horizontal, 14).frame(minHeight: 46)
                    .background(Xbox.surface, in: RoundedRectangle(cornerRadius: Xbox.corner))
                }

                XboxSection(title: "Display") {
                    XboxChoiceRow(id: "set-scaling", title: "Scaling", options: ScalingMode.allCases, label: \.label, selection: $settings.scaling)
                    XboxChoiceRow(id: "set-upscaler", title: "Upscaler",
                                  detail: "VideoToolbox ML uses Apple's low-latency super-resolution model. It only accepts sources up to 1280 px wide (so it upgrades 720p to 1080p); larger streams fall back to MetalFX automatically.",
                                  options: Upscaler.allCases, label: \.label, selection: $settings.upscaler)
                    XboxToggleRow(id: "set-protectfps", title: "Protect frame rate",
                                  detail: "Steps the upscaler down (VideoToolbox ML, then MetalFX, then off) while the device is hot or drawing a frame takes the GPU more than about 60% of the frame's time, and back up once it has been well for a while. The stats overlay shows when it is holding the upscaler back.",
                                  isOn: $settings.protectFrameRate)
                    XboxToggleRow(id: "set-deband", title: "Debanding",
                                  detail: "Smooths the visible steps 8-bit video leaves in skies, fog and dark gradients. Edges and texture are left alone.",
                                  isOn: $settings.deband)
                    XboxChoiceRow(id: "set-sharpness", title: "Sharpening",
                                  detail: "Brings back fine detail the video compression and upscaling soften. It adapts to the picture: edges that are already crisp are left alone, so there are no halos. Lower it if compression noise becomes visible.",
                                  options: Array(0...10), label: { $0 == 0 ? "Off" : "\($0)" }, selection: $settings.sharpness)
                    XboxToggleRow(id: "set-adaptivesharp", title: "Adaptive sharpening",
                                  detail: "When the stream is short of bitrate, sharpening brings out its blocks and ringing. This eases the sharpening off (never fully) and strengthens the debanding while the picture is heavily compressed, and restores both when it is clean again. It goes by the quantiser the decoder reports; with a decoder that reports none it does nothing.",
                                  isOn: $settings.adaptiveSharpening)
                    XboxToggleRow(id: "set-chroma", title: "Sharper colour edges",
                                  detail: "The video carries colour at half the resolution of brightness. This rebuilds colour edges along the brightness edges, so red text and saturated outlines don't smear. Off: plain interpolation.",
                                  isOn: $settings.chromaUpsampling)
                    XboxToggleRow(id: "set-ambient", title: "Ambient bars",
                                  detail: "In Fit mode, fills the black bars with a soft glow in the colours of the picture's edge, fading to black away from it.",
                                  isOn: $settings.ambientBars)
                    XboxChoiceRow(id: "set-edr", title: "HDR highlight expansion",
                                  detail: "The console only sends SDR. This stretches the brightest parts of the picture into the display's HDR headroom. It is an estimate, not real HDR: white menus and subtitles get brighter too.",
                                  options: EDRExpansion.allCases, label: \.label, selection: $settings.edrExpansion)
                    XboxToggleRow(id: "set-pacing", title: "Smooth frame pacing (adds a little latency)",
                                  detail: "Frames arrive from the network unevenly, which shows as judder in steady camera movement. This holds each frame for about half a frame (8 ms at 60 fps) and shows them at an even rhythm. The stats overlay shows the result under pacing.",
                                  isOn: $settings.framePacing)
                    if FrameInterpolator.isSupported {
                        XboxToggleRow(id: "set-framegen", title: "Frame generation (Apple ML, adds latency)",
                                      detail: "Doubles the frame rate you see by inserting a frame made by Apple's low-latency frame interpolation model between every two game frames. Repeated frames in the stream (a 30 fps game arrives as 60 with each frame sent twice) are recognised and replaced. The real frame is held back until the generated one has been shown, so it adds about half a game frame plus the model's time: roughly 20-35 ms for a 30 fps game. Best for slower games; switch it off for shooters. The stats overlay shows the game's frame rate, the model's time and the added delay. Can be switched mid-stream from the stream menu.",
                                      isOn: $settings.frameGeneration)
                    }
                    if NoiseFilter.isSupported {
                        XboxChoiceRow(id: "set-denoise", title: "Noise reduction (Apple ML)",
                                      detail: "Calms the shimmer, mosquito noise and blocking that video compression leaves, most visible in foliage, dark scenes and flat walls. Uses Apple's temporal noise filter with the previous frames as reference, so it adds no frame of delay, only the model's time (shown in the stats overlay). Stronger settings also soften fine texture; Light is the safe start. Experimental.",
                                      options: NoiseReduction.allCases, label: \.label, selection: $settings.noiseReduction)
                    }
                    XboxToggleRow(id: "set-compare", title: "Compare: left half original",
                                  detail: "Splits the picture down the middle: the left half without upscaling, sharpening, debanding or noise reduction, the right half with your settings, so their effect can be judged side by side. Frame generation is not part of the comparison. Also in the stream menu.",
                                  isOn: $settings.compareSplit)
                    XboxToggleRow(id: "set-drawonarrival", title: "Draw frames as they arrive",
                                  detail: "Draws each frame the moment it is decoded instead of waiting for the display's next refresh to pick it up, which saves up to one refresh of latency. Not used while smooth frame pacing is on.",
                                  isOn: $settings.drawOnArrival)
                    #if os(macOS)
                    XboxToggleRow(id: "set-fullscreen", title: "Start streams in full screen", isOn: $settings.startFullscreen)
                    #endif
                    XboxToggleRow(id: "set-stats", title: "Show stats overlay by default", isOn: $settings.showStats)
                }

                XboxSection(title: "Input") {
                    XboxToggleRow(id: "set-onconsole", title: "Controller is paired to the console",
                                  detail: "For Remote Play near the console: play with a controller connected to the Xbox itself, with this app as the screen only. The app sends the game no input, so controllers connected to this device, the keyboard, the mouse and on-screen controls do nothing in the game. Cloud streams are not affected.",
                                  isOn: $settings.controllerOnConsole)
                    #if os(iOS)
                    XboxToggleRow(id: "set-touch", title: "On-screen controls when no controller is connected", isOn: $settings.touchControls)
                    XboxToggleRow(id: "set-touchhaptics", title: "Haptic feedback for on-screen buttons", isOn: $settings.touchHaptics)
                    XboxRow(id: "set-trytouch", title: "Try on-screen controls", action: { tryingTouchControls = true }) {
                        Image(systemName: "chevron.right").foregroundStyle(Xbox.secondaryText)
                    }
                    .fullScreenCover(isPresented: $tryingTouchControls) { TouchGamepadTestView() }
                    #endif
                    XboxToggleRow(id: "set-keyboard", title: "Keyboard controls a virtual gamepad",
                                  detail: "Enter/Space = A, Esc/Delete = B, X, Y, arrows = D-pad, WASD = left stick, HUJK = right stick, Q/E = bumpers, Z/C = triggers, M = Menu, V = View, N = Xbox button.",
                                  isOn: $settings.keyboardAsGamepad)
                    XboxToggleRow(id: "set-mkb", title: "Mouse and keyboard (experimental)",
                                  detail: mouseKeyboardDetail,
                                  isOn: $settings.mouseKeyboard)
                    XboxToggleRow(id: "set-mouseaim", title: "Mouse aims with the right stick (experimental)",
                                  detail: mouseAimDetail, disabled: settings.mouseKeyboard, isOn: $settings.mouseAim)
                    XboxChoiceRow(id: "set-mouseaim-sens", title: "Mouse aim sensitivity",
                                  options: Array(1...10), label: { "\($0)" }, selection: $settings.mouseAimSensitivity)
                    XboxChoiceRow(id: "set-mouseaim-curve", title: "Mouse aim fine movement",
                                  detail: "Boost small, slow movements if precise aiming feels sluggish while big swipes are fine.",
                                  options: [0, 1, 2], label: { ["Linear", "Boosted", "Strong"][$0] }, selection: $settings.mouseAimCurve)
                    XboxChoiceRow(id: "set-mouseaim-dz", title: "Mouse aim dead zone compensation",
                                  detail: "How much of the stick's travel the game ignores. Raise it if slow mouse movement does nothing; lower it if the camera jumps or keeps drifting.",
                                  options: Array(stride(from: 0, through: 30, by: 5)), label: { "\($0)%" }, selection: $settings.mouseAimDeadZone)
                    XboxToggleRow(id: "set-vibration", title: "Controller vibration", isOn: $settings.vibration)
                }

                XboxSection(title: "Experimental: Diagnostics") {
                    XboxToggleRow(id: "set-diag", title: "Record diagnostics for each stream",
                                  detail: "Writes HTTP calls (tokens stripped), SDP offer/answer, data-channel messages, getStats every second and sampled decoded-frame formats to diagnostics/<timestamp>/.",
                                  isOn: $settings.diagnosticsEnabled)
                    XboxToggleRow(id: "set-diagoverlay", title: "Show diagnostics overlay", disabled: !settings.diagnosticsEnabled, isOn: $settings.diagnosticsOverlay)
                    XboxRow(id: "set-diagfolder", title: "Show diagnostics folder", action: {
                        let url = DiagnosticsRecorder.rootURL
                        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                        Platform.reveal(url)
                    }) { Image(systemName: "folder").foregroundStyle(Xbox.secondaryText) }
                    XboxChoiceRow(id: "set-codec", title: "Preferred video codec", options: VideoCodecPreference.allCases, label: \.label, selection: $settings.codecPreference)
                    XboxToggleRow(id: "set-codeconly", title: "Offer only the preferred codec (no H.264 fallback)",
                                  detail: "Without fallback the console may refuse the session or send video the app can't decode.",
                                  isOn: $settings.codecOnlyPreferred)
                    XboxChoiceRow(id: "set-profile", title: "Client profile (os.name)", options: ClientProfile.allCases, label: \.label, selection: $settings.clientProfile)
                    XboxChoiceRow(id: "set-sdk", title: "Client identity", options: SDKProfile.allCases, label: \.label, selection: $settings.sdkProfile)
                    XboxChoiceRow(id: "set-bitrate", title: "Video bitrate ceiling (b=AS)",
                                  options: [0] + [5, 10, 15, 20, 25, 30, 40, 50, 60, 80, 100].map { $0 * 1000 },
                                  label: { $0 == 0 ? "None (server default)" : "\($0 / 1000) Mbps" }, selection: $settings.maxVideoBitrateKbps)
                    XboxChoiceRow(id: "set-display", title: "Reported display size",
                                  detail: "Sent in X-MS-Device-Info displayInfo and dimensionschanged. Now: \(settings.osName), \(settings.requestedSize.width)×\(settings.requestedSize.height).",
                                  options: ReportedDisplaySize.allCases, label: \.label, selection: $settings.reportedDisplaySize)
                }

                XboxSection(title: "Experimental: Transport") {
                    XboxToggleRow(id: "set-rtx", title: "Offer retransmission (RTX)",
                                  detail: "Offers a retransmission stream for video, so a lost packet can be resent instead of costing a keyframe. Untested against a console: it only does anything if the console accepts it. Applies from the next stream.",
                                  isOn: $settings.offerRTX)
                    XboxToggleRow(id: "set-playout", title: "Low-latency playout",
                                  detail: "Decodes and shows each frame as soon as it is complete instead of holding it to even out network jitter. Lower latency, more uneven motion on a jittery network. Untested against a console. Applies from the next stream.",
                                  isOn: $settings.lowLatencyPlayout)
                    XboxToggleRow(id: "set-audiocatchup", title: "Faster audio catch-up",
                                  detail: "Lets audio speed up more readily to shed delay after a network hiccup, at the cost of more audible time-stretching. Untested against a console. Applies from the next stream.",
                                  isOn: $settings.fastAudioCatchUp)
                    XboxToggleRow(id: "set-framefeedback", title: "Report frame timing to the server",
                                  detail: "Sends the timing of every displayed frame on the input channel, as the official web client does. Untested against a console: whether it changes what the console sends is unknown. Applies from the next stream.",
                                  isOn: $settings.frameTimingFeedback)
                }

                XboxSection(title: "Network") {
                    XboxToggleRow(id: "set-consoleice", title: "Add console's own address as ICE candidate", isOn: $settings.consoleAddressCandidate)
                    regionRow("set-region-home", "Remote Play region", token: auth.xhome, selection: $settings.xhomeRegionOverride)
                    regionRow("set-region-cloud", "Cloud region", token: auth.xcloud, selection: $settings.xcloudRegionOverride)
                    #if os(macOS)
                    XboxToggleRow(id: "set-awdl", title: "Turn off AWDL while streaming",
                                  detail: "AirDrop, AirPlay and Handoff make the Wi-Fi radio leave your network's channel at regular intervals, which a stream on Wi-Fi sees as latency spikes. This keeps them off for as long as a stream runs and brings them back afterwards. It needs the helper below turned on.",
                                  isOn: $settings.awdlOffWhileStreaming)
                    awdlHelperRow
                    #endif
                }

                XboxSection(title: "Log") {
                    XboxRow(id: "set-log", title: "Show log", action: { showLog = true }) {
                        Image(systemName: "chevron.right").foregroundStyle(Xbox.secondaryText)
                    }
                    #if os(iOS)
                    XboxRow(id: "set-files", title: "Open app folder in Files", action: { Platform.reveal(Platform.dataDirectory) }) {
                        Image(systemName: "folder").foregroundStyle(Xbox.secondaryText)
                    }
                    #else
                    XboxRow(id: "set-reveallog", title: "Reveal log file in Finder", action: { Platform.reveal(Log.shared.logFileURL) }) {
                        Image(systemName: "folder").foregroundStyle(Xbox.secondaryText)
                    }
                    #endif
                }

                XboxSection(title: "About") {
                    XboxRow(id: "set-licenses", title: "Open-source licences", detail: "Greenlight, WebRTC and the libraries inside it", action: { showLicenses = true }) {
                        Image(systemName: "chevron.right").foregroundStyle(Xbox.secondaryText)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
    }

    #if os(macOS)
    /// The root helper: turn it on (registers it and sends the user to approve it), or off again.
    @ViewBuilder private var awdlHelperRow: some View {
        let running = awdlHelper != nil
        XboxRow(id: "set-awdl-helper", title: awdlHelperTitle(running: running), detail: awdlNote ?? awdlHelperDetail(running: running),
                action: { awdlHelperAction(running: running) }) {
            Image(systemName: running ? "checkmark.circle.fill" : awdlService == .requiresApproval ? "exclamationmark.circle" : "power")
                .foregroundStyle(running ? Xbox.brightGreen : Xbox.secondaryText)
        }
        .task {
            // Approval happens in System Settings, so keep asking the helper whether it is there.
            while !Task.isCancelled {
                let status = await AWDLHold.helperStatus()
                if (status != nil) != (awdlHelper != nil) { awdlNote = nil }
                awdlHelper = status
                // An XPC round trip to the system: not on the main thread.
                awdlService = await Task.detached { AWDLHold.service.status }.value
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func awdlHelperTitle(running: Bool) -> String {
        if running { return "AWDL helper is on" }
        switch awdlService {
        case .requiresApproval: return "AWDL helper is waiting for your approval"
        case .enabled: return "AWDL helper isn't answering"
        default: return "Turn on the AWDL helper"
        }
    }

    private func awdlHelperDetail(running: Bool) -> String {
        switch (running, awdlService) {
        case (true, .enabled): "Select to turn it off."
        case (true, _): "It was installed from Terminal. Select to copy the command that removes it."
        case (false, .requiresApproval): "Select to open System Settings, then switch on iGreenLight under Allow in the Background."
        case (false, .enabled): "Select to turn it off, then turn it on again."
        default: "Turning AWDL off needs administrator rights, which the app doesn't have, so a small background service does it. Select, then switch on iGreenLight under Allow in the Background in System Settings. You only do this once."
        }
    }

    private func awdlHelperAction(running: Bool) {
        let service = AWDLHold.service
        awdlNote = nil
        switch service.status {
        case .enabled:
            do { try service.unregister() } catch { awdlNote = "Couldn't turn it off: \(error.localizedDescription)" }
        case .requiresApproval:
            SMAppService.openSystemSettingsLoginItems()
        default:
            if running {
                Platform.copy(AWDLHold.uninstallCommand)
                awdlNote = "Copied. Paste it in Terminal and enter your password."
                break
            }
            do {
                try service.register()
            } catch where service.status != .requiresApproval {
                // A build that can't register a daemon can still install the helper with the bundled script and sudo.
                if let command = AWDLHold.installCommand {
                    Platform.copy(command)
                    awdlNote = "This build can't turn the helper on by itself (\(error.localizedDescription)). A Terminal command that installs it is copied instead: paste it in Terminal and enter your password."
                } else {
                    awdlNote = "Couldn't turn it on: \(error.localizedDescription)"
                }
            } catch {}
            if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        }
        awdlService = service.status
    }
    #endif

    private var mouseAimDetail: String {
        #if os(macOS)
        "For games that only take a controller, laid out like a PC shooter. Mouse = right stick, left button = RT, right button = LT, middle button or V = right stick click. WASD = left stick, Shift = left stick click, Space/Enter = A, Ctrl or C = B, R = X, F = Y, Q = LB, E = RB, arrows or 1–4 = D-pad (up, right, down, left), Tab = View, Esc = Menu, N = Xbox button. Click the picture to capture the pointer; press ⌘ to get it back. Not used while mouse and keyboard mode is on."
        #else
        "For games that only take a controller, laid out like a PC shooter, with a connected mouse and keyboard. Mouse = right stick, left button = RT, right button = LT, middle button or V = right stick click. WASD = left stick, Shift = left stick click, Space/Enter = A, Ctrl or C = B, R = X, F = Y, Q = LB, E = RB, arrows or 1–4 = D-pad (up, right, down, left), Tab = View, Esc = Menu, N = Xbox button. Not used while mouse and keyboard mode is on."
        #endif
    }

    private var mouseKeyboardDetail: String {
        #if os(macOS)
        "Sends the keyboard and mouse to the game as themselves, for games that support them, instead of the virtual gamepad. Click the picture to capture the pointer; press ⌘ to get it back."
        #else
        "Sends a connected keyboard and mouse to the game as themselves, for games that support them, instead of the virtual gamepad."
        #endif
    }

    private func regionRow(_ id: String, _ title: String, token: XboxAuth.StreamToken?, selection: Binding<String>) -> some View {
        XboxChoiceRow(id: id, title: title, options: [""] + (token?.offeringSettings.regions.map(\.name) ?? []),
                      label: { $0.isEmpty ? "Default (\(token?.defaultRegion?.name ?? "-"))" : $0 }, selection: selection)
    }
}

/// Settings → About → Open-source licences: the texts in the bundle's `Licenses` folder.
struct LicensesView: View {
    let onClose: () -> Void

    private static let texts: [(name: String, text: String)] = {
        guard let dir = Bundle.main.url(forResource: "Licenses", withExtension: nil),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return files.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { url in
            (try? String(contentsOf: url, encoding: .utf8)).map { (url.deletingPathExtension().lastPathComponent, $0) }
        }
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            XboxButton(id: "licenses-back", title: "Back", systemImage: "chevron.left", prominent: false, action: onClose)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Self.texts, id: \.name) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.name).font(.title3.bold()).foregroundStyle(.white)
                            Text(item.text).font(.system(.caption, design: .monospaced)).foregroundStyle(.white.opacity(0.85))
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(10)
            }
            .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: Xbox.corner))
        }
        .padding(20)
        .padScope("licenses", onBack: onClose)
    }
}
