import Foundation
import IntentRuntime
import RenderBackend
import SceneRuntime
import simd

extension EditorSceneAdapter {
    /// 在场景里生成一个新实体并立即可见，返回 raw entity id。
    /// 调用方一般紧接着把返回的 id 写回 store 作为新的选中态。
    @discardableResult
    public func spawnEntity(from asset: EditorAsset,
                            at position: SIMD3<Float> = SIMD3<Float>(0, 0, 0)) -> UInt64? {
        let label = uniqueDisplayName(base: asset.name)
        let result = applySceneTransaction(intentVerb: "scene.spawn_entity",
                                           summary: "Spawn imported mesh entity",
                                           mutations: [
                                            .spawnImportedMeshEntity(label: label,
                                                                     kindLabel: asset.kind.sceneKindLabel,
                                                                     meshIndex: asset.meshIndex,
                                                                     position: position)
                                           ])
        guard let entityID = result?.createdEntityIDs.first else { return nil }
        attachMeshColliderIfAvailable(entityID: entityID, meshIndex: asset.meshIndex)
        return entityID
    }

    private func uniqueDisplayName(base: String) -> String {
        let existing: Set<String> = Set(scene.entities().compactMap {
            scene.component(SceneNameComponent.self, for: $0)?.value
        })
        if !existing.contains(base) { return base }
        var suffix = 2
        while existing.contains("\(base) \(suffix)") {
            suffix += 1
        }
        return "\(base) \(suffix)"
    }

    private func attachMeshColliderIfAvailable(entityID rawID: UInt64, meshIndex: Int) {
        guard let entity = EntityID(rawValue: rawID),
              scene.contains(entity),
              let bounds = MeshBoundsRegistry.shared.bounds(for: meshIndex)
        else {
            return
        }

        let resourceID = meshColliderResourceID(for: meshIndex)
        var resource = scene.resource(MeshColliderBoundsResource.self) ?? MeshColliderBoundsResource()
        resource.boundsByResourceID[resourceID] = SpatialAABB(min: bounds.min, max: bounds.max)
        scene.setResource(resource)

        _ = scene.setComponent(Collider(shape: .mesh(resourceID: resourceID, center: .zero)), for: entity)
        notifyRevisionChanged()
    }

    private func meshColliderResourceID(for meshIndex: Int) -> String {
        "meshIndex:\(meshIndex)"
    }
}

private extension EntityID {
    init?(rawValue: UInt64) {
        self.init(index: UInt32(rawValue & 0xFFFF_FFFF),
                  generation: UInt32(rawValue >> 32))
    }
}
