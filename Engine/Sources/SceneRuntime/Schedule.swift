public enum RuntimeSystemPhase: String, CaseIterable, Sendable {
    case commandApply
    case hierarchyPropagate
    case fixedPhysicsPrepare
    case fixedPhysicsStep
    case physicsWriteback
    case animationAndScripts
    case spatialIndexUpdate
    case renderExtract
}

public enum RuntimeCommand: Sendable {
    case createEntity
    case destroyEntity(EntityID)
    case setParent(parent: EntityID?, child: EntityID)
    case setLocalTransform(entity: EntityID, transform: LocalTransform)
}

public struct RuntimeCommandBuffer: Sendable {
    private var commands: [RuntimeCommand] = []

    public init() {}

    public var count: Int {
        commands.count
    }

    public var isEmpty: Bool {
        commands.isEmpty
    }

    public mutating func enqueue(_ command: RuntimeCommand) {
        commands.append(command)
    }

    public mutating func createEntity() {
        enqueue(.createEntity)
    }

    public mutating func destroyEntity(_ entity: EntityID) {
        enqueue(.destroyEntity(entity))
    }

    public mutating func setParent(_ parent: EntityID?, for child: EntityID) {
        enqueue(.setParent(parent: parent, child: child))
    }

    public mutating func setLocalTransform(_ transform: LocalTransform, for entity: EntityID) {
        enqueue(.setLocalTransform(entity: entity, transform: transform))
    }

    mutating func drain() -> [RuntimeCommand] {
        let drained = commands
        commands.removeAll(keepingCapacity: true)
        return drained
    }
}

public struct RuntimeScheduleReport: Sendable {
    public var phases: [RuntimeSystemPhase]
    public var appliedCommandCount: Int
    public var createdEntities: [EntityID]
    public var destroyedEntities: [EntityID]
    public var physicsStepCount: Int
    public var physicsWritebackCount: Int
    public var physicsBodyCount: Int
    public var physicsConstraintCount: Int
    public var physicsContactCount: Int
    public var physicsBackendIdentifier: String
    public var revision: UInt64

    public init(
        phases: [RuntimeSystemPhase] = [],
        appliedCommandCount: Int = 0,
        createdEntities: [EntityID] = [],
        destroyedEntities: [EntityID] = [],
        physicsStepCount: Int = 0,
        physicsWritebackCount: Int = 0,
        physicsBodyCount: Int = 0,
        physicsConstraintCount: Int = 0,
        physicsContactCount: Int = 0,
        physicsBackendIdentifier: String = "none",
        revision: UInt64 = 0
    ) {
        self.phases = phases
        self.appliedCommandCount = appliedCommandCount
        self.createdEntities = createdEntities
        self.destroyedEntities = destroyedEntities
        self.physicsStepCount = physicsStepCount
        self.physicsWritebackCount = physicsWritebackCount
        self.physicsBodyCount = physicsBodyCount
        self.physicsConstraintCount = physicsConstraintCount
        self.physicsContactCount = physicsContactCount
        self.physicsBackendIdentifier = physicsBackendIdentifier
        self.revision = revision
    }
}

public struct RuntimeWorldSchedule {
    private struct ExtractedRenderInstance {
        var entity: EntityID
        var instance: RenderInstance
    }

    private struct PhysicsSyncCache {
        var bodies: [EntityID: PhysicsBodyDescriptor] = [:]
        var constraints: [EntityID: PhysicsConstraintDescriptor] = [:]
    }

    private var physicsBackend: any PhysicsBackend = NullPhysicsBackend()
    private var explicitPhysicsBackend: (any PhysicsBackend)?
    private var scriptDriver: (any RuntimeScriptDriver)?
    private var physicsClock = PhysicsStepClockResource()
    private var physicsFrameState = PhysicsFrameStateResource()
    private var physicsSyncCache = PhysicsSyncCache()
    private var resolvedPhysicsBackendKind: PhysicsBackendKind = .none

    public init() {}

    public mutating func setPhysicsBackend(_ backend: any PhysicsBackend) {
        explicitPhysicsBackend = backend
        physicsBackend = backend
        resolvedPhysicsBackendKind = .none
        physicsFrameState.backendIdentifier = backend.identifier
    }

    public mutating func clearPhysicsBackendOverride() {
        explicitPhysicsBackend = nil
        resolvedPhysicsBackendKind = .none
        physicsBackend = NullPhysicsBackend()
        physicsFrameState.backendIdentifier = physicsBackend.identifier
    }

    public mutating func setScriptDriver(_ driver: any RuntimeScriptDriver) {
        scriptDriver?.reset()
        scriptDriver = driver
    }

    public mutating func clearScriptDriver() {
        scriptDriver?.reset()
        scriptDriver = nil
    }

    public var currentPhysicsBackendIdentifier: String {
        physicsBackend.identifier
    }

    public var currentPhysicsClock: PhysicsStepClockResource {
        physicsClock
    }

    public var currentPhysicsFrameState: PhysicsFrameStateResource {
        physicsFrameState
    }

    public mutating func run(
        world: inout RuntimeWorld,
        commands: inout RuntimeCommandBuffer,
        deltaTimeSeconds: Double
    ) -> RuntimeScheduleReport {
        let drainedCommands = commands.drain()
        var createdEntities: [EntityID] = []
        var destroyedEntities: [EntityID] = []
        let physicsSettings = world.resource(PhysicsSettingsResource.self) ?? PhysicsSettingsResource()
        var physicsStepCount = 0
        var physicsWritebackCount = 0
        var physicsBodyCount = 0
        var physicsConstraintCount = 0
        var physicsContactCount = 0

        var activeBodies: [PhysicsBodyDescriptor] = []
        var activeConstraints: [PhysicsConstraintDescriptor] = []
        var syncEvents: [PhysicsSyncEvent] = []
        var pendingWritebacks: [PhysicsBodyWriteback] = []

        ensureConfiguredPhysicsBackend(kind: physicsSettings.backendKind)

        for phase in RuntimeSystemPhase.allCases {
            switch phase {
            case .commandApply:
                for command in drainedCommands {
                    switch command {
                    case .createEntity:
                        createdEntities.append(world.createEntity())
                    case let .destroyEntity(entity):
                        if world.destroyEntity(entity) {
                            destroyedEntities.append(entity)
                        }
                    case let .setParent(parent, child):
                        _ = world.setParent(parent, for: child)
                    case let .setLocalTransform(entity, transform):
                        _ = world.setLocalTransform(transform, for: entity)
                    }
                }
            case .hierarchyPropagate:
                world.propagateTransforms()
            case .fixedPhysicsPrepare:
                guard physicsSettings.simulationMode != .off else {
                    physicsBackend.reset()
                    physicsSyncCache = PhysicsSyncCache()
                    physicsClock = PhysicsStepClockResource()
                    physicsFrameState = PhysicsFrameStateResource(backendIdentifier: physicsBackend.identifier)
                    world.setDerivedResource(physicsClock)
                    world.setDerivedResource(physicsFrameState)
                    continue
                }

                activeBodies = collectPhysicsBodies(in: world)
                activeConstraints = collectPhysicsConstraints(in: world)
                physicsBodyCount = activeBodies.count
                physicsConstraintCount = activeConstraints.count
                syncEvents = diffPhysicsSyncEvents(
                    bodies: activeBodies,
                    constraints: activeConstraints
                )
                let prepareContext = PhysicsPrepareContext(
                    settings: physicsSettings,
                    deltaTimeSeconds: deltaTimeSeconds,
                    activeBodies: activeBodies,
                    activeConstraints: activeConstraints,
                    syncEvents: syncEvents
                )
                _ = physicsBackend.prepare(context: prepareContext)
                replacePhysicsSyncCache(bodies: activeBodies, constraints: activeConstraints)
            case .fixedPhysicsStep:
                guard physicsSettings.simulationMode != .off else { continue }
                physicsClock.accumulatedSeconds += deltaTimeSeconds
                physicsClock.lastStepCount = 0
                physicsClock.lastSteppedSeconds = 0

                let fixedStep = max(physicsSettings.fixedTimeStepSeconds, 0.000_001)
                let maxSubsteps = max(physicsSettings.maxSubstepsPerFrame, 0)
                var substepIndex = 0

                while physicsClock.accumulatedSeconds + 0.000_000_1 >= fixedStep && substepIndex < maxSubsteps {
                    let stepResult = physicsBackend.step(
                        context: PhysicsStepContext(
                            settings: physicsSettings,
                            stepDeltaSeconds: fixedStep,
                            stepIndex: substepIndex,
                            activeBodies: activeBodies,
                            activeConstraints: activeConstraints
                        )
                    )
                    physicsClock.accumulatedSeconds -= fixedStep
                    physicsClock.simulatedSteps += 1
                    physicsClock.lastStepCount += 1
                    physicsClock.lastSteppedSeconds += fixedStep
                    physicsStepCount += 1
                    physicsContactCount += stepResult.contactCount
                    pendingWritebacks = mergeWritebacks(existing: pendingWritebacks, incoming: stepResult.writebacks)
                    substepIndex += 1
                }
            case .physicsWriteback:
                guard physicsSettings.simulationMode != .off else { continue }
                for writeback in pendingWritebacks {
                    if world.applyPhysicsWriteback(writeback) {
                        physicsWritebackCount += 1
                    }
                }
                if physicsWritebackCount > 0 {
                    world.propagateTransforms()
                }
                physicsFrameState = PhysicsFrameStateResource(
                    backendIdentifier: physicsBackend.identifier,
                    bodyCount: physicsBodyCount,
                    constraintCount: physicsConstraintCount,
                    contactCount: physicsContactCount,
                    writebackCount: physicsWritebackCount,
                    simulatedSteps: physicsStepCount,
                    simulatedSeconds: physicsClock.lastSteppedSeconds
                )
                world.setDerivedResource(physicsClock)
                world.setDerivedResource(physicsFrameState)
            case .animationAndScripts:
                if let scriptDriver {
                    withUnsafeMutablePointer(to: &world) { worldPointer in
                        withUnsafeMutablePointer(to: &commands) { commandPointer in
                            var scriptContext = RuntimeScriptPhaseContext(
                                world: worldPointer,
                                commands: commandPointer,
                                deltaTimeSeconds: deltaTimeSeconds
                            )
                            scriptDriver.run(context: &scriptContext)
                        }
                    }
                }
                if world.hierarchyNeedsPropagation() {
                    world.propagateTransforms()
                }
            case .spatialIndexUpdate:
                world.setDerivedResource(buildSpatialIndexResource(in: world))
                break
            case .renderExtract:
                world.setDerivedResource(extractRenderScene(in: world))
                break
            }
        }

        world.advanceRevision()

        return RuntimeScheduleReport(
            phases: RuntimeSystemPhase.allCases,
            appliedCommandCount: drainedCommands.count,
            createdEntities: createdEntities,
            destroyedEntities: destroyedEntities,
            physicsStepCount: physicsStepCount,
            physicsWritebackCount: physicsWritebackCount,
            physicsBodyCount: physicsBodyCount,
            physicsConstraintCount: physicsConstraintCount,
            physicsContactCount: physicsContactCount,
            physicsBackendIdentifier: physicsBackend.identifier,
            revision: world.revision
        )
    }

    private mutating func replacePhysicsSyncCache(
        bodies: [PhysicsBodyDescriptor],
        constraints: [PhysicsConstraintDescriptor]
    ) {
        physicsSyncCache.bodies = Dictionary(uniqueKeysWithValues: bodies.map { ($0.entity, $0) })
        physicsSyncCache.constraints = Dictionary(uniqueKeysWithValues: constraints.map { ($0.entity, $0) })
    }

    private func collectPhysicsBodies(in world: RuntimeWorld) -> [PhysicsBodyDescriptor] {
        world.entities().compactMap { entity in
            let rigidBody = world.component(RigidBody.self, for: entity)
            let collider = world.component(Collider.self, for: entity)
            guard rigidBody != nil || collider != nil,
                  let localTransform = world.localTransform(for: entity),
                  let worldTransform = world.worldTransform(for: entity)
            else {
                return nil
            }
            return PhysicsBodyDescriptor(
                entity: entity,
                localTransform: localTransform,
                worldTransform: worldTransform,
                rigidBody: rigidBody,
                collider: collider
            )
        }
    }

    private func collectPhysicsConstraints(in world: RuntimeWorld) -> [PhysicsConstraintDescriptor] {
        world.entities().compactMap { entity in
            guard let constraint = world.component(Constraint.self, for: entity),
                  let worldTransform = world.worldTransform(for: entity)
            else {
                return nil
            }
            return PhysicsConstraintDescriptor(
                entity: entity,
                worldTransform: worldTransform,
                constraint: constraint
            )
        }
    }

    private func diffPhysicsSyncEvents(
        bodies: [PhysicsBodyDescriptor],
        constraints: [PhysicsConstraintDescriptor]
    ) -> [PhysicsSyncEvent] {
        let bodyMap = Dictionary(uniqueKeysWithValues: bodies.map { ($0.entity, $0) })
        let constraintMap = Dictionary(uniqueKeysWithValues: constraints.map { ($0.entity, $0) })
        var events: [PhysicsSyncEvent] = []

        for descriptor in bodies where physicsSyncCache.bodies[descriptor.entity] != descriptor {
            events.append(.bodyUpsert(descriptor))
        }
        for entity in physicsSyncCache.bodies.keys where bodyMap[entity] == nil {
            events.append(.bodyRemove(entity))
        }

        for descriptor in constraints where physicsSyncCache.constraints[descriptor.entity] != descriptor {
            events.append(.constraintUpsert(descriptor))
        }
        for entity in physicsSyncCache.constraints.keys where constraintMap[entity] == nil {
            events.append(.constraintRemove(entity))
        }

        return events
    }

    private func mergeWritebacks(
        existing: [PhysicsBodyWriteback],
        incoming: [PhysicsBodyWriteback]
    ) -> [PhysicsBodyWriteback] {
        var merged = Dictionary(uniqueKeysWithValues: existing.map { ($0.entity, $0) })
        for writeback in incoming {
            merged[writeback.entity] = writeback
        }
        return Array(merged.values)
    }

    private mutating func ensureConfiguredPhysicsBackend(kind: PhysicsBackendKind) {
        guard explicitPhysicsBackend == nil else { return }
        guard resolvedPhysicsBackendKind != kind else { return }

        physicsBackend.reset()
        switch kind {
        case .none:
            physicsBackend = NullPhysicsBackend()
        case .jolt:
            physicsBackend = JoltPhysicsBackend()
        }
        resolvedPhysicsBackendKind = kind
        physicsFrameState.backendIdentifier = physicsBackend.identifier
    }

    private func extractRenderScene(in world: RuntimeWorld) -> ExtractedRenderSceneResource {
        let cameraSelection = selectRenderCamera(in: world)
        let instances = collectRenderInstances(in: world)
        return ExtractedRenderSceneResource(
            scene: RenderScene(
                camera: cameraSelection.camera,
                instances: instances.map(\ .instance)
            ),
            activeCameraEntity: cameraSelection.entity,
            instanceEntities: instances.map(\ .entity),
            sourceRevision: world.revision
        )
    }

    private func selectRenderCamera(in world: RuntimeWorld) -> (entity: EntityID?, camera: RenderCamera) {
        var fallbackSelection: (entity: EntityID?, camera: RenderCamera)?

        for entity in world.entities() {
            guard let component = world.component(CameraComponent.self, for: entity) else {
                continue
            }

            let camera = RenderCamera(
                eye: world.worldTransform(for: entity)?.translation ?? .zero,
                target: component.target,
                up: component.up,
                fovYRadians: component.fovYRadians,
                near: component.near,
                far: component.far
            )

            if fallbackSelection == nil {
                fallbackSelection = (entity, camera)
            }
            if component.isActive {
                return (entity, camera)
            }
        }

        return fallbackSelection ?? (nil, .fallbackPerspective)
    }

    private func collectRenderInstances(in world: RuntimeWorld) -> [ExtractedRenderInstance] {
        world.entities().compactMap { entity in
            guard let renderMesh = world.component(RenderMeshComponent.self, for: entity),
                  renderMesh.isVisible,
                  let worldTransform = world.worldTransform(for: entity)
            else {
                return nil
            }

            return ExtractedRenderInstance(
                entity: entity,
                instance: RenderInstance(
                    meshIndex: renderMesh.meshIndex,
                    transform: worldTransform.matrix
                )
            )
        }
    }
}
