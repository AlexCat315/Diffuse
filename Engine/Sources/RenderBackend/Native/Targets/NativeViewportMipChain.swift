import NativeRHI

/// Independent 2D levels avoid backend-specific subresource/feedback rules.
/// Every first-level sample is clamped to the scene's used region; allocation
/// padding never enters the pyramid. All three NativeRHI backends use this path.
final class NativeViewportMipChain {
    private let device: Device
    private let pass: NativeFullscreenPass
    private let sampler: Sampler
    private var levels: [TextureResource] = []

    init(device: Device) throws {
        self.device = device
        // The fullscreen FXAA program has a linear resampling path when edge
        // offsets are zero: all luma taps agree and the early return samples
        // the original color. Keep this mode isolated from authored FXAA settings.
        pass = try NativeFullscreenPass(device: device, shader: "fxaa", colorFormat: .bgra8Unorm)
        sampler = try device.makeSampler(SamplerDescriptor(minFilter: .linear, magFilter: .linear,
            mipFilter: .nearest, addressModeU: .clampToEdge, addressModeV: .clampToEdge))
    }
    deinit { device.destroy(sampler) }

    func record(source: TextureResource, used: RenderDrawableSize, into commands: CommandBuffer) throws -> [TextureResource] {
        var sizes: [RenderDrawableSize] = [], size = used
        while size.width > 1 || size.height > 1 {
            size = RenderDrawableSize(width: max(1, size.width / 2), height: max(1, size.height / 2))
            sizes.append(size)
        }
        if levels.count != sizes.count || zip(levels, sizes).contains(where: {
            $0.0.descriptor.width != Int($0.1.width) || $0.0.descriptor.height != Int($0.1.height)
        }) {
            levels = try sizes.map { size in
                try TextureResource(device: device, descriptor: TextureDescriptor(width: Int(size.width), height: Int(size.height),
                    format: .bgra8Unorm, usage: [.sampled, .colorTarget, .transferSource], label: "viewport-mip"))
            }
        }
        var previous = source, usedSize = used
        for (level, size) in zip(levels, sizes) {
            let capacity = RenderDrawableSize(width: UInt32(previous.descriptor.width), height: UInt32(previous.descriptor.height))
            try pass.encode(size: size, color: RenderColorTarget(texture: level.texture, loadAction: .dontCare), entries: [
                .init(slot: 0, resource: .sampler(sampler)),
                .init(slot: 1, resource: .texture(previous.texture)),
                .init(slot: 2, resource: .texture(previous.texture)),
                .init(slot: 3, resource: NativeUniformUpload.binding(SIMD4<Float>.zero, device: device)),
                .init(slot: 4, resource: NativeUniformUpload.binding(PostEffectUniforms.frame(used: usedSize, capacity: capacity), device: device))
            ], into: commands)
            previous = level; usedSize = size
        }
        return levels
    }
}
