#if canImport(Metal)
import Foundation
import Metal
import XCTest
@testable import NativeRHI

final class MetalRayQueryTests: XCTestCase {
    func testBuildBlasTlasThenTraceHitAndMiss() throws {
        let device = try Device.make(DeviceConfig(preferredBackends: [.metal]))
        guard device.capabilities.rayTracing.computeRayQuery else { throw XCTSkip("No ray tracing GPU") }
        let vertices: [Float] = [-1, -1, 0, 1, -1, 0, 0, 1, 0]
        let buffer = try device.makeBuffer(BufferDescriptor(size: 36, usage: .storageRead))
        try device.uploadBufferData(buffer, data: vertices.withUnsafeBytes { Data($0) })
        let blas = try device.makeAccelerationStructure(.bottomLevel([TriangleGeometry(vertices: buffer, triangleCount: 1)]))
        var instance = AccelerationInstance(structure: blas)
        instance.transform.x.w = 1
        let tlas = try device.makeAccelerationStructure(.topLevel([instance]))
        let source = """
        #include <metal_stdlib>
        #include <metal_raytracing>
        using namespace metal;
        using namespace raytracing;
        kernel void rayMain(instance_acceleration_structure scene [[buffer(0)]],
                            texture2d<float, access::write> output [[texture(1)]],
                            uint id [[thread_position_in_grid]]) {
            ray r;
            r.origin = float3(id == 0 ? 1.0f : 4.0f, 0, 1);
            r.direction = float3(0, 0, -1);
            r.min_distance = 0.001f;
            r.max_distance = 100.0f;
            intersector<triangle_data, instancing> tracer;
            auto hit = tracer.intersect(r, scene);
            output.write(hit.type == intersection_type::none ? float4(1,0,0,1) : float4(0,1,0,1), uint2(id,0));
        }
        """
        let shader = try device.makeShaderModule(ShaderModuleDescriptor(metalSource: source, stage: .compute, entryPoint: "rayMain"))
        let target = try device.makeTexture(TextureDescriptor(width: 2, height: 1, format: .rgba8Unorm,
            usage: [.storageWrite, .transferSource]))
        let binding = try device.makeBindingLayout(BindingLayoutDescriptor(entries: [
            BindingLayoutEntry(slot: 0, type: .accelerationStructure, stage: .compute),
            BindingLayoutEntry(slot: 1, type: .storageTexture, stage: .compute)]))
        let layout = try device.makePipelineLayout(PipelineLayoutDescriptor(setLayouts: [binding]))
        let set = try device.makeBindingSet(layout: binding, descriptor: BindingSetDescriptor(entries: [
            BindingSetEntry(slot: 0, resource: .accelerationStructure(tlas)),
            BindingSetEntry(slot: 1, resource: .storageTexture(target))]))
        let pipeline = try device.makeComputePipeline(ComputePipelineDescriptor(layout: layout, shader: shader))
        let commands = CommandBuffer()
        try device.recordBuild(blas, into: commands)
        try device.recordBuild(tlas, into: commands)
        commands.computePass {
            $0.setPipeline(pipeline)
            $0.setBindingSet(set)
            $0.dispatch(groupsX: 2)
        }
        try device.beginFrame()
        try device.submit(commands)
        device.endFrame()
        try device.waitUntilIdle()
        var pixels = [UInt8](repeating: 0, count: 8)
        try pixels.withUnsafeMutableBytes {
            try device.readTextureData(target, width: 2, height: 1, bytesPerRow: 8, into: $0)
        }
        XCTAssertEqual(pixels, [0, 255, 0, 255, 255, 0, 0, 255])
    }

    func testRejectsGeometryBeyondTheVertexBuffer() throws {
        let device = try Device.make(DeviceConfig(preferredBackends: [.metal]))
        guard device.capabilities.rayTracing.accelerationStructures else { throw XCTSkip("No ray tracing GPU") }
        let buffer = try device.makeBuffer(BufferDescriptor(size: 12, usage: .storageRead))
        XCTAssertThrowsError(try device.makeAccelerationStructure(.bottomLevel([
            TriangleGeometry(vertices: buffer, triangleCount: 1)])))
        XCTAssertThrowsError(try device.makeAccelerationStructure(.bottomLevel([
            TriangleGeometry(vertices: buffer, triangleCount: Int.max)])))
    }
}
#endif
