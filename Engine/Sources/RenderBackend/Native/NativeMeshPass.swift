import AssetPipeline
import Foundation
import NativeRHI
import SceneRuntime
import SIMDCompat

struct NativePreparedMeshDraw {
    let batch: NativeMeshBatch
    let bindings: BindingSet
    let basePipeline: GraphicsPipeline
    let depthPipeline: GraphicsPipeline?
}
private struct NativeMeshPipelineKey: Hashable {
    let depth: Bool
    let hdr: Bool
    let mirrored: Bool
    let doubleSided: Bool
    let blend: Bool
}

/// Preparation resolves visibility/materials and allocates only frame-owned
/// instance data. Pipeline variants and immutable layouts remain resident.
final class NativeMeshPass {
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
        let expected: [String: UInt32] = ["draw":0,"instances":1,"meshSampler":2,"baseTexture":3,"sceneLights":4,"normalTexture":5,"mrTexture":6,"shadow":7,"shadowSampler":8,"shadowTexture":9,"iblTexture":10,"skinParameters":11,"jointPalette":12]
        guard [vs,fs,ds].allSatisfy({ artifact in artifact.interface.bindings.count == expected.count
            && artifact.interface.bindings.allSatisfy { expected[$0.name] == $0.slot } }) else {
            throw RHIError.layoutMismatch("native mesh shader binding ABI mismatch")
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
                 matrices: RenderCameraMatrices, depthPrepass: Bool, hdr: Bool, lighting: NativeLightingBindings, skin: NativeSkinBindings,
                 deformables: [EntityID: NativeMeshGeometry]) throws -> (draws: [NativePreparedMeshDraw], visibility: MeshVisibilityPlan) {
        let prepared = try NativeMeshBatchPlanner.prepare(packet: packet, store: store, viewProjection: matrices.viewProjection, deformables: deformables)
        var draws: [NativePreparedMeshDraw] = []
        for batch in prepared.batches {
            let mesh = batch.mesh, key = batch.key, uniforms = batch.uniforms
            let bytes = uniforms.withUnsafeBytes { Data($0) }
            let upload = try device.uploadTransient(bytes)
            let bindings = try device.makeBindingSet(layout: bindingLayout, descriptor: BindingSetDescriptor(entries: [
                BindingSetEntry(slot: 0, resource: .uniformBuffer(buffer: upload.buffer, offset: upload.offset, size: MemoryLayout<MeshInstanceUniforms>.stride)),
                BindingSetEntry(slot: 1, resource: .storageBuffer(buffer: upload.buffer, offset: upload.offset)),
                BindingSetEntry(slot: 2, resource: .sampler(store.sampler)),
                BindingSetEntry(slot: 3, resource: .texture(key.baseTexture.flatMap { mesh.textures[$0] } ?? store.fallbacks[0])),
                BindingSetEntry(slot: 4, resource: lighting.lights),
                BindingSetEntry(slot: 5, resource: .texture(key.normalTexture.flatMap { mesh.textures[$0] } ?? store.fallbacks[1])),
                BindingSetEntry(slot: 6, resource: .texture(key.mrTexture.flatMap { mesh.textures[$0] } ?? store.fallbacks[2])),
                BindingSetEntry(slot: 7, resource: lighting.shadows),
                BindingSetEntry(slot: 8, resource: .sampler(lighting.sampler)),
                BindingSetEntry(slot: 9, resource: .texture(lighting.atlas)),
                BindingSetEntry(slot: 10, resource: .texture(lighting.environment)),
                BindingSetEntry(slot: 11, resource: skin[batch.skinEntity].parameters),
                BindingSetEntry(slot: 12, resource: skin[batch.skinEntity].matrices)
            ]))
            let base = try pipeline(key: key, depth: false, hdr: hdr)
            let depth = depthPrepass && key.mode != .blend ? try pipeline(key: key, depth: true, hdr: hdr) : nil
            draws.append(NativePreparedMeshDraw(batch: batch, bindings: bindings, basePipeline: base, depthPipeline: depth))
        }
        return (draws, prepared.visibility)
    }

    func encode(draws: [NativePreparedMeshDraw], size: RenderDrawableSize,
                color: RenderColorTarget?, depth: RenderDepthTarget, depthOnly: Bool, into commands: CommandBuffer) {
        commands.renderPass(descriptor: RenderPassDescriptor(colorTargets: color.map { [$0] } ?? [], depthTarget: depth)) { pass in
            pass.setViewport(Viewport(width: Double(size.width), height: Double(size.height)))
            pass.setScissor(ScissorRect(width: Int(size.width), height: Int(size.height)))
            for draw in draws {
                pass.setPipeline(depthOnly ? draw.depthPipeline! : draw.basePipeline)
                pass.setBindingSet(draw.bindings); pass.setVertexBuffer(draw.batch.geometry.vertices)
                pass.setIndexBuffer(draw.batch.geometry.indices, type: .uint32)
                pass.drawIndexed(DrawIndexedArguments(indexCount: draw.batch.key.indexCount, instanceCount: draw.batch.uniforms.count, firstIndex: draw.batch.key.firstIndex))
            }
        }
    }
    private func pipeline(key: NativeMeshBatchKey, depth: Bool, hdr: Bool) throws -> GraphicsPipeline {
        let variant = NativeMeshPipelineKey(depth: depth, hdr: hdr, mirrored: key.mirrored, doubleSided: key.doubleSided, blend: key.mode == .blend)
        if let existing = pipelines[variant] { return existing }
        let pipeline = try device.makeGraphicsPipeline(GraphicsPipelineDescriptor(layout: pipelineLayout,
            vertex: vertex, fragment: depth ? depthFragment : fragment,
            colorAttachments: depth ? [] : [ColorAttachmentDescriptor(format: hdr ? .rgba16Float : .bgra8Unorm, blend: variant.blend ? .alphaBlend : .opaque)],
            rasterization: RasterizationState(cullMode: key.doubleSided ? .none : .back,
                frontWinding: key.mirrored ? .clockwise : .counterClockwise),
            depthStencil: DepthStencilState(depthCompare: depth ? .less : .lessOrEqual, depthWriteEnabled: !variant.blend),
            vertexLayout: NativeMeshVertexLayout.descriptor, label: depth ? "native-depth" : "native-mesh"))
        pipelines[variant] = pipeline; return pipeline
    }
}
