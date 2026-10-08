// NativeRHITests — Vulkan immediate upload → device-local texture → readback.
//
// Exercises the staging buffer + layout-transition path headlessly (no swapchain):
// write a known color into a device-local texture via the upload ring, then copy
// it back out and verify the pixels. Guarded by runtime availability.

#if (os(Windows) || os(Linux)) && canImport(CVulkanHeaders)
import Foundation
import XCTest
@testable import NativeRHI

final class VulkanUploadReadbackTests: XCTestCase {

    func testRecordedBufferCopiesPreserveDataAcrossPlannedBarrier() throws {
        guard VulkanBackend.isAvailable else { throw XCTSkip("No Vulkan loader / ICD") }
        let backend = try VulkanBackend.make(config: DeviceConfig(preferredBackends: [.vulkan], enableValidation: false))
        let handles = [Buffer(id: 1), Buffer(id: 2), Buffer(id: 3)]
        for handle in handles {
            try backend.createBuffer(handle, descriptor: BufferDescriptor(size: 64,
                usage: [.transferSource, .transferDestination]))
        }
        defer { handles.forEach { backend.destroyBuffer($0) } }
        let data = Data((0..<64).map(UInt8.init))
        try backend.uploadBufferData(handles[0], offset: 0, data: data)
        let commands = CommandBuffer()
        commands.copyPass { $0.copyBuffer(src: handles[0], dst: handles[1], size: 64) }
        commands.copyPass { $0.copyBuffer(src: handles[1], dst: handles[2], size: 64) }
        let plan = try SubmissionPlanner().buildPlan(queue: .graphics, commands: commands.commands,
                                                     external: SubmitDescriptor())
        _ = try backend.makeFrameUploader(slot: 0)
        var completions: [XCTestExpectation] = []
        for submit in plan.submits {
            let completed = expectation(description: "Vulkan buffer copy completion")
            completions.append(completed)
            try backend.submit(submit) { completed.fulfill() }
        }
        XCTAssertEqual(XCTWaiter.wait(for: completions, timeout: 10), .completed)
        try backend.waitUntilIdle()
        let allocation = try XCTUnwrap(backend.registries.buffers[handles[2].id]?.allocation)
        let mapped = try XCTUnwrap(allocation.mappedBase)
        XCTAssertEqual(Data(bytes: mapped.advanced(by: Int(allocation.offset)), count: 64), data)
    }

    func testUploadThenReadbackRoundTripsPixels() throws {
        guard VulkanBackend.isAvailable else {
            throw XCTSkip("No native Vulkan driver on this Windows/Linux host")
        }
        let config = DeviceConfig(preferredBackends: [.vulkan], enableValidation: false)
        let device = try Device.make(config)

        let width = 4
        let height = 4
        let bytesPerRow = width * 4
        let byteCount = bytesPerRow * height

        let descriptor = TextureDescriptor(
            width: width, height: height, format: .rgba8Unorm,
            usage: [.transferDestination, .transferSource, .sampled])
        let texture = try device.makeTexture(descriptor)

        // Fill with a known red pixel.
        var uploaded = Data(count: byteCount)
        for y in 0..<height {
            for x in 0..<width {
                let o = (y * width + x) * 4
                uploaded[o] = 255     // R
                uploaded[o + 1] = 0   // G
                uploaded[o + 2] = 0   // B
                uploaded[o + 3] = 255 // A
            }
        }
        try device.uploadTextureData(texture, data: uploaded,
                                     region: .init(width: width,height: height), bytesPerRow: bytesPerRow)

        var readback = Data(count: byteCount)
        try readback.withUnsafeMutableBytes { dest in
            try device.readTextureData(texture, width: width, height: height,
                                       bytesPerRow: bytesPerRow, into: dest)
        }

        // Verify at least one pixel came back as red.
        XCTAssertEqual(readback[0], 255, "R channel should survive the round trip")
        XCTAssertEqual(readback[3], 255, "A channel should survive the round trip")
    }
}
#endif
