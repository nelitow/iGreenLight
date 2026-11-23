import Foundation
import SwiftUI

enum StreamQuality: String, CaseIterable, Identifiable, Codable {
    // The raw values are what is stored: a new tier gets a new name and the others keep theirs.
    case p720, p720HQ, p1080, p1080HQ, p1440
    var id: String { rawValue }
    var label: String {
        switch self { case .p720: "720p"; case .p720HQ: "720p HQ"; case .p1080: "1080p"; case .p1080HQ: "1080p HQ"; case .p1440: "1440p (best)" }
    }
    /// Value for the control-channel `userRequestedResolutionUpdate` message (what the official web client sends).
    /// Typical bitrates: 720 ≈ 2 Mbps, 1080 ≈ 9 Mbps, 1080HQ ≈ 12 Mbps, 1440 ≈ 17–28 Mbps.
    var resolutionAlias: String {
        switch self { case .p720: "720"; case .p720HQ: "720HQ"; case .p1080: "1080"; case .p1080HQ: "1080HQ"; case .p1440: "1440" }
    }
    /// os.name in X-MS-Device-Info picks the server-side profile (Better xCloud's trick).
    var osName: String {
        // The "720HQ" alias is a Remote Play control message. Cloud gaming has no profile known to match it, so
        // 720p HQ asks for the 720p one there; what the cloud sends for it is unverified.
        switch self { case .p720, .p720HQ: "android"; case .p1080: "windows"; case .p1080HQ, .p1440: "tizen" }
    }
    var height: Int {
        switch self { case .p720, .p720HQ: 720; case .p1080, .p1080HQ: 1080; case .p1440: 1440 }
    }
}

enum ScalingMode: String, CaseIterable, Identifiable, Codable {
    case fit, zoom, stretch
    var id: String { rawValue }
    var label: String {
        switch self { case .fit: "Fit (letterbox)"; case .zoom: "Zoom (fill, crop)"; case .stretch: "Stretch" }
    }
}

enum Upscaler: String, CaseIterable, Identifiable, Codable {
    case off, metalFX, videoToolbox
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: "Off (bilinear)"
        case .metalFX: "MetalFX Spatial"
        case .videoToolbox: "VideoToolbox ML + MetalFX"
        }
    }
}

/// SDR→EDR highlight expansion: how far above SDR white the brightest pixels may go (capped by the display's headroom).
enum EDRExpansion: String, CaseIterable, Identifiable, Codable {
    case off, subtle, medium, strong
    var id: String { rawValue }
    var label: String {
        switch self { case .off: "Off (SDR)"; case .subtle: "Subtle (up to 1.5×)"; case .medium: "Medium (up to 2.5×)"; case .strong: "Strong (up to 4×)" }
    }
    var peak: Float {
        switch self { case .off: 1; case .subtle: 1.5; case .medium: 2.5; case .strong: 4 }
    }
}

// MARK: Experimental (Diagnostics) settings

enum VideoCodecPreference: String, CaseIterable, Identifiable, Codable {
    case h264High, h264High51, h264Main, h264Baseline, hevcMain, hevcMain10, vp9p0, vp9p2, av1
    var id: String { rawValue }
    var label: String {
        switch self {
        case .h264High: "H.264 High 640c1f"
        case .h264High51: "H.264 High L5.1 640033"
        case .h264Main: "H.264 Main 4d0033 (default)"
        case .h264Baseline: "H.264 Constrained Baseline 42e01f"
        case .hevcMain: "HEVC Main (profile-id 1)"
        case .hevcMain10: "HEVC Main 10 (profile-id 2)"
        case .vp9p0: "VP9 profile 0"
        case .vp9p2: "VP9 profile 2 (10-bit)"
        case .av1: "AV1 main (dav1d, software)"
        }
    }
}

/// `os.name` in X-MS-Device-Info and `settings.osName` in /play; picks the server-side client profile.
enum ClientProfile: String, CaseIterable, Identifiable, Codable {
    case auto = "", android, windows, tizen, webOS, xboxOS, kepler
    var id: String { rawValue }
    var label: String { self == .auto ? "From Quality setting" : rawValue }
}

/// Client identity sent in X-MS-Device-Info.appInfo / browser.
enum SDKProfile: String, CaseIterable, Identifiable, Codable {
    case greenlight, current
    var id: String { rawValue }
    var label: String { self == .greenlight ? "Greenlight (app 21.1.98, SDK 8.5.3, Chrome 119)" : "Current web (app 26.1.97, SDK 10.3.7, Chrome 140)" }
    var appVersion: String { self == .greenlight ? "21.1.98" : "26.1.97" }
    var sdkVersion: String { self == .greenlight ? "8.5.3" : "10.3.7" }
    var browserVersion: String { self == .greenlight ? "119.0" : "140.0.3485.54" }
}

enum ReportedDisplaySize: String, CaseIterable, Identifiable, Codable {
    case auto, w1920h1080, w1920h1200, w2560h1440, w2560h1600, w3840h2160, w4096h2160
    var id: String { rawValue }
    var size: (Int, Int)? {
        switch self {
        case .auto: nil
        case .w1920h1080: (1920, 1080)
        case .w1920h1200: (1920, 1200)
        case .w2560h1440: (2560, 1440)
        case .w2560h1600: (2560, 1600)
        case .w3840h2160: (3840, 2160)
        case .w4096h2160: (4096, 2160)
        }
    }
    var label: String { size.map { "\($0.0)×\($0.1)" } ?? "From Quality / 16:10 setting" }
}

/// App settings, backed by UserDefaults. Mirrors Greenlight's settings pages where it makes sense.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    #if os(iOS)
    // A phone screen is about 1200 px tall in landscape: 1440p would only cost bitrate and battery.
    @AppStorage("quality") var quality: StreamQuality = .p1080HQ
    /// Show the on-screen gamepad while no controller is connected.
    @AppStorage("touchControls") var touchControls = true
    @AppStorage("touchHaptics") var touchHaptics = true
    #else
    @AppStorage("quality") var quality: StreamQuality = .p1440
    /// Keep AWDL off while a stream runs (`AWDLHold`). Does nothing until the helper is installed.
    @AppStorage("awdlOffWhileStreaming") var awdlOffWhileStreaming = true
    #endif
    @AppStorage("request1610") var request1610 = false
    @AppStorage("scaling") var scaling: ScalingMode = .fit
    @AppStorage("upscaler") var upscaler: Upscaler = .metalFX
    @AppStorage("deband") var deband = true
    /// Contrast-adaptive sharpening, 0 (off) ... 10.
    @AppStorage("sharpness") var sharpness = 3
    /// Back the sharpening off, and the debanding up, while the stream is heavily compressed (`SharpenGovernor`).
    @AppStorage("adaptiveSharpening") var adaptiveSharpening = true
    /// Luma-guided chroma upsampling in the renderer's YUV→RGB pass.
    @AppStorage("chromaUpsampling") var chromaUpsampling = true
    /// Lower the upscaler while the device is hot or the GPU can't keep up (`UpscalerGovernor`).
    @AppStorage("protectFrameRate") var protectFrameRate = true
    @AppStorage("ambientBars") var ambientBars = true
    @AppStorage("edrExpansion") var edrExpansion: EDRExpansion = .off
    @AppStorage("holdResolution") var holdResolution = true
    /// Show frames on an even cadence from a short queue (`FramePacer`); costs about half a stream frame of latency.
    @AppStorage("framePacing") var framePacing = false
    /// Unpaced only: draw each frame when the decoder delivers it instead of at the next display tick.
    @AppStorage("drawOnArrival") var drawOnArrival = true
    /// Insert a VideoToolbox ML-interpolated frame between game frames (`FrameInterpolator`), macOS 26+.
    @AppStorage("frameGeneration") var frameGeneration = false
    /// VideoToolbox ML temporal noise filter on the decoded frames (`NoiseFilter`), macOS 26+.
    @AppStorage("noiseReduction") var noiseReduction: NoiseReduction = .off
    /// Left half of the picture unprocessed, for judging the image settings.
    @AppStorage("compareSplit") var compareSplit = false
    @AppStorage("startFullscreen") var startFullscreen = true
    @AppStorage("locale") var locale = "en-US"
    @AppStorage("vibration") var vibration = true
    @AppStorage("keyboardAsGamepad") var keyboardAsGamepad = true
    /// Send the keyboard and mouse to the game as themselves instead of mapping the keyboard to a gamepad.
    @AppStorage("mouseKeyboard") var mouseKeyboard = false
    /// For games that only take a controller: the mouse moves the right stick and its buttons are the triggers.
    @AppStorage("mouseAim") var mouseAim = false
    /// 1...10; see `MouseStick.fullSpeed(sensitivity:)`.
    @AppStorage("mouseAimSensitivity") var mouseAimSensitivity = 5
    /// Percent of the stick's travel the game ignores, which slow mouse movement is lifted past.
    @AppStorage("mouseAimDeadZone") var mouseAimDeadZone = 10
    /// 0 linear, 1 boosted, 2 strong; see `MouseStick.curve(setting:)`.
    @AppStorage("mouseAimCurve") var mouseAimCurve = 0
    /// Remote Play only: the controller is paired to the console itself, so the app is just the screen. It
    /// registers no gamepad with the console and sends the game no input.
    @AppStorage("controllerOnConsole") var controllerOnConsole = false
    @AppStorage("showStats") var showStats = false
    @AppStorage("consoleAddressCandidate") var consoleAddressCandidate = true
    @AppStorage("xhomeRegionOverride") var xhomeRegionOverride = ""
    @AppStorage("xcloudRegionOverride") var xcloudRegionOverride = ""

    // Experimental / Diagnostics
    @AppStorage("diagnosticsEnabled") var diagnosticsEnabled = false
    @AppStorage("diagnosticsOverlay") var diagnosticsOverlay = true
    @AppStorage("codecPreference") var codecPreference: VideoCodecPreference = .h264Main
    @AppStorage("codecOnlyPreferred") var codecOnlyPreferred = false
    @AppStorage("clientProfile") var clientProfile: ClientProfile = .auto
    @AppStorage("sdkProfile") var sdkProfile: SDKProfile = .greenlight
    /// 0 = no b=AS line (server default).
    @AppStorage("maxVideoBitrateKbps") var maxVideoBitrateKbps = 0
    @AppStorage("reportedDisplaySize") var reportedDisplaySize: ReportedDisplaySize = .auto
    // Transport options (`WebRTCClient.Options`), read when a stream starts. None has been tried against a console.
    @AppStorage("offerRTX") var offerRTX = false
    @AppStorage("lowLatencyPlayout") var lowLatencyPlayout = false
    @AppStorage("fastAudioCatchUp") var fastAudioCatchUp = false
    @AppStorage("frameTimingFeedback") var frameTimingFeedback = false

    var osName: String { clientProfile == .auto ? quality.osName : clientProfile.rawValue }

    /// Settings that affect stream negotiation, recorded with each diagnostics run.
    var experimentalSnapshot: [String: Any] {
        ["quality": quality.label, "osName": osName, "clientProfile": clientProfile.rawValue.isEmpty ? "auto" : clientProfile.rawValue,
         "sdkProfile": sdkProfile.rawValue, "codecPreference": codecPreference.rawValue, "codecOnlyPreferred": codecOnlyPreferred,
         "maxVideoBitrateKbps": maxVideoBitrateKbps, "requestedSize": "\(requestedSize.width)x\(requestedSize.height)",
         "request1610": request1610, "reportedDisplaySize": reportedDisplaySize.rawValue, "upscaler": upscaler.rawValue, "deband": deband, "sharpness": sharpness, "ambientBars": ambientBars, "edrExpansion": edrExpansion.rawValue, "holdResolution": holdResolution, "framePacing": framePacing, "frameGeneration": frameGeneration, "noiseReduction": noiseReduction.rawValue, "compareSplit": compareSplit,
         "drawOnArrival": drawOnArrival, "chromaUpsampling": chromaUpsampling, "adaptiveSharpening": adaptiveSharpening,
         "protectFrameRate": protectFrameRate, "offerRTX": offerRTX, "lowLatencyPlayout": lowLatencyPlayout,
         "fastAudioCatchUp": fastAudioCatchUp, "frameTimingFeedback": frameTimingFeedback,
         "consoleAddressCandidate": consoleAddressCandidate]
    }

    /// Size we tell the server we want (dimensionschanged + displayInfo).
    var requestedSize: (width: Int, height: Int) {
        if let s = reportedDisplaySize.size { return s }
        switch (quality.height, request1610) {
        case (720, true): return (1280, 800)
        case (720, false): return (1280, 720)
        case (1440, true): return (2560, 1600)
        case (1440, false): return (2560, 1440)
        case (_, true): return (1920, 1200)
        default: return (1920, 1080)
        }
    }
}
