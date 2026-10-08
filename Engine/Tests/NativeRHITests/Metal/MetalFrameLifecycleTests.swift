// NativeRHITests — Metal frame lifecycle + deferred destruction.
//
// Drives several frames through the frontend frame ring, submitting clears
// each time, retiring resources, and confirms no crash / no use-after-free.
// The frontend defers `destroy*` calls to GPU completion; the backend only
// releases concrete Metal objects when invoked.

#if canImport(Metal)
import XCTest
import Metal
import simd
@testable import NativeRHI

final class MetalFrameLifecycleTests: XCTestCase {

    func testFrameLifecycleAndDeferredDestroy() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("No Metal device available")
        }
        let config = DeviceConfig(preferredBackends: [.metal], enableValidation: false, framesInFlight: 2)
        let device = try Device.make(config)

        let target = try device.makeTexture(
            TextureDescriptor(
                width: 4, height: 4, format: .rgba8Unorm,
                usage: [.colorTarget, .sampled]
            )
        )

        // Several frames in flight; submit a clear each frame.
        for _ in 0..<3 {
            try device.beginFrame()
            let cmd = CommandBuffer()
            try cmd.renderPass(
                descriptor: RenderPassDescriptor(
                    colorTargets: [
                        RenderColorTarget(
                            texture: target,
                            loadAction: .clear(SIMD4<Float>(0, 0, 0, 1)),
                            store: true
                        )
                    ]
                )
            ) { _ in }
            try device.submit(cmd)
            device.endFrame()
        }

        // Retire the texture and ensure deferred destruction does not crash.
        device.destroy(target)

        try device.waitUntilIdle()
        // Reaching here without a crash / use-after-free is the pass condition.
    }
}
#endif
