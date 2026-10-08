import Foundation
import NativeRHI
import SceneRuntime
import SIMDCompat

private struct NativeParticlePipelineKey: Hashable { let hdr: Bool; let blend: ParticleBlendMode }
struct NativeParticleDraw {
    let pipeline: GraphicsPipeline
    let bindings: BindingSet
}
struct NativeParticleFrame {
    let draws: [NativeParticleDraw]
    let indirect: Buffer
    let candidates: Int
}

/// Stable GPU compaction feeds one indirect draw per authored texture/blend batch.
final class NativeParticlePass {
    private let device: Device
    private let bindings: BindingLayout
    private let layout: PipelineLayout
    private let vertex: ShaderModule
    private let fragment: ShaderModule
    private let cull: NativeComputePass
    private let textures: NativeParticleTextures
    let buffers: NativeParticleBuffers
    private var pipelines: [NativeParticlePipelineKey: GraphicsPipeline] = [:]
    init(device: Device) throws {
        self.device = device
        cull = try NativeComputePass(device: device,shader: "particle_cull_compact",bufferStrides: [
            1: MemoryLayout<GPUParticleInstance>.stride,2: MemoryLayout<GPUParticleCullBatch>.stride,
            3: MemoryLayout<GPUParticleInstance>.stride,4: MemoryLayout<GPUParticleIndirectDrawArgs>.stride])
        textures = try NativeParticleTextures(device: device); buffers = NativeParticleBuffers(device: device)
        let vs = try NativeShaderLibrary.artifact(name: "particles",api: device.backendAPI,stage: .vertex)
        let fs = try NativeShaderLibrary.artifact(name: "particles",api: device.backendAPI,stage: .fragment)
        guard vs.interface.bindings.first(where: { $0.slot == 1 })?.buffer.elementStride == MemoryLayout<GPUParticleInstance>.stride else {
            throw RHIError.layoutMismatch("particle instance shader/host stride differs")
        }
        bindings = try device.makeBindingLayout(NativeShaderLibrary.layout(artifacts: [vs,fs]))
        layout = try device.makePipelineLayout(PipelineLayoutDescriptor(setLayouts: [bindings]))
        vertex = try device.makeShaderModule(vs.moduleDescriptor())
        do { fragment = try device.makeShaderModule(fs.moduleDescriptor()) }
        catch { device.destroy(vertex); throw error }
    }
    deinit { pipelines.values.forEach { device.destroy($0) }; device.destroy(vertex); device.destroy(fragment) }
    func prepare(scene: RenderScene, matrices: RenderCameraMatrices, hdr: Bool, into commands: CommandBuffer) throws -> NativeParticleFrame? {
        guard !scene.particles.isEmpty else { return nil }
        let batches = ParticleRenderBatchPlan(particles: scene.particles).batches
        try buffers.ensure(instances: scene.particles.count,batches: batches.count)
        guard let visible = buffers.visible, let indirect = buffers.indirect else { throw RHIError.outOfMemory }
        let instances = scene.particles.map { GPUParticleInstance(particle: $0) }
        let source = try device.uploadTransient(instances.withUnsafeBytes { Data($0) })
        let ranges = batches.map { GPUParticleCullBatch(sourceStart: UInt32($0.start),sourceCount: UInt32($0.count),outputStart: UInt32($0.start)) }
        let descriptors = try device.uploadTransient(ranges.withUnsafeBytes { Data($0) })
        try cull.encode(entries: [
            BindingSetEntry(slot: 0,resource: NativeUniformUpload.binding(GPUParticleCullUniforms(viewProj: matrices.viewProjection,params: SIMD4(UInt32(batches.count),0,0,0)),device: device)),
            BindingSetEntry(slot: 1,resource: .storageBuffer(buffer: source.buffer,offset: source.offset)),
            BindingSetEntry(slot: 2,resource: .storageBuffer(buffer: descriptors.buffer,offset: descriptors.offset)),
            BindingSetEntry(slot: 3,resource: .storageBuffer(buffer: visible)),
            BindingSetEntry(slot: 4,resource: .storageBuffer(buffer: indirect))
        ],groups: batches.count,into: commands)
        let forward = simd_normalize(scene.camera.target-scene.camera.eye)
        let cross = simd_cross(forward,scene.camera.up), length = simd_length(cross)
        let right = length > 1e-5 ? cross/length : SIMD3<Float>(1,0,0)
        let uniforms = try NativeUniformUpload.binding(ParticleUniforms(viewProj: matrices.viewProjection,
            cameraRight: SIMD4(right,0),cameraUp: SIMD4(simd_cross(right,forward),0),cameraForward: SIMD4(forward,0)),device: device)
        let draws = try batches.map { batch in
            let pipeline = try pipeline(hdr: hdr,blend: batch.key.blendMode)
            let set = try device.makeBindingSet(layout: bindings,descriptor: BindingSetDescriptor(entries: [
                BindingSetEntry(slot: 0,resource: uniforms),BindingSetEntry(slot: 1,resource: .storageBuffer(buffer: visible)),
                BindingSetEntry(slot: 2,resource: .sampler(textures.sampler)),BindingSetEntry(slot: 3,resource: .texture(textures.texture(path: batch.key.texturePath))),
                BindingSetEntry(slot: 4,resource: NativeUniformUpload.binding(SIMD4<UInt32>(UInt32(batch.start),0,0,0),device: device))
            ]))
            return NativeParticleDraw(pipeline: pipeline,bindings: set)
        }
        return NativeParticleFrame(draws: draws,indirect: indirect,candidates: instances.count)
    }
    func encode(_ frame: NativeParticleFrame, size: RenderDrawableSize, color: Texture, depth: Texture, into commands: CommandBuffer) {
        commands.renderPass(descriptor: RenderPassDescriptor(colorTargets: [RenderColorTarget(texture: color,loadAction: .load)],
            depthTarget: RenderDepthTarget(texture: depth,loadAction: .load))) { pass in
            pass.setViewport(Viewport(width: Double(size.width),height: Double(size.height)))
            pass.setScissor(ScissorRect(width: Int(size.width),height: Int(size.height)))
            for (index,draw) in frame.draws.enumerated() {
                pass.setPipeline(draw.pipeline); pass.setBindingSet(draw.bindings)
                pass.drawIndirect(buffer: frame.indirect,offset: index*MemoryLayout<GPUParticleIndirectDrawArgs>.stride)
            }
        }
    }
    private func pipeline(hdr: Bool, blend: ParticleBlendMode) throws -> GraphicsPipeline {
        let key = NativeParticlePipelineKey(hdr: hdr,blend: blend)
        if let existing = pipelines[key] { return existing }
        let state = blend == .alpha ? AttachmentBlendState.alphaBlend : AttachmentBlendState(enabled: true,
            destinationColorBlendFactor: .one,sourceAlphaBlendFactor: .zero,destinationAlphaBlendFactor: .one)
        let result = try device.makeGraphicsPipeline(GraphicsPipelineDescriptor(layout: layout,vertex: vertex,fragment: fragment,
            colorAttachments: [ColorAttachmentDescriptor(format: hdr ? .rgba16Float : .bgra8Unorm,blend: state)],
            rasterization: RasterizationState(cullMode: .none),depthStencil: DepthStencilState(depthCompare: .lessOrEqual,depthWriteEnabled: false),label: "native-particles"))
        pipelines[key] = result; return result
    }
}
