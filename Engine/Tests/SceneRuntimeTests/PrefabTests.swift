import SceneRuntime
import Testing
import Foundation
import SIMDCompat

@Suite("Prefab")
struct PrefabTests {

    /// Builds a small two-node prefab source: a named root with a child, components on both.
    private func makeSource() -> (scene: SceneRuntime, root: EntityID) {
        var scene = SceneRuntime()
        let root = scene.createEntity()
        _ = scene.setComponent(SceneNameComponent(value: "Turret"), for: root)
        _ = scene.setComponent(SceneKindComponent(value: "Enemy"), for: root)
        _ = scene.setLocalTransform(LocalTransform(translation: SIMD3<Float>(0, 1, 0)), for: root)
        _ = scene.setComponent(RigidBody(motionType: .dynamic, mass: 12), for: root)
        _ = scene.setComponent(Collider(shape: .sphere(radius: 0.5, center: .zero)), for: root)

        let barrel = scene.createEntity()
        _ = scene.setComponent(SceneNameComponent(value: "Barrel"), for: barrel)
        _ = scene.setLocalTransform(LocalTransform(translation: SIMD3<Float>(0, 0.5, 1)), for: barrel)
        _ = scene.setComponent(RenderMeshComponent(meshIndex: 3), for: barrel)
        _ = scene.setParent(root, for: barrel)
        return (scene, root)
    }

    @Test("capture then instantiate recreates the subtree")
    func captureInstantiateRoundTrip() throws {
        let (source, root) = makeSource()
        let prefab = try Prefab.capture(from: source, root: root)
        #expect(prefab != nil)

        var target = SceneRuntime()
        let newRoot = try prefab!.instantiate(into: &target)
        #expect(newRoot != nil)
        _ = target.tick()

        #expect(target.snapshot.entityCount == 2)
        let turret = target.findEntity(named: "Turret")
        #expect(turret == newRoot)
        #expect(target.component(RigidBody.self, for: turret!)?.mass == 12)
        #expect(target.component(Collider.self, for: turret!) != nil)

        let barrel = target.findEntity(named: "Barrel")
        #expect(barrel != nil)
        #expect(target.parent(of: barrel!) == turret)
        #expect(target.component(RenderMeshComponent.self, for: barrel!)?.meshIndex == 3)
    }

    @Test("instantiate can be repeated to spawn independent copies")
    func instantiateMultipleTimes() throws {
        let (source, root) = makeSource()
        let prefab = try #require(try Prefab.capture(from: source, root: root))

        var target = SceneRuntime()
        let a = try prefab.instantiate(into: &target)
        let b = try prefab.instantiate(into: &target)
        let c = try prefab.instantiate(into: &target)

        #expect(a != nil && b != nil && c != nil)
        #expect(a != b && b != c && a != c)
        #expect(target.snapshot.entityCount == 6) // 2 entities x 3 copies
        #expect(target.entities(with: SceneNameComponent.self).count == 6)
    }

    @Test("instantiate applies parent and transform overrides to the root only")
    func instantiateWithOverrides() throws {
        let (source, root) = makeSource()
        let prefab = try #require(try Prefab.capture(from: source, root: root))

        var target = SceneRuntime()
        let anchor = target.createEntity()
        _ = target.setComponent(SceneNameComponent(value: "Anchor"), for: anchor)

        let placement = LocalTransform(translation: SIMD3<Float>(10, 0, -4))
        let newRoot = try prefab.instantiate(into: &target, parent: anchor, transform: placement)
        #expect(newRoot != nil)
        _ = target.tick()

        // Root reparented and repositioned.
        #expect(target.parent(of: newRoot!) == anchor)
        let t = target.localTransform(for: newRoot!)
        #expect(abs(t!.translation.x - 10) < 0.01)
        #expect(abs(t!.translation.z + 4) < 0.01)

        // Child keeps its captured local transform (override is root-only).
        let barrel = target.findEntity(named: "Barrel")
        let bt = target.localTransform(for: barrel!)
        #expect(abs(bt!.translation.z - 1) < 0.01)
    }

    @Test("capture returns nil for an entity outside the scene")
    func captureMissingEntity() throws {
        let empty = SceneRuntime()
        var other = SceneRuntime()
        let stray = other.createEntity()
        #expect(try Prefab.capture(from: empty, root: stray) == nil)
    }

    @Test("prefab data survives a raw serialize/load cycle")
    func prefabDataIsRelocatable() throws {
        let (source, root) = makeSource()
        let prefab = try #require(try Prefab.capture(from: source, root: root))

        // Re-wrap the bytes (as if loaded from disk) and instantiate.
        let reloaded = Prefab(data: prefab.data)
        var target = SceneRuntime()
        let newRoot = try reloaded.instantiate(into: &target)
        #expect(newRoot != nil)
        #expect(target.snapshot.entityCount == 2)
    }
}
