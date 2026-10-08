import CDX12Bridge
import Foundation

extension DX12Device {
    public func createBuffer(_ handle: Buffer, descriptor: BufferDescriptor) throws {
        guard descriptor.size > 0 else { throw RHIError.invalidArgument("buffer size must be positive") }
        try check(grhi_dx12_buffer(native, handle.id, UInt64(descriptor.size), descriptor.usage.rawValue, 0))
        resources.buffers[handle.id] = descriptor
    }
    public func createTexture(_ handle: Texture, descriptor: TextureDescriptor) throws {
        var desc = try GRHI_TextureDesc(width: rhiCount(descriptor.width), height: rhiCount(descriptor.height), depth: rhiCount(descriptor.depth), layers: rhiCount(descriptor.layers), mips: rhiCount(descriptor.mipLevels), samples: rhiCount(descriptor.sampleCount), format: descriptor.format.dx12, usage: descriptor.usage.rawValue, dimension: descriptor.dimension.dx12)
        try check(grhi_dx12_texture(native, handle.id, &desc)); resources.textures[handle.id] = descriptor
    }
    public func createSampler(_ handle: Sampler, descriptor: SamplerDescriptor) throws {
        var desc = GRHI_SamplerDesc(min_filter: descriptor.minFilter == .linear ? 1 : 0, mag_filter: descriptor.magFilter == .linear ? 1 : 0, mip_filter: descriptor.mipFilter == .linear ? 1 : 0, address_u: descriptor.addressModeU.dx12, address_v: descriptor.addressModeV.dx12, address_w: descriptor.addressModeW.dx12, compare_enabled: descriptor.compareEnabled ? 1 : 0, compare_op: descriptor.compareOp.dx12)
        try check(grhi_dx12_sampler(native, handle.id, &desc))
    }
    public func createShaderModule(_ handle: ShaderModule, descriptor: ShaderModuleDescriptor) throws {
        guard descriptor.format == .dxil else { throw RHIError.invalidArgument("DX12 requires DXIL") }
        try descriptor.code.withUnsafeBytes { try check(grhi_dx12_shader(native, handle.id, descriptor.stage.dx12, $0.baseAddress, $0.count)) }
    }
    public func registerBindingLayout(_ handle: BindingLayout, descriptor: BindingLayoutDescriptor) throws {
        let entries = try descriptor.entries.map { try GRHI_BindingDecl(slot: $0.slot, type: $0.type.dx12, stages: $0.visibility.rawValue, read_only: $0.buffer.readOnly ? 1 : 0, element_stride: rhiCount($0.buffer.elementStride)) }
        try entries.withUnsafeBufferPointer { try check(grhi_dx12_binding_layout(native, handle.id, $0.baseAddress, $0.count)) }
    }
    public func registerPipelineLayout(_ handle: PipelineLayout, descriptor: PipelineLayoutDescriptor) throws {
        let sets = descriptor.setLayouts.map(\.id)
        let constants = descriptor.pushConstants.map { GRHI_ConstantDecl(slot: $0.slot, stage: $0.stage.dx12, bytes: UInt32($0.byteCount)) }
        try sets.withUnsafeBufferPointer { setPointer in
            try constants.withUnsafeBufferPointer { try check(grhi_dx12_pipeline_layout(native, handle.id, setPointer.baseAddress, setPointer.count, $0.baseAddress, $0.count)) }
        }
    }
    public func registerBindingSet(_ handle: BindingSet, layout: BindingLayout, layoutEntries: [BindingLayoutEntry], setEntries: [BindingSetEntry]) throws {
        let entries = try setEntries.map { entry -> GRHI_BindingValue in
            var result = GRHI_BindingValue(); result.slot = entry.slot
            switch entry.resource {
            case .sampler(let r): result.resource = r.id; result.type = 0
            case .texture(let r): result.resource = r.id; result.type = 1
            case .storageTexture(let r): result.resource = r.id; result.type = 2
            case .uniformBuffer(let r, let offset), .storageBuffer(let r, let offset):
                guard offset >= 0 else { throw RHIError.invalidArgument("negative binding offset") }
                result.resource = r.id; result.offset = UInt64(offset)
                if case .uniformBuffer = entry.resource { result.type = 3 } else { result.type = 4 }
            case .accelerationStructure(let r): result.resource = r.id; result.type = 5
            }
            return result
        }
        try entries.withUnsafeBufferPointer { try check(grhi_dx12_binding_set(native, handle.id, layout.id, $0.baseAddress, $0.count)) }
    }
    public func uploadBufferData(_ buffer: Buffer, offset: Int, data: Data) throws {
        guard offset >= 0 else { throw RHIError.invalidArgument("negative upload offset") }
        try data.withUnsafeBytes { try check(grhi_dx12_upload_buffer(native, buffer.id, UInt64(offset), $0.baseAddress, $0.count)) }
    }
    public func uploadTextureData(_ texture: Texture, data: Data, width: Int, height: Int, bytesPerRow: Int) throws {
        try data.withUnsafeBytes { try transfer(texture, width: width, height: height, row: bytesPerRow, pointer: UnsafeMutableRawPointer(mutating: $0.baseAddress), size: $0.count, upload: true) }
    }
    public func readTextureData(_ texture: Texture, width: Int, height: Int, bytesPerRow: Int, into destination: UnsafeMutableRawBufferPointer) throws {
        try transfer(texture, width: width, height: height, row: bytesPerRow, pointer: destination.baseAddress, size: destination.count, upload: false)
    }
    private func transfer(_ texture: Texture, width: Int, height: Int, row: Int, pointer: UnsafeMutableRawPointer?, size: Int, upload: Bool) throws {
        try check(grhi_dx12_transfer_texture(native, texture.id, rhiCount(width), rhiCount(height), rhiCount(row), pointer, size, upload ? 1 : 0))
    }
}
