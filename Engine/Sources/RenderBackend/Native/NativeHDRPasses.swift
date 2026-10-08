import NativeRHI
import SIMDCompat

/// Sky background, HDR reference grid and final display conversion.
final class NativeHDRPasses {
    private let device: Device
    private let sky: NativeFullscreenPass
    private let tone: NativeFullscreenPass
    private let grid: NativeEditorGridPass
    private let sampler: Sampler
    init(device: Device) throws {
        self.device = device
        sky = try NativeFullscreenPass(device: device, shader: "skybox", colorFormat: .rgba16Float,
            depth: DepthStencilState(depthCompare: .lessOrEqual, depthWriteEnabled: false))
        tone = try NativeFullscreenPass(device: device, shader: "tonemap", colorFormat: .bgra8Unorm)
        grid = try NativeEditorGridPass(device: device, colorFormat: .rgba16Float)
        sampler = try device.makeSampler(SamplerDescriptor(minFilter: .linear, magFilter: .linear,
            mipFilter: .nearest, addressModeU: .clampToEdge, addressModeV: .clampToEdge))
    }
    deinit { device.destroy(sampler) }
    func encodeSky(packet: RenderPacket, matrices: RenderCameraMatrices, hdr: Texture, depth: Texture,
                   into commands: CommandBuffer) throws {
        let uniforms = SkyboxUniforms(invViewProj: simd_inverse(matrices.viewProjection),
            skyTint: SIMD4(0.10,0.20,0.42,packet.scene.camera.projection == .orthographic ? 1 : 0),
            horizonTint: SIMD4(0.95,0.48,0.18,1), groundTint: SIMD4(0.03,0.04,0.05,1))
        try sky.encode(size: packet.drawableSize, color: RenderColorTarget(texture: hdr, loadAction: .clear(SIMD4(0.01,0.01,0.02,1))),
            depth: RenderDepthTarget(texture: depth, loadAction: .load),
            entries: [BindingSetEntry(slot: 0, resource: NativeUniformUpload.binding(uniforms, device: device))], into: commands)
    }
    func encodeGrid(packet: RenderPacket, hdr: Texture, depth: Texture, into commands: CommandBuffer) throws {
        try grid.encode(packet: packet, color: RenderColorTarget(texture: hdr, loadAction: .load),
            depth: RenderDepthTarget(texture: depth, loadAction: .load), into: commands)
    }
    func encodeTonemap(size: RenderDrawableSize, capacity: RenderDrawableSize, hdr: Texture, output: Texture, bloom: Texture? = nil, into commands: CommandBuffer) throws {
        let toneUniforms = TonemapUniforms(params: SIMD4(1,0.85,bloom == nil ? 0 : 1,1))
        let frame = PostEffectUniforms.frame(used: size,capacity: capacity)
        try tone.encode(size: size, color: RenderColorTarget(texture: output, loadAction: .clear(SIMD4(0,0,0,1))), entries: [
            BindingSetEntry(slot: 0, resource: .sampler(sampler)), BindingSetEntry(slot: 1, resource: .texture(hdr)),
            BindingSetEntry(slot: 2, resource: .texture(bloom ?? hdr)),
            BindingSetEntry(slot: 3, resource: NativeUniformUpload.binding(toneUniforms, device: device)),
            BindingSetEntry(slot: 4, resource: NativeUniformUpload.binding(frame, device: device))
        ], into: commands)
    }
}
