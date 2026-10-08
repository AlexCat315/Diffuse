import Foundation
import XCTest
@testable import NativeRHI

/// The same shader/resource contract is exercised on the available native APIs.
final class NativeGPUContractTests: XCTestCase {
    private func makeDevice(_ api: GraphicsAPI) throws -> Device {
        guard NativeRHI.isCompiledIn(api) else { throw XCTSkip("Backend is not compiled") }
        #if canImport(CVulkanHeaders)
        if api == .vulkan && !VulkanBackend.isAvailable { throw XCTSkip("No Vulkan ICD") }
        #endif
        return try Device.make(DeviceConfig(preferredBackends: [api], enableValidation: false))
    }
    #if canImport(Metal)
    func testMetalTextureSamplerAndFloatReadback() throws { try sample(.metal, target: "metal") }
    func testMetalRasterPipelineBindsUniformsAndPreservesLoadAction() throws {
        let device = try makeDevice(.metal)
        let vertex = try ShaderFixtures.compile("raster", entry: "vertexMain", stage: .vertex, target: "metal")
        let fragment = try ShaderFixtures.compile("raster", entry: "fragmentMain", stage: .fragment, target: "metal")
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
    func testMetalStorageAcrossTransferComputeAndGraphicsQueues() throws { try storageAcrossQueues(.metal, target: "metal") }
    func testMetalPushConstantsAndLayoutRejection() throws { try constants(.metal, target: "metal") }
    #endif
    #if canImport(CVulkanHeaders)
    func testVulkanTextureSamplerAndFloatReadback() throws { try sample(.vulkan, target: "spirv") }
    func testVulkanStorageAcrossTransferComputeAndGraphicsQueues() throws { try storageAcrossQueues(.vulkan, target: "spirv") }
    func testVulkanPushConstantsAndLayoutRejection() throws { try constants(.vulkan, target: "spirv") }
    func testVulkanFailedEncodingRestoresLayoutsAndPlanner() throws {
        let device = try makeDevice(.vulkan)
        let source = try device.makeBuffer(BufferDescriptor(size: 16, usage: .transferSource))
        try device.uploadBufferData(source, data: Data(repeating: 91, count: 16))
        let texture = try device.makeTexture(TextureDescriptor(width: 4, height: 1, format: .r32Uint, usage: [.transferDestination, .transferSource]))
        let invalid = CommandBuffer()
        invalid.copyPass {
            $0.uploadBufferToTexture(buffer: source, bytesPerRow: 16, texture: texture, width: 4, height: 1)
            $0.copyBuffer(src: Buffer(id: 0x4242), dst: source, size: 16)
        }
        try device.beginFrame()
        XCTAssertThrowsError(try device.submit(invalid))
        let valid = CommandBuffer()
        valid.copyPass { $0.uploadBufferToTexture(buffer: source, bytesPerRow: 16, texture: texture, width: 4, height: 1) }
        try device.submit(valid, queue: .transfer)
        device.endFrame(); try device.waitUntilIdle()
        var bytes = [UInt8](repeating: 0, count: 16)
        try bytes.withUnsafeMutableBytes { try device.readTextureData(texture, width: 4, height: 1, bytesPerRow: 16, into: $0) }
        XCTAssertEqual(bytes, [UInt8](repeating: 91, count: 16))
    }
    #endif
    private func storageAcrossQueues(_ api: GraphicsAPI, target: String) throws {
        let device = try makeDevice(api)
        let artifact = try ShaderFixtures.compile("storage-read", entry: "computeMain", stage: .compute, target: target)
        XCTAssertEqual(artifact.interface.bindings.first(where: { $0.name == "inputs" })?.buffer.readOnly, true)
        XCTAssertEqual(artifact.interface.bindings.first(where: { $0.name == "outputs" })?.buffer.readOnly, false)
        let binding = try device.makeBindingLayout(artifact.bindingLayoutDescriptor())
        let layout = try device.makePipelineLayout(PipelineLayoutDescriptor(setLayouts: [binding]))
        let pipeline = try device.makeComputePipeline(ComputePipelineDescriptor(layout: layout, shader: device.makeShaderModule(artifact.moduleDescriptor())))
        let initial = try device.makeBuffer(BufferDescriptor(size: 32, usage: .transferSource))
        let input = try device.makeBuffer(BufferDescriptor(size: 32, usage: [.storageRead, .transferDestination]))
        let output = try device.makeBuffer(BufferDescriptor(size: 32, usage: [.storageWrite, .transferSource]))
        let set = try device.makeBindingSet(layout: binding, descriptor: BindingSetDescriptor(entries: [
            BindingSetEntry(slot: 0, resource: .storageBuffer(buffer: input)), BindingSetEntry(slot: 1, resource: .storageBuffer(buffer: output))]))
        var values = (40..<48).map(UInt32.init)
        try values.withUnsafeMutableBytes { try device.uploadBufferData(initial, data: Data($0)) }
        let texture = try device.makeTexture(TextureDescriptor(width: 8, height: 1, format: .r32Uint, usage: [.transferDestination, .transferSource]))
        try device.beginFrame()
        let transfer = CommandBuffer(); transfer.copyPass { $0.copyBuffer(src: initial, dst: input, size: 32) }
        try device.submit(transfer, queue: .transfer)
        let compute = CommandBuffer(); compute.computePass { $0.setPipeline(pipeline); $0.setBindingSet(set); $0.dispatch(groupsX: 2) }
        try device.submit(compute, queue: .compute)
        let copy = CommandBuffer(); copy.copyPass { $0.uploadBufferToTexture(buffer: output, bytesPerRow: 32, texture: texture, width: 8, height: 1) }
        try device.submit(copy, queue: .graphics)
        device.endFrame(); try device.waitUntilIdle()
        values = [UInt32](repeating: 0, count: 8)
        try values.withUnsafeMutableBytes { try device.readTextureData(texture, width: 8, height: 1, bytesPerRow: 32, into: $0) }
        XCTAssertEqual(values, (51..<59).map(UInt32.init))
    }
    private func constants(_ api: GraphicsAPI, target: String) throws {
        let device = try makeDevice(api)
        let artifact = try ShaderFixtures.compile("push-constants", entry: "computeMain", stage: .compute, target: target)
        XCTAssertEqual(artifact.interface.pushConstants, [PushConstantRange(stage: .compute, slot: 1, byteCount: 4)])
        let binding = try device.makeBindingLayout(artifact.bindingLayoutDescriptor())
        var descriptor = PipelineLayoutDescriptor(setLayouts: [binding])
        let withoutConstants = try device.makePipelineLayout(descriptor)
        descriptor.pushConstants = artifact.interface.pushConstants
        let layout = try device.makePipelineLayout(descriptor)
        XCTAssertNotEqual(layout, withoutConstants)
        XCTAssertEqual(try device.makePipelineLayout(descriptor), layout)
        let shader = try device.makeShaderModule(artifact.moduleDescriptor())
        let pipeline = try device.makeComputePipeline(ComputePipelineDescriptor(layout: layout, shader: shader))
        let buffer = try device.makeBuffer(BufferDescriptor(size: 4, usage: [.storageWrite, .transferSource]))
        let set = try device.makeBindingSet(layout: binding, descriptor: BindingSetDescriptor(entries: [BindingSetEntry(slot: 0, resource: .storageBuffer(buffer: buffer))]))
        let texture = try device.makeTexture(TextureDescriptor(width: 1, height: 1, format: .r32Uint, usage: [.transferDestination, .transferSource]))
        try device.beginFrame()
        let invalid = CommandBuffer(); invalid.computePass { $0.setPipeline(pipeline); $0.pushConstant(slot: 9, value: UInt32(73)) }
        XCTAssertThrowsError(try device.submit(invalid))
        let valid = CommandBuffer(); valid.computePass { $0.setPipeline(pipeline); $0.setBindingSet(set); $0.pushConstant(slot: 1, value: UInt32(73)); $0.dispatch(groupsX: 1) }
        valid.copyPass { $0.uploadBufferToTexture(buffer: buffer, bytesPerRow: 4, texture: texture, width: 1, height: 1) }
        try device.submit(valid); device.endFrame(); try device.waitUntilIdle()
        var value: UInt32 = 0
        try withUnsafeMutableBytes(of: &value) { try device.readTextureData(texture, width: 1, height: 1, bytesPerRow: 4, into: $0) }
        XCTAssertEqual(value, 73)
    }
    private func sample(_ api: GraphicsAPI, target: String) throws {
        let device = try makeDevice(api)
        let artifact = try ShaderFixtures.compile("sample", entry: "computeMain", stage: .compute, target: target)
        let binding = try device.makeBindingLayout(artifact.bindingLayoutDescriptor())
        let layout = try device.makePipelineLayout(PipelineLayoutDescriptor(setLayouts: [binding]))
        let pipeline = try device.makeComputePipeline(ComputePipelineDescriptor(layout: layout, shader: device.makeShaderModule(artifact.moduleDescriptor())))
        let image = try device.makeTexture(TextureDescriptor(width: 1, height: 1, format: .rgba32Float, usage: .sampled))
        var expected = SIMD4<Float>(0.25, 0.5, 0.75, 1)
        try withUnsafeBytes(of: &expected) { try device.uploadTextureData(image, data: Data($0), width: 1, height: 1, bytesPerRow: 16) }
        let sampler = try device.makeSampler(SamplerDescriptor(minFilter: .nearest, magFilter: .nearest))
        let output = try device.makeBuffer(BufferDescriptor(size: 16, usage: [.storageWrite, .transferSource]))
        let set = try device.makeBindingSet(layout: binding, descriptor: BindingSetDescriptor(entries: [
            BindingSetEntry(slot: 0, resource: .texture(image)), BindingSetEntry(slot: 1, resource: .sampler(sampler)), BindingSetEntry(slot: 2, resource: .storageBuffer(buffer: output))]))
        let readback = try device.makeTexture(TextureDescriptor(width: 1, height: 1, format: .rgba32Float, usage: [.transferSource, .transferDestination]))
        let commands = CommandBuffer()
        commands.computePass { $0.setPipeline(pipeline); $0.setBindingSet(set); $0.dispatch(groupsX: 1) }
        commands.copyPass { $0.uploadBufferToTexture(buffer: output, bytesPerRow: 16, texture: readback, width: 1, height: 1) }
        try device.beginFrame(); try device.submit(commands); device.endFrame(); try device.waitUntilIdle()
        var value = SIMD4<Float>.zero
        try withUnsafeMutableBytes(of: &value) { try device.readTextureData(readback, width: 1, height: 1, bytesPerRow: 16, into: $0) }
        XCTAssertEqual(value, expected)
    }

}
