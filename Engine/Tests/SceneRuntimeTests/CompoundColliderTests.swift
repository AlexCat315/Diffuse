import SceneRuntime
import SIMDCompat
import Testing

@Suite("CompoundCollider")
struct CompoundColliderTests {
    private let compound = Collider(
        shapes: [
            ColliderShapeInstance(
                shape: .box(halfExtents: SIMD3<Float>(0.5, 0.5, 0.5), center: .zero),
                localPosition: SIMD3<Float>(-2, 0, 0)
            ),
            ColliderShapeInstance(
                shape: .cylinder(radius: 0.5, halfHeight: 0.75, center: .zero),
                localPosition: SIMD3<Float>(2, 0, 0),
                localRotation: SIMD4<Float>(0, 0, 0, 1),
                localScale: SIMD3<Float>(1, 1.5, 1)
            ),
        ],
        layerID: 2,
        layerMask: 0x00FF,
        material: PhysicsMaterial(friction: 0.4, restitution: 0.2, density: 3)
    )

    @Test("Jolt queries every child in a compound collider")
    func nativeCompoundShape() {
        var runtime = SceneRuntime()
        let entity = runtime.createEntity()
        _ = runtime.setLocalTransform(.identity, for: entity)
        _ = runtime.setComponent(compound, for: entity)

        let left = runtime.physicsRaycast(
            PhysicsRaycastQuery(origin: SIMD3<Float>(-2, 0, -4), direction: SIMD3<Float>(0, 0, 1), maxDistance: 8)
        )
        let right = runtime.physicsRaycast(
            PhysicsRaycastQuery(origin: SIMD3<Float>(2, 0, -4), direction: SIMD3<Float>(0, 0, 1), maxDistance: 8)
        )
        let gap = runtime.physicsRaycast(
            PhysicsRaycastQuery(origin: SIMD3<Float>(0, 0, -4), direction: SIMD3<Float>(0, 0, 1), maxDistance: 8)
        )

        #expect(left?.entity == entity)
        #expect(right?.entity == entity)
        #expect(gap == nil)
    }

    @Test("Scene v2 preserves compound local transforms")
    func serializationRoundTrip() throws {
        var runtime = SceneRuntime()
        let entity = runtime.createEntity()
        _ = runtime.setLocalTransform(.identity, for: entity)
        _ = runtime.setComponent(compound, for: entity)

        let data = try SceneSerializer.serialize(runtime)
        var restored = SceneRuntime()
        try SceneSerializer.deserialize(data, into: &restored)
        let restoredEntity = try #require(restored.entities().first)
        #expect(restored.component(Collider.self, for: restoredEntity) == compound)
    }

    @Test("empty compounds report an explicit native error")
    func emptyCompoundFails() {
        var runtime = SceneRuntime()
        runtime.setPhysicsSettings(PhysicsSettingsResource(simulationMode: .play, backendKind: .jolt))
        let entity = runtime.createEntity()
        _ = runtime.setLocalTransform(.identity, for: entity)
        _ = runtime.setComponent(Collider(shapes: []), for: entity)
        let report = runtime.tick(deltaTime: 1.0 / 60.0)
        #expect(report.physicsError?.code == .invalidShape)
    }

    @Test("unified queries return stable all-hit ordering")
    func unifiedAllHits() {
        var runtime = SceneRuntime()
        var expected: [EntityID] = []
        for z: Float in [1, 4, 7] {
            let entity = runtime.createEntity()
            expected.append(entity)
            _ = runtime.setLocalTransform(LocalTransform(translation: SIMD3<Float>(0, 0, z)), for: entity)
            _ = runtime.setComponent(
                Collider(shape: .box(halfExtents: SIMD3<Float>(0.5, 0.5, 0.5), center: .zero)),
                for: entity
            )
        }

        let hits = runtime.raycast(
            PhysicsRaycastQuery(origin: SIMD3<Float>(0, 0, -2), direction: SIMD3<Float>(0, 0, 1), maxDistance: 12),
            options: PhysicsQueryOptions(resultMode: .all)
        )
        #expect(hits.map(\.entity) == expected)
        #expect(hits.map(\.distance) == hits.map(\.distance).sorted())

        let castHits = runtime.shapeCast(
            PhysicsSweepShapeQuery(
                shape: .sphere(radius: 0.25),
                position: SIMD3<Float>(0, 0, -2),
                translation: SIMD3<Float>(0, 0, 12)
            ),
            options: PhysicsQueryOptions(resultMode: .all)
        )
        #expect(castHits.map(\.entity) == expected)
    }
}
