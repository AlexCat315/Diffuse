import AssetPipeline
import Foundation
import NativeRHI
import SceneRuntime
import SIMDCompat

struct NativeMeshBatchKey: Hashable {
    var mesh: Int
    var firstIndex: Int
    var indexCount: Int
    var mode: MaterialAlphaMode
    var cutoff: Float
    var doubleSided: Bool
    var mirrored: Bool
    var color: SIMD4<Float>
    var baseTexture: Int?
    var normalTexture: Int?
    var mrTexture: Int?
    var uniqueInstance: Int?
}
struct NativePreparedMeshDraw {
    let mesh: NativeMesh
    let key: NativeMeshBatchKey
    let bindings: BindingSet
    let instanceCount: Int
    let basePipeline: GraphicsPipeline
    let depthPipeline: GraphicsPipeline?
}
private struct NativeMeshPipelineKey: Hashable {
    let depth: Bool
    let mirrored: Bool
    let doubleSided: Bool
}

/// Preparation resolves visibility/materials and allocates only frame-owned
/// instance data. Pipeline variants and immutable layouts remain resident.
final class NativeOpaquePass {
    private let device: Device
    private let bindingLayout: BindingLayout
    private let pipelineLayout: PipelineLayout
    private let vertex: ShaderModule
    private let fragment: ShaderModule
    private let depthFragment: ShaderModule
    private var pipelines: [NativeMeshPipelineKey: GraphicsPipeline] = [:]

    init(device: Device) throws {
        self.device = device
        let vs = try NativeShaderLibrary.artifact(name: "opaque_mesh", api: device.backendAPI, stage: .vertex)
        let fs = try NativeShaderLibrary.artifact(name: "opaque_mesh", api: device.backendAPI, stage: .fragment)
        let ds = try NativeShaderLibrary.artifact(name: "opaque_depth", api: device.backendAPI, stage: .fragment)
        let reflected = try NativeShaderLibrary.layout(artifacts: [vs,fs,ds])
        // This shader's explicit cross-target slots are part of the offline ABI.
        let expected: [String: UInt32] = ["draw":0,"instances":1,"meshSampler":2,"baseTexture":3,"settings":4,"normalTexture":5,"mrTexture":6]
        guard [vs,fs,ds].allSatisfy({ artifact in artifact.interface.bindings.count == expected.count
            && artifact.interface.bindings.allSatisfy { expected[$0.name] == $0.slot } }) else {
            throw RHIError.layoutMismatch("native opaque shader binding ABI mismatch")
        }
        bindingLayout = try device.makeBindingLayout(reflected)
        pipelineLayout = try device.makePipelineLayout(PipelineLayoutDescriptor(setLayouts: [bindingLayout]))
        let vertexModule = try device.makeShaderModule(vs.moduleDescriptor())
        var fragmentModule: ShaderModule?
        do {
            let colorModule = try device.makeShaderModule(fs.moduleDescriptor()); fragmentModule = colorModule
            depthFragment = try device.makeShaderModule(ds.moduleDescriptor())
            vertex = vertexModule; fragment = colorModule
        } catch { device.destroy(vertexModule); if let fragmentModule { device.destroy(fragmentModule) }; throw error }
    }
    deinit {
        pipelines.values.forEach { device.destroy($0) }
        device.destroy(vertex); device.destroy(fragment); device.destroy(depthFragment)
    }

    func prepare(packet: RenderPacket, store: NativeMeshStore,
                 matrices: RenderCameraMatrices, depthPrepass: Bool) throws -> (draws: [NativePreparedMeshDraw], visibility: MeshVisibilityPlan) {
        let visibility = MeshVisibilityPlan.make(scene: packet.scene, viewProjection: matrices.viewProjection,
            settings: packet.renderSettings, skinnedEntities: [], meshBounds: { store[$0]?.bounds }, meshExists: { store[$0] != nil })
        var members: [NativeMeshBatchKey: [Int]] = [:]
        var order: [NativeMeshBatchKey] = []
        for index in visibility.visibleIndices {
            let instance = packet.scene.instances[index]
            let meshIndex = visibility.meshIndices[index] ?? instance.meshIndex
            guard let mesh = store[meshIndex] else { throw RHIError.invalidArgument("unregistered native mesh \(meshIndex)") }
            for part in mesh.submeshes {
                let material = ResolvedMeshMaterial(imported: mesh.materials[part.materialIndex], runtime: instance.material)
                guard material.modeIsOpaque else { throw RHIError.unsupportedFeature("native transparent mesh pass is pending") }
                let key = NativeMeshBatchKey(mesh: meshIndex, firstIndex: Int(part.indexStart), indexCount: Int(part.indexCount),
                    mode: material.alphaMode, cutoff: material.cutoff, doubleSided: material.doubleSided,
                    mirrored: simd_determinant(instance.transform) < 0, color: material.color,
                    baseTexture: material.baseTexture, normalTexture: material.normalTexture, mrTexture: material.mrTexture,
                    uniqueInstance: packet.renderSettings.enableMeshInstancing ? nil : index)
                if members[key] == nil { order.append(key) }
                members[key, default: []].append(index)
            }
        }
        if packet.renderSettings.enableGroupedDrawByMesh { order.sort { $0.mesh < $1.mesh } }
        let settings = SIMD4<Float>(Float(packet.renderSettings.debugViewMode.rawValue), packet.scene.environment.exposure, 0, 0)
        let settingsData = withUnsafeBytes(of: settings) { Data($0) }
        let settingsUpload = try device.uploadTransient(settingsData)
        var draws: [NativePreparedMeshDraw] = []
        for key in order {
            guard let mesh = store[key.mesh], let indices = members[key] else { continue }
            // Bound each batch to the same maximum as the WGSL path.
            for start in stride(from: 0, to: indices.count, by: 16_384) {
                let uniforms = indices[start..<min(start + 16_384, indices.count)].map { index in
                    let instance = packet.scene.instances[index]
                    return MeshInstanceUniforms(mvp: matrices.viewProjection * instance.transform, model: instance.transform,
                        colorTint: SIMD4(instance.colorTint * SIMD3(key.color.x,key.color.y,key.color.z), key.color.w),
                        material: SIMD4(key.mode == .mask ? 1 : 0, key.cutoff, key.doubleSided ? 1 : 0, 0))
                }
                let bytes = uniforms.withUnsafeBytes { Data($0) }
                let upload = try device.uploadTransient(bytes)
                let bindings = try device.makeBindingSet(layout: bindingLayout, descriptor: BindingSetDescriptor(entries: [
                    BindingSetEntry(slot: 0, resource: .uniformBuffer(buffer: upload.buffer, offset: upload.offset, size: MemoryLayout<MeshInstanceUniforms>.stride)),
                    BindingSetEntry(slot: 1, resource: .storageBuffer(buffer: upload.buffer, offset: upload.offset)),
                    BindingSetEntry(slot: 2, resource: .sampler(store.sampler)),
                    BindingSetEntry(slot: 3, resource: .texture(key.baseTexture.flatMap { mesh.textures[$0] } ?? store.fallbacks[0])),
                    BindingSetEntry(slot: 4, resource: .uniformBuffer(buffer: settingsUpload.buffer, offset: settingsUpload.offset, size: settingsData.count)),
                    BindingSetEntry(slot: 5, resource: .texture(key.normalTexture.flatMap { mesh.textures[$0] } ?? store.fallbacks[1])),
                    BindingSetEntry(slot: 6, resource: .texture(key.mrTexture.flatMap { mesh.textures[$0] } ?? store.fallbacks[2]))
                ]))
                let base = try pipeline(key: key, depth: false)
                let depth = depthPrepass ? try pipeline(key: key, depth: true) : nil
                draws.append(NativePreparedMeshDraw(mesh: mesh, key: key, bindings: bindings,
                    instanceCount: uniforms.count, basePipeline: base, depthPipeline: depth))
            }
        }
        return (draws, visibility)
    }

    func encode(draws: [NativePreparedMeshDraw], size: RenderDrawableSize,
                color: RenderColorTarget?, depth: RenderDepthTarget, depthOnly: Bool, into commands: CommandBuffer) {
        commands.renderPass(descriptor: RenderPassDescriptor(colorTargets: color.map { [$0] } ?? [], depthTarget: depth)) { pass in
            pass.setViewport(Viewport(width: Double(size.width), height: Double(size.height)))
            pass.setScissor(ScissorRect(width: Int(size.width), height: Int(size.height)))
            for draw in draws {
                pass.setPipeline(depthOnly ? draw.depthPipeline! : draw.basePipeline)
                pass.setBindingSet(draw.bindings); pass.setVertexBuffer(draw.mesh.vertices)
                pass.setIndexBuffer(draw.mesh.indices, type: .uint32)
                pass.drawIndexed(DrawIndexedArguments(indexCount: draw.key.indexCount, instanceCount: draw.instanceCount, firstIndex: draw.key.firstIndex))
            }
        }
    }
    private func pipeline(key: NativeMeshBatchKey, depth: Bool) throws -> GraphicsPipeline {
        let variant = NativeMeshPipelineKey(depth: depth, mirrored: key.mirrored, doubleSided: key.doubleSided)
        if let existing = pipelines[variant] { return existing }
        let layout = VertexLayoutDescriptor(attributes: [
            VertexAttribute(location: 0, format: .float3, offset: MeshAsset.positionOffset),
            VertexAttribute(location: 1, format: .float3, offset: MeshAsset.normalOffset),
            VertexAttribute(location: 2, format: .float3, offset: MeshAsset.colorOffset),
            VertexAttribute(location: 3, format: .float2, offset: MeshAsset.uvOffset),
            VertexAttribute(location: 4, format: .float4, offset: MeshAsset.tangentOffset)
        ], bufferLayouts: [VertexBufferLayout(stride: MeshAsset.vertexStride)])
        let pipeline = try device.makeGraphicsPipeline(GraphicsPipelineDescriptor(layout: pipelineLayout,
            vertex: vertex, fragment: depth ? depthFragment : fragment,
            colorAttachments: depth ? [] : [ColorAttachmentDescriptor(format: .bgra8Unorm)],
            rasterization: RasterizationState(cullMode: key.doubleSided ? .none : .back,
                frontWinding: key.mirrored ? .clockwise : .counterClockwise),
            depthStencil: DepthStencilState(depthCompare: depth ? .less : .lessOrEqual, depthWriteEnabled: true),
            vertexLayout: layout, label: depth ? "native-depth" : "native-opaque"))
        pipelines[variant] = pipeline; return pipeline
    }
}
private extension ResolvedMeshMaterial { var modeIsOpaque: Bool { alphaMode != .blend } }
