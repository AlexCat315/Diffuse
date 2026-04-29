import AssetPipeline
import Testing
import simd

@Suite("MeshAsset")
struct MeshAssetTests {
    @Test("mesh exposes vertex and triangle counts")
    func meshExposesCounts() {
        var vertices: [Float] = []
        MeshAsset.appendVertex(to: &vertices, position: SIMD3<Float>(0, 0, 0))
        MeshAsset.appendVertex(to: &vertices, position: SIMD3<Float>(1, 0, 0))
        MeshAsset.appendVertex(to: &vertices, position: SIMD3<Float>(0, 1, 0))
        let mesh = MeshAsset(name: "tri", vertices: vertices, indices: [0, 1, 2])

        #expect(mesh.vertexCount == 3)
        #expect(mesh.triangleCount == 1)
    }
}
