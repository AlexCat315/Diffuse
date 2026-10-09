import NativeRHI
import SIMDCompat

/// Fullscreen effects own resident pipelines/targets, while all uniforms and
/// bindings belong to the frame. History validity lives in RenderTemporalState.
final class NativePostPasses {
    private let device: Device
    private let sampler: Sampler
    private var pipelines: [RenderPassKind: NativeFullscreenPass] = [:]
    private(set) var targets: NativePostTargets?
    private(set) var revision: UInt64 = 0
    init(device: Device) throws {
        self.device = device
        sampler = try device.makeSampler(SamplerDescriptor(minFilter: .linear,magFilter: .linear,mipFilter: .nearest,
            addressModeU: .clampToEdge,addressModeV: .clampToEdge))
    }
    deinit { targets?.destroy(device: device); device.destroy(sampler) }
    func ensureTargets(size: RenderDrawableSize) throws {
        guard targets?.size != size else { return }
        let replacement = try NativePostTargets.make(device: device,size: size)
        targets?.destroy(device: device); targets = replacement; revision &+= 1
    }
    func encode<T>(kind: RenderPassKind, input: Texture, secondary: Texture, output: Texture,
                   uniforms: T, size: RenderDrawableSize, into commands: CommandBuffer) throws {
        let pipeline: NativeFullscreenPass
        if let existing = pipelines[kind] { pipeline = existing }
        else {
            pipeline = try NativeFullscreenPass(device: device,shader: kind == .inkPaperPost ? "ink_paper_post" : kind.rawValue,
                colorFormat: kind == .fxaa ? .bgra8Unorm : .rgba16Float)
            pipelines[kind] = pipeline
        }
        guard let targets else { throw RHIError.outOfMemory }
        let frame = PostEffectUniforms.frame(used: size,capacity: targets.size)
        try pipeline.encode(size: size,color: RenderColorTarget(texture: output,loadAction: .clear(.zero)),entries: [
            BindingSetEntry(slot: 0,resource: .sampler(sampler)),BindingSetEntry(slot: 1,resource: .texture(input)),
            BindingSetEntry(slot: 2,resource: .texture(secondary)),
            BindingSetEntry(slot: 3,resource: NativeUniformUpload.binding(uniforms,device: device)),
            BindingSetEntry(slot: 4,resource: NativeUniformUpload.binding(frame,device: device))],into: commands)
    }
}
