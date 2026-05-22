import Foundation
import AssetPipeline
import IntentRuntime
import RenderBackend
import SceneRuntime
import SIMDCompat

extension EditorSceneAdapter {
    /// 鍦ㄥ満鏅噷鐢熸垚涓€涓柊瀹炰綋骞剁珛鍗冲彲瑙侊紝杩斿洖 raw entity id銆?
    /// 璋冪敤鏂逛竴鑸揣鎺ョ潃鎶婅繑鍥炵殑 id 鍐欏洖 store 浣滀负鏂扮殑閫変腑鎬併€?
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
        attachAssetReference(entityID: entityID, asset: asset)
        attachMeshColliderIfAvailable(entityID: entityID, meshIndex: asset.meshIndex)
        attachAnimationPlayerIfAvailable(entityID: entityID, meshIndex: asset.meshIndex)
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

    private func attachAssetReference(entityID rawID: UInt64, asset: EditorAsset) {
        guard let entity = EntityID(rawValue: rawID), scene.contains(entity) else {
            return
        }
        _ = scene.setComponent(
            AssetReferenceComponent(assetID: asset.id,
                                    name: asset.name,
                                    relativePath: asset.relativePath,
                                    absolutePath: asset.absolutePath,
                                    kind: asset.kind.rawValue,
                                    meshIndex: asset.meshIndex),
            for: entity
        )
        if var renderMesh = scene.component(RenderMeshComponent.self, for: entity) {
            renderMesh.assetID = asset.id
            _ = scene.setComponent(renderMesh, for: entity)
        }
        notifyRevisionChanged()
    }

    private func attachMeshColliderIfAvailable(entityID rawID: UInt64, meshIndex: Int) {
        guard let entity = EntityID(rawValue: rawID),
              scene.contains(entity)
        else {
            return
        }

        let resourceID = meshColliderResourceID(for: meshIndex)
        let geometry = meshColliderGeometry(for: meshIndex)
        let bounds = MeshBoundsRegistry.shared.bounds(for: meshIndex).map { SpatialAABB(min: $0.min, max: $0.max) }
            ?? geometry?.localBounds
        guard bounds != nil || geometry != nil else { return }

        if let bounds {
            var resource = scene.resource(MeshColliderBoundsResource.self) ?? MeshColliderBoundsResource()
            resource.boundsByResourceID[resourceID] = bounds
            scene.setResource(resource)
        }
        if let geometry {
            var resource = scene.resource(MeshColliderGeometryResource.self) ?? MeshColliderGeometryResource()
            resource.geometryByResourceID[resourceID] = geometry
            scene.setResource(resource)
        }

        _ = scene.setComponent(Collider(shape: .mesh(resourceID: resourceID, center: .zero)), for: entity)
        notifyRevisionChanged()
    }

    private func meshColliderResourceID(for meshIndex: Int) -> String {
        "meshIndex:\(meshIndex)"
    }

    private func attachAnimationPlayerIfAvailable(entityID rawID: UInt64, meshIndex: Int) {
        guard let entity = EntityID(rawValue: rawID),
              scene.contains(entity),
              let mesh = AssetRegistry.shared.meshAsset(for: meshIndex),
              !mesh.animations.isEmpty
        else { return }
        _ = scene.setComponent(AnimationPlayer(), for: entity)
        notifyRevisionChanged()
    }

    private func meshColliderGeometry(for meshIndex: Int) -> MeshColliderGeometry? {
        guard let mesh = AssetRegistry.shared.meshAsset(for: meshIndex),
              mesh.triangleCount > 0 else {
            return nil
        }
        let positions = (0..<mesh.vertexCount).compactMap { mesh.position(at: $0) }
        return MeshColliderGeometry(positions: positions,
                                    triangleIndices: mesh.indices,
                                    localBounds: SpatialAABB(min: mesh.localBounds.min,
                                                             max: mesh.localBounds.max))
    }
}

private extension EntityID {
    init?(rawValue: UInt64) {
        self.init(index: UInt32(rawValue & 0xFFFF_FFFF),
                  generation: UInt32(rawValue >> 32))
    }
}
