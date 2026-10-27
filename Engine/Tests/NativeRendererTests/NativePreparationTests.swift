import AssetPipeline
import Foundation
import NativeRHI
import NativeRendererValidation
import RenderBackend
import SceneRuntime
import XCTest

final class NativePreparationTests: XCTestCase {
    func testPreparedRendererCanRenderItsInitialSettings() async throws {
        #if os(macOS)
        let api = GraphicsAPI.metal
        #elseif os(Windows)
        let api = GraphicsAPI.dx12
        #else
        let api = GraphicsAPI.vulkan
        #endif
        let device = try RendererTestDevice.make(DeviceConfig(preferredBackends: [api], enableValidation: false))
        var packet = MeshProbeScene.packet(size: RenderDrawableSize(width: 64, height: 48))
        packet.renderSettings.shading.pbr = false
        packet.renderSettings.postProcessing.fxaa = true
        let events = PreparationSnapshots()
        let renderer = try await NativeRenderer.prepared(device: device,
            initialSettings: packet.renderSettings, onProgress: events.append)
        XCTAssertEqual(events.last?.phase, .finished)
        XCTAssertEqual(events.last?.completedSteps, 8)
        XCTAssertGreaterThan(device.pipelineStatistics.compute.cold.count, 0)
        let before = device.pipelineStatistics.cacheMisses
        try renderer.renderChecked(packet: packet)
        try device.waitUntilIdle()
        XCTAssertNotNil(renderer.colorTexture)
        XCTAssertEqual(device.pipelineStatistics.cacheMisses, before,
            "the initial scene must use the prepared pipeline variants")
    }
}

private final class PreparationSnapshots: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ResourcePreparationProgress?
    func append(_ value: ResourcePreparationProgress) { lock.withLock { self.value = value } }
    var last: ResourcePreparationProgress? { lock.withLock { value } }
}
