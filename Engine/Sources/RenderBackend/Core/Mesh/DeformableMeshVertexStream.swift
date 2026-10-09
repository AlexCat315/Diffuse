import AssetPipeline
import SceneRuntime
import SIMDCompat

/// CPU-side interleaved stream matching the static `MeshAsset` vertex layout.
/// Keeping this conversion separate makes the physics-to-render contract
/// testable without requiring a GPU device.
struct DeformableMeshVertexStream: Sendable, Equatable {
    var vertices: [Float]
    var indices: [UInt32]

    init?(_ mesh: RenderDeformableMesh) {
        guard mesh.isValid else { return nil }
        var vertices: [Float] = []
        vertices.reserveCapacity(mesh.vertexCount * MeshAsset.vertexFloatCount)
        for index in mesh.positions.indices {
            let input = mesh.normals[index]
            let normal = simd_length_squared(input) > 0.000001 ? input : SIMD3<Float>(0, 1, 0)
            MeshAsset.appendVertex(
                to: &vertices,
                position: mesh.positions[index],
                normal: normal,
                uv: mesh.textureCoordinates[index],
                tangent: Self.tangent(for: normal)
            )
        }
        self.vertices = vertices
        indices = mesh.triangleIndices
    }

    var vertexBufferSize: UInt64 {
        UInt64(vertices.count * MemoryLayout<Float>.size)
    }

    var indexBufferSize: UInt64 {
        UInt64(indices.count * MemoryLayout<UInt32>.size)
    }

    private static func tangent(for normal: SIMD3<Float>) -> SIMD4<Float> {
        let reference = abs(normal.y) < 0.95
            ? SIMD3<Float>(0, 1, 0)
            : SIMD3<Float>(1, 0, 0)
        let tangent = simd_normalize(simd_cross(reference, normal))
        return SIMD4<Float>(tangent, 1)
    }
}
