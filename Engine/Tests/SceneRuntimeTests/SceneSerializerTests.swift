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
}

private func translationMatrix(_ t: SIMD3<Float>) -> simd_float4x4 {
    simd_float4x4(rows: [
        SIMD4<Float>(1, 0, 0, t.x),
        SIMD4<Float>(0, 1, 0, t.y),
        SIMD4<Float>(0, 0, 1, t.z),
        SIMD4<Float>(0, 0, 0, 1),
    ])
}
