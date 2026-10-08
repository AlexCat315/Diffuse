// NativeRHITests — Metal same-state storage hazard (WAW) encoding.
//
// Two copy passes write to the same texture while it stays in the
// copyDestination state the whole time. The access layer detects a
// write-after-write hazard and emits an ordering barrier even though the state
// never changes; Metal encodes the two blit encoders (its automatic hazard
// tracking orders tracked resources) and the second write must win. This
// verifies the Metal backend still encodes correctly under the orthogonal
// access-dependency model.

#if canImport(Metal)
import XCTest
import Metal
import simd
@testable import NativeRHI

final class MetalStorageHazardTests: XCTestCase {

    func testSameStateWriteAfterWriteOrdersAndSecondWins() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("No Metal device available")
        }
        let config = DeviceConfig(preferredBackends: [.metal], enableValidation: false)
        let device = try Device.make(config)

        let w = 4, h = 4
        let bytesPerRow = w * 4
        let byteCount = bytesPerRow * h

        let target = try device.makeTexture(
            TextureDescriptor(
                width: w, height: h, format: .rgba8Unorm,
                usage: [.transferDestination, .sampled]
            )
        )

        // Two distinct source buffers: red then blue.
        let redBuffer = try device.makeBuffer(
            BufferDescriptor(size: byteCount, usage: .transferSource, label: "red")
        )
        let blueBuffer = try device.makeBuffer(
            BufferDescriptor(size: byteCount, usage: .transferSource, label: "blue")
        )

        var redBytes = [UInt8](repeating: 0, count: byteCount)
        var blueBytes = [UInt8](repeating: 0, count: byteCount)
        for pixel in 0..<(w * h) {
            let base = pixel * 4
            redBytes[base] = 255; redBytes[base + 3] = 255
            blueBytes[base + 2] = 255; blueBytes[base + 3] = 255
        }
        try device.uploadBufferData(redBuffer, data: Data(redBytes))
        try device.uploadBufferData(blueBuffer, data: Data(blueBytes))

        try device.beginFrame()
        let cmd = CommandBuffer()
        cmd.copyPass { encoder in
            encoder.uploadBufferToTexture(
                buffer: redBuffer, bytesPerRow: bytesPerRow,
                texture: target, width: w, height: h
            )
        }
        cmd.copyPass { encoder in
            encoder.uploadBufferToTexture(
                buffer: blueBuffer, bytesPerRow: bytesPerRow,
                texture: target, width: w, height: h
            )
        }
        try device.submit(cmd)
        device.endFrame()
        try device.waitUntilIdle()

        var pixels = [UInt8](repeating: 0, count: byteCount)
        try pixels.withUnsafeMutableBufferPointer { buf in
            try device.readTextureData(
                target, width: w, height: h, bytesPerRow: bytesPerRow,
                into: UnsafeMutableRawBufferPointer(buf)
            )
        }

        // The second write (blue) must win: R=0, B=255 at the first pixel.
        XCTAssertEqual(pixels[0], 0)   // red channel
        XCTAssertEqual(pixels[2], 255) // blue channel
        XCTAssertEqual(pixels[3], 255) // alpha
    }
}
#endif
