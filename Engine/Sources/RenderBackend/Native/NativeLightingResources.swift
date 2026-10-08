import Foundation
import NativeRHI

struct NativeLightingBindings {
    let lights: BindingResource
    let shadows: BindingResource
    let sampler: Sampler
    let atlas: Texture
    let environment: Texture
}

enum NativeUniformUpload {
    static func binding<T>(_ value: T, device: Device) throws -> BindingResource {
        let data = withUnsafeBytes(of: value) { Data($0) }
        let location = try device.uploadTransient(data)
        return .uniformBuffer(buffer: location.buffer, offset: location.offset, size: data.count)
    }
}

/// Immutable studio environment and shadow filtering, independent of scene meshes.
final class NativeLightingResources {
    private let device: Device
    private let shadowSampler: Sampler
    private var environment: Texture?
    init(device: Device) throws {
        self.device = device
        shadowSampler = try device.makeSampler(SamplerDescriptor(minFilter: .linear, magFilter: .linear,
            mipFilter: .nearest, addressModeU: .clampToEdge, addressModeV: .clampToEdge))
    }
    deinit { if let environment { device.destroy(environment) }; device.destroy(shadowSampler) }

    func ensureEnvironment() throws {
        guard environment == nil else { return }
        let levels = StudioEnvironmentIBL.generate()
        let texture = try device.makeTexture(TextureDescriptor(width: StudioEnvironmentIBL.baseWidth,
            height: StudioEnvironmentIBL.baseHeight, format: .rgba16Float, usage: [.sampled,.transferDestination],
            mipLevels: StudioEnvironmentIBL.mipCount, label: "native-studio-ibl"))
        do {
            for (index,level) in levels.enumerated() {
                try device.uploadTextureData(texture, data: level.halfRGBA.withUnsafeBytes { Data($0) },
                    region: .init(width: level.width,height: level.height), bytesPerRow: level.width*8, subresource: .init(mipLevel: index))
            }
            environment = texture
        } catch { device.destroy(texture); throw error }
    }
    func prepare(packet: RenderPacket, plan: ShadowAtlasPlan, atlas: Texture?, fallback: Texture) throws -> NativeLightingBindings {
        var lights = SceneLightUniforms(scene: packet.scene, shadowBindingsByLightIndex: plan.shadowBindingsByLightIndex)
        lights.exposureAndLightCount.z = Float(packet.renderSettings.debugViewMode.rawValue)
        return try NativeLightingBindings(lights: NativeUniformUpload.binding(lights, device: device),
            shadows: NativeUniformUpload.binding(plan.uniforms, device: device), sampler: shadowSampler,
            atlas: atlas ?? fallback, environment: environment ?? fallback)
    }
}
