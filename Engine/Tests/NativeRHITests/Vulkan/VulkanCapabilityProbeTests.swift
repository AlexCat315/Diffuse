// NativeRHITests — Vulkan availability + real capability probe.
//
// Guarded by runtime availability (linked native loader + ICD present). Capabilities
// report implemented paths; adapter extension presence is diagnostic only.

#if (os(Windows) || os(Linux)) && canImport(CVulkanHeaders)
import XCTest
@testable import NativeRHI

final class VulkanCapabilityProbeTests: XCTestCase {

    func testUnavailableReportsFalseWithoutCrash() {
        // Query the native driver without assuming an installed ICD.
        _ = VulkanBackend.isAvailable
    }

    func testBackendCreatesAndReportsRealCapabilities() throws {
        guard VulkanBackend.isAvailable else {
            throw XCTSkip("No native Vulkan driver on this Windows/Linux host")
        }
        let config = DeviceConfig(preferredBackends: [.vulkan], enableValidation: false)
        let backend = try VulkanBackend.make(config: config)

        XCTAssertFalse(backend.deviceName.isEmpty)
        let caps = backend.queryCapabilities()
        print("[Vulkan] deviceName=\(backend.deviceName) " +
              "rayTracing=\(caps.rayTracing) meshShaders=\(caps.meshShading.mesh) " +
              "compute=\(caps.compute) indirectDraw=\(caps.indirectDraw)")
        let adapter = backend.queryAdapterCapabilities()
        XCTAssertTrue(!caps.meshShading.mesh || adapter.meshShading)
        XCTAssertTrue(!caps.meshShading.task || caps.meshShading.mesh)
        XCTAssertTrue(!caps.rayTracing.computeRayQuery || (caps.rayTracing.accelerationStructures && adapter.rayTracing))
        XCTAssertFalse(caps.rayTracing.pipelines)
        XCTAssertFalse(caps.meshShading.indirect)
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
