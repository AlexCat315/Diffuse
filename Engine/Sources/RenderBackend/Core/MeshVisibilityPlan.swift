import EngineMath
import SceneRuntime
import SIMDCompat

/// Camera visibility is separate from shadow visibility: offscreen objects can
/// still cast shadows into the camera view. Unknown/skinned bounds stay visible.
struct MeshVisibilityPlan {
    var visibleIndices: [Int] = []
    var meshIndices: [Int: Int] = [:]
    var culledCount = 0
    var lodCount = 0

    static func make(scene: RenderScene, viewProjection: simd_float4x4,
                     settings: RenderSettings, skinnedEntities: Set<EntityID>,
                     meshExists: (Int) -> Bool) -> MeshVisibilityPlan {
        let frustum = Frustum3D(viewProjection: viewProjection)
        let deformables = Dictionary(scene.deformableMeshes.filter(\.isValid).map { ($0.entity, $0) }, uniquingKeysWith: { first, _ in first })
        var result = MeshVisibilityPlan()
        for (index, instance) in scene.instances.enumerated() {
            let dynamic = instance.entity.flatMap { deformables[$0] }
            let skinned = instance.entity.map { skinnedEntities.contains($0) } ?? false
            var bounds: Bounds3D?
            if let dynamic { bounds = Bounds3D(points: dynamic.positions) }
            else if !skinned {
                let slots = [instance.meshIndex] + instance.mesh.levelsOfDetail.filter { meshExists($0.meshIndex) }.map(\.meshIndex)
                var combined = Bounds3D.empty
                var known = true
                for slot in slots {
                    guard let local = MeshBoundsRegistry.shared.bounds(for: slot) else { known = false; break }
                    let center = (local.min + local.max) * 0.5
                    let half = (local.max - local.min) * 0.5
                    let transformed = instance.transform * SIMD4<Float>(center, 1)
                    let a = instance.transform.columns.0, b = instance.transform.columns.1, c = instance.transform.columns.2
                    let extent = SIMD3<Float>(
                        abs(a.x) * half.x + abs(b.x) * half.y + abs(c.x) * half.z,
                        abs(a.y) * half.x + abs(b.y) * half.y + abs(c.y) * half.z,
                        abs(a.z) * half.x + abs(b.z) * half.y + abs(c.z) * half.z)
                    let worldCenter = SIMD3<Float>(transformed.x, transformed.y, transformed.z)
                    combined = combined.union(Bounds3D(min: worldCenter - extent, max: worldCenter + extent))
                }
                if known { bounds = combined }
            }
            if settings.enableFrustumCulling, let bounds, !frustum.intersects(bounds) {
                result.culledCount += 1; continue
            }
            var meshIndex = instance.meshIndex
            if settings.enableDistanceLOD, dynamic == nil, !skinned {
                let t = instance.transform.columns.3
                let distance = simd_distance(scene.camera.eye, SIMD3<Float>(t.x, t.y, t.z))
                for lod in instance.mesh.levelsOfDetail.sorted(by: { $0.minimumDistance < $1.minimumDistance })
                    where lod.minimumDistance.isFinite && distance >= lod.minimumDistance && meshExists(lod.meshIndex) {
                    meshIndex = lod.meshIndex
                }
            }
            if meshIndex != instance.meshIndex { result.lodCount += 1 }
            result.visibleIndices.append(index)
            result.meshIndices[index] = meshIndex
        }
        return result
    }
}
