import SceneRuntime
import EngineKernel
import Testing
import SIMDCompat

@Suite("SpatialQueries")
struct SpatialQueryTests {
    @Test("spatialIndexUpdate builds world-space bounds for colliders")
    func spatialIndexUpdateBuildsWorldSpaceBounds() {
        var runtime = SceneRuntime()

        let parent = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform(translation: SIMD3<Float>(2, 0, 0)), for: parent)

        let childBox = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform(translation: SIMD3<Float>(1, 0, 0)), for: childBox)
        _ = runtime.setParent(parent, for: childBox)
        _ = runtime.setComponent(
            Collider(shape: .box(halfExtents: SIMD3<Float>(0.5, 0.5, 0.5), center: .zero)),
            for: childBox
        )

        _ = runtime.tick()

        let entry = runtime.spatialIndex.entries.first { $0.entity == childBox }
        #expect(entry?.bounds.center == SIMD3<Float>(3, 0, 0))
        #expect(entry?.bounds.halfExtents == SIMD3<Float>(0.5, 0.5, 0.5))
    }

    @Test("mesh colliders use registered local mesh bounds")
    func meshCollidersUseRegisteredLocalMeshBounds() {
        var runtime = SceneRuntime()
        runtime.setResource(MeshColliderBoundsResource(
            boundsByResourceID: [
                "wide-mesh": SpatialAABB(min: SIMD3<Float>(-2, -1, -0.25),
                                         max: SIMD3<Float>(2, 1, 0.25)),
            ]
        ))

        let entity = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform(translation: SIMD3<Float>(10, 0, 0)), for: entity)
        _ = runtime.setComponent(
            Collider(shape: .mesh(resourceID: "wide-mesh", center: SIMD3<Float>(1, 0, 0))),
            for: entity
        )

        _ = runtime.tick()

        let entry = runtime.spatialIndex.entries.first { $0.entity == entity }
        #expect(entry?.bounds.center == SIMD3<Float>(11, 0, 0))
        #expect(entry?.bounds.halfExtents == SIMD3<Float>(2, 1, 0.25))

        let hit = runtime.physicsRaycast(
            PhysicsRaycastQuery(origin: SIMD3<Float>(6, 0, 0),
                                direction: SIMD3<Float>(1, 0, 0),
                                maxDistance: 10)
        )
        #expect(hit?.entity == entity)
        #expect(abs((hit?.distance ?? 0) - 3) < 0.000_1)
    }

    @Test("spatialIndexUpdate reports job-backed incremental cache diffs")
    func spatialIndexUpdateReportsJobBackedIncrementalCacheDiffs() {
        var runtime = SceneRuntime()
        runtime.setJobSystem(JobSystem(workerCount: 4, minimumChunkSize: 1, label: "test.jobs.spatial.update"))

        var entities: [EntityID] = []
        for index in 0..<4 {
            let entity = runtime.createEntity()
            _ = runtime.setLocalTransform(LocalTransform(translation: SIMD3<Float>(Float(index), 0, 0)), for: entity)
            _ = runtime.setComponent(
                Collider(shape: .box(halfExtents: SIMD3<Float>(0.5, 0.5, 0.5), center: .zero)),
                for: entity
            )
            entities.append(entity)
        }

        _ = runtime.tick()
        _ = runtime.setComponent(
            Collider(shape: .box(halfExtents: SIMD3<Float>(1, 0.5, 0.5), center: .zero)),
            for: entities[0]
        )

        let report = runtime.tick()

        #expect(report.parallelPhases.contains(.spatialIndexUpdate))
        #expect(report.jobCount(for: .spatialIndexUpdate) >= 8)
        #expect(runtime.spatialIndex.entries.count == entities.count)
        #expect(runtime.spatialIndex.entries.first { $0.entity == entities[0] }?.bounds.halfExtents.x == 1)
    }

    @Test("raycast returns the nearest collider hit from the spatial cache")
    func raycastReturnsNearestColliderHit() {
        var runtime = SceneRuntime()

        let sphere = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform(translation: SIMD3<Float>(1, 0, 0)), for: sphere)
        _ = runtime.setComponent(Collider(shape: .sphere(radius: 1, center: .zero)), for: sphere)

        let box = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform(translation: SIMD3<Float>(4, 0, 0)), for: box)
        _ = runtime.setComponent(
            Collider(shape: .box(halfExtents: SIMD3<Float>(0.5, 0.5, 0.5), center: .zero)),
            for: box
        )

        _ = runtime.tick()

        let hit = runtime.raycast(
            SceneRaycastQuery(
                origin: SIMD3<Float>(-5, 0, 0),
                direction: SIMD3<Float>(1, 0, 0),
                maxDistance: 20
            )
        )

        #expect(hit?.entity == sphere)
        #expect(hit?.distance == 5)
        #expect(hit?.position == SIMD3<Float>(0, 0, 0))
        #expect(hit?.normal == SIMD3<Float>(-1, 0, 0))
    }

    @Test("raycast uses a precise sphere narrow phase instead of the broad-phase AABB")
    func raycastUsesPreciseSphereNarrowPhase() {
        var runtime = SceneRuntime()

        let sphere = runtime.createEntity()
        _ = runtime.setComponent(Collider(shape: .sphere(radius: 1, center: .zero)), for: sphere)

        _ = runtime.tick()

        let hit = runtime.raycast(
            SceneRaycastQuery(
                origin: SIMD3<Float>(-5, 0.5, 0),
                direction: SIMD3<Float>(1, 0, 0),
                maxDistance: 20
            )
        )

        #expect(hit?.entity == sphere)
        #expect(abs((hit?.distance ?? 0) - 4.133_974_6) < 0.000_1)
        #expect(abs((hit?.position.x ?? 0) + 0.866_025_4) < 0.000_1)
        #expect(abs((hit?.normal.x ?? 0) + 0.866_025_4) < 0.000_1)
        #expect(abs((hit?.normal.y ?? 0) - 0.5) < 0.000_1)
    }

    @Test("raycast uses a precise rotated box narrow phase instead of the broad-phase AABB")
    func raycastUsesPreciseRotatedBoxNarrowPhase() {
        var runtime = SceneRuntime()

        let box = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform(matrix: rotatedBoxMatrix(angleRadians: .pi / 4)), for: box)
        _ = runtime.setComponent(
            Collider(shape: .box(halfExtents: SIMD3<Float>(1, 0.2, 0.5), center: .zero)),
            for: box
        )

        _ = runtime.tick()

        let hit = runtime.raycast(
            SceneRaycastQuery(
                origin: SIMD3<Float>(0, 5, 0),
                direction: SIMD3<Float>(0, -1, 0),
                maxDistance: 20
            )
        )

        #expect(hit?.entity == box)
        #expect(abs((hit?.distance ?? 0) - 4.717_157_4) < 0.000_2)
        #expect(abs((hit?.position.y ?? 0) - 0.282_842_7) < 0.000_2)
        #expect(abs((hit?.normal.x ?? 0) + 0.707_106_77) < 0.000_2)
        #expect(abs((hit?.normal.y ?? 0) - 0.707_106_77) < 0.000_2)
    }

    @Test("raycast uses a precise capsule narrow phase instead of the broad-phase AABB")
    func raycastUsesPreciseCapsuleNarrowPhase() {
        var runtime = SceneRuntime()

        let capsule = runtime.createEntity()
        _ = runtime.setComponent(
            Collider(shape: .capsule(radius: 0.5, halfHeight: 1, center: .zero)),
            for: capsule
        )

        _ = runtime.tick()

        let hit = runtime.raycast(
            SceneRaycastQuery(
                origin: SIMD3<Float>(-5, 1.3, 0),
                direction: SIMD3<Float>(1, 0, 0),
                maxDistance: 20
            )
        )

        #expect(hit?.entity == capsule)
        #expect(abs((hit?.distance ?? 0) - 4.6) < 0.000_1)
        #expect(abs((hit?.position.x ?? 0) + 0.4) < 0.000_1)
        #expect(abs((hit?.normal.x ?? 0) + 0.8) < 0.000_1)
        #expect(abs((hit?.normal.y ?? 0) - 0.6) < 0.000_1)
    }

    @Test("overlap uses a precise sphere narrow phase instead of the broad-phase AABB")
    func overlapUsesPreciseSphereNarrowPhase() {
        var runtime = SceneRuntime()

        let sphere = runtime.createEntity()
        _ = runtime.setComponent(Collider(shape: .sphere(radius: 1, center: .zero)), for: sphere)

        _ = runtime.tick()

        let hits = runtime.overlap(
            SceneOverlapQuery(
                bounds: SpatialAABB(center: SIMD3<Float>(0.95, 0.95, 0), halfExtents: SIMD3<Float>(0.05, 0.05, 0.05))
            )
        )

        #expect(hits.isEmpty)
    }

    @Test("overlap uses a precise rotated box narrow phase instead of the broad-phase AABB")
    func overlapUsesPreciseRotatedBoxNarrowPhase() {
        var runtime = SceneRuntime()

        let box = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform(matrix: rotatedBoxMatrix(angleRadians: .pi / 4)), for: box)
        _ = runtime.setComponent(
            Collider(shape: .box(halfExtents: SIMD3<Float>(1, 0.2, 0.5), center: .zero)),
            for: box
        )

        _ = runtime.tick()

        let hits = runtime.overlap(
            SceneOverlapQuery(
                bounds: SpatialAABB(center: SIMD3<Float>(0.83, 0.83, 0), halfExtents: SIMD3<Float>(0.02, 0.02, 0.02))
            )
        )

        #expect(hits.isEmpty)
    }

    @Test("overlap uses a precise capsule narrow phase instead of the broad-phase AABB")
    func overlapUsesPreciseCapsuleNarrowPhase() {
        var runtime = SceneRuntime()

        let capsule = runtime.createEntity()
        _ = runtime.setComponent(
            Collider(shape: .capsule(radius: 0.5, halfHeight: 1, center: .zero)),
            for: capsule
        )

        _ = runtime.tick()

        let hits = runtime.overlap(
            SceneOverlapQuery(
                bounds: SpatialAABB(center: SIMD3<Float>(0.45, 1.45, 0), halfExtents: SIMD3<Float>(0.05, 0.05, 0.05))
            )
        )

        #expect(hits.isEmpty)
    }

    @Test("overlap returns every intersecting collider in stable order")
    func overlapReturnsIntersectingColliders() {
        var runtime = SceneRuntime()

        let sphere = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform(translation: SIMD3<Float>(1, 0, 0)), for: sphere)
        _ = runtime.setComponent(Collider(shape: .sphere(radius: 1, center: .zero)), for: sphere)

        let box = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform(translation: SIMD3<Float>(4, 0, 0)), for: box)
        _ = runtime.setComponent(
            Collider(shape: .box(halfExtents: SIMD3<Float>(0.5, 0.5, 0.5), center: .zero)),
            for: box
        )

        let trigger = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform(translation: SIMD3<Float>(2, 0, 0)), for: trigger)
        _ = runtime.setComponent(
            Collider(
                shape: .box(halfExtents: SIMD3<Float>(0.25, 0.25, 0.25), center: .zero),
                isTrigger: true
            ),
            for: trigger
        )

        _ = runtime.tick()

        let hits = runtime.overlap(
            SceneOverlapQuery(
                bounds: SpatialAABB(center: SIMD3<Float>(2.2, 0, 0), halfExtents: SIMD3<Float>(2, 1, 1))
            )
        )

        #expect(hits.map(\ .entity) == [sphere, box])

        let hitsIncludingTriggers = runtime.overlap(
            SceneOverlapQuery(
                bounds: SpatialAABB(center: SIMD3<Float>(2.2, 0, 0), halfExtents: SIMD3<Float>(2, 1, 1)),
                includeTriggers: true
            )
        )

        #expect(hitsIncludingTriggers.map(\ .entity) == [sphere, box, trigger].sorted { $0.rawValue < $1.rawValue })
    }

    @Test("sweep returns the nearest collider hit from the spatial cache")
    func sweepReturnsNearestColliderHit() {
        var runtime = SceneRuntime()

        let nearBox = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform(translation: SIMD3<Float>(3, 0, 0)), for: nearBox)
        _ = runtime.setComponent(
            Collider(shape: .box(halfExtents: SIMD3<Float>(0.5, 0.5, 0.5), center: .zero)),
            for: nearBox
        )

        let farBox = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform(translation: SIMD3<Float>(6, 0, 0)), for: farBox)
        _ = runtime.setComponent(
            Collider(shape: .box(halfExtents: SIMD3<Float>(0.5, 0.5, 0.5), center: .zero)),
            for: farBox
        )

        _ = runtime.tick()

        let hit = runtime.sweep(
            SceneSweepQuery(
                bounds: SpatialAABB(center: .zero, halfExtents: SIMD3<Float>(0.5, 0.5, 0.5)),
                translation: SIMD3<Float>(10, 0, 0)
            )
        )

        #expect(hit?.entity == nearBox)
        #expect(abs((hit?.fraction ?? 0) - 0.2) < 0.000_1)
        #expect(abs((hit?.distance ?? 0) - 2) < 0.000_1)
        #expect(hit?.position == SIMD3<Float>(2, 0, 0))
        #expect(hit?.normal == SIMD3<Float>(-1, 0, 0))
    }

    @Test("sweep skips triggers unless the query includes them")
    func sweepSkipsTriggersUnlessIncluded() {
        var runtime = SceneRuntime()

        let trigger = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform(translation: SIMD3<Float>(2, 0, 0)), for: trigger)
        _ = runtime.setComponent(
            Collider(
                shape: .box(halfExtents: SIMD3<Float>(0.5, 0.5, 0.5), center: .zero),
                isTrigger: true
            ),
            for: trigger
        )

        let solid = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform(translation: SIMD3<Float>(4, 0, 0)), for: solid)
        _ = runtime.setComponent(
            Collider(shape: .box(halfExtents: SIMD3<Float>(0.5, 0.5, 0.5), center: .zero)),
            for: solid
        )

        _ = runtime.tick()

        let defaultHit = runtime.sweep(
            SceneSweepQuery(
                bounds: SpatialAABB(center: .zero, halfExtents: SIMD3<Float>(0.5, 0.5, 0.5)),
                translation: SIMD3<Float>(10, 0, 0)
            )
        )
        let triggerHit = runtime.sweep(
            SceneSweepQuery(
                bounds: SpatialAABB(center: .zero, halfExtents: SIMD3<Float>(0.5, 0.5, 0.5)),
                translation: SIMD3<Float>(10, 0, 0),
                includeTriggers: true
            )
        )

        #expect(defaultHit?.entity == solid)
        #expect(triggerHit?.entity == trigger)
        #expect(triggerHit?.isTrigger == true)
    }

    @Test("sweep uses a precise sphere narrow phase instead of the broad-phase AABB")
    func sweepUsesPreciseSphereNarrowPhase() {
        var runtime = SceneRuntime()

        let sphere = runtime.createEntity()
        _ = runtime.setComponent(Collider(shape: .sphere(radius: 1, center: .zero)), for: sphere)

        _ = runtime.tick()

        let hit = runtime.sweep(
            SceneSweepQuery(
                bounds: SpatialAABB(center: SIMD3<Float>(-5, 1, 1), halfExtents: SIMD3<Float>(0.05, 0.05, 0.05)),
                translation: SIMD3<Float>(10, 0, 0)
            )
        )

        #expect(hit == nil)
    }

    @Test("physics queries apply excludeEntity and layer filters")
    func physicsQueriesApplyUnifiedFilters() {
        var runtime = SceneRuntime()

        let excluded = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform(translation: SIMD3<Float>(1, 0, 0)), for: excluded)
        _ = runtime.setComponent(
            Collider(shape: .box(halfExtents: SIMD3<Float>(0.5, 0.5, 0.5), center: .zero),
                     layerID: 1,
                     layerMask: 0b0010),
            for: excluded
        )

        let wrongLayerID = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform(translation: SIMD3<Float>(3, 0, 0)), for: wrongLayerID)
        _ = runtime.setComponent(
            Collider(shape: .box(halfExtents: SIMD3<Float>(0.5, 0.5, 0.5), center: .zero),
                     layerID: 2,
                     layerMask: 0b0010),
            for: wrongLayerID
        )

        let wrongLayerMask = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform(translation: SIMD3<Float>(5, 0, 0)), for: wrongLayerMask)
        _ = runtime.setComponent(
            Collider(shape: .box(halfExtents: SIMD3<Float>(0.5, 0.5, 0.5), center: .zero),
                     layerID: 1,
                     layerMask: 0b0100),
            for: wrongLayerMask
        )

        let filteredHit = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform(translation: SIMD3<Float>(7, 0, 0)), for: filteredHit)
        _ = runtime.setComponent(
            Collider(shape: .box(halfExtents: SIMD3<Float>(0.5, 0.5, 0.5), center: .zero),
                     layerID: 1,
                     layerMask: 0b0010),
            for: filteredHit
        )

        _ = runtime.tick()

        let filter = PhysicsQueryFilter(
            excludeEntity: excluded,
            layerID: 1,
            layerMask: 0b0010
        )

        let raycastHit = runtime.physicsRaycast(
            PhysicsRaycastQuery(
                origin: SIMD3<Float>(-5, 0, 0),
                direction: SIMD3<Float>(1, 0, 0),
                maxDistance: 20
            ),
            filter: filter
        )
        let overlapHits = runtime.physicsOverlapAABB(
            PhysicsOverlapAABBQuery(
                bounds: SpatialAABB(center: SIMD3<Float>(4, 0, 0), halfExtents: SIMD3<Float>(4, 1, 1))
            ),
            filter: filter
        )
        let sweepHit = runtime.physicsSweepAABB(
            PhysicsSweepAABBQuery(
                bounds: SpatialAABB(center: .zero, halfExtents: SIMD3<Float>(0.5, 0.5, 0.5)),
                translation: SIMD3<Float>(10, 0, 0)
            ),
            filter: filter
        )

        #expect(raycastHit?.entity == filteredHit)
        #expect(overlapHits.map(\ .entity) == [filteredHit])
        #expect(sweepHit?.entity == filteredHit)
    }

    @Test("physics sweep reports the shape contact normal instead of the broad-phase axis")
    func physicsSweepReportsPreciseContactNormal() {
        var runtime = SceneRuntime()

        let sphere = runtime.createEntity()
        _ = runtime.setComponent(Collider(shape: .sphere(radius: 1, center: .zero)), for: sphere)

        _ = runtime.tick()

        let hit = runtime.physicsSweepAABB(
            PhysicsSweepAABBQuery(
                bounds: SpatialAABB(center: SIMD3<Float>(-5, 0.5, 0), halfExtents: SIMD3<Float>(0.05, 0.05, 0.05)),
                translation: SIMD3<Float>(10, 0, 0)
            )
        )
        let expectedDistance: Float = 4.056_971_5
        let expectedNormal = SIMD3<Float>(-0.893_028_56, 0.45, 0)

        #expect(hit?.entity == sphere)
        #expect(abs((hit?.distance ?? 0) - expectedDistance) < 0.001)
        #expect(abs((hit?.normal.x ?? 0) - expectedNormal.x) < 0.01)
        #expect(abs((hit?.normal.y ?? 0) - expectedNormal.y) < 0.01)
    }
}

private func rotatedBoxMatrix(angleRadians: Float) -> simd_float4x4 {
    let cosine = cos(angleRadians)
    let sine = sin(angleRadians)
    return simd_float4x4(rows: [
        SIMD4<Float>(cosine, -sine, 0, 0),
        SIMD4<Float>(sine, cosine, 0, 0),
        SIMD4<Float>(0, 0, 1, 0),
        SIMD4<Float>(0, 0, 0, 1),
    ])
}
