import Foundation
import NativeRHI
import SceneRuntime
import SIMDCompat

private struct NativeShadowPipelineKey: Hashable {
    let mirrored: Bool
    let doubleSided: Bool
}
struct NativeShadowDraw {
    let batch: NativeMeshBatch
    let bindings: BindingSet
    let pipeline: GraphicsPipeline
}
struct NativeShadowTile {
    let light: ShadowAtlasLight
    let draws: [NativeShadowDraw]
}
private struct NativeShadowTargets {
    let size: UInt32
    let color: Texture
    let depth: Texture
    func destroy(device: Device) { device.destroy(color); device.destroy(depth) }
}

/// A color depth atlas preserves the existing five-tap shadow filtering contract.
final class NativeShadowPass {
    private let device: Device
    private let bindings: BindingLayout
    private let layout: PipelineLayout
    private let vertex: ShaderModule
    private let fragment: ShaderModule
    private var pipelines: [NativeShadowPipelineKey: GraphicsPipeline] = [:]
    private var targets: NativeShadowTargets?
    var atlas: Texture? { targets?.color }
    init(device: Device) throws {
        self.device = device
        let vs = try NativeShaderLibrary.artifact(name: "shadow_mesh", api: device.backendAPI, stage: .vertex)
        let fs = try NativeShaderLibrary.artifact(name: "shadow_mesh", api: device.backendAPI, stage: .fragment)
        bindings = try device.makeBindingLayout(NativeShaderLibrary.layout(artifacts: [vs,fs]))
        layout = try device.makePipelineLayout(PipelineLayoutDescriptor(setLayouts: [bindings]))
        let module = try device.makeShaderModule(vs.moduleDescriptor())
        do { fragment = try device.makeShaderModule(fs.moduleDescriptor()); vertex = module }
        catch { device.destroy(module); throw error }
    }
    deinit {
        targets?.destroy(device: device); pipelines.values.forEach { device.destroy($0) }
        device.destroy(vertex); device.destroy(fragment)
    }
    func ensureTargets(plan: ShadowAtlasPlan) throws {
        guard !plan.lights.isEmpty, targets?.size != plan.atlasSize else { return }
        let color = try device.makeTexture(TextureDescriptor(width: Int(plan.atlasSize), height: Int(plan.atlasSize),
            format: .rgba16Float, usage: [.sampled,.colorTarget], label: "native-shadow-atlas"))
        do {
            let depth = try device.makeTexture(TextureDescriptor(width: Int(plan.atlasSize), height: Int(plan.atlasSize),
                format: .depth32Float, usage: .depthStencilTarget, label: "native-shadow-depth"))
            targets?.destroy(device: device); targets = NativeShadowTargets(size: plan.atlasSize, color: color, depth: depth)
        } catch { device.destroy(color); throw error }
    }
    func prepare(packet: RenderPacket, store: NativeMeshStore, plan: ShadowAtlasPlan, skin: NativeSkinBindings,
                 deformables: [EntityID: NativeMeshGeometry]) throws -> [NativeShadowTile] {
        guard !plan.lights.isEmpty else { return [] }
        let batches = try NativeMeshBatchPlanner.prepare(packet: packet, store: store,
            viewProjection: matrix_identity_float4x4, deformables: deformables, shadow: true).batches
        // Every atlas tile shares the same caster geometry/instances. Upload it
        // once; only the 64-byte light matrix differs between tiles.
        let uploads = try batches.map { try device.uploadTransient($0.uniforms.withUnsafeBytes { Data($0) }) }
        return try plan.lights.map { light in
            let view = try NativeUniformUpload.binding(ShadowRenderUniforms(lightViewProjection: light.lightViewProjection), device: device)
            let draws = try batches.enumerated().map { index, batch in
                let upload = uploads[index]
                let set = try device.makeBindingSet(layout: bindings, descriptor: BindingSetDescriptor(entries: [
                    BindingSetEntry(slot: 0, resource: .uniformBuffer(buffer: upload.buffer, offset: upload.offset, size: MemoryLayout<MeshInstanceUniforms>.stride)),
                    BindingSetEntry(slot: 1, resource: .storageBuffer(buffer: upload.buffer, offset: upload.offset)),
                    BindingSetEntry(slot: 2, resource: .sampler(store.sampler)),
                    BindingSetEntry(slot: 3, resource: .texture(batch.key.baseTexture.flatMap { batch.mesh.textures[$0] } ?? store.fallbacks[0])),
                    BindingSetEntry(slot: 4, resource: view),
                    BindingSetEntry(slot: 11, resource: skin[batch.skinEntity].parameters),
                    BindingSetEntry(slot: 12, resource: skin[batch.skinEntity].matrices)
                ]))
                return try NativeShadowDraw(batch: batch, bindings: set, pipeline: pipeline(key: batch.key))
            }
            return NativeShadowTile(light: light, draws: draws)
        }
    }
    func encode(tiles: [NativeShadowTile], plan: ShadowAtlasPlan, into commands: CommandBuffer) {
        guard !tiles.isEmpty, let targets else { return }
        commands.renderPass(descriptor: RenderPassDescriptor(colorTargets: [
            RenderColorTarget(texture: targets.color, loadAction: .clear(SIMD4(1,1,1,1)))],
            depthTarget: RenderDepthTarget(texture: targets.depth, loadAction: .clear(1)))) { pass in
            for tile in tiles {
                let x = Int(tile.light.tileX*plan.tileSize), y = Int(tile.light.tileY*plan.tileSize)
                pass.setViewport(Viewport(x: Double(x), y: Double(y), width: Double(plan.tileSize), height: Double(plan.tileSize)))
                pass.setScissor(ScissorRect(x: x, y: y, width: Int(plan.tileSize), height: Int(plan.tileSize)))
                for draw in tile.draws {
                    pass.setPipeline(draw.pipeline); pass.setBindingSet(draw.bindings)
                    pass.setVertexBuffer(draw.batch.geometry.vertices); pass.setIndexBuffer(draw.batch.geometry.indices, type: .uint32)
                    pass.drawIndexed(DrawIndexedArguments(indexCount: draw.batch.key.indexCount,
                        instanceCount: draw.batch.uniforms.count, firstIndex: draw.batch.key.firstIndex))
                }
            }
        }
    }
    private func pipeline(key: NativeMeshBatchKey) throws -> GraphicsPipeline {
        let variant = NativeShadowPipelineKey(mirrored: key.mirrored, doubleSided: key.doubleSided)
        if let existing = pipelines[variant] { return existing }
        let pipeline = try device.makeGraphicsPipeline(GraphicsPipelineDescriptor(layout: layout, vertex: vertex, fragment: fragment,
            colorAttachments: [ColorAttachmentDescriptor(format: .rgba16Float)],
            rasterization: RasterizationState(cullMode: key.doubleSided ? .none : .back,
                frontWinding: key.mirrored ? .clockwise : .counterClockwise),
            depthStencil: DepthStencilState(depthCompare: .less, depthWriteEnabled: true),
            vertexLayout: NativeMeshVertexLayout.descriptor, label: "native-shadow"))
        pipelines[variant] = pipeline; return pipeline
    }
}
