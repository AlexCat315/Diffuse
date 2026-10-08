#if canImport(Metal)
import Foundation
import Metal
import XCTest
@testable import NativeRHI

final class MetalSlangTests: XCTestCase {
    func testSlangComputeUsesReflectedEightThreadWorkgroups() throws {
        let artifact = try ShaderFixtures.compile("compute", entry: "computeMain", stage: .compute, target: "metal")
        XCTAssertEqual(artifact.interface.threadgroupSize.x, 8)
        let device = try Device.make(DeviceConfig(preferredBackends: [.metal]))
        let shader = try device.makeShaderModule(artifact.moduleDescriptor())
        let buffer = try device.makeBuffer(BufferDescriptor(size: 64, usage: [.storageWrite, .transferSource]))
        let target = try device.makeTexture(TextureDescriptor(width: 16, height: 1, format: .r32Uint,
            usage: [.transferDestination, .transferSource]))
        let binding = try device.makeBindingLayout(artifact.bindingLayoutDescriptor())
        let layout = try device.makePipelineLayout(PipelineLayoutDescriptor(setLayouts: [binding]))
        let set = try device.makeBindingSet(layout: binding, descriptor: BindingSetDescriptor(entries: [
            BindingSetEntry(slot: 0, resource: .storageBuffer(buffer: buffer))]))
        let pipeline = try device.makeComputePipeline(ComputePipelineDescriptor(layout: layout, shader: shader))
        let commands = CommandBuffer()
        commands.computePass {
            $0.setPipeline(pipeline)
            $0.setBindingSet(set)
            $0.dispatch(groupsX: 2)
        }
        commands.copyPass {
            $0.uploadBufferToTexture(.init(buffer: buffer, bytesPerRow: 64, texture: target, region: .init(width: 16, height: 1)))
        }
        try device.beginFrame()
        try device.submit(commands)
        device.endFrame()
        try device.waitUntilIdle()
        var values = [UInt32](repeating: 0, count: 16)
        try values.withUnsafeMutableBytes {
            try device.readTextureData(target, width: 16, height: 1, bytesPerRow: 64, into: $0)
        }
        XCTAssertEqual(values, (7..<23).map(UInt32.init))
    }

    func testSlangMeshPipelineDrawsGreenTriangle() throws {
        let device = try Device.make(DeviceConfig(preferredBackends: [.metal]))
        guard device.capabilities.meshShading.mesh else { throw XCTSkip("No mesh shader GPU") }
        let mesh = try device.makeShaderModule(ShaderFixtures.compile("mesh", entry: "meshMain", stage: .mesh, target: "metal", groups: [3, 1, 1]).moduleDescriptor())
        let fragment = try device.makeShaderModule(ShaderFixtures.compile("mesh", entry: "fragmentMain", stage: .fragment, target: "metal").moduleDescriptor())
        let layout = try device.makePipelineLayout(PipelineLayoutDescriptor(setLayouts: []))
        var descriptor = MeshPipelineDescriptor(layout: layout, mesh: mesh)
        descriptor.fragment = fragment
        descriptor.colorAttachments = [ColorAttachmentDescriptor(format: .rgba8Unorm)]
        let pipeline = try device.makeMeshPipeline(descriptor)
        let target = try device.makeTexture(TextureDescriptor(width: 8, height: 8, format: .rgba8Unorm,
            usage: [.colorTarget, .transferSource]))
        let commands = CommandBuffer()
        commands.renderPass(descriptor: RenderPassDescriptor(colorTargets: [
            RenderColorTarget(texture: target, loadAction: .clear(SIMD4(1, 0, 0, 1)))])) {
            $0.setMeshPipeline(pipeline)
            $0.setViewport(Viewport(width: 8, height: 8))
            $0.drawMeshTasks(x: 1)
        }
        try device.beginFrame()
        try device.submit(commands)
        device.endFrame()
        try device.waitUntilIdle()
        var pixels = [UInt8](repeating: 0, count: 256)
        try pixels.withUnsafeMutableBytes {
            try device.readTextureData(target, width: 8, height: 8, bytesPerRow: 32, into: $0)
        }
        XCTAssertEqual(Array(pixels[(4 * 8 + 4) * 4..<(4 * 8 + 4) * 4 + 4]), [0, 255, 0, 255])
        XCTAssertEqual(pixels[0], 255)
    }
}
#endif
