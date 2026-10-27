import AssetPipeline
import Foundation
import NativeRHI
import SceneRuntime
import SIMDCompat

struct NativePreparedMeshDraw {
    let batch: NativeMeshBatch
    let bindings: BindingSet
    /// Per-draw offsets for the layout's dynamic slots, ordered by ascending
    /// slot (draw/instances, scene lights, shadows, style).
    let dynamicOffsets: [UInt32]
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

/// A ring-backed uniform block resolved to its persistent chunk buffer and the
/// offset of this frame's data. The descriptor binds the chunk at offset 0 and
/// the per-frame offset is supplied as a dynamic offset at bind time.
private struct NativeRingBlock {
    let buffer: Buffer
    let offset: UInt32
    let size: Int
}

private func ringBlock(_ resource: BindingResource) throws -> NativeRingBlock {
    guard case .uniformBuffer(let buffer, let offset, let size?) = resource else {
        throw RHIError.layoutMismatch("expected a bounded ring uniform block")
    }
    return NativeRingBlock(buffer: buffer, offset: UInt32(offset), size: size)
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
        let style = try ringBlock(NativeUniformUpload.binding(StylizedCharacterUniforms(style: packet.renderSettings.stylization.style), device: device))
        let lights = try ringBlock(lighting.lights)
        let shadows = try ringBlock(lighting.shadows)
        var draws: [NativePreparedMeshDraw] = []
        for batch in prepared.batches {
            let mesh = batch.mesh, key = batch.key, uniforms = batch.uniforms
            let bytes = uniforms.withUnsafeBytes { Data($0) }
            let instance = try device.uploadTransient(bytes)
            let instanceOffset = UInt32(instance.offset)
            let bindings = try device.makeBindingSet(layout: shaders.bindings, descriptor: BindingSetDescriptor(entries: [
                BindingSetEntry(slot: 0, resource: .uniformBuffer(buffer: instance.buffer, offset: 0, size: MemoryLayout<MeshInstanceUniforms>.stride)),
                BindingSetEntry(slot: 1, resource: .storageBuffer(buffer: instance.buffer, offset: 0)),
                BindingSetEntry(slot: 2, resource: .sampler(store.sampler)),
                BindingSetEntry(slot: 3, resource: .texture(key.baseTexture.flatMap { mesh.textures[$0] } ?? store.fallbacks[0])),
                BindingSetEntry(slot: 4, resource: .uniformBuffer(buffer: lights.buffer, offset: 0, size: lights.size)),
                BindingSetEntry(slot: 5, resource: .texture(key.normalTexture.flatMap { mesh.textures[$0] } ?? store.fallbacks[1])),
                BindingSetEntry(slot: 6, resource: .texture(key.mrTexture.flatMap { mesh.textures[$0] } ?? store.fallbacks[2])),
                BindingSetEntry(slot: 7, resource: .uniformBuffer(buffer: shadows.buffer, offset: 0, size: shadows.size)),
                BindingSetEntry(slot: 8, resource: .sampler(lighting.sampler)),
                BindingSetEntry(slot: 9, resource: .texture(lighting.atlas)),
                BindingSetEntry(slot: 10, resource: .texture(lighting.environment)),
                BindingSetEntry(slot: 11, resource: skin[batch.skinEntity].parameters),
                BindingSetEntry(slot: 12, resource: skin[batch.skinEntity].matrices),
                BindingSetEntry(slot: 13, resource: .uniformBuffer(buffer: style.buffer, offset: 0, size: style.size))
            ]))
            let dynamicOffsets: [UInt32] = [
                instanceOffset, instanceOffset,
                lights.offset, shadows.offset, style.offset
            ]
            let stylized = packet.renderSettings.stylization.enabled
            let base = try pipeline(key: key,kind: .color,hdr: hdr,stylized: stylized)
            let depth = depthPrepass && key.mode != .blend ? try pipeline(key: key,kind: .depth,hdr: hdr,stylized: false) : nil
            let outline = stylized && key.mode != .blend && MeshOutlinePolicy.includes(bounds: batch.mesh.geometry.bounds)
                ? try pipeline(key: key,kind: .outline,hdr: hdr,stylized: false) : nil
            draws.append(NativePreparedMeshDraw(batch: batch, bindings: bindings, dynamicOffsets: dynamicOffsets,
                basePipeline: base, depthPipeline: depth, outlinePipeline: outline))
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
                pass.setBindingSet(draw.bindings, dynamicOffsets: draw.dynamicOffsets); pass.setVertexBuffer(draw.batch.geometry.vertices)
                pass.setIndexBuffer(draw.batch.geometry.indices, type: .uint32)
                pass.drawIndexed(DrawIndexedArguments(indexCount: draw.batch.key.indexCount, instanceCount: draw.batch.uniforms.count, firstIndex: draw.batch.key.firstIndex))
            }
        }
    }
    private func pipeline(key: NativeMeshBatchKey, kind: NativeMeshPassKind, hdr: Bool, stylized: Bool) throws -> GraphicsPipeline {
        let variant = NativeMeshPipelineKey(kind: kind,stylized: stylized,hdr: hdr, mirrored: key.mirrored, doubleSided: key.doubleSided, blend: key.mode == .blend)
        return try pipeline(variant)
    }
    func prewarm(settings: RenderSettings) throws {
        for mirrored in [false, true] {
            for doubleSided in [false, true] {
                for blend in [false, true] {
                    _ = try pipeline(NativeMeshPipelineKey(kind: .color, stylized: settings.stylization.enabled,
                        hdr: settings.shading.pbr, mirrored: mirrored, doubleSided: doubleSided, blend: blend))
                    if !blend, settings.shading.depthPrepass {
                        _ = try pipeline(NativeMeshPipelineKey(kind: .depth, stylized: false,
                            hdr: settings.shading.pbr, mirrored: mirrored, doubleSided: doubleSided, blend: false))
                    }
                    if !blend, settings.stylization.enabled {
                        _ = try pipeline(NativeMeshPipelineKey(kind: .outline, stylized: false,
                            hdr: settings.shading.pbr, mirrored: mirrored, doubleSided: doubleSided, blend: false))
                    }
                }
            }
        }
    }
    private func pipeline(_ variant: NativeMeshPipelineKey) throws -> GraphicsPipeline {
        let kind = variant.kind, hdr = variant.hdr, stylized = variant.stylized
        if let existing = pipelines[variant] { return existing }
        let pipeline = try device.makeGraphicsPipeline(GraphicsPipelineDescriptor(layout: pipelineLayout,
            vertex: shaders[kind == .outline ? .outlineVertex : .vertex],
            fragment: shaders[kind == .outline ? .outlineFragment : kind == .depth ? .depth : stylized ? .stylized : .color],
            colorAttachments: kind == .depth ? [] : [ColorAttachmentDescriptor(format: hdr ? .rgba16Float : .bgra8Unorm, blend: variant.blend ? .alphaBlend : .opaque)],
            rasterization: RasterizationState(cullMode: kind == .outline ? .front : variant.doubleSided ? .none : .back,
                frontWinding: variant.mirrored ? .clockwise : .counterClockwise),
            depthStencil: DepthStencilState(depthCompare: kind == .depth ? .less : .lessOrEqual, depthWriteEnabled: !variant.blend && kind != .outline),
            vertexLayout: NativeMeshVertexLayout.descriptor, label: "native-mesh-\(kind)"))
        pipelines[variant] = pipeline; return pipeline
    }
}
