import Foundation
import AssetPipeline
import IntentRuntime
import RenderBackend
import SceneRuntime
import SIMDCompat

/// Ready-to-use entities exposed by the editor's Hierarchy create menu.
/// These templates intentionally map to SceneRuntime primitives so they work
/// in a new project before any assets have been imported.
public enum EditorEntityTemplate: String, CaseIterable, Sendable {
    case empty
    case cube
    case directionalLight
    case pointLight
    case spotLight
    case camera

    public var displayName: String {
        switch self {
        case .empty: return "Empty Entity"
        case .cube: return "Cube"
        case .directionalLight: return "Directional Light"
        case .pointLight: return "Point Light"
        case .spotLight: return "Spot Light"
        case .camera: return "Camera"
        }
    }
}

extension EditorSceneAdapter {
    /// Creates a built-in entity without requiring a project asset. The
    /// operation participates in editor history and returns the new raw id so
    /// the caller can select it immediately.
    @discardableResult
    public func spawnEntity(template: EditorEntityTemplate,
                            at position: SIMD3<Float>? = nil,
                            parentID: UInt64? = nil) -> UInt64? {
        let spawnPosition = position ?? defaultSpawnPosition(for: template)
        let mutation: SceneMutation
        switch template {
        case .empty:
            mutation = .spawnEmptyEntity(label: uniqueDisplayName(base: "Empty Entity"),
                                         position: spawnPosition,
                                         parentID: parentID)
        case .cube:
            mutation = .spawnImportedMeshEntity(label: uniqueDisplayName(base: "Cube"),
                                                kindLabel: "Mesh",
                                                meshIndex: 0,
                                                position: spawnPosition,
                                                parentID: parentID)
        case .directionalLight:
            mutation = .spawnLightEntity(label: uniqueDisplayName(base: "Directional Light"),
                                         lightType: .directional,
                                         position: spawnPosition,
                                         initialIntensity: 3,
                                         initialCastShadows: true,
                                         parentID: parentID)
        case .pointLight:
            mutation = .spawnLightEntity(label: uniqueDisplayName(base: "Point Light"),
                                         lightType: .point,
                                         position: spawnPosition,
                                         initialIntensity: 10,
                                         initialRange: 10,
                                         initialCastShadows: true,
                                         parentID: parentID)
        case .spotLight:
            mutation = .spawnLightEntity(label: uniqueDisplayName(base: "Spot Light"),
                                         lightType: .spot,
                                         position: spawnPosition,
                                         initialIntensity: 10,
                                         initialRange: 10,
                                         initialCastShadows: true,
                                         parentID: parentID)
        case .camera:
            mutation = .spawnCameraEntity(label: uniqueDisplayName(base: "Camera"),
                                          position: spawnPosition,
                                          initialFovYDegrees: 60,
                                          parentID: parentID)
        }

        let result = applySceneTransaction(intentVerb: "scene.create_entity",
                                           summary: "Create \(template.displayName.lowercased())",
                                           mutations: [mutation])
        return result?.createdEntityIDs.first
    }

    private func defaultSpawnPosition(for template: EditorEntityTemplate) -> SIMD3<Float> {
        switch template {
        case .empty, .cube:
            return .zero
        case .directionalLight:
            return SIMD3<Float>(0, 3, 0)
        case .pointLight, .spotLight:
            return SIMD3<Float>(0, 2, 0)
        case .camera:
            return SIMD3<Float>(0, 1.5, 5)
        }
    }

    /// 在场景里生成一个新实体并立即可见，返回 raw entity id。
    /// 调用方一般紧接着把返回的 id 写回 store 作为新的选中态。
    @discardableResult
    public func spawnEntity(from asset: EditorAsset,
                            at position: SIMD3<Float> = SIMD3<Float>(0, 0, 0)) -> UInt64? {
        withEditHistoryGroup {
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
        let textureCoordinates = (0..<mesh.vertexCount).compactMap {
            mesh.textureCoordinate(at: $0)
        }
        return MeshColliderGeometry(positions: positions,
                                    triangleIndices: mesh.indices,
                                    textureCoordinates: textureCoordinates,
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
