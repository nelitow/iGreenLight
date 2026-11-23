import Foundation
import AVFAudio
import AudioToolbox
import WebRTC

/// Audio output, replacing libwebrtc's built-in devices.
///
/// The built-in iOS device is made for calls: a VoiceProcessingIO unit (echo cancellation, gain control),
/// mono, and a play-and-record session. Game audio through that is thin, mono and can cut out. The built-in
/// macOS device opens whichever output was the default when the stream started and stays on it, so connecting
/// AirPods mid-stream doesn't move the sound, and it talks to the device's channels directly.
///
/// This one is a plain output unit fed 48 kHz interleaved stereo: RemoteIO with a `.playback` session on iOS,
/// the default-output unit on macOS, which follows the system output as it changes and converts to whatever
/// format and channel layout that device has. No microphone; nothing is recorded.
final class GameAudioDevice: NSObject, RTCAudioDevice, @unchecked Sendable {
    private static let sampleRate = 48_000.0
    private static let channels = 2

    private var unit: AudioUnit?
    private var delegate: RTCAudioDeviceDelegate?
    /// Read on the audio render thread.
    fileprivate var playout: RTCAudioDeviceGetPlayoutDataBlock?
    private var playing = false
    private var observers: [NSObjectProtocol] = []
    /// Playback gain, 0...1. Written on the main thread, read on the render thread; a stale read for one
    /// buffer only delays a volume change by a few milliseconds.
    nonisolated(unsafe) static var gain: Float = 1

    /// Percent to gain on a squared curve, so the slider's middle sounds like half volume rather than barely
    /// quieter than full.
    static func setVolume(percent: Int) {
        let v = Float(min(100, max(0, percent))) / 100
        gain = v * v
    }

    // MARK: RTCAudioDevice — parameters
    var deviceInputSampleRate: Double { Self.sampleRate }
    var inputIOBufferDuration: TimeInterval { 0.01 }
    var inputNumberOfChannels: Int { 1 }
    var inputLatency: TimeInterval { 0 }
    var deviceOutputSampleRate: Double { Self.sampleRate }
    var outputNumberOfChannels: Int { Self.channels }
    #if os(iOS)
    var outputIOBufferDuration: TimeInterval { max(0.005, AVAudioSession.sharedInstance().ioBufferDuration) }
    var outputLatency: TimeInterval { AVAudioSession.sharedInstance().outputLatency }
    #else
    var outputIOBufferDuration: TimeInterval { 0.01 }
    var outputLatency: TimeInterval { 0 }
    #endif

    // MARK: Lifecycle
    private(set) var isInitialized = false

    func initialize(with delegate: RTCAudioDeviceDelegate) -> Bool {
        self.delegate = delegate
        playout = delegate.getPlayoutData
        isInitialized = true
        #if os(iOS)
        let nc = NotificationCenter.default
        observers = [
            // A call or Siri took the audio: start again when it's handed back.
            nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] n in
                guard let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
                self?.delegate?.dispatchAsync { self?.resume() }
            },
            nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil) { [weak self] _ in
                self?.delegate?.dispatchAsync { self?.rebuild() }
            },
        ]
        #endif
        return true
    }

    func terminateDevice() -> Bool {
        _ = stopPlayout()
        disposeUnit()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        playout = nil
        delegate = nil
        isInitialized = false
        return true
    }

    // MARK: Playout
    var isPlayoutInitialized: Bool { unit != nil }

    func initializePlayout() -> Bool {
        if unit != nil { return true }
        #if os(iOS)
        let subType = kAudioUnitSubType_RemoteIO
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setPreferredSampleRate(Self.sampleRate)
            try session.setPreferredIOBufferDuration(0.005)
            try session.setActive(true)
        } catch {
            log("Audio", "audio session setup failed: \(error.localizedDescription)")
        }
        #else
        // Follows the system's default output device, including when it changes mid-stream.
        let subType = kAudioUnitSubType_DefaultOutput
        #endif

        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: subType,
                                             componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &desc) else { log("Audio", "no output unit component"); return false }
        var u: AudioUnit?
        guard AudioComponentInstanceNew(component, &u) == noErr, let u else { log("Audio", "couldn't create the output unit"); return false }

        // What WebRTC hands over: interleaved 16-bit stereo. The unit converts to whatever the route wants.
        let bytesPerFrame = UInt32(Self.channels * 2)
        var format = AudioStreamBasicDescription(mSampleRate: Self.sampleRate, mFormatID: kAudioFormatLinearPCM,
                                                 mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                                                 mBytesPerPacket: bytesPerFrame, mFramesPerPacket: 1, mBytesPerFrame: bytesPerFrame,
                                                 mChannelsPerFrame: UInt32(Self.channels), mBitsPerChannel: 16, mReserved: 0)
        var callback = AURenderCallbackStruct(inputProc: gameAudioRender, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        var status = AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format,
                                          UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        if status == noErr {
            status = AudioUnitSetProperty(u, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback,
                                          UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        }
        if status == noErr { status = AudioUnitInitialize(u) }
        guard status == noErr else {
            log("Audio", "output unit setup failed: \(status)")
            AudioComponentInstanceDispose(u)
            return false
        }
        unit = u
        #if os(iOS)
        let route = session.currentRoute.outputs.map { "\($0.portName) (\($0.portType.rawValue))" }.joined(separator: ", ")
        log("Audio", "output ready: 48 kHz stereo, device \(Int(session.sampleRate)) Hz, buffer \(String(format: "%.1f", session.ioBufferDuration * 1000)) ms, route \(route)")
        #else
        log("Audio", "output ready: 48 kHz stereo to the system default output")
        #endif
        return true
    }

    var isPlaying: Bool { playing }

    func startPlayout() -> Bool {
        guard let unit else { return false }
        let status = AudioOutputUnitStart(unit)
        playing = status == noErr
        log("Audio", playing ? "playout started" : "playout failed to start: \(status)")
        return playing
    }

    func stopPlayout() -> Bool {
        if let unit, playing { AudioOutputUnitStop(unit) }
        playing = false
        return true
    }

    #if os(iOS)
    private func resume() {
        guard playing, let unit else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        let status = AudioOutputUnitStart(unit)
        log("Audio", "resumed after interruption: \(status)")
    }

    private func rebuild() {
        let was = playing
        _ = stopPlayout()
        disposeUnit()
        if initializePlayout(), was { _ = startPlayout() }
    }
    #endif

    private func disposeUnit() {
        guard let u = unit else { return }
        AudioUnitUninitialize(u)
        AudioComponentInstanceDispose(u)
        unit = nil
    }

    // MARK: Recording — not used; the microphone is never opened.
    var isRecordingInitialized: Bool { false }
    func initializeRecording() -> Bool { true }
    var isRecording: Bool { false }
    func startRecording() -> Bool { true }
    func stopRecording() -> Bool { true }
}

/// Render thread: ask WebRTC for the next frames; silence if it has none.
private func gameAudioRender(_ refCon: UnsafeMutableRawPointer, _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                             _ timestamp: UnsafePointer<AudioTimeStamp>, _ bus: UInt32, _ frames: UInt32,
                             _ data: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    guard let data else { return noErr }
    let device = Unmanaged<GameAudioDevice>.fromOpaque(refCon).takeUnretainedValue()
    if let playout = device.playout, playout(flags, timestamp, Int(bus), frames, data) == noErr {
        let gain = GameAudioDevice.gain
        if gain < 0.999 {
            for buffer in UnsafeMutableAudioBufferListPointer(data) {
                guard let p = buffer.mData?.assumingMemoryBound(to: Int16.self) else { continue }
                let n = Int(buffer.mDataByteSize) / 2
                for i in 0..<n { p[i] = Int16(Float(p[i]) * gain) }
            }
        }
        return noErr
    }
    for buffer in UnsafeMutableAudioBufferListPointer(data) {
        if let p = buffer.mData { memset(p, 0, Int(buffer.mDataByteSize)) }
    }
    flags.pointee.insert(.unitRenderAction_OutputIsSilence)
    return noErr
}
