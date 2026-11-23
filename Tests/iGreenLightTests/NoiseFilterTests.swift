import Foundation
import Testing
import CoreVideo
import QuartzCore
import WebRTC
@testable import iGreenLight

/// A still scene with fresh noise in every frame: the filtered output should be closer to the clean picture than
/// the input, repeats should come out identical, and with compare on the left half should be the original.
@Suite(.serialized) struct NoiseFilterTests {
    static let w = 1920, h = 1080

    static func clean(_ col: Int, _ row: Int) -> Int { 60 + (col / 64 % 2) * 40 + row / 20 }

    static func frame(seed: UInt64, noise: Int) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &pb)
        let p = pb!
        CVPixelBufferLockBaseAddress(p, [])
        let y = CVPixelBufferGetBaseAddressOfPlane(p, 0)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRowOfPlane(p, 0)
        var s = seed &* 6364136223846793005 &+ 1
        for row in 0..<h { for col in 0..<w {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            let n = Int((s >> 33) % UInt64(2 * noise + 1)) - noise
            y[row * bpr + col] = UInt8(max(0, min(255, clean(col, row) + n)))
        } }
        memset(CVPixelBufferGetBaseAddressOfPlane(p, 1)!, 128, CVPixelBufferGetBytesPerRowOfPlane(p, 1) * h / 2)
        CVPixelBufferUnlockBaseAddress(p, [])
        return p
    }

    /// Mean absolute luma error against the clean picture over a region, in 8-bit full-range steps.
    static func error(_ p: CVPixelBuffer, x0: Int, x1: Int) -> Double {
        CVPixelBufferLockBaseAddress(p, .readOnly); defer { CVPixelBufferUnlockBaseAddress(p, .readOnly) }
        let y = CVPixelBufferGetBaseAddressOfPlane(p, 0)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRowOfPlane(p, 0)
        let fmt = CVPixelBufferGetPixelFormatType(p)
        guard CVPixelBufferGetHeightOfPlane(p, 0) >= h, bpr >= w else { return -1 }
        let video = fmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        var sum = 0.0, n = 0.0
        for row in stride(from: 100, to: h - 100, by: 7) { for col in stride(from: x0, to: x1, by: 5) {
            var v = Double(y[row * bpr + col])
            if video { v = (v - 16) * 255 / 219 }
            sum += abs(v - Double(clean(col, row))); n += 1
        } }
        return sum / n
    }

    final class Sink: NSObject, RTCVideoRenderer, @unchecked Sendable {
        let lock = NSLock()
        var got: [RTCVideoFrame] = []
        func setSize(_ size: CGSize) {}
        func renderFrame(_ frame: RTCVideoFrame?) { if let frame { lock.lock(); got.append(frame); lock.unlock() } }
    }

    @Test func reducesNoiseKeepsRepeatsAndCompares() async throws {
        guard NoiseFilter.isSupported else { return }
        let sink = Sink()
        let nf = NoiseFilter(downstream: sink)
        nf.reduction = .medium
        let frames = (0..<40).map { Self.frame(seed: UInt64($0), noise: 12) }
        func feed(_ i: Int, _ pb: CVPixelBuffer) {
            let f = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: pb), rotation: ._0, timeStampNs: Int64(i) * 33_333_333)
            f.timeStamp = Int32(bitPattern: UInt32(i * 3000))
            nf.renderFrame(f)
        }
        // Until the model is loaded frames pass through.
        for i in 0..<40 {
            feed(i, frames[i])
            try await Task.sleep(nanoseconds: 33_000_000)
            if nf.status.contains(" ms") { break }
        }
        for i in 40..<60 { feed(i, frames[i % 40]); try await Task.sleep(nanoseconds: 33_000_000) }
        // A repeat of the last frame.
        feed(59, frames[59 % 40])
        try await Task.sleep(nanoseconds: 100_000_000)
        sink.lock.lock(); let got = sink.got; sink.got.removeAll(); sink.lock.unlock()
        let last = (got[got.count - 2].buffer as! RTCCVPixelBuffer).pixelBuffer
        let repeated = (got[got.count - 1].buffer as! RTCCVPixelBuffer).pixelBuffer
        let before = Self.error(frames[19], x0: 0, x1: Self.w), after = Self.error(last, x0: 0, x1: Self.w)
        print("NF test: status '\(nf.status)', error vs clean: input \(String(format: "%.2f", before)), filtered \(String(format: "%.2f", after))")
        #expect(after < before * 0.75)
        #expect(last === repeated)

        nf.compare = true
        for i in 60..<66 { feed(i, frames[i % 40]); try await Task.sleep(nanoseconds: 33_000_000) }
        try await Task.sleep(nanoseconds: 100_000_000)
        sink.lock.lock(); let cmp = (sink.got.last!.buffer as! RTCCVPixelBuffer).pixelBuffer; sink.lock.unlock()
        let left = Self.error(cmp, x0: 0, x1: Self.w / 2 - 8), right = Self.error(cmp, x0: Self.w / 2 + 8, x1: Self.w)
        print("NF test: compare, left (original) \(String(format: "%.2f", left)), right (filtered) \(String(format: "%.2f", right))")
        #expect(left > right * 1.3)
        nf.reduction = .off
    }
}
