/// A coherent snapshot for GPU resource consumers, separate from authored assets.
public struct MeshAssetCatalog: Sendable {
    public let revision: UInt64
    public let meshes: [RegisteredMeshAsset]
}
