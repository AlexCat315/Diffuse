import AssetPipeline
import Foundation
import NativeRHI
import NativeRendererValidation
import RenderBackend
import SceneRuntime
import SIMDCompat
import XCTest

/// Regression test for the per-frame BindingSet cache miss that used to occur
/// because the cache descriptor baked the upload ring's per-frame offset.
///
/// The mesh pass now binds ring-backed blocks at offset 0 and passes the
/// per-frame offset as a dynamic offset, so the descriptor (and hence the
/// cached BindingSet) is stable once the per-frame-slot set exists. After the
/// initial warmup, changing the number of visible instances must not create
/// any new BindingSets.
final class NativeBindingSetCacheTests: XCTestCase {
    #if os(macOS)
    func testMetalVaryingInstanceCountReusesBindingSets() throws {
        try varyingInstanceCountReusesBindingSets(.metal)
    }
    #endif
    #if os(Windows) || os(Linux)
    func testVulkanVaryingInstanceCountReusesBindingSets() throws {
        try varyingInstanceCountReusesBindingSets(.vulkan)
    }
    #endif

    private func varyingInstanceCountReusesBindingSets(_ api: GraphicsAPI) throws {
        let framesInFlight = 3
        let cube = BuiltinMesh.cube(color: SIMD3(repeating: 1))
        AssetRegistry.shared.registerForTesting(cube, at: 77)
        defer { AssetRegistry.shared.unregisterTestingMesh(at: 77) }
        let device = try RendererTestDevice.make(DeviceConfig(
            preferredBackends: [api], enableValidation: false, framesInFlight: framesInFlight))
        let renderer = try NativeRenderer(device: device)
        defer { try? device.waitUntilIdle() }

        func render(count: Int, frame: Int) throws {
            var packet = MeshProbeScene.packet(
                size: RenderDrawableSize(width: 96, height: 96), frame: frame)
            packet.renderSettings.shading.pbr = false
            packet.renderSettings.shading.depthPrepass = false
            // Isolate every instance so the number of draws moves 1:1 with the
            // visible instance count, exercising the worst-case churn path.
            packet.renderSettings.visibility.meshInstancing = false
            packet.scene.camera = RenderCamera(
                eye: SIMD3(0, 0, 40), target: .zero, near: 0.1, far: 100)
            packet.scene.instances = (0..<count).map { i in
                var t = matrix_identity_float4x4
                t.columns.3 = SIMD4(Float(i) * 1.5 - Float(count) * 0.75, 0, 0, 1)
                return RenderInstance(meshIndex: 77, transform: t)
            }
            try renderer.renderChecked(packet: packet)
        }

        // Warmup: one frame per in-flight frame slot.
        for frame in 0..<framesInFlight {
            try render(count: 10 + frame * 3, frame: frame)
        }
        let missesAfterWarmup = device.bindingSetCacheStats.misses

        // Vary the visible instance count across frame slots; every draw must
        // reuse the warmup set for its slot.
        let postWarmupCounts = [10, 19, 13, 16, 10, 19]
        for (index, count) in postWarmupCounts.enumerated() {
            try render(count: count, frame: framesInFlight + index)
            XCTAssertEqual(device.bindingSetCacheStats.misses, missesAfterWarmup,
                           "frame \(index) created a new BindingSet despite stable descriptors")
        }
        // Measure the hit delta for two frames with different counts. Each frame
        // performs one BindingSet lookup per mesh batch plus a fixed number for
        // the other passes, so the difference between the two deltas must equal
        // the difference in instance count — and every one must be a hit.
        let frameForA = framesInFlight + postWarmupCounts.count
        let statsBeforeA = device.bindingSetCacheStats
        try render(count: 12, frame: frameForA)
        let statsAfterA = device.bindingSetCacheStats
        let statsBeforeB = statsAfterA
        try render(count: 18, frame: frameForA + 1)
        let statsAfterB = device.bindingSetCacheStats

        XCTAssertEqual(statsAfterA.misses, statsBeforeA.misses)
        XCTAssertEqual(statsAfterB.misses, statsBeforeB.misses)
        let deltaA = statsAfterA.hits - statsBeforeA.hits
        let deltaB = statsAfterB.hits - statsBeforeB.hits
        XCTAssertEqual(deltaB - deltaA, 18 - 12)
    }
}
