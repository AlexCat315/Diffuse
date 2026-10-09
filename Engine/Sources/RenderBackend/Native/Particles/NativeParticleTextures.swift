import AssetPipeline
import Logging
import NativeRHI

/// Resident particle images, including retryable decode failures and a white fallback.
final class NativeParticleTextures {
    private let device: Device
    let sampler: Sampler
    private let fallback: Texture
    private var images: [String: Texture] = [:]
    private var failures: Set<String> = []
    init(device: Device) throws {
        self.device = device
        sampler = try device.makeSampler(SamplerDescriptor(minFilter: .linear,magFilter: .linear,mipFilter: .nearest,
            addressModeU: .clampToEdge,addressModeV: .clampToEdge))
        do { fallback = try NativeMeshStore.texture(device: device,image: DecodedTextureAsset(pixels: [255,255,255,255],width: 1,height: 1)) }
        catch { device.destroy(sampler); throw error }
    }
    deinit { images.values.forEach { device.destroy($0) }; device.destroy(fallback); device.destroy(sampler) }
    func texture(path: String?) -> Texture {
        guard let path else { return fallback }
        if let existing = images[path] { return existing }
        do {
            let result = try NativeMeshStore.texture(device: device,image: ImageAssetDecoder.decodeRGBA8(path: path))
            images[path] = result; failures.remove(path); return result
        } catch {
            if failures.insert(path).inserted { Logger.renderer.warning("particle texture decode failed: source=\(path) reason=\(error)") }
            return fallback
        }
    }
}
