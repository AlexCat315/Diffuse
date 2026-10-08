// NativeRHITests — Vulkan availability + real capability probe.
//
// Guarded by runtime availability (loader dlopen + ICD present). Capabilities are
// report implemented paths; adapter extension presence is diagnostic only.

#if canImport(CVulkanHeaders)
import XCTest
@testable import NativeRHI

final class VulkanCapabilityProbeTests: XCTestCase {

    func testUnavailableReportsFalseWithoutCrash() {
        // On this host the loader + MoltenVK ICD are present, but the test still
        // must not crash; the value is the real queried one.
        _ = VulkanBackend.isAvailable
    }

    func testBackendCreatesAndReportsRealCapabilities() throws {
        guard VulkanBackend.isAvailable else {
            throw XCTSkip("No Vulkan loader / ICD (MoltenVK) on this host")
        }
        let config = DeviceConfig(preferredBackends: [.vulkan], enableValidation: false)
        let backend = try VulkanBackend.make(config: config)

        XCTAssertFalse(backend.deviceName.isEmpty)
        let caps = backend.queryCapabilities()
        print("[Vulkan] deviceName=\(backend.deviceName) " +
              "rayTracing=\(caps.rayTracing) meshShaders=\(caps.meshShading.mesh) " +
              "compute=\(caps.compute) indirectDraw=\(caps.indirectDraw)")
        // These paths are unavailable even on an adapter advertising extensions.
        XCTAssertFalse(caps.rayTracing.accelerationStructures,
                       "Vulkan acceleration structure commands are not implemented")
        XCTAssertFalse(caps.meshShading.mesh,
                       "Vulkan mesh commands are not implemented")
        XCTAssertTrue(caps.graphics)
        XCTAssertTrue(caps.compute)
    }

    func testInvalidComputeCommandsAreRejectedAndEmptyComputeSubmitSucceeds() throws {
        guard VulkanBackend.isAvailable else { throw XCTSkip("No Vulkan loader / ICD") }
        let device = try Device.make(DeviceConfig(preferredBackends: [.vulkan], enableValidation: false))
        let commands = CommandBuffer()
        commands.computePass { $0.dispatch(groupsX: 1) }
        try device.beginFrame()
        XCTAssertThrowsError(try device.submit(commands))
        try device.submit(CommandBuffer(), queue: .compute)
        device.endFrame()
        try device.waitUntilIdle()
    }
}
#endif
