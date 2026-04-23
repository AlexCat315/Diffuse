import SceneRuntime
import EngineKernel
import Testing
import simd

private struct TransformStub: RuntimeComponent, Equatable {
    var x: Int
    var y: Int
}

private struct NameStub: RuntimeComponent, Equatable {
    var value: String
}

private struct CounterResource: Sendable, Equatable {
    var value: Int
}

private final class RecordingPhysicsBackend: PhysicsBackend, @unchecked Sendable {
    var prepareContexts: [PhysicsPrepareContext] = []
    var stepContexts: [PhysicsStepContext] = []

    var identifier: String {
        "recording"
    }

    func prepare(context: PhysicsPrepareContext) -> PhysicsPrepareResult {
        prepareContexts.append(context)
        return PhysicsPrepareResult(
            synchronizedBodies: context.activeBodies.count,
            synchronizedConstraints: context.activeConstraints.count
        )
    }

    func step(context: PhysicsStepContext) -> PhysicsStepResult {
        stepContexts.append(context)
        guard let body = context.activeBodies.first else {
            return PhysicsStepResult()
        }
        return PhysicsStepResult(
            bodyCount: context.activeBodies.count,
            constraintCount: context.activeConstraints.count,
            contactCount: 1,
            writebacks: [
                PhysicsBodyWriteback(
                    entity: body.entity,
                    worldTransform: WorldTransform(matrix: simd_float4x4(
                        rows: [
                            SIMD4<Float>(1, 0, 0, Float(context.stepIndex + 1)),
                            SIMD4<Float>(0, 1, 0, 0),
                            SIMD4<Float>(0, 0, 1, 0),
                            SIMD4<Float>(0, 0, 0, 1),
                        ]
                    )),
                    linearVelocity: SIMD3<Float>(Float(context.stepIndex + 1), 0, 0),
                    angularVelocity: SIMD3<Float>(0, Float(context.stepIndex + 1), 0),
                    isSleeping: false
                )
            ]
        )
    }

    func reset() {}
}

@Suite("RuntimeWorld")
struct RuntimeWorldTests {
    @Test("Entity slots reuse indices and invalidate stale generations")
    func entityGenerationChangesWhenReusingSlot() {
        var world = RuntimeWorld()

        let first = world.createEntity()
        #expect(world.contains(first))

        let destroyedFirst = world.destroyEntity(first)
        #expect(destroyedFirst)
        #expect(!world.contains(first))

        let reused = world.createEntity()
        #expect(world.contains(reused))
        #expect(first.index == reused.index)
        #expect(first.generation != reused.generation)
    }

    @Test("Typed component stores keep component types isolated")
    func typedComponentStoresArePerType() {
        var world = RuntimeWorld()
        let entity = world.createEntity()

        let insertedTransform = world.setComponent(TransformStub(x: 2, y: 4), for: entity)
        let insertedName = world.setComponent(NameStub(value: "Hero"), for: entity)
        #expect(insertedTransform)
        #expect(insertedName)
        #expect(world.component(TransformStub.self, for: entity) == TransformStub(x: 2, y: 4))
        #expect(world.component(NameStub.self, for: entity) == NameStub(value: "Hero"))
        #expect(world.summary.componentStoreCount == 2)

        let updatedTransform = world.updateComponent(TransformStub.self, for: entity) { transform in
            transform.x += 1
            transform.y += 2
        }
        #expect(updatedTransform)
        #expect(world.component(TransformStub.self, for: entity) == TransformStub(x: 3, y: 6))

        let removed = world.removeComponent(NameStub.self, from: entity)
        #expect(removed == NameStub(value: "Hero"))
        #expect(world.component(NameStub.self, for: entity) == nil)

        let destroyedEntity = world.destroyEntity(entity)
        #expect(destroyedEntity)
        #expect(world.component(TransformStub.self, for: entity) == nil)
        let insertedAfterDestroy = world.setComponent(TransformStub(x: 0, y: 0), for: entity)
        #expect(!insertedAfterDestroy)
    }

    @Test("World resources are stored independently from entity components")
    func worldResourcesAreTypedAndMutable() {
        var world = RuntimeWorld()

        world.setResource(CounterResource(value: 1))
        #expect(world.resource(CounterResource.self) == CounterResource(value: 1))
        #expect(world.summary.resourceCount == 1)

        let updatedResource = world.updateResource(CounterResource.self) { resource in
            resource.value += 9
        }
        #expect(updatedResource)
        #expect(world.resource(CounterResource.self) == CounterResource(value: 10))

        let removed = world.removeResource(CounterResource.self)
        #expect(removed == CounterResource(value: 10))
        #expect(world.resource(CounterResource.self) == nil)
    }

    @Test("SceneRuntime snapshot mirrors RuntimeWorld revision and entity count")
    func sceneRuntimeSnapshotTracksWorldState() {
        var runtime = SceneRuntime()
        #expect(runtime.snapshot == SceneRuntimeSnapshot())

        let entity = runtime.createEntity()
        let afterCreate = runtime.snapshot
        #expect(afterCreate.entityCount == 1)
        #expect(afterCreate.revision > 0)
        #expect(runtime.contains(entity))

        runtime.tick()
        #expect(runtime.snapshot.revision == afterCreate.revision + 1)

        let destroyed = runtime.destroyEntity(entity)
        #expect(destroyed)
        #expect(runtime.snapshot.entityCount == 0)
    }

    @Test("Hierarchy propagation composes parent and child transforms")
    func hierarchyPropagationBuildsWorldTransform() {
        var world = RuntimeWorld()
        let parent = world.createEntity()
        let child = world.createEntity()

        let parentTransformSet = world.setLocalTransform(LocalTransform(translation: SIMD3<Float>(2, 0, 0)), for: parent)
        let childTransformSet = world.setLocalTransform(LocalTransform(translation: SIMD3<Float>(0, 3, 0)), for: child)
        let parented = world.setParent(parent, for: child)
        #expect(parentTransformSet)
        #expect(childTransformSet)
        #expect(parented)
        #expect(world.hierarchyNeedsPropagation())

        world.propagateTransforms()

        #expect(world.parent(of: child) == parent)
        #expect(world.children(of: parent) == [child])

        let resolvedParent = world.worldTransform(for: parent)
        let resolvedChild = world.worldTransform(for: child)
        #expect(resolvedParent?.translation == SIMD3<Float>(2, 0, 0))
        #expect(resolvedChild?.translation == SIMD3<Float>(2, 3, 0))
    }

    @Test("Destroying a parent detaches children back to the root")
    func destroyingParentOrphansChildrenSafely() {
        var world = RuntimeWorld()
        let parent = world.createEntity()
        let child = world.createEntity()

        _ = world.setLocalTransform(LocalTransform(translation: SIMD3<Float>(4, 0, 0)), for: parent)
        _ = world.setLocalTransform(LocalTransform(translation: SIMD3<Float>(0, 1, 0)), for: child)
        _ = world.setParent(parent, for: child)
        world.propagateTransforms()

        let destroyedParent = world.destroyEntity(parent)
        #expect(destroyedParent)
        #expect(world.parent(of: child) == nil)

        world.propagateTransforms()
        #expect(world.worldTransform(for: child)?.translation == SIMD3<Float>(0, 1, 0))
    }

    @Test("SceneRuntime runs a fixed phase schedule and applies queued commands")
    func sceneRuntimeRunsDeterministicSchedule() {
        var runtime = SceneRuntime()
        runtime.createQueuedEntity()

        let report = runtime.tick()

        #expect(report.phases == RuntimeSystemPhase.allCases)
        #expect(report.appliedCommandCount == 1)
        #expect(report.createdEntities.count == 1)
        #expect(runtime.snapshot.entityCount == 1)
    }

    @Test("Queued hierarchy commands are visible after the schedule runs")
    func queuedHierarchyCommandsApplyBeforeRenderExtraction() {
        var runtime = SceneRuntime()
        let parent = runtime.createEntity()
        let child = runtime.createEntity()

        runtime.setQueuedLocalTransform(LocalTransform(translation: SIMD3<Float>(5, 0, 0)), for: parent)
        runtime.setQueuedLocalTransform(LocalTransform(translation: SIMD3<Float>(0, 2, 0)), for: child)
        runtime.setQueuedParent(parent, for: child)

        let report = runtime.tick()

        #expect(report.appliedCommandCount == 3)
        #expect(runtime.parent(of: child) == parent)
        #expect(runtime.worldTransform(for: child)?.translation == SIMD3<Float>(5, 2, 0))
    }

    @Test("Physics schedule respects fixed timestep and writes back body state")
    func physicsScheduleWritesBackBodyState() {
        var runtime = SceneRuntime()
        let backend = RecordingPhysicsBackend()
        runtime.setPhysicsBackend(backend)
        runtime.setPhysicsSettings(
            PhysicsSettingsResource(
                simulationMode: .play,
                backendKind: .none,
                fixedTimeStepSeconds: 1.0 / 60.0,
                maxSubstepsPerFrame: 4
            )
        )

        let entity = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform.identity, for: entity)
        _ = runtime.setComponent(RigidBody(), for: entity)
        _ = runtime.setComponent(
            Collider(shape: .box(halfExtents: SIMD3<Float>(0.5, 0.5, 0.5), center: .zero)),
            for: entity
        )

        let report = runtime.tick(deltaTime: 1.0 / 30.0)

        #expect(report.physicsBackendIdentifier == "recording")
        #expect(report.physicsStepCount == 2)
        #expect(report.physicsWritebackCount == 1)
        #expect(report.physicsBodyCount == 1)
        #expect(runtime.physicsClock.lastStepCount == 2)
        #expect(runtime.physicsClock.simulatedSteps == 2)
        #expect(runtime.physicsFrameState.contactCount == 2)
        #expect(runtime.worldTransform(for: entity)?.translation == SIMD3<Float>(2, 0, 0))
        #expect(runtime.component(RigidBody.self, for: entity)?.linearVelocity == SIMD3<Float>(2, 0, 0))
        #expect(backend.prepareContexts.count == 1)
        #expect(backend.stepContexts.count == 2)
    }

    @Test("Physics prepare emits removal sync events when tracked bodies disappear")
    func physicsPrepareEmitsRemovalEvents() {
        var runtime = SceneRuntime()
        let backend = RecordingPhysicsBackend()
        runtime.setPhysicsBackend(backend)
        runtime.setPhysicsSettings(
            PhysicsSettingsResource(
                simulationMode: .play,
                backendKind: .none,
                fixedTimeStepSeconds: 1.0 / 60.0,
                maxSubstepsPerFrame: 1
            )
        )

        let entity = runtime.createEntity()
        _ = runtime.setComponent(RigidBody(), for: entity)
        _ = runtime.setComponent(
            Collider(shape: .sphere(radius: 0.5, center: .zero)),
            for: entity
        )

        _ = runtime.tick(deltaTime: 1.0 / 60.0)
        _ = runtime.destroyEntity(entity)
        _ = runtime.tick(deltaTime: 1.0 / 60.0)

        let lastPrepare = backend.prepareContexts.last
        #expect(lastPrepare?.syncEvents.contains(.bodyRemove(entity)) == true)
    }

    @Test("SceneRuntime stores current frame input as a derived resource")
    func sceneRuntimeStoresInputFrameResource() {
        var runtime = SceneRuntime()
        let inputEvents: [InputEvent] = [
            .keyDown(.init(scancode: 4, keycode: 65, modifiers: .shift, isRepeat: false)),
            .windowResized(width: 1920, height: 1080)
        ]

        _ = runtime.tick(deltaTime: 0.25, frameIndex: 12, inputEvents: inputEvents)

        let resource = runtime.resource(InputFrameResource.self)
        #expect(resource?.frameIndex == 12)
        #expect(resource?.deltaTimeSeconds == 0.25)
        #expect(resource?.events.count == inputEvents.count)
        if case let .keyDown(event)? = resource?.events.first {
            #expect(event.keycode == 65)
            #expect(event.modifiers == .shift)
        } else {
            Issue.record("expected the first input event to be keyDown")
        }
    }
}
