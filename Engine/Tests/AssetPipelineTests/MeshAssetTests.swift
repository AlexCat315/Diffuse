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

    @Test("mesh exposes position accessors")
    func meshExposesPositionAccessors() {
        var vertices: [Float] = []
        MeshAsset.appendVertex(to: &vertices, position: SIMD3<Float>(0, 0, 0))
        MeshAsset.appendVertex(to: &vertices, position: SIMD3<Float>(1, 0, 0))
        var mesh = MeshAsset(name: "line", vertices: vertices, indices: [0, 1])

        #expect(mesh.position(at: 1) == SIMD3<Float>(1, 0, 0))
        mesh.setPosition(SIMD3<Float>(2, 3, 4), at: 1)
        #expect(mesh.position(at: 1) == SIMD3<Float>(2, 3, 4))
        #expect(mesh.position(at: 5) == nil)
    }
}
