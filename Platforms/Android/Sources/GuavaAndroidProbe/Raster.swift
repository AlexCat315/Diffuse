import Foundation
import NativeRHI

extension ProbeContext {
    func raster(samples: Int) throws -> String {
        let vertex = try shader("raster.vertex"), fragment = try shader("raster.fragment")
        let binding = try device.makeBindingLayout(BindingLayoutDescriptor(reflecting: [vertex, fragment]))
        let layout = try device.makePipelineLayout(PipelineLayoutDescriptor(setLayouts: [binding]))
        let vs = try device.makeShaderModule(vertex.moduleDescriptor()), fs = try device.makeShaderModule(fragment.moduleDescriptor())
        var raster = RasterizationState(); raster.cullMode = .none
        var descriptor = GraphicsPipelineDescriptor(layout: layout, vertex: vs, fragment: fs,
            colorAttachments: [ColorAttachmentDescriptor(format: .rgba8Unorm)], depthFormat: .depth32Float,
            rasterization: raster, depthStencil: DepthStencilState())
        descriptor.sampleCount = samples
        let pipeline = try device.makeGraphicsPipeline(descriptor)
        let buffer = try device.makeBuffer(BufferDescriptor(size: 256, usage: [.uniform]))
        var green = SIMD4<Float>(0, 1, 0, 1)
        try withUnsafeBytes(of: &green) { try device.uploadBufferData(buffer, data: Data($0)) }
        let indirect = try device.makeBuffer(BufferDescriptor(size: 16, usage: .indirect))
        try [UInt32(3), 1, 0, 0].withUnsafeBytes { try device.uploadBufferData(indirect, data: Data($0)) }
        let set = try device.makeBindingSet(layout: binding, descriptor: BindingSetDescriptor(entries: [
            BindingSetEntry(slot: 0, resource: .uniformBuffer(buffer: buffer))]))
        let target = try device.makeTexture(TextureDescriptor(width: 64, height: 64, format: .rgba8Unorm,
            usage: [.colorTarget, .transferSource]))
        let color = samples == 1 ? target : try device.makeTexture(TextureDescriptor(width: 64, height: 64,
            format: .rgba8Unorm, usage: .colorTarget, sampleCount: samples))
        let depth = try device.makeTexture(TextureDescriptor(width: 64, height: 64, format: .depth32Float,
            usage: .depthStencilTarget, sampleCount: samples))
        defer {
            device.destroy(depth); if samples != 1 { device.destroy(color) }; device.destroy(target)
            device.destroy(buffer); device.destroy(indirect); device.destroy(pipeline); device.destroy(vs); device.destroy(fs)
        }
        for index in 0..<6 {
            let commands = CommandBuffer()
            var attachment = RenderColorTarget(texture: color, loadAction: .clear(SIMD4(1, 0, 0, 1)))
            if samples != 1 { attachment.resolveTexture = target }
            commands.renderPass(descriptor: RenderPassDescriptor(colorTargets: [attachment],
                depthTarget: RenderDepthTarget(texture: depth, loadAction: .clear(1)))) {
                $0.setPipeline(pipeline); $0.setBindingSet(set)
                if index % 2 == 0 { $0.draw(vertexCount: 3) }
                else { $0.drawIndirect(buffer: indirect) }
            }
            // The second pass must preserve the result of the first, including
            // a multisample resolve consumed in the same command list.
            commands.renderPass(descriptor: RenderPassDescriptor(colorTargets: [RenderColorTarget(texture: target, loadAction: .load)])) { _ in }
            try submit(commands)
        }
        let pixels = try read(target, width: 64, height: 64)
        let center = (32 * 64 + 32) * 4
        try require(Array(pixels[center..<center + 4]) == [0, 255, 0, 255], "raster center mismatch")
        try require(Array(pixels[0..<4]) == [255, 0, 0, 255], "raster background/load mismatch")
        if samples == 4 {
            try require(stride(from: 0, to: pixels.count, by: 4).contains { pixels[$0] > 0 && pixels[$0] < 255 }, "MSAA edge coverage is missing")
        }
        try writeImage(pixels, width: 64, height: 64, name: "raster-\(samples)x")
        return "6 frames, direct/indirect draw, depth, uniform binding, load preservation and \(samples)x samples verified"
    }
}
