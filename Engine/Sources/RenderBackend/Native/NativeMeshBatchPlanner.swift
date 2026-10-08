import AssetPipeline
import SceneRuntime
import SIMDCompat
import NativeRHI

struct NativeMeshBatchKey: Hashable {
    var mesh: Int
    var firstIndex: Int
    var indexCount: Int
    var mode: MaterialAlphaMode
    var cutoff: Float
    var doubleSided: Bool
    var mirrored: Bool
    var color: SIMD4<Float>
    var baseTexture: Int?
    var normalTexture: Int?
    var mrTexture: Int?
    var uniqueInstance: Int?
}
struct NativeMeshBatch {
    let mesh: NativeMesh
    let key: NativeMeshBatchKey
    let uniforms: [MeshInstanceUniforms]
}

/// CPU geometry/material batching shared by camera and shadow views.
enum NativeMeshBatchPlanner {
    static func prepare(packet: RenderPacket, store: NativeMeshStore, viewProjection: simd_float4x4,
                        shadow: Bool = false) throws -> (batches: [NativeMeshBatch], visibility: MeshVisibilityPlan) {
        let visibility = MeshVisibilityPlan.make(scene: packet.scene, viewProjection: viewProjection,
            settings: shadow ? shadowSettings(packet.renderSettings) : packet.renderSettings, skinnedEntities: [],
            meshBounds: { store[$0]?.bounds }, meshExists: { store[$0] != nil })
        var members: [NativeMeshBatchKey: [Int]] = [:]
        var order: [NativeMeshBatchKey] = []
        for index in visibility.visibleIndices {
            let instance = packet.scene.instances[index]
            let meshIndex = visibility.meshIndices[index] ?? instance.meshIndex
            guard let mesh = store[meshIndex] else { throw RHIError.invalidArgument("unregistered native mesh \(meshIndex)") }
            for part in mesh.submeshes {
                let material = ResolvedMeshMaterial(imported: mesh.materials[part.materialIndex], runtime: instance.material)
                guard material.modeIsOpaque else { throw RHIError.unsupportedFeature("native transparent mesh pass is pending") }
                let key = NativeMeshBatchKey(mesh: meshIndex, firstIndex: Int(part.indexStart), indexCount: Int(part.indexCount),
                    mode: material.alphaMode, cutoff: material.cutoff, doubleSided: material.doubleSided,
                    mirrored: simd_determinant(instance.transform) < 0, color: material.color,
                    baseTexture: material.baseTexture, normalTexture: material.normalTexture, mrTexture: material.mrTexture,
                    uniqueInstance: packet.renderSettings.enableMeshInstancing ? nil : index)
                if members[key] == nil { order.append(key) }
                members[key, default: []].append(index)
            }
        }
        if packet.renderSettings.enableGroupedDrawByMesh { order.sort { $0.mesh < $1.mesh } }
        var batches: [NativeMeshBatch] = []
        for key in order {
            guard let mesh = store[key.mesh], let indices = members[key] else { continue }
            // Bound each batch to the same maximum as the WGSL path.
            for start in stride(from: 0, to: indices.count, by: 16_384) {
                let uniforms = indices[start..<min(start + 16_384, indices.count)].map { index in
                    let instance = packet.scene.instances[index]
                    return MeshInstanceUniforms(mvp: viewProjection * instance.transform, model: instance.transform,
                        colorTint: SIMD4(instance.colorTint * SIMD3(key.color.x,key.color.y,key.color.z), key.color.w),
                        material: SIMD4(key.mode == .mask ? 1 : 0, key.cutoff, key.doubleSided ? 1 : 0, 0))
                }
                batches.append(NativeMeshBatch(mesh: mesh, key: key, uniforms: uniforms))
            }
        }
        return (batches,visibility)
    }
    private static func shadowSettings(_ settings: RenderSettings) -> RenderSettings {
        var result = settings; result.enableFrustumCulling = false; result.enableDistanceLOD = false
        return result
    }
}
private extension ResolvedMeshMaterial { var modeIsOpaque: Bool { alphaMode != .blend } }
