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

    func testCPUProfilePreservesRenderingAndAccumulatesSubmissions() throws {
        let device = try Device.make(DeviceConfig(preferredBackends: [.metal], enableValidation: true))
        let target = try device.makeTexture(TextureDescriptor(width: 4, height: 4, format: .rgba8Unorm,
            usage: [.colorTarget, .transferSource]))
        let commands = CommandBuffer()
        commands.renderPass(descriptor: RenderPassDescriptor(colorTargets: [
            RenderColorTarget(texture: target, loadAction: .clear(SIMD4<Float>(1, 0, 0, 1)))])) { _ in }
        func render(_ profile: SubmissionCPUProfile?) throws -> [UInt8] {
            try device.beginFrame()
            do { try device.submit(commands, cpuProfile: profile) }
            catch { device.endFrame(); throw error }
            device.endFrame()
            try device.waitUntilIdle()
            var bytes = [UInt8](repeating: 0, count: 64)
            try bytes.withUnsafeMutableBytes {
                try device.readTextureData(target, width: 4, height: 4, bytesPerRow: 16, into: $0)
            }
            return bytes
        }
        let reference = try render(nil)
        let profile = SubmissionCPUProfile()
        XCTAssertEqual(try render(profile), reference)
        XCTAssertEqual(Array(reference.prefix(4)), [255, 0, 0, 255])
        let first = [profile.validationNanoseconds, profile.planningNanoseconds,
            profile.encodingNanoseconds, profile.queueSubmitNanoseconds]
        XCTAssertTrue(first.allSatisfy { $0 > 0 })
        XCTAssertEqual(try render(profile), reference)
        let accumulated = [profile.validationNanoseconds, profile.planningNanoseconds,
            profile.encodingNanoseconds, profile.queueSubmitNanoseconds]
        XCTAssertTrue(zip(accumulated, first).allSatisfy { $0 > $1 })
    }

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
