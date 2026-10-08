import AssetPipeline
import Foundation
import Testing

@Suite("MeshAssetCatalog")
struct MeshAssetCatalogTests {
    @Test("catalog snapshots pair changes and removals with revisions")
    func revisions() throws {
        let registry = AssetRegistry()
        let initial = try #require(registry.meshCatalog(since: nil))
        #expect(initial.meshes.isEmpty)
        #expect(registry.meshCatalog(since: initial.revision) == nil)
        registry.registerForTesting(BuiltinMesh.cube(), at: 45)
        let first = try #require(registry.meshCatalog(since: initial.revision))
        #expect(first.meshes.map(\.meshIndex) == [45])
        var replacement = BuiltinMesh.cube(); replacement.name = "replacement"
        registry.registerForTesting(replacement, at: 45)
        let second = try #require(registry.meshCatalog(since: first.revision))
        #expect(second.meshes[0].mesh.name == "replacement")
        registry.unregisterTestingMesh(at: 45)
        let removed = try #require(registry.meshCatalog(since: second.revision))
        #expect(removed.meshes.isEmpty)
        registry.reset()
        #expect(registry.meshCatalog(since: removed.revision) != nil)
    }
}
