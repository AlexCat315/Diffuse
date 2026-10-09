import AssetPipeline
import SceneRuntime

/// Imported primitive values combined with runtime overrides. Both renderers
/// use this resolution so texture and coverage rules stay consistent.
struct ResolvedMeshMaterial {
    var color: SIMD4<Float>
    var alphaMode: MaterialAlphaMode
    var cutoff: Float
    var doubleSided: Bool
    var baseTexture: Int?
    var normalTexture: Int?
    var mrTexture: Int?

    init(imported: MeshMaterial, runtime: RenderMaterial) {
        color = imported.baseColorFactor * runtime.baseColorFactor
        alphaMode = runtime.alphaMode ?? imported.alphaMode
        cutoff = runtime.alphaCutoff ?? imported.alphaCutoff
        doubleSided = runtime.doubleSided ?? imported.doubleSided
        baseTexture = runtime.baseColorTextureIndex ?? imported.baseColorTextureIndex
        normalTexture = runtime.normalTextureIndex ?? imported.normalTextureIndex
        mrTexture = imported.metallicRoughnessTextureIndex
    }
}
