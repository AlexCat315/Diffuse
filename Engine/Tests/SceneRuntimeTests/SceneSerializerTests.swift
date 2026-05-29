import SceneRuntime
import ScriptRuntime
import Testing
import Foundation
import SIMDCompat

@Suite("SceneSerializer")
struct SceneSerializerTests {

    // MARK: - Empty scene

    @Test("round-trip: empty scene")
    func emptySceneRoundTrip() throws {
        let original = SceneRuntime()
        let data = try SceneSerializer.serialize(original)
        #expect(!data.isEmpty)

        var restored = SceneRuntime()
        try SceneSerializer.deserialize(data, into: &restored)
        #expect(restored.snapshot.entityCount == 0)
    }

    // MARK: - Single entity with transform

    @Test("round-trip: entity with name and transform")
    func entityWithNameAndTransform() throws {
        var original = SceneRuntime()
        let entity = original.createEntity()
        _ = original.setComponent(SceneNameComponent(value: "TestEntity"), for: entity)
        _ = original.setLocalTransform(
            LocalTransform(matrix: translationMatrix(SIMD3<Float>(3, 5, 7))),
            for: entity
        )

        let data = try SceneSerializer.serialize(original)
        var restored = SceneRuntime()
        try SceneSerializer.deserialize(data, into: &restored)

        #expect(restored.snapshot.entityCount == 1)
        let entities = restored.entities()
        #expect(entities.count == 1)
        let name = restored.component(SceneNameComponent.self, for: entities[0])
        #expect(name?.value == "TestEntity")
        let t = restored.localTransform(for: entities[0])
        #expect(t != nil)
        #expect(abs(t!.translation.x - 3) < 0.01)
        #expect(abs(t!.translation.y - 5) < 0.01)
        #expect(abs(t!.translation.z - 7) < 0.01)
    }

    // MARK: - Hierarchy

    @Test("round-trip: parent-child hierarchy")
    func parentChildHierarchy() throws {
        var original = SceneRuntime()
        let parent = original.createEntity()
        _ = original.setComponent(SceneNameComponent(value: "Parent"), for: parent)
        _ = original.setLocalTransform(LocalTransform(translation: .zero), for: parent)

        let child = original.createEntity()
        _ = original.setComponent(SceneNameComponent(value: "Child"), for: child)
        _ = original.setLocalTransform(LocalTransform(translation: SIMD3<Float>(1, 0, 0)), for: child)
        _ = original.setParent(parent, for: child)

        let data = try SceneSerializer.serialize(original)
        var restored = SceneRuntime()
        try SceneSerializer.deserialize(data, into: &restored)
        _ = restored.tick()

        let entities = restored.entities()
        #expect(entities.count == 2)

        let restoredParent = restored.findEntity(named: "Parent")
        #expect(restoredParent != nil)
        let restoredChild = restored.findEntity(named: "Child")
        #expect(restoredChild != nil)

        let childParent = restored.parent(of: restoredChild!)
        #expect(childParent == restoredParent)
    }

    // MARK: - RigidBody

    @Test("round-trip: rigidbody preserves properties")
    func rigidBodyRoundTrip() throws {
        var original = SceneRuntime()
        let entity = original.createEntity()
        _ = original.setLocalTransform(LocalTransform(translation: .zero), for: entity)
        _ = original.setComponent(
            RigidBody(motionType: .dynamic, mass: 80, gravityScale: 2, linearDamping: 0.1, allowSleep: false),
            for: entity
        )

        let data = try SceneSerializer.serialize(original)
        var restored = SceneRuntime()
        try SceneSerializer.deserialize(data, into: &restored)

        let entities = restored.entities()
        #expect(entities.count == 1)
        let rb = restored.component(RigidBody.self, for: entities[0])
        #expect(rb != nil)
        #expect(rb!.motionType == .dynamic)
        #expect(rb!.mass == 80)
        #expect(rb!.gravityScale == 2)
        #expect(rb!.linearDamping == 0.1)
        #expect(rb!.allowSleep == false)
    }

    // MARK: - Collider shapes

    @Test("round-trip: box collider")
    func boxColliderRoundTrip() throws {
        var original = SceneRuntime()
        let entity = original.createEntity()
        _ = original.setLocalTransform(LocalTransform(translation: .zero), for: entity)
        _ = original.setComponent(
            Collider(shape: .box(halfExtents: SIMD3<Float>(1, 2, 3), center: SIMD3<Float>(0, 0.5, 0)),
                     isTrigger: true, layerID: 3, layerMask: 0x00FF),
            for: entity
        )

        let data = try SceneSerializer.serialize(original)
        var restored = SceneRuntime()
        try SceneSerializer.deserialize(data, into: &restored)

        let entities = restored.entities()
        let col = restored.component(Collider.self, for: entities[0])
        #expect(col != nil)
        #expect(col!.isTrigger == true)
        #expect(col!.layerID == 3)
        #expect(col!.layerMask == 0x00FF)

        if case let .box(he, center) = col!.shape {
            #expect(he == SIMD3<Float>(1, 2, 3))
            #expect(center == SIMD3<Float>(0, 0.5, 0))
        } else {
            #expect(Bool(false), "expected box shape")
        }
    }

    @Test("round-trip: sphere collider")
    func sphereColliderRoundTrip() throws {
        var original = SceneRuntime()
        let entity = original.createEntity()
        _ = original.setLocalTransform(LocalTransform(translation: .zero), for: entity)
        _ = original.setComponent(
            Collider(shape: .sphere(radius: 2.5, center: SIMD3<Float>(0, 1, 0))),
            for: entity
        )

        let data = try SceneSerializer.serialize(original)
        var restored = SceneRuntime()
        try SceneSerializer.deserialize(data, into: &restored)

        let entities = restored.entities()
        let col = restored.component(Collider.self, for: entities[0])
        #expect(col != nil)
        if case let .sphere(r, c) = col!.shape {
            #expect(r == 2.5)
            #expect(c == SIMD3<Float>(0, 1, 0))
        } else {
            #expect(Bool(false), "expected sphere shape")
        }
    }

    // MARK: - Camera

    @Test("round-trip: camera component")
    func cameraRoundTrip() throws {
        var original = SceneRuntime()
        let entity = original.createEntity()
        _ = original.setLocalTransform(LocalTransform(translation: .zero), for: entity)
        _ = original.setComponent(
            CameraComponent(target: SIMD3<Float>(0, 1, 0), fovYRadians: 1.2, near: 0.05, far: 500, isActive: true),
            for: entity
        )

        let data = try SceneSerializer.serialize(original)
        var restored = SceneRuntime()
        try SceneSerializer.deserialize(data, into: &restored)

        let entities = restored.entities()
        let cam = restored.component(CameraComponent.self, for: entities[0])
        #expect(cam != nil)
        #expect(cam!.isActive)
        #expect(cam!.fovYRadians == 1.2)
        #expect(cam!.near == 0.05)
        #expect(cam!.far == 500)
    }

    // MARK: - Light

    @Test("round-trip: light component")
    func lightRoundTrip() throws {
        var original = SceneRuntime()
        let entity = original.createEntity()
        _ = original.setLocalTransform(LocalTransform(translation: .zero), for: entity)
        _ = original.setComponent(
            LightComponent(type: .spot, color: SIMD3<Float>(1, 0.5, 0.2), intensity: 5, range: 25,
                          spotInnerAngleDegrees: 15, spotOuterAngleDegrees: 40, castShadows: true),
            for: entity
        )

        let data = try SceneSerializer.serialize(original)
        var restored = SceneRuntime()
        try SceneSerializer.deserialize(data, into: &restored)

        let entities = restored.entities()
        let light = restored.component(LightComponent.self, for: entities[0])
        #expect(light != nil)
        #expect(light!.type == .spot)
        #expect(light!.intensity == 5)
        #expect(light!.range == 25)
        #expect(light!.castShadows)
    }

    // MARK: - Audio

    @Test("round-trip: audio source and listener")
    func audioRoundTrip() throws {
        var original = SceneRuntime()
        let entity = original.createEntity()
        _ = original.setLocalTransform(LocalTransform(translation: .zero), for: entity)
        _ = original.setComponent(
            AudioSource(clipName: "footstep", volume: 0.8, pitch: 1.2, loop: true, spatialBlend: 0.5),
            for: entity
        )
        _ = original.setComponent(AudioListener(masterVolume: 0.9), for: entity)

        let data = try SceneSerializer.serialize(original)
        var restored = SceneRuntime()
        try SceneSerializer.deserialize(data, into: &restored)

        let entities = restored.entities()
        let src = restored.component(AudioSource.self, for: entities[0])
        #expect(src != nil)
        #expect(src!.clipName == "footstep")
        #expect(src!.volume == 0.8)
        #expect(src!.loop)

        let listener = restored.component(AudioListener.self, for: entities[0])
        #expect(listener != nil)
        #expect(listener!.masterVolume == 0.9)
    }

    // MARK: - Multi-entity

    @Test("round-trip: full scene with multiple entity types")
    func fullSceneRoundTrip() throws {
        var original = SceneRuntime()

        // Ground
        let ground = original.createEntity()
        _ = original.setComponent(SceneNameComponent(value: "Ground"), for: ground)
        _ = original.setComponent(SceneKindComponent(value: "Static Mesh"), for: ground)
        _ = original.setLocalTransform(LocalTransform(translation: SIMD3<Float>(0, -0.5, 0)), for: ground)
        _ = original.setComponent(RenderMeshComponent(meshIndex: 0), for: ground)
        _ = original.setComponent(
            Collider(shape: .box(halfExtents: SIMD3<Float>(10, 0.5, 10), center: .zero)),
            for: ground
        )
        _ = original.setComponent(RigidBody(motionType: .static), for: ground)

        // Player
        let player = original.createEntity()
        _ = original.setComponent(SceneNameComponent(value: "Player"), for: player)
        _ = original.setComponent(SceneKindComponent(value: "Character"), for: player)
        _ = original.setLocalTransform(LocalTransform(translation: SIMD3<Float>(0, 1, 0)), for: player)
        _ = original.setComponent(
            Collider(shape: .capsule(radius: 0.5, halfHeight: 1, center: SIMD3<Float>(0, 1, 0))),
            for: player
        )
        _ = original.setComponent(RigidBody(motionType: .dynamic, mass: 80), for: player)

        // Camera
        let camera = original.createEntity()
        _ = original.setComponent(SceneNameComponent(value: "MainCamera"), for: camera)
        _ = original.setComponent(SceneKindComponent(value: "Camera"), for: camera)
        _ = original.setLocalTransform(LocalTransform(translation: SIMD3<Float>(0, 5, 10)), for: camera)
        _ = original.setComponent(CameraComponent(isActive: true), for: camera)
        _ = original.setComponent(AudioListener(), for: camera)

        // Hierarchy
        _ = original.setParent(ground, for: player)

        let data = try SceneSerializer.serialize(original)
        var restored = SceneRuntime()
        try SceneSerializer.deserialize(data, into: &restored)

        #expect(restored.snapshot.entityCount == 3)

        // Verify all entities exist with correct components
        let ground2 = restored.findEntity(named: "Ground")
        #expect(ground2 != nil)
        #expect(restored.component(RigidBody.self, for: ground2!)?.motionType == .static)
        #expect(restored.component(RenderMeshComponent.self, for: ground2!)?.meshIndex == 0)

        let player2 = restored.findEntity(named: "Player")
        #expect(player2 != nil)
        #expect(restored.component(RigidBody.self, for: player2!)?.mass == 80)
        #expect(restored.component(Collider.self, for: player2!) != nil)

        let camera2 = restored.findEntity(named: "MainCamera")
        #expect(camera2 != nil)
        #expect(restored.component(CameraComponent.self, for: camera2!)?.isActive == true)
        #expect(restored.component(AudioListener.self, for: camera2!) != nil)

        // Verify hierarchy
        _ = restored.tick()
        #expect(restored.parent(of: player2!) == ground2)
    }

    // MARK: - Render material

    @Test("round-trip: render material (PBR factors + texture indices)")
    func renderMaterialRoundTrip() throws {
        var original = SceneRuntime()
        let entity = original.createEntity()
        _ = original.setComponent(
            RenderMaterialComponent(baseColorFactor: SIMD4<Float>(0.2, 0.4, 0.6, 1),
                                    baseColorTextureIndex: 7,
                                    normalTextureIndex: 9,
                                    metallicFactor: 0.8,
                                    roughnessFactor: 0.3,
                                    emissiveFactor: SIMD3<Float>(1, 0, 0)),
            for: entity
        )

        let data = try SceneSerializer.serialize(original)
        var restored = SceneRuntime()
        try SceneSerializer.deserialize(data, into: &restored)

        let m = restored.component(RenderMaterialComponent.self, for: restored.entities()[0])
        #expect(m != nil)
        #expect(m!.baseColorFactor == SIMD4<Float>(0.2, 0.4, 0.6, 1))
        #expect(m!.baseColorTextureIndex == 7)
        #expect(m!.normalTextureIndex == 9)
        #expect(m!.metallicFactor == 0.8)
        #expect(m!.roughnessFactor == 0.3)
        #expect(m!.emissiveFactor == SIMD3<Float>(1, 0, 0))
    }

    // MARK: - Asset reference

    @Test("round-trip: asset reference")
    func assetReferenceRoundTrip() throws {
        var original = SceneRuntime()
        let entity = original.createEntity()
        _ = original.setComponent(
            AssetReferenceComponent(assetID: "a1", name: "Barrel", relativePath: "models/barrel.glb",
                                    absolutePath: "/proj/models/barrel.glb", kind: "mesh", meshIndex: 4),
            for: entity
        )

        let data = try SceneSerializer.serialize(original)
        var restored = SceneRuntime()
        try SceneSerializer.deserialize(data, into: &restored)

        let a = restored.component(AssetReferenceComponent.self, for: restored.entities()[0])
        #expect(a == AssetReferenceComponent(assetID: "a1", name: "Barrel", relativePath: "models/barrel.glb",
                                             absolutePath: "/proj/models/barrel.glb", kind: "mesh", meshIndex: 4))
    }

    // MARK: - Particle emitter config

    @Test("round-trip: particle emitter configuration")
    func particleEmitterRoundTrip() throws {
        var original = SceneRuntime()
        let entity = original.createEntity()
        _ = original.setComponent(
            ParticleEmitter(emissionRate: 33, maxParticles: 128, lifetime: 1.5,
                            spawnRadius: 0.25, startVelocity: SIMD3<Float>(0, 3, 0),
                            gravity: SIMD3<Float>(0, -2, 0), startSize: 0.5, endSize: 0.1,
                            seed: 12345),
            for: entity
        )

        let data = try SceneSerializer.serialize(original)
        var restored = SceneRuntime()
        try SceneSerializer.deserialize(data, into: &restored)

        let e = restored.component(ParticleEmitter.self, for: restored.entities()[0])
        #expect(e != nil)
        #expect(e!.emissionRate == 33)
        #expect(e!.maxParticles == 128)
        #expect(e!.lifetime == 1.5)
        #expect(e!.spawnRadius == 0.25)
        #expect(e!.startVelocity == SIMD3<Float>(0, 3, 0))
        #expect(e!.seed == 12345)
        // Deterministic config restored: same seed + same advance ⇒ same particles.
        var a = e!; var b = original.component(ParticleEmitter.self, for: original.entities()[0])!
        a.emit(5); b.emit(5)
        a.advance(deltaTime: 0.1); b.advance(deltaTime: 0.1)
        #expect(a.particles == b.particles)
    }

    // MARK: - Constraint

    @Test("round-trip: constraint reconnects to remapped entities")
    func constraintRoundTrip() throws {
        var original = SceneRuntime()
        let bodyA = original.createEntity()
        _ = original.setComponent(SceneNameComponent(value: "A"), for: bodyA)
        let bodyB = original.createEntity()
        _ = original.setComponent(SceneNameComponent(value: "B"), for: bodyB)
        _ = original.setComponent(
            Constraint(constraintType: .hinge, entityA: bodyA, entityB: bodyB,
                       pivotA: SIMD3<Float>(1, 0, 0), pivotB: SIMD3<Float>(-1, 0, 0),
                       axisA: SIMD3<Float>(0, 0, 1), axisB: SIMD3<Float>(0, 0, 1),
                       minLimit: -1.2, maxLimit: 1.2),
            for: bodyA
        )

        let data = try SceneSerializer.serialize(original)
        var restored = SceneRuntime()
        try SceneSerializer.deserialize(data, into: &restored)

        let a2 = restored.findEntity(named: "A")
        let b2 = restored.findEntity(named: "B")
        #expect(a2 != nil && b2 != nil)
        let c = restored.component(Constraint.self, for: a2!)
        #expect(c != nil)
        #expect(c!.constraintType == .hinge)
        #expect(c!.entityA == a2!)   // remapped to the restored entities, not the originals
        #expect(c!.entityB == b2!)
        #expect(c!.pivotA == SIMD3<Float>(1, 0, 0))
        #expect(c!.minLimit == -1.2)
        #expect(c!.maxLimit == 1.2)
    }

    @Test("prefab capture drops a constraint whose endpoint is outside the subtree")
    func prefabDropsDanglingConstraint() throws {
        var scene = SceneRuntime()
        let root = scene.createEntity()
        _ = scene.setComponent(SceneNameComponent(value: "Root"), for: root)
        let external = scene.createEntity() // not part of the captured subtree
        _ = scene.setComponent(
            Constraint(constraintType: .distance, entityA: root, entityB: external),
            for: root
        )

        let prefab = try #require(try Prefab.capture(from: scene, root: root))
        var target = SceneRuntime()
        let newRoot = try #require(try prefab.instantiate(into: &target))
        // The constraint referenced an entity outside the subtree, so it must not survive.
        #expect(target.component(Constraint.self, for: newRoot) == nil)
    }
}

private func translationMatrix(_ t: SIMD3<Float>) -> simd_float4x4 {
    simd_float4x4(rows: [
        SIMD4<Float>(1, 0, 0, t.x),
        SIMD4<Float>(0, 1, 0, t.y),
        SIMD4<Float>(0, 0, 1, t.z),
        SIMD4<Float>(0, 0, 0, 1),
    ])
}
