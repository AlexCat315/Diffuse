import SceneRuntime
import SIMDCompat

struct ShadowAtlasLight: Equatable, Sendable {
    let sceneLightIndex: Int
    let slot: Int
    let cascadeIndex: Int
    let tileX: UInt32
    let tileY: UInt32
    let lightViewProjection: simd_float4x4
}

struct ShadowAtlasPlan: Equatable, Sendable {
    let uniforms: ShadowUniforms
    let lights: [ShadowAtlasLight]
    let tileSize: UInt32
    let atlasSize: UInt32
    let gridDimension: UInt32
    let cascadeCount: Int

    var shadowTileCount: Int {
        lights.count
    }

    var shadowedLightCount: Int {
        shadowBindingsByLightIndex.count
    }

    var shadowBindingsByLightIndex: [Int: ShadowLightBinding] {
        lights.reduce(into: [:]) { partial, light in
            let existing = partial[light.sceneLightIndex]
            let baseSlot = min(existing?.baseSlot ?? light.slot, light.slot)
            let cascadeCount = max(existing?.cascadeCount ?? 0, light.cascadeIndex + 1)
            partial[light.sceneLightIndex] = ShadowLightBinding(
                baseSlot: baseSlot,
                cascadeCount: cascadeCount
            )
        }
    }
}
