import AssetPipeline
import Foundation
import NativeRHI
import NativeRendererValidation
import Testing
@testable import RenderBackend

@Suite("Native renderer GPU regression", .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["GUAVA_RUN_GPU_SMOKE_TESTS"] == "1",
        "set GUAVA_RUN_GPU_SMOKE_TESTS=1 for GPU regression"))
struct RenderBackendGPUSmokeTests {
    @Test("all production scene passes render readable, nonuniform pixels",
        arguments: ["mesh", "pbr", "post", "stylized", "particles", "simulation", "animated"])
    func productionScenes(scene: String) throws {
        let device = try Device.make(DeviceConfig(enableValidation: true))
        let renderer = try NativeRenderer(device: device)
        let size = RenderDrawableSize(width: 192, height: 128)
        if scene == "animated" { AssetRegistry.shared.registerForTesting(AnimatedProbeScene.skinnedFixture(), at: 2) }
        defer { if scene == "animated" { AssetRegistry.shared.unregisterTestingMesh(at: 2) } }
        var packet: RenderPacket
        switch scene {
        case "mesh": packet = MeshProbeScene.packet(size: size)
        case "pbr": packet = PBRProbeScene.packet(size: size)
        case "post": packet = PostProbeScene.packet(size: size)
        case "stylized": packet = StylizedProbeScene.packet(size: size)
        case "particles": packet = ParticleProbeScene.packet(size: size)
        case "simulation": packet = ParticleSimulationProbeScene.packet(size: size)
        default: packet = AnimatedProbeScene.packet(size: size)
        }
        try renderer.renderChecked(packet: packet)
        if scene == "post" {
            // SSR refines a stable opaque scene; the initial frame intentionally
            // omits it while establishing temporal history.
            #expect(!renderer.lastFrameStats.activePasses.contains(.ssr))
            packet = PostProbeScene.packet(size: size, frame: 1)
            try renderer.renderChecked(packet: packet)
        }
        let stats = renderer.lastFrameStats
        #expect(stats.frameIndex == packet.frameIndex)
        #expect(stats.drawCallCount > 0)
        #expect(renderer.currentViewportSurfaceState().isValid)
        let pixels = try GridImage.readback(device: device, texture: #require(renderer.colorTexture), size: size)
        if let output = ProcessInfo.processInfo.environment["GUAVA_GPU_TEST_OUTPUT_DIR"] {
            try GridImage.writePPM(pixels, size: size, to: URL(fileURLWithPath: output).appendingPathComponent("\(scene).ppm"))
        }
        #expect(pixels.count == Int(size.width * size.height * 4))
        // Flat unlit meshes legitimately use only a few colors. Require visible
        // coverage in RGB rather than an arbitrary number of blue-channel shades.
        let coveredPixels = stride(from: 0, to: pixels.count, by: 4).filter {
            pixels[$0] != pixels[0] || pixels[$0 + 1] != pixels[1] || pixels[$0 + 2] != pixels[2]
        }.count
        #expect(coveredPixels > 32)
        if scene == "post" {
            for kind in [RenderPassKind.ssao, .ssr, .taa, .bloom, .fxaa, .tonemap] {
                #expect(stats.activePasses.contains(kind))
            }
        }
        if scene == "simulation" {
            #expect(stats.gpuParticleSimulationParticleCount > 0)
            #expect(stats.gpuParticleSortPassCount > 0)
            #expect(stats.gpuParticleRenderInstanceCount > 0)
        }
    }

    @Test("grid coverage survives resize and empty scenes")
    func editorGrid() throws {
        let device = try Device.make()
        let renderer = try NativeGridRenderer(device: device)
        for size in [RenderDrawableSize(width: 192, height: 128), .init(width: 96, height: 160)] {
            var packet = GridProbeScene.packet(size: size)
            try renderer.renderChecked(packet: packet)
            let pixels = try GridImage.readback(device: device, texture: #require(renderer.colorTexture), size: size)
            packet.renderSettings.viewport.gridEnabled = false
            try renderer.renderChecked(packet: packet)
            let clear = try GridImage.readback(device: device, texture: #require(renderer.colorTexture), size: size)
            #expect(try GridImage.difference(pixels, clear).pixelsOverThree > 300)
            #expect(renderer.lastFrameStats.drawCallCount == 0)
        }
    }
}
