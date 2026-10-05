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
        let manifestRoots = scene.roots().map(manifestNode)
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
        var restoredScene = SceneRuntime()
        var idMap: [UInt64: EntityID] = [:]

        @discardableResult
        func restoreNode(_ node: EditorSceneManifestNode) -> EntityID {
            let entity = restoredScene.createEntity()
            idMap[node.id] = entity
            _ = restoredScene.setComponent(SceneNameComponent(value: node.name), for: entity)
            _ = restoredScene.setComponent(SceneKindComponent(value: node.kind), for: entity)
            _ = restoredScene.setLocalTransform(node.localTransform?.localTransform ?? .identity,
                                                for: entity)
            if let asset = node.asset {
                var component = asset.component
                if let registered = AssetRegistry.shared.entry(for: asset.assetID)
                    ?? AssetRegistry.shared.entry(for: asset.relativePath) {
                    component.assetID = registered.id
                    component.name = registered.name
                    component.relativePath = registered.relativePath
                    component.absolutePath = registered.absolutePath
                    component.kind = registered.kind.rawValue
                    component.meshIndex = registered.meshIndex
                }
                _ = restoredScene.setComponent(component, for: entity)
            }
            if let renderMesh = node.renderMesh {
                var component = renderMesh.component
                let registeredAssetID = renderMesh.assetID ?? node.asset?.assetID
                if let registeredAssetID,
                   let registered = AssetRegistry.shared.entry(for: registeredAssetID) {
                    component.meshIndex = registered.meshIndex
                    component.assetID = registered.id
                }
                _ = restoredScene.setComponent(component, for: entity)
            }
            if let renderMaterial = node.renderMaterial {
                _ = restoredScene.setComponent(renderMaterial.component, for: entity)
            }
            if let camera = node.camera {
                _ = restoredScene.setComponent(camera.component, for: entity)
            }
            if let light = node.light {
                _ = restoredScene.setComponent(light.component, for: entity)
            }
            if let rigidBody = node.rigidBody {
                _ = restoredScene.setComponent(rigidBody.component, for: entity)
            }
            if let collider = node.collider {
                _ = restoredScene.setComponent(collider.component, for: entity)
            }
            if let characterController = node.characterController {
                _ = restoredScene.setComponent(characterController.component, for: entity)
            }
            if let vehicle = node.vehicle {
                _ = restoredScene.setComponent(vehicle.component, for: entity)
            }
            if let softBody = node.softBody {
                _ = restoredScene.setComponent(softBody.component, for: entity)
            }
            if let cloth = node.cloth {
                _ = restoredScene.setComponent(cloth.component, for: entity)
            }
            if let softBodyMesh = node.softBodyMesh {
                _ = restoredScene.setComponent(softBodyMesh.component, for: entity)
            }
            if let destructible = node.destructible {
                _ = restoredScene.setComponent(destructible.component, for: entity)
            }
            if let script = node.script {
                _ = restoredScene.setComponent(script.component, for: entity)
            }
            if let audioSource = node.audioSource {
                _ = restoredScene.setComponent(audioSource.component, for: entity)
            }
            if let audioListener = node.audioListener {
                _ = restoredScene.setComponent(audioListener.component, for: entity)
            }
            if let animationPlayer = node.animationPlayer {
                _ = restoredScene.setComponent(animationPlayer.component, for: entity)
            }
            if let animationGraphPlayer = node.animationGraphPlayer {
                _ = restoredScene.setComponent(animationGraphPlayer.component, for: entity)
            }
            if let particleEmitter = node.particleEmitter {
                _ = restoredScene.setComponent(particleEmitter.component, for: entity)
            }
            for child in node.children {
                let childEntity = restoreNode(child)
                _ = restoredScene.setParent(entity, for: childEntity)
            }
            return entity
        }

        func restoreReferencedComponents(_ node: EditorSceneManifestNode) {
            if let entity = idMap[node.id] {
                if let constraint = node.constraint?.component(idMap: idMap) {
                    _ = restoredScene.setComponent(constraint, for: entity)
                }
                if let ragdoll = node.ragdoll?.component(idMap: idMap) {
                    _ = restoredScene.setComponent(ragdoll, for: entity)
                }
            }
            for child in node.children {
                restoreReferencedComponents(child)
            }
        }

        for root in manifest.roots {
            restoreNode(root)
        }
        for root in manifest.roots {
            restoreReferencedComponents(root)
        }
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

    private func manifestNode(_ entity: EntityID) -> EditorSceneManifestNode {
        let localTransform = scene.localTransform(for: entity).map { EditorSceneManifestMatrix($0.matrix) }
        let asset = scene.component(AssetReferenceComponent.self, for: entity)
            .map(EditorSceneManifestAssetReference.init)
        let renderMesh = scene.component(RenderMeshComponent.self, for: entity)
            .map(EditorSceneManifestRenderMesh.init)
        let renderMaterial = scene.component(RenderMaterialComponent.self, for: entity)
            .map(EditorSceneManifestRenderMaterial.init)
        let camera = scene.component(CameraComponent.self, for: entity)
            .map(EditorSceneManifestCamera.init)
        let light = scene.component(LightComponent.self, for: entity)
            .map(EditorSceneManifestLight.init)
        let rigidBody = scene.component(RigidBody.self, for: entity)
            .map(EditorSceneManifestRigidBody.init)
        let collider = scene.component(Collider.self, for: entity)
            .map(EditorSceneManifestCollider.init)
        let characterController = scene.component(CharacterController.self, for: entity)
            .map(EditorSceneManifestCharacterController.init)
        let vehicle = scene.component(Vehicle.self, for: entity)
            .map(EditorSceneManifestVehicle.init)
        let softBody = scene.component(SoftBody.self, for: entity)
            .map(EditorSceneManifestSoftBody.init)
        let cloth = scene.component(Cloth.self, for: entity)
            .map(EditorSceneManifestCloth.init)
        let softBodyMesh = scene.component(SoftBodyMesh.self, for: entity)
            .map(EditorSceneManifestSoftBodyMesh.init)
        let destructible = scene.component(Destructible.self, for: entity)
            .map(EditorSceneManifestDestructible.init)
        let ragdoll = scene.component(Ragdoll.self, for: entity)
            .map(EditorSceneManifestRagdoll.init)
        let constraint = scene.component(Constraint.self, for: entity)
            .map(EditorSceneManifestConstraint.init)
        let script = scene.component(ScriptComponent.self, for: entity)
            .map(EditorSceneManifestScript.init)
        let audioSource = scene.component(AudioSource.self, for: entity)
            .map(EditorSceneManifestAudioSource.init)
        let audioListener = scene.component(AudioListener.self, for: entity)
            .map(EditorSceneManifestAudioListener.init)
        let animationPlayer = scene.component(AnimationPlayer.self, for: entity)
            .map(EditorSceneManifestAnimationPlayer.init)
        let animationGraphPlayer = scene.component(AnimationGraphPlayer.self, for: entity)
            .map(EditorSceneManifestAnimationGraphPlayer.init)
        let childIDs = scene.children(of: entity)
        var children: [EditorSceneManifestNode] = []
        children.reserveCapacity(childIDs.count)
        for child in childIDs {
            children.append(manifestNode(child))
        }
        let particleEmitter = scene.component(ParticleEmitter.self, for: entity)
            .map(EditorSceneManifestParticleEmitter.init)
        return EditorSceneManifestNode(
            id: entity.rawValue,
            name: displayName(for: entity),
            kind: displayKind(for: entity),
            localTransform: localTransform,
            asset: asset,
            renderMesh: renderMesh,
            renderMaterial: renderMaterial,
            camera: camera,
            light: light,
            rigidBody: rigidBody,
            collider: collider,
            characterController: characterController,
            vehicle: vehicle,
            softBody: softBody,
            cloth: cloth,
            softBodyMesh: softBodyMesh,
            destructible: destructible,
            ragdoll: ragdoll,
            constraint: constraint,
            script: script,
            audioSource: audioSource,
            audioListener: audioListener,
            animationPlayer: animationPlayer,
            animationGraphPlayer: animationGraphPlayer,
            particleEmitter: particleEmitter,
            children: children
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
