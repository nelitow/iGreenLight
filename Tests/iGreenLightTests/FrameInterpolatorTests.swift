import Foundation
import Testing
import CoreVideo
import QuartzCore
import WebRTC
@testable import iGreenLight

/// Feeds a 30 fps game in a 60 fps stream (every frame sent twice) through the interpolator in real time and
/// checks what reaches the renderer: repeats dropped, one generated frame per game frame, the generated frame's
/// content halfway between its neighbours, and the two halves evenly spaced.
@Suite(.serialized) struct FrameInterpolatorTests {
    final class Sink: NSObject, RTCVideoRenderer, @unchecked Sendable {
        let lock = NSLock()
        var got: [(frame: RTCVideoFrame, at: CFTimeInterval)] = []
        func setSize(_ size: CGSize) {}
        func renderFrame(_ frame: RTCVideoFrame?) {
            guard let frame else { return }
            lock.lock(); got.append((frame, CACurrentMediaTime())); lock.unlock()
        }
    }

    static let w = 1920, h = 1080, box = 160

    /// Full-range NV12 frame: grey background, white box at x.
    static func frame(boxX: Int) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &pb)
        let p = pb!
        CVPixelBufferLockBaseAddress(p, [])
        let y = CVPixelBufferGetBaseAddressOfPlane(p, 0)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRowOfPlane(p, 0)
        for row in 0..<h { for col in 0..<w {
            let inBox = col >= boxX && col < boxX + box && row >= 460 && row < 460 + box
            y[row * bpr + col] = inBox ? 235 : UInt8(60 + (col / 40 % 2) * 20)
        } }
        let uv = CVPixelBufferGetBaseAddressOfPlane(p, 1)!.assumingMemoryBound(to: UInt8.self)
        memset(uv, 128, CVPixelBufferGetBytesPerRowOfPlane(p, 1) * h / 2)
        CVPixelBufferUnlockBaseAddress(p, [])
        return p
    }

    /// Column of the box's centre (mean x of bright luma in its rows).
    static func boxCentre(_ p: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(p, .readOnly); defer { CVPixelBufferUnlockBaseAddress(p, .readOnly) }
        let y = CVPixelBufferGetBaseAddressOfPlane(p, 0)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRowOfPlane(p, 0)
        let fullRange = CVPixelBufferGetPixelFormatType(p) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        let thr = fullRange ? 200 : 180
        var sum = 0.0, n = 0.0
        for row in stride(from: 470, to: 610, by: 4) { for col in 0..<w where Int(y[row * bpr + col]) > thr { sum += Double(col); n += 1 } }
        return n > 0 ? sum / n : -1
    }

    @Test func doublesA30fpsGameIn60fpsStream() async throws {
        guard FrameInterpolator.isSupported else { return }
        let sink = Sink()
        let fi = FrameInterpolator(downstream: sink)
        fi.enabled = true
        let step = 24   // px per game frame
        var inputs = Set<ObjectIdentifier>()
        // Let the model load first.

        let warmFrames = [Self.frame(boxX: 100), Self.frame(boxX: 100 + step)]
        for i in 0..<120 {
            let f = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: warmFrames[i % 2]), rotation: ._0, timeStampNs: Int64(i) * 33_333_333)
            f.timeStamp = Int32(bitPattern: UInt32(i * 3000))
            fi.renderFrame(f)
            try await Task.sleep(nanoseconds: 33_000_000)
            if fi.status.hasPrefix("on") { break }
        }

        try await Task.sleep(nanoseconds: 100_000_000)
        sink.lock.lock(); sink.got.removeAll(); sink.lock.unlock()

        // 60 stream frames = 30 game frames, each sent twice.
        var positions: [ObjectIdentifier: Int] = [:]
        let base = 1000
        let games = (0..<30).map { Self.frame(boxX: 300 + $0 * step) }
        var game: CVPixelBuffer?
        let t0 = CACurrentMediaTime()
        for i in 0..<60 {
            if i % 2 == 0 { game = games[i / 2] }
            let rtp = UInt32(1_000_000 + (base + i) * 1500)
            let f = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: game!), rotation: ._0, timeStampNs: Int64(base + i) * 16_666_667)
            f.timeStamp = Int32(bitPattern: rtp)
            inputs.insert(ObjectIdentifier(game!))
            positions[ObjectIdentifier(game!)] = 300 + (i / 2) * step
            fi.renderFrame(f)
            let next = t0 + Double(i + 1) / 60
            while CACurrentMediaTime() < next { usleep(500) }
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        fi.enabled = false

        sink.lock.lock(); let got = sink.got; sink.lock.unlock()
        let pbs = got.map { ($0.frame.buffer as! RTCCVPixelBuffer).pixelBuffer }
        let generated = pbs.indices.filter { !inputs.contains(ObjectIdentifier(pbs[$0])) }
        let real = pbs.indices.filter { inputs.contains(ObjectIdentifier(pbs[$0])) }
        print("FI test: status '\(fi.status)', \(got.count) shown, \(real.count) real, \(generated.count) generated")
        // The first game frame has nothing to blend with, so its repeat passes through too.
        #expect(real.count >= 30 && real.count <= 32)
        #expect(generated.count >= 27)

        // Each generated frame sits between the real frames around it.
        var errs: [Double] = []
        for g in generated where g > 0 && g + 1 < pbs.count {
            guard let a = positions[ObjectIdentifier(pbs[g - 1])], let b = positions[ObjectIdentifier(pbs[g + 1])] else { continue }
            let c = Self.boxCentre(pbs[g]) - Double(Self.box) / 2
            errs.append(abs(c - Double(a + b) / 2))
        }
        let meanErr = errs.reduce(0, +) / Double(max(errs.count, 1))
        print("FI test: generated box position error \(String(format: "%.1f", meanErr)) px (halfway would be 0, repeating a neighbour \(step / 2))")
        #expect(meanErr < Double(step) / 4)

        // Even spacing: all intervals between shown frames near 16.7 ms.
        let gaps = zip(got.dropFirst(), got).map { ($0.at - $1.at) * 1000 }.dropFirst(2).dropLast(2)
        let sorted = gaps.sorted()
        let median = sorted[sorted.count / 2], p90 = sorted[sorted.count * 9 / 10], p10 = sorted[sorted.count / 10]
        print("FI test: gaps p10 \(String(format: "%.1f", p10)) median \(String(format: "%.1f", median)) p90 \(String(format: "%.1f", p90)) ms")
        #expect(p10 > 10 && p90 < 24)
    }

    /// A still picture (every frame a repeat) must keep reaching the renderer, or it looks like a frozen stream.
    @Test func stillPictureKeepsFlowing() async throws {
        guard FrameInterpolator.isSupported else { return }
        let sink = Sink()
        let fi = FrameInterpolator(downstream: sink)
        fi.enabled = true
        let still = Self.frame(boxX: 500)
        let t0 = CACurrentMediaTime()
        for i in 0..<60 {
            let f = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: still), rotation: ._0, timeStampNs: Int64(i) * 16_666_667)
            f.timeStamp = Int32(bitPattern: UInt32(i * 1500))
            fi.renderFrame(f)
            let next = t0 + Double(i + 1) / 60
            while CACurrentMediaTime() < next { usleep(500) }
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        fi.enabled = false
        sink.lock.lock(); let n = sink.got.count; sink.lock.unlock()
        print("FI test: still picture, \(n) of 60 frames reached the renderer")
        #expect(n == 60)
    }
}
