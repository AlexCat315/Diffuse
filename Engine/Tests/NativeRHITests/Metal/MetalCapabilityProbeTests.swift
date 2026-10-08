// NativeRHITests — Metal capability probe (real GPU, no hardcoding).
//
// Asserts that the capabilities reported by the Metal backend are the values
// actually queried from the underlying MTLDevice, never a hardcoded constant.

#if canImport(Metal)
import Foundation
import XCTest
import Metal
@testable import NativeRHI

final class MetalCapabilityProbeTests: XCTestCase {

    /// The backend's `rayTracing` must equal `MTLDevice.supportsRaytracing` on
    /// the real default device. This guards against a hardcoded `true`.
    func testRayTracingMatchesRealMTLDevice() throws {
        guard let mtl = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available")
        }
        let config = DeviceConfig(preferredBackends: [.metal], enableValidation: false)
        let device = try Device.make(config)
        XCTAssertEqual(
            device.adapterCapabilities.rayTracing,
            mtl.supportsRaytracing,
            "rayTracing must reflect MTLDevice.supportsRaytracing"
        )
    }

    func testCapabilitiesAreReported() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("No Metal device available")
        }
        let config = DeviceConfig(preferredBackends: [.metal], enableValidation: false)
        let device = try Device.make(config)
        // These are real probes on this GPU; print them for the record.
        _ = device.capabilities
        XCTAssertFalse(device.deviceName.isEmpty)
    }

    func testInvalidBindingFailureDoesNotPoisonBindingCache() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let device = try Device.make(DeviceConfig(preferredBackends: [.metal]))
        let layout = try device.makeBindingLayout(BindingLayoutDescriptor(entries: [
            BindingLayoutEntry(slot: 0, type: .storageBuffer, stage: .compute)]))
        let descriptor = BindingSetDescriptor(entries: [
            BindingSetEntry(slot: 0, resource: .storageBuffer(buffer: Buffer(id: 0)))])
        // Both attempts must fail: a failed backend registration must not be cached.
        XCTAssertThrowsError(try device.makeBindingSet(layout: layout, descriptor: descriptor))
        XCTAssertThrowsError(try device.makeBindingSet(layout: layout, descriptor: descriptor))
    }

    func testDuplicateBindingSlotsAndTaskShadersAreRejected() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let device = try Device.make(DeviceConfig(preferredBackends: [.metal]))
        XCTAssertThrowsError(try device.makeBindingLayout(BindingLayoutDescriptor(entries: [
            BindingLayoutEntry(slot: 0, type: .storageBuffer, stage: .compute),
            BindingLayoutEntry(slot: 0, type: .uniformBuffer, stage: .compute)])))
        XCTAssertFalse(device.capabilities.meshShading.task)
        XCTAssertThrowsError(try device.makeShaderModule(ShaderModuleDescriptor(
            stage: .task, format: .mslSource, code: Data("unused".utf8), entryPoint: "main")))
    }
}
#endif
