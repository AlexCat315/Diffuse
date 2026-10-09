#if canImport(Metal)
import Foundation
import Metal
import XCTest
@testable import NativeRHI

final class MetalRenderBindingTests: XCTestCase {
    func testSamplerAndTextureChangesRemainVisibleAfterRepeatedSets() throws {
        let device = try Device.make(DeviceConfig(preferredBackends: [.metal], enableValidation: true))
        let vertex = try ShaderFixtures.compile("render-sample", entry: "vertexMain", stage: .vertex, target: "metal")
        let fragment = try ShaderFixtures.compile("render-sample", entry: "fragmentMain", stage: .fragment, target: "metal")
        let binding = try device.makeBindingLayout(fragment.bindingLayoutDescriptor())
        let layout = try device.makePipelineLayout(PipelineLayoutDescriptor(setLayouts: [binding]))
        let pipeline = try device.makeGraphicsPipeline(GraphicsPipelineDescriptor(layout: layout,
            vertex: device.makeShaderModule(vertex.moduleDescriptor()), fragment: device.makeShaderModule(fragment.moduleDescriptor()),
            colorAttachments: [ColorAttachmentDescriptor(format: .rgba8Unorm)], depthFormat: nil, depthStencil: nil))
        var descriptor = SamplerDescriptor()
        descriptor.minFilter = .linear; descriptor.magFilter = .linear
        let linear = try device.makeSampler(descriptor)
        descriptor.minFilter = .nearest; descriptor.magFilter = .nearest
        let nearest = try device.makeSampler(descriptor)
        let gradient = try device.makeTexture(TextureDescriptor(width: 2, height: 1, format: .rgba8Unorm, usage: [.sampled, .transferDestination]))
        let green = try device.makeTexture(TextureDescriptor(width: 2, height: 1, format: .rgba8Unorm, usage: [.sampled, .transferDestination]))
        try device.uploadTextureData(gradient, data: Data([255, 0, 0, 255, 0, 0, 255, 255]), region: .init(width: 2, height: 1), bytesPerRow: 8)
        try device.uploadTextureData(green, data: Data([0, 255, 0, 255, 0, 255, 0, 255]), region: .init(width: 2, height: 1), bytesPerRow: 8)
        func set(_ image: Texture, _ sampler: Sampler) throws -> BindingSet {
            try device.makeBindingSet(layout: binding, descriptor: BindingSetDescriptor(entries: [
                BindingSetEntry(slot: 0, resource: .texture(image)), BindingSetEntry(slot: 1, resource: .sampler(sampler))]))
        }
        let a = try set(gradient, linear), b = try set(gradient, nearest), c = try set(green, nearest)
        let target = try device.makeTexture(TextureDescriptor(width: 16, height: 4, format: .rgba8Unorm, usage: [.colorTarget, .transferSource]))
        let commands = CommandBuffer()
        commands.renderPass(descriptor: RenderPassDescriptor(colorTargets: [RenderColorTarget(texture: target, loadAction: .clear(.zero))])) {
            $0.setPipeline(pipeline); $0.setViewport(Viewport(width: 16, height: 4))
            for (index, set) in [a, b, c, a].enumerated() {
                $0.setScissor(ScissorRect(x: index * 4, y: 0, width: 4, height: 4))
                for _ in 0..<20 { $0.setBindingSet(set) }
                $0.draw(vertexCount: 3)
            }
        }
        try device.beginFrame(); try device.submit(commands); device.endFrame(); try device.waitUntilIdle()
        var pixels = [UInt8](repeating: 0, count: 16 * 4 * 4)
        try pixels.withUnsafeMutableBytes { try device.readTextureData(target, width: 16, height: 4, bytesPerRow: 64, into: $0) }
        for (index, expected) in [[UInt8(128), 0, 128, 255], [0, 0, 255, 255], [0, 255, 0, 255], [128, 0, 128, 255]].enumerated() {
            let pixel = (2 * 16 + index * 4 + 2) * 4
            for channel in 0..<4 { XCTAssertLessThanOrEqual(abs(Int(pixels[pixel + channel]) - Int(expected[channel])), 1) }
        }
    }

    func testOffsetsInlineConstantsAndNewPassRestoreTheRequiredBuffer() throws {
        let device = try Device.make(DeviceConfig(preferredBackends: [.metal], enableValidation: true))
        let vertex = try ShaderFixtures.compile("raster", entry: "vertexMain", stage: .vertex, target: "metal")
        let fragment = try ShaderFixtures.compile("raster", entry: "fragmentMain", stage: .fragment, target: "metal")
        let binding = try device.makeBindingLayout(BindingLayoutDescriptor(entries: [
            BindingLayoutEntry(slot: 0, type: .uniformBuffer, visibility: .graphics)]))
        let layout = try device.makePipelineLayout(PipelineLayoutDescriptor(setLayouts: [binding]))
        let inlineBinding = try device.makeBindingLayout(BindingLayoutDescriptor(entries: [
            BindingLayoutEntry(slot: 0, type: .uniformBuffer, visibility: .vertex)]))
        var inlineLayoutDescriptor = PipelineLayoutDescriptor(setLayouts: [inlineBinding])
        inlineLayoutDescriptor.pushConstants = [PushConstantRange(stage: .fragment, slot: 0, byteCount: 16)]
        let inlineLayout = try device.makePipelineLayout(inlineLayoutDescriptor)
        let pipeline = try device.makeGraphicsPipeline(GraphicsPipelineDescriptor(layout: layout,
            vertex: device.makeShaderModule(vertex.moduleDescriptor()), fragment: device.makeShaderModule(fragment.moduleDescriptor()),
            colorAttachments: [ColorAttachmentDescriptor(format: .rgba8Unorm)], depthFormat: nil, depthStencil: nil))
        let inlinePipeline = try device.makeGraphicsPipeline(GraphicsPipelineDescriptor(layout: inlineLayout,
            vertex: device.makeShaderModule(vertex.moduleDescriptor()), fragment: device.makeShaderModule(fragment.moduleDescriptor()),
            colorAttachments: [ColorAttachmentDescriptor(format: .rgba8Unorm)], depthFormat: nil, depthStencil: nil))
        let buffer = try device.makeBuffer(BufferDescriptor(size: 32, usage: .uniform))
        let colors = [SIMD4<Float>(1, 0, 0, 1), SIMD4<Float>(0, 1, 0, 1)]
        try colors.withUnsafeBytes { try device.uploadBufferData(buffer, data: Data($0)) }
        let red = try device.makeBindingSet(layout: binding, descriptor: BindingSetDescriptor(entries: [
            BindingSetEntry(slot: 0, resource: .uniformBuffer(buffer: buffer, offset: 0, size: 16))]))
        let green = try device.makeBindingSet(layout: binding, descriptor: BindingSetDescriptor(entries: [
            BindingSetEntry(slot: 0, resource: .uniformBuffer(buffer: buffer, offset: 16, size: 16))]))
        let inlineSet = try device.makeBindingSet(layout: inlineBinding, descriptor: BindingSetDescriptor(entries: [
            BindingSetEntry(slot: 0, resource: .uniformBuffer(buffer: buffer, offset: 16, size: 16))]))
        let target = try device.makeTexture(TextureDescriptor(width: 128, height: 32, format: .rgba8Unorm,
            usage: [.colorTarget, .transferSource]))
        let commands = CommandBuffer()
        commands.renderPass(descriptor: RenderPassDescriptor(colorTargets: [RenderColorTarget(texture: target, loadAction: .clear(.zero))])) {
            $0.setPipeline(pipeline); $0.setViewport(Viewport(width: 128, height: 32))
            $0.setScissor(ScissorRect(x: 16, y: 24, width: 24, height: 8))
            $0.setBindingSet(red); $0.setBindingSet(red); $0.draw(vertexCount: 3)
            $0.setScissor(ScissorRect(x: 40, y: 24, width: 24, height: 8))
            $0.setBindingSet(green); $0.draw(vertexCount: 3)
            $0.setScissor(ScissorRect(x: 64, y: 24, width: 24, height: 8))
            $0.setPipeline(inlinePipeline); $0.setBindingSet(inlineSet)
            $0.pushConstant(stage: .fragment, slot: 0, value: SIMD4<Float>(0, 0, 1, 1)); $0.draw(vertexCount: 3)
            $0.setScissor(ScissorRect(x: 88, y: 24, width: 24, height: 8))
            $0.setPipeline(pipeline)
            $0.setBindingSet(green); $0.draw(vertexCount: 3)
        }
        commands.renderPass(descriptor: RenderPassDescriptor(colorTargets: [RenderColorTarget(texture: target, loadAction: .load)])) {
            $0.setPipeline(pipeline); $0.setViewport(Viewport(width: 128, height: 32))
            $0.setScissor(ScissorRect(x: 112, y: 28, width: 12, height: 4))
            $0.setBindingSet(green); $0.draw(vertexCount: 3)
        }
        try device.beginFrame(); try device.submit(commands); device.endFrame(); try device.waitUntilIdle()
        var pixels = [UInt8](repeating: 0, count: 128 * 32 * 4)
        try pixels.withUnsafeMutableBytes { try device.readTextureData(target, width: 128, height: 32, bytesPerRow: 512, into: $0) }
        for (x, y, color) in [(28, 28, [UInt8(255), 0, 0, 255]), (52, 28, [0, 255, 0, 255]),
            (76, 28, [0, 0, 255, 255]), (100, 28, [0, 255, 0, 255]), (116, 30, [0, 255, 0, 255])] {
            let pixel = (y * 128 + x) * 4
            XCTAssertEqual(Array(pixels[pixel..<pixel + 4]), color, "\(x),\(y)")
        }
    }
}
#endif
