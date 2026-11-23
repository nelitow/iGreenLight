import SwiftUI
#if os(macOS)
import AppKit
#endif

@main
struct iGreenLightApp: App {
    @StateObject private var auth = AuthManager()
    @StateObject private var library = LibraryModel()
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #else
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif

    private func bootstrap() {
        // Hosting the unit tests: no sign-in, no network, no controllers.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
        #if DEBUG
        // `--ui-demo`: signed-in screens with made-up consoles and games, for checking the interface without an account.
        if CommandLine.arguments.contains("--ui-demo") {
            auth.gamertag = "Player One"
            auth.demo = true
            auth.state = .signedIn
            library.consoles = [
                XboxConsole(id: "F4001A2B3C4D5E6F", name: "Living room Xbox", consoleType: "XboxSeriesX", powerState: "On", playPath: nil, outOfHomeWarning: false, wirelessWarning: false),
                XboxConsole(id: "F4001A2B3C4D5E70", name: "Bedroom", consoleType: "XboxSeriesS", powerState: "ConnectedStandby", playPath: nil, outOfHomeWarning: false, wirelessWarning: true),
            ]
            library.cloudTitles = (1...36).map { CloudTitle(id: "demo\($0)", productId: "P\($0)", name: "Demo Game \($0)", supportsMKB: $0 % 7 == 0) }
            library.recentTitles = Array(library.cloudTitles.prefix(6))
            _ = GamepadInput.shared
            // `--ui-demo --settings`: open on the Settings tab.
            if CommandLine.arguments.contains("--settings") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NotificationCenter.default.post(name: .showSettingsTab, object: nil) }
            }
            return
        }
        #endif
        #if DEBUG
        // Developer tools (debug builds only). The self-test is fully offline: don't touch the Microsoft services.
        if SmartGlass.requested {
            // Headless LAN SmartGlass probe (scripts/smartglass.sh): connects to the console, logs, exits.
            if !SmartGlass.started { SmartGlass.started = true; Task { await SmartGlass.run(auth: auth); exit(0) } }
        } else if Probe.requested {
            // Headless hypothesis runner (scripts/probe.sh): signs in from the Keychain, runs the spec, exits.
            if !Probe.started { Probe.started = true; Task { await Probe.run(auth: auth); exit(0) } }
        } else if auth.state == .checking, !SelfTest.requested { auth.bootstrap() }
        #else
        if auth.state == .checking { auth.bootstrap() }
        #endif
        _ = GamepadInput.shared
    }

    #if os(iOS)
    // One window: the stream is a full-screen cover and Settings is a tab (see RootView).
    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(auth)
                .environmentObject(library)
                .environmentObject(AppSettings.shared)
                .onAppear { bootstrap() }
        }
    }
    #else
    var body: some Scene {
        WindowGroup("iGreenLight", id: "main") {
            RootView()
                .environmentObject(auth)
                .environmentObject(library)
                .environmentObject(AppSettings.shared)
                .frame(minWidth: 820, minHeight: 520)
                .onAppear { bootstrap() }
        }
        .commands {
            // Settings is a tab of the main window (reachable with the controller), not a separate window.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { NotificationCenter.default.post(name: .showSettingsTab, object: nil) }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .appInfo) {
                Button("Show Log") { Platform.reveal(Log.shared.logFileURL) }
            }
        }

        WindowGroup("Stream", id: "stream", for: StreamTarget.self) { $target in
            if let target {
                StreamContainer(target: target)
                    .environmentObject(auth)
                    .environmentObject(AppSettings.shared)
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 720)
        // Don't reopen (and silently start) a stream session on relaunch.
        .restorationBehavior(.disabled)

    }
    #endif
}

#if os(macOS)
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// End running streams on the server before exiting; give the requests up to 2 s.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let deletes = MainActor.assumeIsolated { StreamSession.stopAllForTermination() }
        guard !deletes.isEmpty else { return .terminateNow }
        // Two independent tasks, whichever comes first replies. (A task group would wait for the deletes even
        // after the timeout: awaiting another task's value doesn't end when the waiter is cancelled.)
        let reply = TerminationReply(sender)
        Task { @MainActor in
            for d in deletes { await d.value }
            reply.send()
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            reply.send()
        }
        return .terminateLater
    }

    @MainActor
    private final class TerminationReply {
        private let app: NSApplication
        private var sent = false
        nonisolated init(_ app: NSApplication) { self.app = app }
        func send() {
            guard !sent else { return }
            sent = true
            app.reply(toApplicationShouldTerminate: true)
        }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        log("App", "iGreenLight launched, log at \(Log.shared.logFileURL.path)")
        #if DEBUG
        if SelfTest.requested {
            Task { @MainActor in
                await SelfTest.run()
                exit(0)
            }
        }
        #endif
    }
}
#endif

/// Consoles + xCloud library state.
@MainActor
final class LibraryModel: ObservableObject {
    @Published var consoles: [XboxConsole] = []
    @Published var consolesError: String?
    @Published var loadingConsoles = false
    @Published var cloudTitles: [CloudTitle] = []
    @Published var recentTitles: [CloudTitle] = []
    @Published var cloudError: String?
    @Published var loadingCloud = false
    /// Bumped by `clear()`: a load that was running for the account that signed out must not publish its results.
    private var generation = 0

    /// Signed out: the next account must not see this one's consoles and games.
    func clear() {
        generation += 1
        consoles = []; consolesError = nil
        cloudTitles = []; recentTitles = []; cloudError = nil
    }

    func loadConsoles(_ auth: AuthManager) async {
        let gen = generation
        loadingConsoles = true; defer { loadingConsoles = false }
        consolesError = nil
        do {
            let t = try await auth.streamToken(cloud: false)
            var list = try await ConsoleAPI.homeServers(baseURL: auth.baseURL(cloud: false, token: t), gsToken: t.gsToken)
            if list.isEmpty, let web = auth.webToken {
                log("Consoles", "no servers from /v6/servers/home, trying smartglass")
                list = (try? await ConsoleAPI.smartglass(web: web)) ?? []
            }
            guard gen == generation else { return }
            consoles = list
            log("Consoles", "found \(list.count) console(s): \(list.map { "\($0.name) [\($0.powerState)]" })")
        } catch {
            log("Consoles", "load failed: \(error)")
            if gen == generation { consolesError = error.localizedDescription }
        }
    }

    func loadCloud(_ auth: AuthManager) async {
        guard auth.hasXCloud else { return }
        let gen = generation
        loadingCloud = true; defer { loadingCloud = false }
        cloudError = nil
        do {
            let t = try await auth.streamToken(cloud: true)
            let base = auth.baseURL(cloud: true, token: t)
            let all = try await GamePassAPI.titles(baseURL: base, gsToken: t.gsToken)
            let lang = AppSettings.shared.locale
            let hydrated = await GamePassAPI.hydrate(all, market: t.market, language: lang)
            let recent = (try? await GamePassAPI.titles(baseURL: base, gsToken: t.gsToken, recent: true)) ?? []
            guard gen == generation else { return }
            cloudTitles = hydrated
            let byId = Dictionary(cloudTitles.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            recentTitles = recent.compactMap { byId[$0.id] }
            log("GamePass", "\(cloudTitles.count) cloud titles, \(recentTitles.count) recent")
        } catch {
            log("GamePass", "load failed: \(error)")
            if gen == generation { cloudError = error.localizedDescription }
        }
    }
}
