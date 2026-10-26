import SceneRuntime
import SIMDCompat
import Testing

@Suite("Natsel migration")
struct NatselMigrationTests {
    private func makeScene(_ backend: PhysicsBackendKind = .natsel) -> SceneRuntime {
        var runtime = SceneRuntime()
        runtime.setPhysicsSettings(PhysicsSettingsResource(simulationMode: .play, backendKind: backend,
            gravity: .zero, fixedTimeStepSeconds: 1.0 / 60.0, maxSubstepsPerFrame: 1, allowSleep: false))
        return runtime
    }

    @Test("disabling and re-enabling physics rebuilds queries from the current ECS state")
    func switchesBackendWithoutLosingBodies() {
        var runtime = makeScene()
        let entity = runtime.createEntity()
        _ = runtime.setComponent(Collider(shape: .sphere(radius: 0.5, center: .zero)), for: entity)
        _ = runtime.setComponent(RigidBody(linearVelocity: SIMD3<Float>(6, 0, 0), allowSleep: false), for: entity)
        var previousX: Float = 0
        for backend in [PhysicsBackendKind.natsel, .none, .natsel] {
            var settings = runtime.physicsSettings
            settings.backendKind = backend
            runtime.setPhysicsSettings(settings)
            let report = runtime.tick(deltaTime: 1.0 / 60.0)
            #expect(report.physics.error == nil)
            #expect(report.physics.backendIdentifier == backend.rawValue)
            let x = runtime.worldTransform(for: entity)?.translation.x ?? 0
            if backend == .none {
                #expect(x == previousX)
                continue
            }
            #expect(x > previousX + 0.09)
            previousX = x
            let hit = runtime.physicsRaycast(PhysicsRaycastQuery(origin: SIMD3<Float>(x, 0, -2),
                direction: SIMD3<Float>(0, 0, 1), maxDistance: 4))
            #expect(hit?.entity == entity)
        }
    }

    @Test("editing a moving compound replaces child geometry and preserves motion")
    func editsDynamicCompound() {
        var runtime = makeScene()
        let entity = runtime.createEntity()
        let shape = ColliderShapeInstance(shape: .sphere(radius: 0.25, center: .zero), localPosition: SIMD3<Float>(-2, 0, 0))
        _ = runtime.setComponent(Collider(shapes: [shape]), for: entity)
        _ = runtime.setComponent(RigidBody(linearVelocity: SIMD3<Float>(0, 1, 0), allowSleep: false), for: entity)
        _ = runtime.tick(deltaTime: 1.0 / 60.0)
        _ = runtime.updateComponent(Collider.self, for: entity) { $0.shapes[0].localPosition.x = 2 }
        let report = runtime.tick(deltaTime: 1.0 / 60.0)
        #expect(report.physics.error == nil)
        #expect(report.physics.bodyCount == 1)
        #expect((runtime.worldTransform(for: entity)?.translation.y ?? 0) > 0.03)
        func ray(_ x: Float) -> PhysicsRaycastQuery {
            PhysicsRaycastQuery(origin: SIMD3<Float>(x, 0, -2), direction: SIMD3<Float>(0, 0, 1), maxDistance: 4)
        }
        #expect(runtime.physicsRaycast(ray(-2)) == nil)
        #expect(runtime.physicsRaycast(ray(2))?.entity == entity)
    }

    @Test("limited overlaps select entities in stable order across geometry rebuilds")
    func limitedOverlapsAreStable() {
        var runtime = makeScene()
        let entities = (0..<4).map { _ in runtime.createEntity() }
        for entity in entities.reversed() {
            _ = runtime.setComponent(Collider(shape: .sphere(radius: 0.5, center: .zero)), for: entity)
        }
        let query = PhysicsOverlapAABBQuery(bounds: SpatialAABB(center: .zero, halfExtents: SIMD3<Float>(repeating: 2)), maxResults: 2)
        #expect(runtime.physicsOverlapAABB(query).map(\.entity) == Array(entities.prefix(2)))
        _ = runtime.updateComponent(Collider.self, for: entities[0]) { $0.shape = .sphere(radius: 0.6, center: .zero) }
        #expect(runtime.physicsOverlapAABB(query).map(\.entity) == Array(entities.prefix(2)))
    }

    @Test("virtual characters emit trigger enter and exit events in play mode")
    func characterTriggers() {
        var runtime = makeScene()
        let trigger = runtime.createEntity()
        _ = runtime.setComponent(Collider(shape: .box(halfExtents: SIMD3<Float>(1, 2, 1), center: .zero), isTrigger: true), for: trigger)
        let character = runtime.createEntity()
        _ = runtime.setComponent(CharacterController(gravityScale: 0), for: character)
        let first = runtime.tick(deltaTime: 1.0 / 60.0)
        #expect(first.physics.error == nil)
        #expect(runtime.physicsEventFrame.triggers.contains { $0.triggerEntity == trigger && $0.otherEntity == character && $0.kind == .enter })
        _ = runtime.setLocalTransform(LocalTransform(translation: SIMD3<Float>(5, 0, 0)), for: character)
        _ = runtime.tick(deltaTime: 1.0 / 60.0)
        #expect(runtime.physicsEventFrame.triggers.contains { $0.triggerEntity == trigger && $0.otherEntity == character && $0.kind == .exit })
    }

    @Test("multiple fixed substeps accumulate gravity and consume impulses once")
    func fixedSubsteps() {
        var runtime = makeScene()
        var settings = runtime.physicsSettings
        settings.gravity = SIMD3<Float>(0, -6, 0)
        settings.maxSubstepsPerFrame = 4
        runtime.setPhysicsSettings(settings)
        let entity = runtime.createEntity()
        _ = runtime.setComponent(Collider(shape: .sphere(radius: 0.5, center: .zero)), for: entity)
        _ = runtime.setComponent(RigidBody(mass: 1, accumulatedLinearImpulse: SIMD3<Float>(1, 0, 0),
            linearDamping: 0, angularDamping: 0, allowSleep: false), for: entity)
        let report = runtime.tick(deltaTime: 1.0 / 30.0)
        #expect(report.physics.error == nil)
        #expect(report.physics.stepCount == 2)
        let velocity = runtime.component(RigidBody.self, for: entity)?.linearVelocity ?? .zero
        #expect(abs(velocity.x - 1) < 0.001)
        #expect(abs(velocity.y + 0.2) < 0.001)
    }

    @Test("sweeps do not report a contact beyond the requested translation")
    func sweepEndpoint() {
        var runtime = makeScene()
        let entity = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform(translation: SIMD3<Float>(2.003, 0, 0)), for: entity)
        _ = runtime.setComponent(Collider(shape: .box(halfExtents: SIMD3<Float>(repeating: 0.5), center: .zero)), for: entity)
        _ = runtime.tick(deltaTime: 0)
        let hit = runtime.physicsSweepShape(PhysicsSweepShapeQuery(shape: .box(halfExtents: SIMD3<Float>(repeating: 0.5)),
            position: .zero, translation: SIMD3<Float>(1, 0, 0)))
        #expect(hit == nil)
    }

    @Test("scene queries consistently exclude geometry with an empty collision mask")
    func queriesWithoutPhysicalCollisions() {
        var runtime = makeScene()
        let entity = runtime.createEntity()
        _ = runtime.setComponent(Collider(shape: .sphere(radius: 0.5, center: .zero), layerMask: 0), for: entity)
        _ = runtime.tick(deltaTime: 0)
        let ray = PhysicsRaycastQuery(origin: SIMD3<Float>(0, 0, -2), direction: SIMD3<Float>(0, 0, 1), maxDistance: 4)
        #expect(runtime.physicsRaycast(ray) == nil)
        #expect(runtime.physicsRaycast(ray, filter: PhysicsQueryFilter(layerID: 0)) == nil)
        let overlap = PhysicsOverlapAABBQuery(bounds: SpatialAABB(center: .zero, halfExtents: SIMD3<Float>(repeating: 1)))
        #expect(runtime.physicsOverlapAABB(overlap).isEmpty)
    }
}
