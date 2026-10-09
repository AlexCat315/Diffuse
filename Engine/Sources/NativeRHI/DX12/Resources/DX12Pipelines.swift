import CDX12Bridge
import Foundation

/// Owns borrowed C arrays and strings until synchronous native creation returns.
final class DX12Arguments {
    private var cleanup: [() -> Void] = []
    deinit { for release in cleanup.reversed() { release() } }
    func store<Value>(_ values: [Value]) -> UnsafePointer<Value>? {
        guard !values.isEmpty else { return nil }
        let p = UnsafeMutablePointer<Value>.allocate(capacity: values.count)
        p.initialize(from: values, count: values.count)
        cleanup.append { p.deinitialize(count: values.count); p.deallocate() }
        return UnsafePointer(p)
    }
    func string(_ value: String) -> UnsafePointer<CChar> { store(value.utf8CString.map { $0 })! }
}

extension DX12Device {
    public func createComputePipeline(_ handle: ComputePipeline, descriptor: ComputePipelineDescriptor) throws {
        try check(grhi_dx12_compute_pipeline(native, handle.id, descriptor.layout.id, descriptor.shader.id))
    }
    public func createGraphicsPipeline(_ handle: GraphicsPipeline, descriptor: GraphicsPipelineDescriptor) throws {
        let arena = DX12Arguments()
        var desc = GRHI_GraphicsDesc()
        desc.sample_count = try rhiCount(descriptor.sampleCount)
        desc.layout = descriptor.layout.id; desc.vertex = descriptor.vertex.id; desc.fragment = descriptor.fragment?.id ?? 0
        desc.raster = descriptor.rasterization.dx12(primitive: descriptor.primitive)
        desc.depth = depth(format: descriptor.depthFormat, stencil: descriptor.stencilFormat, state: descriptor.depthStencil)
        desc.colors = arena.store(descriptor.colorAttachments.map(\.dx12)); desc.color_count = try rhiCount(descriptor.colorAttachments.count)
        if let vertex = descriptor.vertexLayout {
            let buffers = try vertex.bufferLayouts.map { try GRHI_VertexBufferLayout(stride: rhiCount($0.stride), per_instance: $0.stepRate == .perInstance ? 1 : 0) }
            let attributes = try vertex.attributes.map { a -> GRHI_VertexAttribute in
                let format: UInt32
                switch a.format { case .float2: format = 0; case .float3: format = 1; case .float4: format = 2; case .float: format = 3; case .unorm8x4: format = 4 }
                return try GRHI_VertexAttribute(location: a.location, format: format, buffer: a.bufferIndex, offset: rhiCount(a.offset), semantic_index: a.semantic.index, semantic: arena.string(a.semantic.name))
            }
            desc.vertex_buffers = arena.store(buffers); desc.vertex_buffer_count = try rhiCount(buffers.count)
            desc.attributes = arena.store(attributes); desc.attribute_count = try rhiCount(attributes.count)
        }
        try withExtendedLifetime(arena) { try check(grhi_dx12_graphics_pipeline(native, handle.id, &desc)) }
    }
    public func createMeshPipeline(_ handle: MeshPipeline, descriptor: MeshPipelineDescriptor) throws {
        let arena = DX12Arguments(); var desc = GRHI_GraphicsDesc()
        desc.sample_count = 1
        desc.layout = descriptor.layout.id; desc.mesh = descriptor.mesh.id; desc.task = descriptor.task?.id ?? 0; desc.fragment = descriptor.fragment?.id ?? 0
        desc.raster = descriptor.rasterization.dx12(primitive: .triangleList)
        desc.depth = depth(format: descriptor.depthFormat, stencil: nil, state: descriptor.depthStencil)
        desc.colors = arena.store(descriptor.colorAttachments.map(\.dx12)); desc.color_count = try rhiCount(descriptor.colorAttachments.count)
        try withExtendedLifetime(arena) { try check(grhi_dx12_graphics_pipeline(native, handle.id, &desc)) }
    }
    private func depth(format: TextureFormat?, stencil: TextureFormat?, state: DepthStencilState?) -> GRHI_DepthDesc {
        GRHI_DepthDesc(format: format?.dx12 ?? 0, stencil_format: stencil?.dx12 ?? 0, enabled: format != nil && state != nil ? 1 : 0, write: state?.depthWriteEnabled == true ? 1 : 0, compare: state?.depthCompare.dx12 ?? 7)
    }
    public func createAccelerationStructure(_ handle: AccelerationStructure, descriptor: AccelerationStructureDescriptor) throws {
        switch descriptor {
        case .bottomLevel(let geometry):
            let inputs = try geometry.map { try GRHI_Triangle(buffer: $0.vertices.id, triangles: rhiCount($0.triangleCount), offset: nonnegative($0.vertexOffset), stride: nonnegative($0.vertexStride)) }
            try inputs.withUnsafeBufferPointer { try check(grhi_dx12_acceleration_structure(native, handle.id, $0.baseAddress, $0.count, nil, 0)) }
        case .topLevel(let instances):
            let inputs = instances.map { i -> GRHI_Instance in
                var native = GRHI_Instance(); native.blas = i.structure.id; native.mask = i.mask
                let values = [i.transform.x, i.transform.y, i.transform.z].flatMap { [$0.x, $0.y, $0.z, $0.w] }
                withUnsafeMutableBytes(of: &native.transform) { bytes in values.withUnsafeBytes { bytes.copyMemory(from: $0) } }
                return native
            }
            try inputs.withUnsafeBufferPointer { try check(grhi_dx12_acceleration_structure(native, handle.id, nil, 0, $0.baseAddress, $0.count)) }
        }
    }
}

func nonnegative(_ value: Int) throws -> UInt64 {
    guard value >= 0 else { throw RHIError.invalidArgument("negative count or byte offset") }
    return UInt64(value)
}
