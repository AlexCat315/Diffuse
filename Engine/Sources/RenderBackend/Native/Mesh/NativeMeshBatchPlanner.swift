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
    let geometry: NativeMeshGeometry
    let key: NativeMeshBatchKey
    let uniforms: [MeshInstanceUniforms]
    let skinEntity: EntityID?
    let distance: Float
}

/// CPU geometry/material batching shared by camera and shadow views.
enum NativeMeshBatchPlanner {
    static func prepare(packet: RenderPacket, store: NativeMeshStore, viewProjection: simd_float4x4,
                        deformables: [EntityID: NativeMeshGeometry], shadow: Bool = false) throws -> (batches: [NativeMeshBatch], visibility: MeshVisibilityPlan) {
        let visibility = MeshVisibilityPlan.make(scene: packet.scene, viewProjection: viewProjection,
            settings: shadow ? shadowSettings(packet.renderSettings) : packet.renderSettings,
            skinnedEntities: Set(packet.jointPaletteMap.palettes.keys),
            meshBounds: { store[$0]?.geometry.bounds }, meshExists: { store[$0] != nil })
        var members: [NativeMeshBatchKey: [Int]] = [:]
        var order: [NativeMeshBatchKey] = []
        for index in visibility.visibleIndices {
            let instance = packet.scene.instances[index]
            let meshIndex = visibility.meshIndices[index] ?? instance.meshIndex
            let dynamic = instance.entity.flatMap { deformables[$0] }
            guard let mesh = store[meshIndex] ?? dynamic.map({ NativeMesh(geometry: $0, materials: [.fallback], textures: [:]) }) else {
                throw RHIError.invalidArgument("unregistered native mesh \(meshIndex)")
            }
            for part in (dynamic ?? mesh.geometry).submeshes {
                let imported = mesh.materials.indices.contains(part.materialIndex) ? mesh.materials[part.materialIndex] : MeshMaterial.fallback
                let material = ResolvedMeshMaterial(imported: imported, runtime: instance.material)
                if shadow && material.alphaMode == .blend { continue }
                let posed = instance.entity.flatMap { packet.jointPaletteMap.palette(for: $0) } != nil
                let isolated = !packet.renderSettings.enableMeshInstancing || material.alphaMode == .blend || posed || dynamic != nil
                let key = NativeMeshBatchKey(mesh: meshIndex, firstIndex: Int(part.indexStart), indexCount: Int(part.indexCount),
                    mode: material.alphaMode, cutoff: material.cutoff, doubleSided: material.doubleSided,
                    mirrored: simd_determinant(instance.transform) < 0, color: material.color,
                    baseTexture: material.baseTexture, normalTexture: material.normalTexture, mrTexture: material.mrTexture,
                    uniqueInstance: isolated ? index : nil)
                if members[key] == nil { order.append(key) }
                members[key, default: []].append(index)
            }
        }
        if packet.renderSettings.enableGroupedDrawByMesh { order.sort { $0.mesh < $1.mesh } }
        var batches: [NativeMeshBatch] = []
        let forward = simd_normalize(packet.scene.camera.target - packet.scene.camera.eye)
        for key in order {
            guard let indices = members[key] else { continue }
            for start in stride(from: 0, to: indices.count, by: 16_384) {
                let first = packet.scene.instances[indices[start]]
                let dynamic = first.entity.flatMap { deformables[$0] }
                guard let mesh = store[key.mesh] ?? dynamic.map({ NativeMesh(geometry: $0, materials: [.fallback], textures: [:]) }) else { continue }
                let uniforms = indices[start..<min(start + 16_384, indices.count)].map { index in
                    let instance = packet.scene.instances[index]
                    let mode: Float = key.mode == .blend ? 2 : key.mode == .mask ? 1 : 0
                    return MeshInstanceUniforms(mvp: viewProjection * instance.transform, model: instance.transform,
                        colorTint: SIMD4(instance.colorTint * SIMD3(key.color.x,key.color.y,key.color.z), key.color.w),
                        material: SIMD4(mode, key.cutoff, key.doubleSided ? 1 : 0, 0))
                }
                let position = first.transform.columns.3
                batches.append(NativeMeshBatch(mesh: mesh, geometry: dynamic ?? mesh.geometry, key: key, uniforms: uniforms,
                    skinEntity: first.entity, distance: simd_dot(SIMD3(position.x,position.y,position.z) - packet.scene.camera.eye, forward)))
            }
        }
        return (batches,visibility)
    }
    private static func shadowSettings(_ settings: RenderSettings) -> RenderSettings {
        var result = settings; result.enableFrustumCulling = false; result.enableDistanceLOD = false
        return result
    }
}
