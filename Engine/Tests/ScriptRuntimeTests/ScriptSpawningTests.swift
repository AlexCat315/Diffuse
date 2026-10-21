import Foundation
import SceneRuntime
import SIMDCompat
import Testing
import ScriptRuntime

private struct SpawnedEntities: Sendable { var entities: [EntityID] }

@Suite("Script spawning")
struct ScriptSpawningTests {
    @Test("native prefab loading restores scripts onto remapped child entities")
    func nativePrefabScripts() throws {
        var template = SceneRuntime()
        let root = template.createEntity()
        let child = template.createEntity()
        _ = template.setParent(root, for: child)
        _ = template.setComponent(ScriptComponent(ScriptBinding(identifier: "game.child")), for: child)
        let prefab = try #require(try Prefab.captureFull(from: template, root: root))
        var destination = SceneRuntime()
        _ = destination.createEntity()
        let removed = destination.createEntity()
        _ = destination.createEntity()
        _ = destination.destroyEntity(removed)
        let newRoot = try #require(try prefab.instantiateFull(into: &destination))
        let newChild = try #require(destination.children(of: newRoot).first)
        #expect(destination.component(ScriptComponent.self, for: newRoot) == nil)
        #expect(destination.component(ScriptComponent.self, for: newChild)?.bindings.first?.identifier == "game.child")
        #expect(destination.snapshot.entityCount == 4)
    }

    @Test("Batched script transforms reach descendants at the phase boundary")
    func flushesTransformBatch() {
        let scripts = ScriptRuntime()
        let handle = scripts.register(Script().onUpdate { context in
            for x in 1...32 {
                _ = context.setLocalTransform(LocalTransform(translation: SIMD3(Float(x), 0, 0)))
            }
        })
        var scene = SceneRuntime()
        scene.setScriptDriver(scripts)
        let parent = scene.createEntity()
        let child = scene.createEntity()
        _ = scene.setParent(parent, for: child)
        _ = scene.setLocalTransform(LocalTransform(translation: SIMD3(0, 2, 0)), for: child)
        _ = scene.setComponent(Collider(shape: .sphere(radius: 0.25, center: .zero)), for: child)
        _ = scene.setComponent(ScriptComponent(handle), for: parent)
        _ = scene.tick()
        #expect(scene.worldTransform(for: child)?.translation == SIMD3(32, 2, 0))
        #expect(scene.spatialIndex.entries.contains { $0.entity == child })
    }

    @Test("Physics queries see pending local transform writes inside a callback")
    func queriesPendingTransforms() {
        let scripts = ScriptRuntime()
        let handle = scripts.register(Script().onStart { context in
            let target = context.createEntity()
            _ = context.setComponent(Collider(shape: .sphere(radius: 0.5, center: .zero)), for: target)
            _ = context.setLocalTransform(LocalTransform(translation: SIMD3(5, 0, 0)), for: target)
            let query = PhysicsRaycastQuery(origin: SIMD3(3, 0, 0), direction: SIMD3(1, 0, 0), maxDistance: 4)
            #expect(context.physicsRaycast(query)?.entity == target)
            _ = context.translate(SIMD3(10, 0, 0), for: target)
            #expect(context.physicsRaycast(query) == nil)
        })
        var scene = SceneRuntime()
        scene.setScriptDriver(scripts)
        let owner = scene.createEntity()
        _ = scene.setComponent(ScriptComponent(handle), for: owner)
        _ = scene.tick()
    }

    @Test("a script creates and configures an entity visible to the same frame")
    func createsEntity() {
        let scripts = ScriptRuntime()
        let handle = scripts.register(Script().onStart { context in
            let entity = context.createEntity(named: "Bullet", transform: LocalTransform(translation: SIMD3(1, 2, 3)))
            _ = context.setComponent(Collider(shape: .sphere(radius: 0.25, center: .zero)), for: entity)
            context.setResource(SpawnedEntities(entities: [entity]))
            #expect(context.entity(named: "Bullet") == entity)
            #expect(context.worldTransform(of: entity)?.translation == SIMD3(1, 2, 3))
        })
        var scene = SceneRuntime()
        scene.setScriptDriver(scripts)
        let owner = scene.createEntity()
        _ = scene.setComponent(ScriptComponent(handle), for: owner)
        _ = scene.tick()
        let created = scene.resource(SpawnedEntities.self)?.entities.first
        #expect(created != nil)
        #expect(scene.snapshot.entityCount == 2)
        #expect(scene.spatialIndex.entries.contains { $0.entity == created })
    }

    @Test("prefab instances preserve hierarchy and get independent script state")
    func instantiatesGameplayPrefab() throws {
        var template = SceneRuntime()
        let root = template.createEntity()
        let child = template.createEntity()
        _ = template.setLocalTransform(.identity, for: root)
        _ = template.setLocalTransform(.identity, for: child)
        _ = template.setParent(root, for: child)
        _ = template.setComponent(ScriptComponent(ScriptBinding(identifier: "game.counter")), for: child)
        let prefab = try #require(try Prefab.captureFull(from: template, root: root))
        let scripts = ScriptRuntime()
        scripts.register(named: "game.counter") {
            let count = ScriptVar<Float>(0)
            return Script().onUpdate { context in
                count.value += 1
                _ = context.setLocalTransform(LocalTransform(translation: SIMD3(count.value, 0, 0)))
            }
        }
        let spawner = scripts.register(Script().onStart { context in
            do {
                let first = try #require(try context.instantiate(prefab, parent: context.entity))
                let second = try #require(try context.instantiate(prefab, parent: context.entity))
                context.setResource(SpawnedEntities(entities: [first, second]))
            } catch { Issue.record(error) }
        })
        var scene = SceneRuntime()
        scene.setScriptDriver(scripts)
        let owner = scene.createEntity()
        _ = scene.setLocalTransform(.identity, for: owner)
        _ = scene.setComponent(ScriptComponent(spawner), for: owner)
        _ = scene.tick()
        _ = scene.tick()
        let roots = try #require(scene.resource(SpawnedEntities.self)?.entities)
        #expect(roots.count == 2)
        for root in roots {
            #expect(scene.parent(of: root) == owner)
            let child = try #require(scene.children(of: root).first)
            #expect(scene.localTransform(for: child)?.translation == SIMD3<Float>(2, 0, 0))
        }
        #expect(template.snapshot.entityCount == 2)
    }

    @Test("invalid prefab documents fail before creating any entities")
    func rejectsMalformedPrefab() {
        let malformed = Prefab(data: Data(#"{"version":1,"entities":[{},42]}"#.utf8))
        let scripts = ScriptRuntime()
        let handle = scripts.register(Script().onStart { context in
            #expect(throws: SceneSerializerError.self) { try context.instantiate(malformed) }
            #expect(context.entities().count == 1)
        })
        var scene = SceneRuntime()
        scene.setScriptDriver(scripts)
        let owner = scene.createEntity()
        _ = scene.setComponent(ScriptComponent(handle), for: owner)
        _ = scene.tick()
        #expect(scene.snapshot.entityCount == 1)
    }
}
