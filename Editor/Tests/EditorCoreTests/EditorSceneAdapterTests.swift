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

private func entityID(_ rawValue: UInt64) -> EntityID {
    EntityID(index: UInt32(rawValue & 0xFFFF_FFFF),
             generation: UInt32(rawValue >> 32))
}
