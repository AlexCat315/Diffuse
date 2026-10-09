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
    let outlinePipeline: GraphicsPipeline?
    func pipeline(for kind: NativeMeshPassKind) -> GraphicsPipeline {
        switch kind { case .color: basePipeline; case .depth: depthPipeline!; case .outline: outlinePipeline! }
    }
}
enum NativeMeshPassKind: Hashable { case color, depth, outline }
private struct NativeMeshPipelineKey: Hashable {
    let kind: NativeMeshPassKind
    let stylized: Bool
    let hdr: Bool
    let mirrored: Bool
    let doubleSided: Bool
    let blend: Bool
}

/// Preparation resolves visibility/materials and allocates only frame-owned
/// instance data. Pipeline variants and immutable layouts remain resident.
final class NativeMeshPass {
    private let device: Device
    private let shaders: NativeMeshShaders
    private let pipelineLayout: PipelineLayout
    private var pipelines: [NativeMeshPipelineKey: GraphicsPipeline] = [:]

    init(device: Device) throws {
        self.device = device
        shaders = try NativeMeshShaders(device: device)
        pipelineLayout = try device.makePipelineLayout(PipelineLayoutDescriptor(setLayouts: [shaders.bindings]))
    }
    deinit {
        pipelines.values.forEach { device.destroy($0) }
    }

    func prepare(packet: RenderPacket, store: NativeMeshStore,
                 matrices: RenderCameraMatrices, depthPrepass: Bool, hdr: Bool, lighting: NativeLightingBindings, skin: NativeSkinBindings,
                 deformables: [EntityID: NativeMeshGeometry]) throws -> (draws: [NativePreparedMeshDraw], visibility: MeshVisibilityPlan) {
        let prepared = try NativeMeshBatchPlanner.prepare(packet: packet, store: store, viewProjection: matrices.viewProjection, deformables: deformables)
        let style = try NativeUniformUpload.binding(StylizedCharacterUniforms(style: packet.renderSettings.stylizedCharacterStyle),device: device)
        var draws: [NativePreparedMeshDraw] = []
        for batch in prepared.batches {
            let mesh = batch.mesh, key = batch.key, uniforms = batch.uniforms
            let bytes = uniforms.withUnsafeBytes { Data($0) }
            let upload = try device.uploadTransient(bytes)
            let bindings = try device.makeBindingSet(layout: shaders.bindings, descriptor: BindingSetDescriptor(entries: [
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
                BindingSetEntry(slot: 12, resource: skin[batch.skinEntity].matrices),
                BindingSetEntry(slot: 13, resource: style)
            ]))
            let stylized = packet.renderSettings.enableStylizedCharacterShading
            let base = try pipeline(key: key,kind: .color,hdr: hdr,stylized: stylized)
            let depth = depthPrepass && key.mode != .blend ? try pipeline(key: key,kind: .depth,hdr: hdr,stylized: false) : nil
            let outline = stylized && key.mode != .blend && MeshOutlinePolicy.includes(bounds: batch.mesh.geometry.bounds)
                ? try pipeline(key: key,kind: .outline,hdr: hdr,stylized: false) : nil
            draws.append(NativePreparedMeshDraw(batch: batch, bindings: bindings, basePipeline: base, depthPipeline: depth,outlinePipeline: outline))
        }
        return (draws, prepared.visibility)
    }

    func encode(draws: [NativePreparedMeshDraw], size: RenderDrawableSize,
                color: RenderColorTarget?, depth: RenderDepthTarget, kind: NativeMeshPassKind = .color, into commands: CommandBuffer) {
        commands.renderPass(descriptor: RenderPassDescriptor(colorTargets: color.map { [$0] } ?? [], depthTarget: depth)) { pass in
            pass.setViewport(Viewport(width: Double(size.width), height: Double(size.height)))
            pass.setScissor(ScissorRect(width: Int(size.width), height: Int(size.height)))
            for draw in draws {
                pass.setPipeline(draw.pipeline(for: kind))
                pass.setBindingSet(draw.bindings); pass.setVertexBuffer(draw.batch.geometry.vertices)
                pass.setIndexBuffer(draw.batch.geometry.indices, type: .uint32)
                pass.drawIndexed(DrawIndexedArguments(indexCount: draw.batch.key.indexCount, instanceCount: draw.batch.uniforms.count, firstIndex: draw.batch.key.firstIndex))
            }
        }
    }
    private func pipeline(key: NativeMeshBatchKey, kind: NativeMeshPassKind, hdr: Bool, stylized: Bool) throws -> GraphicsPipeline {
        let variant = NativeMeshPipelineKey(kind: kind,stylized: stylized,hdr: hdr, mirrored: key.mirrored, doubleSided: key.doubleSided, blend: key.mode == .blend)
        if let existing = pipelines[variant] { return existing }
        let pipeline = try device.makeGraphicsPipeline(GraphicsPipelineDescriptor(layout: pipelineLayout,
            vertex: shaders[kind == .outline ? .outlineVertex : .vertex],
            fragment: shaders[kind == .outline ? .outlineFragment : kind == .depth ? .depth : stylized ? .stylized : .color],
            colorAttachments: kind == .depth ? [] : [ColorAttachmentDescriptor(format: hdr ? .rgba16Float : .bgra8Unorm, blend: variant.blend ? .alphaBlend : .opaque)],
            rasterization: RasterizationState(cullMode: kind == .outline ? .front : key.doubleSided ? .none : .back,
                frontWinding: key.mirrored ? .clockwise : .counterClockwise),
            depthStencil: DepthStencilState(depthCompare: kind == .depth ? .less : .lessOrEqual, depthWriteEnabled: !variant.blend && kind != .outline),
            vertexLayout: NativeMeshVertexLayout.descriptor, label: "native-mesh-\(kind)"))
        pipelines[variant] = pipeline; return pipeline
    }
}
