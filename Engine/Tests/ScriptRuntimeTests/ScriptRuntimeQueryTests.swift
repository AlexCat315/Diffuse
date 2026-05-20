import SceneRuntime
import ScriptRuntime
import Testing
import SIMDCompat

@Suite("ScriptRuntimeQueries")
struct ScriptRuntimeQueryTests {
    @Test("ScriptRuntime forwards physics raycasts with unified filters")
    func scriptRuntimeForwardsPhysicsRaycasts() {
        var runtime = SceneRuntime()
        let scriptRuntime = ScriptRuntime()

        let excluded = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform(translation: SIMD3<Float>(1, 0, 0)), for: excluded)
        _ = runtime.setComponent(
            Collider(shape: .box(halfExtents: SIMD3<Float>(0.5, 0.5, 0.5), center: .zero),
                     layerID: 1,
                     layerMask: 0b0010),
            for: excluded
        )

        let target = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform(translation: SIMD3<Float>(4, 0, 0)), for: target)
        _ = runtime.setComponent(
            Collider(shape: .box(halfExtents: SIMD3<Float>(0.5, 0.5, 0.5), center: .zero),
                     layerID: 1,
                     layerMask: 0b0010),
            for: target
        )

        _ = runtime.tick()

        let hit = scriptRuntime.physicsRaycast(
            in: runtime,
            query: PhysicsRaycastQuery(
                origin: SIMD3<Float>(-5, 0, 0),
                direction: SIMD3<Float>(1, 0, 0),
                maxDistance: 20
            ),
            filter: PhysicsQueryFilter(
                excludeEntity: excluded,
                layerID: 1,
                layerMask: 0b0010
            )
        )

        #expect(hit?.entity == target)
    }

    @Test("ScriptRuntime forwards physics overlap and sweep AABB queries")
    func scriptRuntimeForwardsOverlapAndSweepQueries() {
        var runtime = SceneRuntime()
        let scriptRuntime = ScriptRuntime()

        let trigger = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform(translation: SIMD3<Float>(2, 0, 0)), for: trigger)
        _ = runtime.setComponent(
            Collider(shape: .box(halfExtents: SIMD3<Float>(0.5, 0.5, 0.5), center: .zero),
                     isTrigger: true,
                     layerID: 1,
                     layerMask: 0b0010),
            for: trigger
        )

        let solid = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform(translation: SIMD3<Float>(4, 0, 0)), for: solid)
        _ = runtime.setComponent(
            Collider(shape: .box(halfExtents: SIMD3<Float>(0.5, 0.5, 0.5), center: .zero),
                     layerID: 1,
                     layerMask: 0b0010),
            for: solid
        )

        _ = runtime.tick()

        let overlapHits = scriptRuntime.physicsOverlapAABB(
            in: runtime,
            query: PhysicsOverlapAABBQuery(
                bounds: SpatialAABB(center: SIMD3<Float>(3, 0, 0), halfExtents: SIMD3<Float>(2, 1, 1))
            ),
            filter: PhysicsQueryFilter(layerID: 1, layerMask: 0b0010)
        )
        let sweepHit = scriptRuntime.physicsSweepAABB(
            in: runtime,
            query: PhysicsSweepAABBQuery(
                bounds: SpatialAABB(center: .zero, halfExtents: SIMD3<Float>(0.5, 0.5, 0.5)),
                translation: SIMD3<Float>(10, 0, 0)
            ),
            filter: PhysicsQueryFilter(
                includeTriggers: true,
                layerID: 1,
                layerMask: 0b0010
            )
        )

        #expect(overlapHits.map(\ .entity) == [solid])
        #expect(sweepHit?.entity == trigger)
        #expect(sweepHit?.isTrigger == true)
    }
}