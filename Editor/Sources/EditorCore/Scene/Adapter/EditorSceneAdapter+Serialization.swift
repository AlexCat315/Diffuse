import Foundation
import AssetPipeline
import GuavaUIRuntime
import IntentRuntime
import RenderBackend
import SceneRuntime
import ScriptRuntime
import SIMDCompat

extension EditorSceneAdapter {
    public func manifest(selectedEntityID: UInt64? = nil) -> EditorSceneManifest {
        let selectedEntity = entity(from: selectedEntityID)
        let restoredSelection = selectedEntity.flatMap { scene.contains($0) ? $0.rawValue : nil }
        let physicsSettings = scene.resource(PhysicsSettingsResource.self)
            .map(EditorSceneManifestPhysicsSettings.init)
        let particleScalability = scene.resource(ParticleScalabilityResource.self)
            .map(EditorSceneManifestParticleScalability.init)
        let particleScalabilityPolicy = scene.resource(ParticleScalabilityPolicyResource.self)
            .map(EditorSceneManifestParticleScalabilityPolicy.init)
        let sceneKind = scene.resource(SceneKindComponent.self)?.value
        let assetCount = AssetRegistry.shared.entriesSnapshot().count
        let timestamp = ISO8601DateFormatter().string(from: Date())
        var ordered: [EntityID] = []
        func visit(_ entity: EntityID) {
            ordered.append(entity)
            for child in scene.children(of: entity) { visit(child) }
        }
        for root in scene.roots() { visit(root) }
        var context = ComponentEncodeContext(entityIndexMap: Dictionary(uniqueKeysWithValues:
            ordered.enumerated().map { ($0.element, $0.offset) }))
        let manifestRoots = scene.roots().map { manifestNode($0, context: &context) }
        return EditorSceneManifest(revision: revision,
                                   entityCount: entityCount,
                                   selectedEntityID: restoredSelection,
                                   sceneKind: sceneKind,
                                   physicsSettings: physicsSettings,
                                   particleScalability: particleScalability,
                                   particleScalabilityPolicy: particleScalabilityPolicy,
                                   projectAssetCount: assetCount > 0 ? assetCount : nil,
                                   lastModifiedAt: timestamp,
                                   lockedEntityIDs: scene.entities(with: EditorHierarchyLockComponent.self).isEmpty
                                       ? nil
                                       : scene.entities(with: EditorHierarchyLockComponent.self)
                                           .map(\.rawValue)
                                           .sorted(),
                                   roots: manifestRoots)
    }

    @discardableResult
    public func load(manifest: EditorSceneManifest, notify: Bool = true) -> EditorSceneManifestLoadResult {
        guard manifest.schemaVersion == EditorSceneManifest.currentSchemaVersion else {
            return EditorSceneManifestLoadResult(
                entityCount: entityCount,
                selectedEntityID: initialSelectionID,
                error: .unsupportedVersion(manifest.schemaVersion)
            )
        }
        var restoredScene = SceneRuntime(componentRegistry: scene.componentRegistry)
        var idMap: [UInt64: EntityID] = [:]
        var orderedNodes: [EditorSceneManifestNode] = []

        @discardableResult
        func restoreNode(_ node: EditorSceneManifestNode) -> EntityID {
            let entity = restoredScene.createEntity()
            idMap[node.id] = entity
            _ = restoredScene.setComponent(SceneNameComponent(value: node.name), for: entity)
            _ = restoredScene.setComponent(SceneKindComponent(value: node.kind), for: entity)
            _ = restoredScene.setLocalTransform(node.localTransform?.localTransform ?? .identity,
                                                for: entity)
            orderedNodes.append(node)
            for child in node.children {
                let childEntity = restoreNode(child)
                _ = restoredScene.setParent(entity, for: childEntity)
            }
            return entity
        }

        // Re-resolves authored asset references (and render-mesh indices that derive
        // from them) against the current asset registry, mirroring the previous
        // per-node open-time resolution. Runs before collider resources are rebuilt so
        // mesh bounds use the re-resolved mesh indices.
        func refreshAssetReferences(_ node: EditorSceneManifestNode) {
            guard let entity = idMap[node.id],
                  let assetReference = restoredScene.component(AssetReferenceComponent.self, for: entity) else {
                for child in node.children {
                    refreshAssetReferences(child)
                }
                return
            }
            var resolved = assetReference
            if let registered = AssetRegistry.shared.entry(for: assetReference.assetID)
                ?? AssetRegistry.shared.entry(for: assetReference.relativePath) {
                resolved.assetID = registered.id
                resolved.name = registered.name
                resolved.relativePath = registered.relativePath
                resolved.absolutePath = registered.absolutePath
                resolved.kind = registered.kind.rawValue
                resolved.meshIndex = registered.meshIndex
            }
            _ = restoredScene.setComponent(resolved, for: entity)
            if var renderMesh = restoredScene.component(RenderMeshComponent.self, for: entity),
               let registered = AssetRegistry.shared.entry(for: renderMesh.assetID ?? resolved.assetID) {
                renderMesh.meshIndex = registered.meshIndex
                renderMesh.assetID = registered.id
                _ = restoredScene.setComponent(renderMesh, for: entity)
            }
            for child in node.children {
                refreshAssetReferences(child)
            }
        }

        for root in manifest.roots { restoreNode(root) }
        var context = ComponentDecodeContext(entityMap: Dictionary(uniqueKeysWithValues:
            orderedNodes.enumerated().compactMap { index, node in idMap[node.id].map { (index, $0) } }))
        for node in orderedNodes {
            guard let entity = idMap[node.id] else { continue }
            SceneSerializer.applyComponentDocument(node.components, to: entity, in: &restoredScene, context: &context)
        }
        for root in manifest.roots { refreshAssetReferences(root) }
        if let physicsSettings = manifest.physicsSettings {
            restoredScene.setResource(physicsSettings.settings)
        }
        if let particleScalability = manifest.particleScalability {
            restoredScene.setResource(particleScalability.settings)
        }
        if let particleScalabilityPolicy = manifest.particleScalabilityPolicy {
            restoredScene.setResource(particleScalabilityPolicy.policy)
        }
        restoredScene.setResource(InputActionMap.guavaDefault)
        for originalID in manifest.lockedEntityIDs ?? [] {
            if let entity = idMap[originalID] {
                _ = restoredScene.setComponent(EditorHierarchyLockComponent(), for: entity)
            }
        }
        rebuildMeshColliderResources(in: &restoredScene)
        restoredScene.propagateTransforms()

        scriptRuntime.reset()
        restoredScene.setScriptDriver(scriptRuntime)
        invalidateParticleFeedback()
        scene = restoredScene
        initialSelectionID = manifest.selectedEntityID.flatMap { idMap[$0]?.rawValue }
            ?? scene.roots().first?.rawValue
        initialExpandedIDs = Set(scene.roots().map(\.rawValue))
        resetEditHistory()
        if notify {
            notifyRevisionChanged(recordHistory: false)
        }
        return EditorSceneManifestLoadResult(entityCount: entityCount,
                                             selectedEntityID: initialSelectionID)
    }

    private func manifestNode(_ entity: EntityID, context: inout ComponentEncodeContext) -> EditorSceneManifestNode {
        EditorSceneManifestNode(
            id: entity.rawValue,
            name: displayName(for: entity),
            kind: displayKind(for: entity),
            localTransform: scene.localTransform(for: entity).map { EditorSceneManifestMatrix($0.matrix) },
            components: SceneSerializer.componentDocument(for: entity, in: scene, context: &context),
            children: scene.children(of: entity).map { manifestNode($0, context: &context) }
        )
    }

    private func rebuildMeshColliderResources(in runtime: inout SceneRuntime) {
        var boundsResource = runtime.resource(MeshColliderBoundsResource.self) ?? MeshColliderBoundsResource()
        var geometryResource = runtime.resource(MeshColliderGeometryResource.self) ?? MeshColliderGeometryResource()
        var changedBounds = false
        var changedGeometry = false

        for entity in runtime.entities() {
            guard let asset = runtime.component(AssetReferenceComponent.self, for: entity),
                  let mesh = AssetRegistry.shared.meshAsset(for: asset.meshIndex) else {
                continue
            }
            var resourceIDs = Set<String>()
            if let collider = runtime.component(Collider.self, for: entity),
               case let .mesh(resourceID, _) = collider.shape {
                resourceIDs.insert(resourceID ?? manifestMeshColliderResourceID(for: asset.meshIndex))
            }
            if let softBodyMesh = runtime.component(SoftBodyMesh.self, for: entity) {
                let resourceID = softBodyMesh.resourceID
                    ?? manifestMeshColliderResourceID(for: asset.meshIndex)
                resourceIDs.insert(resourceID)
                if softBodyMesh.resourceID == nil {
                    var resolved = softBodyMesh
                    resolved.resourceID = resourceID
                    _ = runtime.setComponent(resolved, for: entity)
                }
            }
            guard !resourceIDs.isEmpty else { continue }
            let bounds = SpatialAABB(min: mesh.localBounds.min, max: mesh.localBounds.max)
            let geometry = MeshColliderGeometry(
                positions: (0..<mesh.vertexCount).compactMap { mesh.position(at: $0) },
                triangleIndices: mesh.indices,
                textureCoordinates: (0..<mesh.vertexCount).compactMap {
                    mesh.textureCoordinate(at: $0)
                },
                localBounds: bounds
            )
            for resourceID in resourceIDs {
                boundsResource.boundsByResourceID[resourceID] = bounds
                changedBounds = true
                if mesh.triangleCount > 0 {
                    geometryResource.geometryByResourceID[resourceID] = geometry
                    changedGeometry = true
                }
            }
        }

        if changedBounds {
            runtime.setResource(boundsResource)
        }
        if changedGeometry {
            runtime.setResource(geometryResource)
        }
    }
}