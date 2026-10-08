// NativeRHITests — Metal clear -> submit -> readback integration.
//
// Records a single render pass that clears an offscreen color target to a known
// color, submits it asynchronously, waits for idle, reads the pixels back, and
// asserts the cleared color. This exercises the render encoder, load action,
// store action, asynchronous submit + completion callback, and the readback
// path end-to-end on the real GPU.

#if canImport(Metal)
import XCTest
import Metal
import simd
@testable import NativeRHI

final class MetalClearReadbackTests: XCTestCase {

    func testClearThenReadbackMatches() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("No Metal device available")
        }
        let config = DeviceConfig(preferredBackends: [.metal], enableValidation: false)
        let device = try Device.make(config)

        let w = 4, h = 4
        let target = try device.makeTexture(
            TextureDescriptor(
                width: w, height: h, format: .rgba8Unorm,
                usage: [.colorTarget, .sampled]
            )
        )
        let clear = SIMD4<Float>(0.2, 0.6, 0.9, 1.0)

        try device.beginFrame()
        let cmd = CommandBuffer()
        try cmd.renderPass(
            descriptor: RenderPassDescriptor(
                colorTargets: [
                    RenderColorTarget(texture: target, loadAction: .clear(clear), store: true)
                ]
            )
        ) { _ in }
        try device.submit(cmd)
        device.endFrame()
        try device.waitUntilIdle()

        let bytesPerRow = w * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * h)
        try pixels.withUnsafeMutableBufferPointer { buf in
            try device.readTextureData(
                target, width: w, height: h, bytesPerRow: bytesPerRow,
                into: UnsafeMutableRawBufferPointer(buf)
            )
        }

        let r = Float(pixels[0]) / 255.0
        let g = Float(pixels[1]) / 255.0
        let b = Float(pixels[2]) / 255.0
        XCTAssertEqual(r, clear.x, accuracy: 0.12)
        XCTAssertEqual(g, clear.y, accuracy: 0.12)
        XCTAssertEqual(b, clear.z, accuracy: 0.12)
    }
}
#endif
