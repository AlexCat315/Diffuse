import Foundation
import NativeRHI

extension ProbeContext {
    func transfer() throws -> String {
        let input = try device.makeTexture(TextureDescriptor(width: 8, height: 8, format: .rgba8Unorm,
            usage: [.transferSource, .transferDestination]))
        let output = try device.makeTexture(TextureDescriptor(width: 8, height: 8, format: .rgba8Unorm,
            usage: [.transferSource, .transferDestination]))
        defer { device.destroy(input); device.destroy(output) }
        let bytes = (0..<256).map { UInt8($0) }
        try device.uploadTextureData(input, data: Data(bytes), region: .init(width: 8, height: 8), bytesPerRow: 32)
        let commands = CommandBuffer()
        commands.copyPass { $0.copyTexture(src: input, dst: output, width: 8, height: 8) }
        try submit(commands, queue: .transfer)
        try require(try read(output, width: 8, height: 8) == bytes, "texture upload/copy/readback mismatch")
        return "all 256 bytes match after upload, transfer queue copy and readback"
    }

    func compute() throws -> String {
        let artifact = try shader("compute")
        let module = try device.makeShaderModule(artifact.moduleDescriptor())
        let binding = try device.makeBindingLayout(artifact.bindingLayoutDescriptor())
        let layout = try device.makePipelineLayout(PipelineLayoutDescriptor(setLayouts: [binding]))
        let pipeline = try device.makeComputePipeline(ComputePipelineDescriptor(layout: layout, shader: module))
        let buffer = try device.makeBuffer(BufferDescriptor(size: 64, usage: [.storageWrite, .transferSource]))
        let indirect = try device.makeBuffer(BufferDescriptor(size: 12, usage: .indirect))
        try [UInt32(2), 1, 1].withUnsafeBytes { try device.uploadBufferData(indirect, data: Data($0)) }
        let texture = try device.makeTexture(TextureDescriptor(width: 16, height: 1, format: .r32Uint,
            usage: [.transferSource, .transferDestination]))
        let set = try device.makeBindingSet(layout: binding, descriptor: BindingSetDescriptor(entries: [
            BindingSetEntry(slot: 0, resource: .storageBuffer(buffer: buffer))]))
        defer { device.destroy(buffer); device.destroy(indirect); device.destroy(texture); device.destroy(pipeline); device.destroy(module) }
        let commands = CommandBuffer()
        commands.computePass { $0.setPipeline(pipeline); $0.setBindingSet(set); $0.dispatchIndirect(buffer: indirect) }
        commands.copyPass { $0.uploadBufferToTexture(.init(buffer: buffer, bytesPerRow: 64, texture: texture, region: .init(width: 16, height: 1))) }
        try submit(commands, queue: .compute)
        var values = [UInt32](repeating: 0, count: 16)
        try values.withUnsafeMutableBytes { try device.readTextureData(texture, width: 16, height: 1, bytesPerRow: 64, into: $0) }
        try require(values == (7..<23).map(UInt32.init), "compute storage buffer mismatch: \(values)")
        return "16 indirect-dispatch compute results match on the compute queue"
    }
}
