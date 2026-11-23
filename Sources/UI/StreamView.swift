import SwiftUI
import MetalKit
#if os(macOS)
import AppKit

enum StreamWindow {
    nonisolated(unsafe) static weak var current: NSWindow?
}
#else
import GameController
#endif

/// Owns a StreamSession for the lifetime of the stream window.
struct StreamContainer: View {
    let target: StreamTarget
    @EnvironmentObject var auth: AuthManager
    @State private var session: StreamSession?
    #if os(iOS)
    @Environment(\.scenePhase) private var scenePhase
    #endif

    var body: some View {
        Group {
            if let session { StreamView(session: session) } else { Color.black }
        }
        #if os(iOS)
        .onChange(of: scenePhase) { _, phase in
            // Key and button releases don't arrive while the app isn't in front.
            if phase != .active { session?.releaseKeyboardAndMouse() }
            if phase == .background { StreamScreen.appEnteredBackground() } else if phase == .active { StreamScreen.appBecameActive() }
        }
        #endif
        .onAppear {
            if session == nil {
                let s = StreamSession(target: target, auth: auth)
                session = s
                s.start()
            }
        }
        .onDisappear { session?.stop() }
        .navigationTitle(target.name)
    }
}

struct StreamView: View {
    @ObservedObject var session: StreamSession
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var showStats = AppSettings.shared.showStats
    @State private var isFullScreen = false
    /// The options panel (sliders button, or both sticks clicked on a controller).
    @State private var menuOpen = false
    #if os(iOS)
    /// On-screen gamepad: on while no controller is connected (if the setting allows), or toggled from the controls.
    @State private var touchControls = AppSettings.shared.touchControls && !GamepadInput.anyConnected
    @State private var controllerConnected = GamepadInput.anyConnected
    /// The stream area is at least as wide as it is tall. The app asks for landscape, but a window can still be
    /// tall: the inner display of iPhone Duo doesn't honour the request, nor does an iPad window in Split View.
    @State private var wide = true
    /// The top of the device (Dynamic Island) is on the right.
    @State private var cameraOnRight = false
    #endif

    // The body is split into `layers` and three groups of modifiers: as one expression it is more than the Swift
    // compiler in Xcode 26 will type-check.
    var body: some View {
        platformBehaviour(settingsBehaviour(inputBehaviour(layers)))
    }

    private var layers: some View {
        ZStack {
            // The picture runs edge to edge; on the iPhone the overlays stay inside the safe area
            // (clear of the Dynamic Island and the rounded corners).
            Group {
                Color.black
                if let renderer = session.renderer {
                    #if os(macOS)
                    MetalVideoView(renderer: renderer, onClick: { session.mouse.capture() })
                    #else
                    MetalVideoView(renderer: renderer)
                    #endif
                }
            }
            .ignoresSafeArea()
            #if os(iOS)
            if touchControls, !passive, session.phase == .streaming { TouchGamepadOverlay() }
            #endif
            statusOverlay
            #if os(iOS)
            if controlsOnSide { sideControls } else { floatingControls }
            #else
            floatingControls
            #endif
            if showStats, session.phase == .streaming { statsOverlay }
            if settings.diagnosticsEnabled, settings.diagnosticsOverlay, session.phase == .streaming, !session.diagnosticsLines.isEmpty { diagnosticsOverlay }
            if menuOpen { streamMenu }
            if let d = session.dialog { dialogCard(d) }
        }
        .preferredColorScheme(.dark)
    }

    /// Before and after the stream the controller drives these screens (B cancels / closes). During it the
    /// controller is the game's, except while the menu or a console dialog is up.
    private func inputBehaviour(_ view: some View) -> some View {
        view
            .padScope("stream", onBack: { if session.phase != .streaming { session.stop(); dismiss() } })
            .padKeyboard()
            .onAppear {
                PadNavigator.shared.onMenuChord = { if session.phase == .streaming { menuOpen.toggle() } }
                syncInputOwner()
            }
            .onDisappear {
                PadNavigator.shared.onMenuChord = nil
                PadNavigator.shared.suspended = false
                GamepadInput.shared.uiOwnsInput = false
            }
            .onChange(of: session.phase) { syncInputOwner() }
            .onChange(of: menuOpen) { syncInputOwner() }
            .onChange(of: session.dialog?.id) { syncInputOwner() }
    }

    private func settingsBehaviour(_ view: some View) -> some View {
        view
            .onChange(of: settings.quality) { session.applyQuality() }
            .onChange(of: settings.mouseKeyboard) { session.applyInputMode() }
            .onChange(of: settings.mouseAim) { session.applyInputMode() }
            .onChange(of: settings.controllerOnConsole) { session.applyInputMode() }
            .onChange(of: settings.scaling) { session.applySettings() }
            .onChange(of: settings.upscaler) { session.applySettings() }
            .onChange(of: settings.deband) { session.applySettings() }
            .onChange(of: settings.sharpness) { session.applySettings() }
            .onChange(of: settings.ambientBars) { session.applySettings() }
            .onChange(of: settings.edrExpansion) { session.applySettings() }
            .onChange(of: settings.framePacing) { session.applySettings() }
            .onChange(of: settings.frameGeneration) { session.applySettings() }
            .onChange(of: settings.noiseReduction) { session.applySettings() }
            .onChange(of: settings.compareSplit) { session.applySettings() }
            .onChange(of: settings.volume) { session.applySettings() }
            .onChange(of: settings.drawOnArrival) { session.applySettings() }
            .onChange(of: settings.chromaUpsampling) { session.applySettings() }
            .onChange(of: settings.adaptiveSharpening) { session.applySettings() }
            .onChange(of: settings.protectFrameRate) { session.applySettings() }
            #if os(macOS)
            .onChange(of: settings.awdlOffWhileStreaming) { session.applyAWDLHold() }
            #endif
    }

    #if os(macOS)
    // No window toolbar: in full screen the system gives it an opaque strip that covers the top of the
    // picture. The controls float over the video instead (`floatingControls`).
    private func platformBehaviour(_ view: some View) -> some View {
        view
            .ignoresSafeArea()
            .background(WindowAccessor())
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { n in
                if (n.object as? NSWindow) === StreamWindow.current { isFullScreen = true; StreamWindow.current?.toolbar?.isVisible = false }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { n in
                if (n.object as? NSWindow) === StreamWindow.current { isFullScreen = false }
            }
    }
    #else
    private func platformBehaviour(_ view: some View) -> some View {
        screenBehaviour(view)
            .onGeometryChange(for: Bool.self) { $0.size.width >= $0.size.height } action: { wide = $0 }
            .background(SceneOrientationReader { cameraOnRight = $0 == .landscapeLeft })
            // Taller than wide with the on-screen gamepad up: the picture goes to the top, the gamepad sits below it.
            .onChange(of: !wide && touchControls && !passive, initial: true) { _, top in session.renderer?.pictureAnchorY = top ? 0 : 0.5 }
            .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in
                controllerConnected = true
                touchControls = false
            }
            .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) { _ in
                controllerConnected = GamepadInput.anyConnected
                touchControls = settings.touchControls && !controllerConnected
            }
    }

    private func screenBehaviour(_ view: some View) -> some View {
        view
            .statusBarHidden(true)
            .persistentSystemOverlays(.hidden)
            .onAppear { StreamScreen.enter() }
            // Ended or failed: the card may rotate, and the screen may dim and lock again.
            .onChange(of: session.phase.isTerminal) { _, over in if over { StreamScreen.leave() } }
            .onDisappear { StreamScreen.leave() }
    }
    #endif

    private func syncInputOwner() {
        let ui = menuOpen || session.dialog != nil
        GamepadInput.shared.uiOwnsInput = ui
        if ui || session.phase != .streaming { session.releaseKeyboardAndMouse() } else { session.mouse.autoCapture() }
        PadNavigator.shared.suspended = session.phase == .streaming && !ui
        if session.phase != .streaming, menuOpen { menuOpen = false }
    }

    /// The controller is paired to the console itself: nothing here is sent to the game. Reads the setting so
    /// the view follows it when it is changed from the stream menu.
    private var passive: Bool { settings.controllerOnConsole && session.sendsNoInput }

    private var streamMenu: StreamMenu {
        #if os(iOS)
        StreamMenu(session: session, isOpen: $menuOpen, showStats: $showStats, touchControls: $touchControls)
        #else
        StreamMenu(session: session, isOpen: $menuOpen, showStats: $showStats)
        #endif
    }

    /// A message from the console (e.g. "someone else wants to play").
    private func dialogCard(_ d: StreamSession.Dialog) -> some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 14) {
                Text(d.title).font(.title2.bold()).foregroundStyle(.white)
                Text(d.text).multilineTextAlignment(.center).foregroundStyle(Xbox.secondaryText).frame(maxWidth: 420)
                HStack(spacing: 12) {
                    ForEach(Array((d.buttons.isEmpty ? ["OK"] : d.buttons).enumerated()), id: \.offset) { i, b in
                        XboxButton(id: "dialog-\(i)", title: b, prominent: i == 0) { session.answerDialog(d, result: i) }
                    }
                }
            }
            .padding(28)
            .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 14))
            .padScope("stream-dialog", onBack: { session.answerDialog(d, result: d.buttons.count > 1 ? 1 : 0) })
        }
    }

    #if os(iOS)
    /// With a controller in hand the buttons go where iPhone Duo puts an app's controls: a column of symbols on the
    /// right-hand edge, Close first. With the on-screen gamepad up that edge belongs to the face buttons and the
    /// right stick, so they stay in the row at the top. A tall window keeps the row as well, as iPhone Duo keeps
    /// horizontal bars on its inner display in portrait.
    private var controlsOnSide: Bool { controllerConnected && (!touchControls || passive) && wide }

    /// The column, placed in the black bar beside the picture when there is one (a 16:9 picture on a wider phone),
    /// so it doesn't sit on the picture's edge.
    private var sideControls: some View {
        GeometryReader { g in
            let width: CGFloat = 40
            VStack(spacing: 20) { streamControls }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .fixedSize()
                .focusable(false)
                .foregroundStyle(.white)
                .font(.system(size: 17))
                .frame(width: width)
                .padding(.vertical, 16)
                .streamControlsGlass()
                .environment(\.colorScheme, .dark)
                .position(x: sideColumnCentre(in: g.size, trailingInset: g.safeAreaInsets.trailing, width: width), y: g.size.height / 2)
        }
        .ignoresSafeArea()
        // The column is tied to the hardware, so it stays on the right in right-to-left languages too.
        .environment(\.layoutDirection, .leftToRight)
    }

    /// `size` is the whole screen. Returns the x of the column's centre.
    private func sideColumnCentre(in size: CGSize, trailingInset: CGFloat, width: CGFloat) -> CGFloat {
        let aspect = session.decodedSize.map { CGFloat($0.0) / CGFloat(max($0.1, 1)) } ?? 16.0 / 9
        let picture = settings.scaling == .fit ? min(size.width, size.height * aspect) : size.width
        let bar = (size.width - picture) / 2
        // No bar to speak of (the picture fills the width): inside the safe area, over the picture's edge.
        guard bar >= 24 else { return size.width - trailingInset - 6 - width / 2 }
        // Free strip of the bar: from just past the picture to the screen edge, less the Dynamic Island when the
        // top of the phone is on this side (a phone with one has a wide side inset in landscape).
        let islandHere = cameraOnRight && trailingInset >= 40
        let left = size.width - bar + 4, right = size.width - (islandHere ? 50 : 10)
        // Centred in the strip; where the strip is narrower than the column, against its outer end.
        return right - left >= width ? (left + right) / 2 : right - width / 2
    }
    #endif

    private var streamControls: StreamControls {
        #if os(iOS)
        StreamControls(session: session, showStats: $showStats, menuOpen: $menuOpen, touchControls: $touchControls, passive: passive, closeFirst: controlsOnSide)
        #else
        StreamControls(session: session, showStats: $showStats, menuOpen: $menuOpen, passive: passive)
        #endif
    }

    var floatingControls: some View {
        HStack(spacing: 14) { streamControls }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .focusable(false)
            .foregroundStyle(.white)
            #if os(macOS)
            .font(.system(size: 15))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .streamControlsGlass()
            .environment(\.colorScheme, .dark)
            .padding(10)
            // Windowed, the traffic lights sit in this corner (hidden title bar); start to their right.
            .padding(.leading, isFullScreen ? 0 : 70)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            #else
            // Top centre: between the bumpers of the on-screen gamepad, away from the Dynamic Island.
            .font(.system(size: 17))
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .streamControlsGlass()
            .environment(\.colorScheme, .dark)
            .padding(.top, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            #endif
    }

    #if os(macOS)
    private let overlayTop: CGFloat = 44, overlayFont: CGFloat = 11
    #else
    private let overlayTop: CGFloat = 40, overlayFont: CGFloat = 9
    #endif

    @ViewBuilder var statusOverlay: some View {
        switch session.phase {
        case .streaming: EmptyView()
        case .starting: StatusCard(title: session.target.name, detail: "Starting…", spinner: true) { cancelButton }
        case .provisioning(let s), .connecting(let s), .queued(let s):
            StatusCard(title: session.target.name, detail: s, spinner: true) { cancelButton }
        case .ended(let s):
            StatusCard(title: "Stream ended", detail: s, spinner: false) { XboxButton(id: "stream-close", title: "Close") { dismiss() } }
        case .failed(let s):
            StatusCard(title: "Couldn't stream", detail: s, spinner: false) { XboxButton(id: "stream-close", title: "Close") { dismiss() } }
        }
    }

    private var cancelButton: some View {
        VStack(spacing: 10) {
            XboxButton(id: "stream-cancel", title: "Cancel", prominent: false) { session.stop(); dismiss() }
            if PadNavigator.shared.padConnected {
                HStack(spacing: 6) {
                    PadGlyph(kind: .sticks)
                    Text("opens the menu during the stream").font(.footnote).foregroundStyle(Xbox.secondaryText)
                }
            }
        }
    }

    var diagnosticsOverlay: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("DIAGNOSTICS").bold()
            ForEach(Array(session.diagnosticsLines.enumerated()), id: \.offset) { Text($0.element) }
        }
        .font(.system(size: overlayFont, design: .monospaced))
        .foregroundStyle(.yellow)
        .padding(8)
        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
        .padding(12)
        .padding(.top, overlayTop)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .allowsHitTesting(false)
    }

    var statsOverlay: some View {
        let s = session.stats
        return VStack(alignment: .leading, spacing: 2) {
            Text("\(s.resolution) @ \(Int(s.fps)) fps  \(s.codec)")
            Text(String(format: "%.1f Mbps  RTT %@  jitter %.1f ms  lost %d", s.bitrateMbps, s.rttMs.map { String(format: "%.0f ms", $0) } ?? "-", s.jitterMs, s.packetsLost))
            if let d = s.decodeMs { Text(String(format: "decode %.1f ms", d)) }
            Text("path: \(s.path)")
            Text("server video: \(s.serverSize ?? "-")  requested: \(settings.requestedSize.width)x\(settings.requestedSize.height)")
            Text("upscale: \(s.upscale)  [\(settings.scaling.rawValue)]")
            if let note = s.frameRateNote { Text("protect frame rate: \(note)").foregroundStyle(.orange) }
            if let note = s.sharpenNote { Text("adaptive: \(note)") }
            Text("render cost: \(session.renderer?.timingSummary ?? "-")")
            Text("pacing: \(session.renderer?.pacingSummary ?? "-")")
            Text(s.freezeLine).foregroundStyle(s.freezeIsRecent ? .orange : .white)
            Text("controllers: \(GamepadInput.shared.controllerNames.joined(separator: ", ").isEmpty ? "keyboard" : GamepadInput.shared.controllerNames.joined(separator: ", "))")
        }
        .font(.system(size: overlayFont, design: .monospaced))
        .foregroundStyle(.white)
        .padding(8)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
        .padding(12)
        .padding(.top, overlayTop)   // clear the controls
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

extension View {
    /// Backing of the floating stream controls: Liquid Glass on iOS / macOS 26 and later, the frosted blur before that.
    @ViewBuilder func streamControlsGlass() -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            glassEffect(.regular.interactive(), in: .capsule)
        } else {
            background(.ultraThinMaterial, in: Capsule())
        }
    }
}

/// The stream's floating buttons.
///
/// A view of its own that doesn't observe the session, so the once-a-second stats redraw of `StreamView` leaves it alone.
struct StreamControls: View {
    let session: StreamSession
    @Binding var showStats: Bool
    @Binding var menuOpen: Bool
    #if os(iOS)
    @Binding var touchControls: Bool
    #endif
    /// The controller is paired to the console itself: the buttons that send input to the game are left out.
    var passive = false
    /// Disconnect leads instead of trailing (the vertical column, where Close belongs at the top).
    var closeFirst = false
    @Environment(\.dismiss) private var dismiss

    private var disconnect: some View {
        Button("Disconnect", systemImage: "xmark.circle") { session.stop(); dismiss() }
    }

    var body: some View {
        if closeFirst { disconnect }
        #if os(macOS)
        Button("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right") { StreamWindow.current?.toggleFullScreen(nil) }
            .help("Toggle full screen (⌃⌘F)")
        #else
        if !passive {
            Button("On-screen controls", systemImage: touchControls ? "gamecontroller.fill" : "gamecontroller") { touchControls.toggle() }
        }
        #endif
        if !passive {
            Button("Guide", systemImage: "xbox.logo") { session.sendGuideButton() }.help("Press the Xbox button")
        }
        Button("Stats", systemImage: "chart.bar") { showStats.toggle() }.help("Toggle stats overlay")
        Button("Options", systemImage: "slider.horizontal.3") { menuOpen.toggle() }.help("Stream options")
        if !closeFirst { disconnect }
    }
}

/// Options panel over the stream, in the console's style. Works by touch, mouse and controller
/// (D-pad to move, A / left / right to change, B to close). Doesn't observe the session, for the same reason as `StreamControls`.
struct StreamMenu: View {
    let session: StreamSession
    @Binding var isOpen: Bool
    @Binding var showStats: Bool
    #if os(iOS)
    @Binding var touchControls: Bool
    #endif
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    private var passive: Bool { settings.controllerOnConsole && session.sendsNoInput }

    var body: some View {
        ZStack(alignment: .trailing) {
            Color.black.opacity(0.35).ignoresSafeArea().onTapGesture { isOpen = false }
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "gamecontroller.fill").font(.title2)
                    Text(session.target.name).font(.title3.bold()).lineLimit(1)
                    Spacer()
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 8)
                PadScrollView {
                    VStack(spacing: 6) {
                        XboxRow(id: "menu-resume", title: "Resume", action: { isOpen = false }) { Image(systemName: "play.fill").foregroundStyle(Xbox.brightGreen) }
                        if !passive {
                            XboxRow(id: "menu-guide", title: "Press the Xbox button", action: { isOpen = false; session.sendGuideButton() }) { Image(systemName: "xbox.logo").foregroundStyle(Xbox.secondaryText) }
                        }
                        XboxVolumeRow(id: "menu-volume", volume: $settings.volume)
                        XboxChoiceRow(id: "menu-quality", title: session.target.kind == .home ? "Quality" : "Quality (next session)",
                                      options: StreamQuality.allCases, label: \.label, selection: $settings.quality)
                        XboxChoiceRow(id: "menu-scaling", title: "Scaling", options: ScalingMode.allCases, label: \.label, selection: $settings.scaling)
                        XboxChoiceRow(id: "menu-upscaler", title: "Upscaler", options: Upscaler.allCases, label: \.label, selection: $settings.upscaler)
                        XboxToggleRow(id: "menu-deband", title: "Debanding", isOn: $settings.deband)
                        XboxChoiceRow(id: "menu-sharpness", title: "Sharpening", options: Array(0...10), label: { $0 == 0 ? "Off" : "\($0)" }, selection: $settings.sharpness)
                        XboxToggleRow(id: "menu-ambient", title: "Ambient bars", isOn: $settings.ambientBars)
                        XboxChoiceRow(id: "menu-edr", title: "HDR highlight expansion", options: EDRExpansion.allCases, label: \.label, selection: $settings.edrExpansion)
                        XboxToggleRow(id: "menu-pacing", title: "Smooth frame pacing", isOn: $settings.framePacing)
                        if FrameInterpolator.isSupported {
                            XboxToggleRow(id: "menu-framegen", title: "Frame generation (Apple ML)", isOn: $settings.frameGeneration)
                        }
                        if NoiseFilter.isSupported {
                            XboxChoiceRow(id: "menu-denoise", title: "Noise reduction (Apple ML)", options: NoiseReduction.allCases, label: \.label, selection: $settings.noiseReduction)
                        }
                        XboxToggleRow(id: "menu-compare", title: "Compare: left half original", isOn: $settings.compareSplit)
                        XboxToggleRow(id: "menu-stats", title: "Stats overlay", isOn: $showStats)
                        if session.target.kind == .home {
                            XboxToggleRow(id: "menu-onconsole", title: "Controller is paired to the console", isOn: $settings.controllerOnConsole)
                        }
                        XboxToggleRow(id: "menu-mkb", title: "Mouse and keyboard", disabled: passive, isOn: $settings.mouseKeyboard)
                        XboxToggleRow(id: "menu-mouseaim", title: "Mouse aims with the right stick", disabled: passive || settings.mouseKeyboard, isOn: $settings.mouseAim)
                        XboxChoiceRow(id: "menu-mouseaim-sens", title: "Mouse aim sensitivity", options: Array(1...10), label: { "\($0)" }, selection: $settings.mouseAimSensitivity)
                        XboxChoiceRow(id: "menu-mouseaim-curve", title: "Mouse aim fine movement", options: [0, 1, 2], label: { ["Linear", "Boosted", "Strong"][$0] }, selection: $settings.mouseAimCurve)
                        #if os(iOS)
                        XboxToggleRow(id: "menu-touch", title: "On-screen controls", disabled: passive, isOn: $touchControls)
                        #endif
                        XboxRow(id: "menu-keyframe", title: "Request keyframe", action: { session.requestKeyframe() }) { Image(systemName: "arrow.clockwise").foregroundStyle(Xbox.secondaryText) }
                        XboxRow(id: "menu-disconnect", title: "Disconnect", action: { session.stop(); dismiss() }) { Image(systemName: "xmark.circle").foregroundStyle(Color(red: 1, green: 0.45, blue: 0.42)) }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                }
                PadHints(hints: [(.a, "Change"), (.b, "Close")])
            }
            .frame(maxWidth: 380)
            .background(Color(white: 0.08).opacity(0.94))
            .padScope("stream-menu", onBack: { isOpen = false })
        }
        .transition(.opacity)
    }
}

struct StatusCard<Actions: View>: View {
    let title: String
    let detail: String
    let spinner: Bool
    @ViewBuilder var actions: () -> Actions

    init(title: String, detail: String, spinner: Bool, @ViewBuilder actions: @escaping () -> Actions = { EmptyView() }) {
        self.title = title; self.detail = detail; self.spinner = spinner; self.actions = actions
    }

    var body: some View {
        VStack(spacing: 14) {
            if spinner { ProgressView().controlSize(.large) }
            Text(title).font(.title2.bold()).foregroundStyle(.white)
            Text(detail).multilineTextAlignment(.center).foregroundStyle(Xbox.secondaryText).frame(maxWidth: 420)
            actions()
        }
        .padding(28)
        .background(Color(white: 0.12).opacity(0.92), in: RoundedRectangle(cornerRadius: 14))
    }
}

#if os(iOS)
/// MTKView host for the Metal renderer.
struct MetalVideoView: UIViewRepresentable {
    let renderer: MetalVideoRenderer
    func makeUIView(context: Context) -> MTKView {
        let v = MTKView()
        renderer.configure(v)
        return v
    }
    func updateUIView(_ view: MTKView, context: Context) {}
}
#else
/// MTKView host for the Metal renderer.
struct MetalVideoView: NSViewRepresentable {
    let renderer: MetalVideoRenderer
    /// A click on the picture (mouse-and-keyboard mode captures the pointer with it).
    var onClick: () -> Void = {}
    func makeNSView(context: Context) -> MTKView {
        let v = StreamMTKView()
        v.onClick = onClick
        renderer.configure(v)
        return v
    }
    func updateNSView(_ nsView: MTKView, context: Context) { (nsView as? StreamMTKView)?.onClick = onClick }
}

final class StreamMTKView: MTKView {
    var onClick: () -> Void = {}
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) { onClick() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }
    override func mouseMoved(with event: NSEvent) { NSCursor.setHiddenUntilMouseMoves(true) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
}

/// Registers the hosting window as the stream window (for keyboard capture) and sets a 16:9 content aspect.
struct WindowAccessor: NSViewRepresentable {
    /// Configures the window once the view is actually in one (it often isn't yet on the next runloop turn).
    final class Probe: NSView {
        private var configured = false
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let w = window, !configured else { return }
            configured = true
            StreamWindow.current = w
            w.collectionBehavior.insert(.fullScreenPrimary)
            w.backgroundColor = .black
            w.titlebarAppearsTransparent = true
            w.titlebarSeparatorStyle = .none
            DispatchQueue.main.async {
                if AppSettings.shared.startFullscreen, !w.styleMask.contains(.fullScreen) { w.toggleFullScreen(nil) }
            }
        }
    }
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
#endif
