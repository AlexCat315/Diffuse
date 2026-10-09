import AssetPipeline
import RHIWGPU
import SceneRuntime
import SIMDCompat

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
