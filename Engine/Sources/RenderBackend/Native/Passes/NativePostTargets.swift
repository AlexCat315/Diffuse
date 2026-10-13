import NativeRHI

/// Which post targets a frame needs, derived solely from the capability
/// switches. The opaque-cache snapshot is excluded: it is allocated on demand
/// when the scene first becomes stable, so always-moving scenes never pay for it.
struct NativePostRequirements: Equatable {
    /// Number of fullscreen effects that ping-pong through the HDR color targets
    /// (ink paper, SSAO, SSR, TAA, Bloom). 0 → none, 1 → target `a`, ≥2 → `a` + `b`.
    var pingPongEffects: Int
    var needsHistory: Bool
    var needsLDR: Bool

    static func make(_ settings: RenderSettings) -> NativePostRequirements {
        let pingPong = (settings.stylization.enabled ? 1 : 0)
            + (settings.postProcessing.ssao ? 1 : 0)
            + (settings.postProcessing.ssr ? 1 : 0)
            + (settings.postProcessing.taa ? 1 : 0)
            + (settings.postProcessing.bloom ? 1 : 0)
        return NativePostRequirements(
            pingPongEffects: pingPong,
            needsHistory: settings.postProcessing.taa,
            needsLDR: settings.postProcessing.fxaa)
    }
}

/// Fullscreen post targets. Every texture is allocated only when a pass in the
/// assembled pipeline actually reads or writes it.
struct NativePostTargets {
    /// Matches the scene color/depth capacity, including history and snapshot.
    let size: RenderDrawableSize
    let requirements: NativePostRequirements
    let a: Texture?
    let b: Texture?
    let history: Texture?
    let ldr: Texture?
    /// Opaque-cache storage, allocated lazily on the first stable capture.
    private(set) var snapshot: Texture?

    var textures: [Texture] { [a, b, history, ldr, snapshot].compactMap { $0 } }

    /// Ping-pong target following `texture`. The first effect leaves the scene
    /// HDR target for `a`; subsequent effects alternate between `a` and `b`.
    func next(after texture: Texture) -> Texture {
        if texture == a { return b ?? a! }
        return a!
    }

    /// Allocates the opaque-cache snapshot the first time a stable frame is captured.
    mutating func ensureSnapshot(device: Device) throws -> Texture {
        if let snapshot { return snapshot }
        let texture = try device.makeTexture(TextureDescriptor(
            width: Int(size.width), height: Int(size.height),
            format: .rgba16Float,
            usage: [.colorTarget, .sampled, .transferSource, .transferDestination],
            label: "native-post-snapshot"))
        snapshot = texture
        return texture
    }

    func destroy(device: Device) { textures.forEach { device.destroy($0) } }

    static func make(device: Device, size: RenderDrawableSize,
                     requirements: NativePostRequirements) throws -> NativePostTargets {
        var created: [Texture] = []
        do {
            func hdrColor(_ label: String) throws -> Texture {
                let texture = try device.makeTexture(TextureDescriptor(
                    width: Int(size.width), height: Int(size.height),
                    format: .rgba16Float,
                    usage: [.colorTarget, .sampled, .transferSource, .transferDestination],
                    label: label))
                created.append(texture)
                return texture
            }
            func ldrColor(_ label: String) throws -> Texture {
                let texture = try device.makeTexture(TextureDescriptor(
                    width: Int(size.width), height: Int(size.height),
                    format: .bgra8Unorm,
                    usage: [.colorTarget, .sampled, .transferSource, .transferDestination],
                    label: label))
                created.append(texture)
                return texture
            }
            let a = requirements.pingPongEffects >= 1 ? try hdrColor("native-post-a") : nil
            let b = requirements.pingPongEffects >= 2 ? try hdrColor("native-post-b") : nil
            let history = requirements.needsHistory ? try hdrColor("native-post-history") : nil
            let ldr = requirements.needsLDR ? try ldrColor("native-post-ldr") : nil
            return NativePostTargets(size: size, requirements: requirements,
                                     a: a, b: b, history: history, ldr: ldr, snapshot: nil)
        } catch {
            created.forEach { device.destroy($0) }
            throw error
        }
    }
}
