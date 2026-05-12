import AssetPipeline
@testable import EditorCore
import RenderBackend
import SceneRuntime
import simd
import Testing

@Suite("EditorSceneAdapter", .serialized)
struct EditorSceneAdapterTests {
    @Test("Preview scene manifest captures hierarchy roots")
    func previewManifestCapturesHierarchyRoots() {
        let scene = EditorSceneAdapter()

        let manifest = scene.manifest(selectedEntityID: scene.defaultSelectionID)

        #expect(manifest.schemaVersion == 3)
        #expect(manifest.revision == scene.revision)
        #expect(manifest.entityCount == scene.entityCount)
        #expect(manifest.selectedEntityID == scene.defaultSelectionID)
        #expect(!manifest.roots.isEmpty)
        #expect(manifest.roots.contains { $0.name == "Main Camera" })
        #expect(manifest.roots.contains { $0.camera != nil })
    }

    @Test("Scene manifest restores preview hierarchy and runtime components")
    func sceneManifestRestoresPreviewHierarchyAndComponents() {
        let source = EditorSceneAdapter()
        let manifest = source.manifest(selectedEntityID: source.defaultSelectionID)
        let restored = EditorSceneAdapter()

        let result = restored.load(manifest: manifest)

        #expect(result.entityCount == manifest.entityCount)
        #expect(result.selectedEntityID != nil)
        #expect(restored.roots.map(\.name) == source.roots.map(\.name))

        let nodes = flatten(restored.roots)
        let hero = nodes.first { $0.name == "Hero" }
        let camera = nodes.first { $0.name == "Main Camera" }
        let light = nodes.first { $0.name == "Key Light" }
        let constraint = nodes.first { $0.name == "Hero Follow" }

        #expect(hero != nil)
        #expect(camera != nil)
        #expect(light != nil)
        #expect(constraint != nil)

        if let heroID = hero.map(\.id).map(entityID) {
            #expect(restored.scene.component(RenderMeshComponent.self, for: heroID)?.meshIndex == 1)
            #expect(restored.scene.component(RigidBody.self, for: heroID)?.motionType == .dynamic)
            #expect(restored.scene.component(Collider.self, for: heroID) != nil)
        }
        if let cameraID = camera.map(\.id).map(entityID) {
            #expect(restored.scene.component(CameraComponent.self, for: cameraID)?.isActive == true)
        }
        if let lightID = light.map(\.id).map(entityID) {
            #expect(restored.scene.component(LightComponent.self, for: lightID)?.intensity == 3.0)
        }
        if let constraintID = constraint.map(\.id).map(entityID) {
            #expect(restored.scene.component(Constraint.self, for: constraintID)?.constraintType == .distance)
        }
    }

    @Test("Scene manifest round-trips the renderable scene contract")
    func sceneManifestRoundTripsRenderableSceneContract() {
        let source = EditorSceneAdapter()
        guard let hero = flatten(source.roots).first(where: { $0.name == "Hero" }) else {
            Issue.record("Expected preview scene hero")
            return
        }
        let heroID = entityID(hero.id)
        _ = source.scene.setComponent(
            RenderMeshComponent(meshIndex: 12,
                                isVisible: true,
                                colorTint: SIMD3<Float>(0.4, 0.5, 0.6),
                                assetID: "hero.asset"),
            for: heroID
        )
        _ = source.scene.setComponent(
            RenderMaterialComponent(baseColorFactor: SIMD4<Float>(0.8, 0.7, 0.6, 0.9),
                                    baseColorTextureIndex: 2,
                                    normalTextureIndex: 4,
                                    metallicFactor: 0.3,
                                    roughnessFactor: 0.65,
                                    emissiveFactor: SIMD3<Float>(0.1, 0.2, 0.3)),
            for: heroID
        )

        let manifest = source.manifest(selectedEntityID: hero.id)
        let manifestHero = findNode(in: manifest.roots, id: hero.id)

        #expect(manifestHero?.renderMesh?.meshIndex == 12)
        #expect(manifestHero?.renderMesh?.assetID == "hero.asset")
        #expect(manifestHero?.renderMesh?.colorTint?.simdValue == SIMD3<Float>(0.4, 0.5, 0.6))
        #expect(manifestHero?.renderMaterial?.baseColorFactor.simdValue == SIMD4<Float>(0.8, 0.7, 0.6, 0.9))
        #expect(manifestHero?.renderMaterial?.baseColorTextureIndex == 2)
        #expect(manifestHero?.renderMaterial?.normalTextureIndex == 4)

        let restored = EditorSceneAdapter()
        let result = restored.load(manifest: manifest)
        guard let restoredHeroID = result.selectedEntityID.map(entityID) else {
            Issue.record("Expected restored hero selection")
            return
        }

        let restoredMesh = restored.scene.component(RenderMeshComponent.self, for: restoredHeroID)
        let restoredMaterial = restored.scene.component(RenderMaterialComponent.self, for: restoredHeroID)
        #expect(restoredMesh?.meshIndex == 12)
        #expect(restoredMesh?.assetID == "hero.asset")
        #expect(restoredMesh?.colorTint == SIMD3<Float>(0.4, 0.5, 0.6))
        #expect(restoredMaterial?.baseColorFactor == SIMD4<Float>(0.8, 0.7, 0.6, 0.9))
        #expect(restoredMaterial?.baseColorTextureIndex == 2)
        #expect(restoredMaterial?.normalTextureIndex == 4)
        #expect(restoredMaterial?.metallicFactor == 0.3)
        #expect(restoredMaterial?.roughnessFactor == 0.65)
        #expect(restoredMaterial?.emissiveFactor == SIMD3<Float>(0.1, 0.2, 0.3))
    }

    @Test("Resetting preview scene publishes a new revision")
    func resetPreviewScenePublishesRevision() {
        let scene = EditorSceneAdapter()
        var revisions: [UInt64] = []
        scene.onRevisionChanged = { revisions.append($0) }

        scene.resetToPreviewScene()

        #expect(revisions == [scene.revision])
        #expect(scene.defaultSelectionID != nil)
    }

    @Test("Spawning imported mesh attaches registered mesh collider bounds")
    func spawningImportedMeshAttachesRegisteredMeshColliderBounds() {
        let registry = MeshBoundsRegistry.shared
        registry.clearAll()
        defer { registry.clearAll() }

        let localMin = SIMD3<Float>(-2, -1, -0.25)
        let localMax = SIMD3<Float>(2, 1, 0.25)
        registry.register(meshIndex: 42, min: localMin, max: localMax)

        let scene = EditorSceneAdapter()
        let asset = EditorAsset(
            id: "wide-mesh",
            name: "Wide Mesh",
            relativePath: "Meshes/Wide.obj",
            absolutePath: "/tmp/Meshes/Wide.obj",
            kind: .obj,
            meshIndex: 42
        )

        guard let rawID = scene.spawnEntity(from: asset, at: SIMD3<Float>(10, 0, 0)) else {
            Issue.record("Expected imported mesh spawn to create an entity")
            return
        }
        let entity = entityID(rawID)

        guard let collider = scene.scene.component(Collider.self, for: entity) else {
            Issue.record("Expected imported mesh spawn to attach a mesh collider")
            return
        }

        switch collider.shape {
        case let .mesh(resourceID, center):
            #expect(resourceID == "meshIndex:42")
            #expect(center == .zero)
        default:
            Issue.record("Expected imported mesh collider shape")
        }

        let resource = scene.scene.resource(MeshColliderBoundsResource.self)
        #expect(resource?.bounds(for: "meshIndex:42")?.min == localMin)
        #expect(resource?.bounds(for: "meshIndex:42")?.max == localMax)

        let hit = scene.scene.raycast(
            SceneRaycastQuery(
                origin: SIMD3<Float>(6, 0, 0),
                direction: SIMD3<Float>(1, 0, 0),
                maxDistance: 100,
                includeTriggers: true
            )
        )
        #expect(hit?.entity == entity)
        #expect(hit?.distance == 2)
    }
}

private func flatten(_ nodes: [EditorSceneNode]) -> [EditorSceneNode] {
    nodes.flatMap { [$0] + flatten($0.children) }
}

private func findNode(in nodes: [EditorSceneManifestNode], id: UInt64) -> EditorSceneManifestNode? {
    for node in nodes {
        if node.id == id {
            return node
        }
        if let found = findNode(in: node.children, id: id) {
            return found
        }
    }
    return nil
}

private func entityID(_ rawValue: UInt64) -> EntityID {
    EntityID(index: UInt32(rawValue & 0xFFFF_FFFF),
             generation: UInt32(rawValue >> 32))
}
