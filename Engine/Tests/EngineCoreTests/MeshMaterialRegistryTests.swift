import AssetPipeline
@testable import RenderBackend
import Testing
import simd

@Suite("MeshMaterialRegistry")
struct MeshMaterialRegistryTests {
    @Test("registers mesh material and texture metadata by mesh index")
    func registersMaterialMetadata() {
        let registry = MeshMaterialRegistry.shared
        registry.clearAll()
        defer { registry.clearAll() }

        let material = MeshMaterial(
            name: "ink",
            baseColorFactor: SIMD4<Float>(0.5, 0.4, 0.3, 1),
            baseColorTextureIndex: 0,
            normalTextureIndex: nil,
            metallicFactor: 0,
            roughnessFactor: 1
        )
        let texture = MeshTexture(sourceURI: "ink.png", mimeType: "image/png")
        let mesh = MeshAsset(
            name: "hero",
            vertices: [],
            indices: [],
            materials: [material],
            textures: [texture]
        )

        registry.register(meshIndex: 7, mesh: mesh)

        let set = registry.materials(for: 7)
        #expect(set?.materials == [material])
        #expect(set?.textures == [texture])
        #expect(registry.materials(for: 8) == nil)
    }
}
