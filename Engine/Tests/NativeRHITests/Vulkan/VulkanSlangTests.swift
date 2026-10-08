#if (os(Windows) || os(Linux)) && canImport(CVulkanHeaders)
import Foundation
import XCTest
@testable import NativeRHI

final class VulkanSlangTests: XCTestCase {
    private func device() throws -> Device {
        guard VulkanBackend.isAvailable else { throw XCTSkip("No Vulkan loader / ICD") }
        return try Device.make(DeviceConfig(preferredBackends: [.vulkan], enableValidation: false))
    }

    func testComputePipelineCreatedBeforeBindingSetUsesNamedEntryPoint() throws {
        let device = try device()
        let artifact = try ShaderFixtures.compile("compute", entry: "computeMain", stage: .compute, target: "spirv")
        let shader = try device.makeShaderModule(artifact.moduleDescriptor())
        let binding = try device.makeBindingLayout(artifact.bindingLayoutDescriptor())
        let layout = try device.makePipelineLayout(PipelineLayoutDescriptor(setLayouts: [binding]))
        let pipeline = try device.makeComputePipeline(ComputePipelineDescriptor(layout: layout, shader: shader))
        let buffer = try device.makeBuffer(BufferDescriptor(size: 64, usage: [.storageWrite, .transferSource]))
        let set = try device.makeBindingSet(layout: binding, descriptor: BindingSetDescriptor(entries: [
            BindingSetEntry(slot: 0, resource: .storageBuffer(buffer: buffer))]))
        let target = try device.makeTexture(TextureDescriptor(width: 16, height: 1, format: .r32Uint,
            usage: [.transferSource, .transferDestination]))
        let commands = CommandBuffer()
        commands.computePass { $0.setPipeline(pipeline); $0.setBindingSet(set); $0.dispatch(groupsX: 2) }
        commands.copyPass { $0.uploadBufferToTexture(.init(buffer: buffer, bytesPerRow: 64, texture: target, region: .init(width: 16, height: 1))) }
        try device.beginFrame()
        try device.submit(commands, queue: .compute)
        device.endFrame()
        try device.waitUntilIdle()
        var values = [UInt32](repeating: 0, count: 16)
        try values.withUnsafeMutableBytes { try device.readTextureData(target, width: 16, height: 1, bytesPerRow: 64, into: $0) }
        XCTAssertEqual(values, (7..<23).map(UInt32.init))
    }

    func testRasterPipelineBindsUniformsAndPreservesLoadAction() throws {
        let device = try device()
        let vertex = try ShaderFixtures.compile("raster", entry: "vertexMain", stage: .vertex, target: "spirv")
        let fragment = try ShaderFixtures.compile("raster", entry: "fragmentMain", stage: .fragment, target: "spirv")
        var bindingDescriptor = try fragment.bindingLayoutDescriptor()
        bindingDescriptor.entries[0].visibility = .graphics
        let binding = try device.makeBindingLayout(bindingDescriptor)
        let layout = try device.makePipelineLayout(PipelineLayoutDescriptor(setLayouts: [binding]))
        let pipeline = try device.makeGraphicsPipeline(GraphicsPipelineDescriptor(layout: layout,
            vertex: device.makeShaderModule(vertex.moduleDescriptor()), fragment: device.makeShaderModule(fragment.moduleDescriptor()),
            colorAttachments: [ColorAttachmentDescriptor(format: .rgba8Unorm)], depthFormat: nil, depthStencil: nil))
        let buffer = try device.makeBuffer(BufferDescriptor(size: 256, usage: [.uniform]))
        var color = SIMD4<Float>(0, 1, 0, 1)
        try withUnsafeBytes(of: &color) { try device.uploadBufferData(buffer, data: Data($0)) }
        let set = try device.makeBindingSet(layout: binding, descriptor: BindingSetDescriptor(entries: [
            BindingSetEntry(slot: 0, resource: .uniformBuffer(buffer: buffer))]))
        let target = try device.makeTexture(TextureDescriptor(width: 8, height: 8, format: .rgba8Unorm, usage: [.colorTarget, .transferSource]))
        let commands = CommandBuffer()
        commands.renderPass(descriptor: RenderPassDescriptor(colorTargets: [
            RenderColorTarget(texture: target, loadAction: .clear(SIMD4(1, 0, 0, 1)))])) {
            $0.setPipeline(pipeline); $0.setBindingSet(set); $0.draw(vertexCount: 3)
        }
        commands.renderPass(descriptor: RenderPassDescriptor(colorTargets: [RenderColorTarget(texture: target, loadAction: .load)])) { _ in }
        try device.beginFrame()
        try device.submit(commands)
        device.endFrame()
        try device.waitUntilIdle()
        var pixels = [UInt8](repeating: 0, count: 256)
        try pixels.withUnsafeMutableBytes { try device.readTextureData(target, width: 8, height: 8, bytesPerRow: 32, into: $0) }
        let center = (4 * 8 + 4) * 4
        XCTAssertEqual(Array(pixels[center..<center + 4]), [0, 255, 0, 255])
        XCTAssertTrue(stride(from: 0, to: 256, by: 4).contains { pixels[$0] == 255 })
    }
}
#endif
