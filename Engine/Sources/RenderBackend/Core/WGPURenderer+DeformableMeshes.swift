import AssetPipeline
import RHIWGPU
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
            let normal = mesh.normals[index]
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

extension WGPURenderer {
    func syncDeformableMeshes(
        _ meshes: [RenderDeformableMesh]
    ) throws -> DeformableMeshUploadReport {
        var report = DeformableMeshUploadReport()
        var activeEntities = Set<EntityID>()

        for deformable in meshes.sorted(by: {
            $0.entity.rawValue < $1.entity.rawValue
        }) {
            guard !activeEntities.contains(deformable.entity),
                  let stream = DeformableMeshVertexStream(deformable)
            else {
                report.rejectedMeshCount += 1
                continue
            }
            activeEntities.insert(deformable.entity)
            report.meshCount += 1
            report.vertexCount += deformable.vertexCount
            report.triangleCount += deformable.triangleCount

            let previous = deformableMeshResources[deformable.entity]
            let topologyChanged = previous?.topologyRevision != deformable.topologyRevision
                || previous?.triangleCount != deformable.triangleCount
            let verticesChanged = previous?.revision != deformable.revision
                || previous?.vertexCount != deformable.vertexCount
            guard verticesChanged || topologyChanged else { continue }

            let vertexBuffer: GPUBuffer
            let vertexBufferReallocated: Bool
            if let previous, previous.mesh.vertexBuffer.size >= stream.vertexBufferSize {
                vertexBuffer = previous.mesh.vertexBuffer
                vertexBufferReallocated = false
            } else {
                vertexBuffer = try backend.createBuffer(
                    size: stream.vertexBufferSize,
                    usage: [.vertex, .copyDst]
                )
                vertexBufferReallocated = true
            }

            let indexBuffer: GPUBuffer
            let indexBufferReallocated: Bool
            if let previous, previous.mesh.indexBuffer.size >= stream.indexBufferSize {
                indexBuffer = previous.mesh.indexBuffer
                indexBufferReallocated = false
            } else {
                indexBuffer = try backend.createBuffer(
                    size: stream.indexBufferSize,
                    usage: [.index, .copyDst]
                )
                indexBufferReallocated = true
            }

            if verticesChanged || vertexBufferReallocated {
                stream.vertices.withUnsafeBytes { raw in
                    guard let baseAddress = raw.baseAddress else { return }
                    backend.writeBuffer(
                        vertexBuffer,
                        data: baseAddress,
                        size: raw.count
                    )
                }
                report.uploadedBytes += stream.vertexBufferSize
            }
            if topologyChanged || indexBufferReallocated {
                stream.indices.withUnsafeBytes { raw in
                    guard let baseAddress = raw.baseAddress else { return }
                    backend.writeBuffer(
                        indexBuffer,
                        data: baseAddress,
                        size: raw.count
                    )
                }
                report.uploadedBytes += stream.indexBufferSize
            }

            deformableMeshResources[deformable.entity] = GPUDeformableMeshResource(
                mesh: GPUMesh(
                    vertexBuffer: vertexBuffer,
                    indexBuffer: indexBuffer,
                    indexCount: UInt32(stream.indices.count),
                    name: "deformable.\(deformable.entity.rawValue)",
                    submeshes: []
                ),
                revision: deformable.revision,
                topologyRevision: deformable.topologyRevision,
                vertexCount: deformable.vertexCount,
                triangleCount: deformable.triangleCount
            )
        }

        deformableMeshResources = deformableMeshResources.filter {
            activeEntities.contains($0.key)
        }
        return report
    }

    func resolvedMesh(for instance: RenderInstance) -> GPUMesh? {
        if let entity = instance.entity,
           let deformable = deformableMeshResources[entity] {
            return deformable.mesh
        }
        guard meshes.indices.contains(instance.meshIndex) else { return nil }
        return meshes[instance.meshIndex]
    }
}
