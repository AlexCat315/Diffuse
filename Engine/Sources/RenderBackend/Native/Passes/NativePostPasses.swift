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
    func ensureTargets(size: RenderDrawableSize, requirements: NativePostRequirements) throws {
        if let targets, targets.size == size, targets.requirements == requirements { return }
        let replacement = try NativePostTargets.make(device: device, size: size, requirements: requirements)
        targets?.destroy(device: device); targets = replacement; revision &+= 1
    }
    /// Allocates and returns the opaque-cache snapshot on first stable capture.
    func ensureSnapshot() throws -> Texture {
        guard var current = targets else { throw RHIError.outOfMemory }
        let texture = try current.ensureSnapshot(device: device)
        targets = current
        return texture
    }
    var snapshot: Texture? { targets?.snapshot }
    func prewarm(settings: RenderSettings) throws {
        let fullscreen: Set<RenderPassKind> = [.ssao, .ssr, .taa, .bloom, .fxaa, .inkPaperPost]
        for kind in RenderFramePlanner.makePlan(settings: settings).passes where fullscreen.contains(kind) {
            _ = try pipeline(for: kind)
        }
    }
    private func pipeline(for kind: RenderPassKind) throws -> NativeFullscreenPass {
        if let existing = pipelines[kind] { return existing }
        let result = try NativeFullscreenPass(device: device, shader: kind == .inkPaperPost ? "ink_paper_post" : kind.rawValue,
            colorFormat: kind == .fxaa ? .bgra8Unorm : .rgba16Float)
        pipelines[kind] = result
        return result
    }
    func encode<T>(kind: RenderPassKind, input: Texture, secondary: Texture, output: Texture,
                   uniforms: T, size: RenderDrawableSize, into commands: CommandBuffer) throws {
        let pipeline = try pipeline(for: kind)
        guard let targets else { throw RHIError.outOfMemory }
        let frame = PostEffectUniforms.frame(used: size,capacity: targets.size)
        try pipeline.encode(size: size,color: RenderColorTarget(texture: output,loadAction: .clear(.zero)),entries: [
            BindingSetEntry(slot: 0,resource: .sampler(sampler)),BindingSetEntry(slot: 1,resource: .texture(input)),
            BindingSetEntry(slot: 2,resource: .texture(secondary)),
            BindingSetEntry(slot: 3,resource: NativeUniformUpload.binding(uniforms,device: device)),
            BindingSetEntry(slot: 4,resource: NativeUniformUpload.binding(frame,device: device))],into: commands)
    }
}
