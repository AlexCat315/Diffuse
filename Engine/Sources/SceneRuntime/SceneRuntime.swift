import EngineKernel
import SIMDCompat

public struct SceneRuntimeSnapshot: Sendable, Equatable {
    public var entityCount: Int
    public var revision: UInt64

    public init(entityCount: Int = 0, revision: UInt64 = 0) {
        self.entityCount = entityCount
        self.revision = revision
    }
}

public struct InputFrameResource: Sendable {
    public var frameIndex: UInt64
    public var deltaTimeSeconds: Double
    public var events: [InputEvent]

    public init(
        frameIndex: UInt64 = 0,
        deltaTimeSeconds: Double = 0,
        events: [InputEvent] = []
    ) {
        self.frameIndex = frameIndex
        self.deltaTimeSeconds = deltaTimeSeconds
        self.events = events
    }
}

public struct SceneRuntime {
    private var world = RuntimeWorld()
    private var commandBuffer = RuntimeCommandBuffer()
    private var schedule = RuntimeWorldSchedule()

    public init() {}

    public var snapshot: SceneRuntimeSnapshot {
        world.snapshot
    }

    public var summary: RuntimeWorldSummary {
        world.summary
    }

    public var extractedRenderScene: ExtractedRenderSceneResource? {
        world.resource(ExtractedRenderSceneResource.self)
    }

    public var renderScene: RenderScene {
        extractedRenderScene?.scene ?? .empty
    }

    public var spatialIndex: SpatialIndexResource {
        world.resource(SpatialIndexResource.self) ?? buildSpatialIndexResource(in: world)
    }

    public var particleFrameStats: ParticleFrameStatsResource {
        world.resource(ParticleFrameStatsResource.self) ?? .empty
    }

    public var particleScalabilityState: ParticleScalabilityStateResource {
        world.resource(ParticleScalabilityStateResource.self) ?? .default
    }

    public var physicsDebugFrame: PhysicsDebugFrameResource {
        world.resource(PhysicsDebugFrameResource.self) ?? schedule.currentPhysicsDebugFrame
    }

    public var physicsEventFrame: PhysicsEventFrameResource {
        world.resource(PhysicsEventFrameResource.self) ?? schedule.currentPhysicsEventFrame
    }

    public var characterStateFrame: CharacterStateFrameResource {
        world.resource(CharacterStateFrameResource.self) ?? .empty
    }

    public var vehicleStateFrame: VehicleStateFrameResource {
        world.resource(VehicleStateFrameResource.self) ?? .empty
    }

    public var softBodyStateFrame: SoftBodyStateFrameResource {
        world.resource(SoftBodyStateFrameResource.self) ?? .empty
    }

    public var ragdollStateFrame: RagdollStateFrameResource {
        world.resource(RagdollStateFrameResource.self) ?? .empty
    }

    public var physicsStateHashFrame: PhysicsStateHashFrameResource {
        world.resource(PhysicsStateHashFrameResource.self) ?? .empty
    }

    public mutating func beginPhysicsCommandRecording(maxFrames: Int = 36_000) {
        world.setDerivedResource(PhysicsCommandRecordingResource(
            isRecording: true,
            maxFrames: maxFrames,
            frames: []
        ))
    }

    public mutating func endPhysicsCommandRecording() -> PhysicsCommandTape {
        var recording = world.resource(PhysicsCommandRecordingResource.self) ?? .inactive
        recording.isRecording = false
        world.setDerivedResource(recording)
        return PhysicsCommandTape(frames: recording.frames)
    }

    public var physicsCommandRecording: PhysicsCommandRecordingResource {
        world.resource(PhysicsCommandRecordingResource.self) ?? .inactive
    }

    @discardableResult
    public mutating func replayPhysicsCommandFrame(_ frame: PhysicsCommandFrame) -> RuntimeScheduleReport {
        setPhysicsSettings(frame.settings)
        world.setDerivedResource(PhysicsCommandReplayControlResource(isReplaying: true))
        for command in frame.bodyCommands.sorted(by: { $0.entity.rawValue < $1.entity.rawValue }) {
            if command.force != .zero {
                _ = applyForce(command.force, to: command.entity, wake: command.wake)
            }
            if command.torque != .zero {
                _ = applyTorque(command.torque, to: command.entity, wake: command.wake)
            }
            if command.linearImpulse != .zero {
                _ = applyLinearImpulse(command.linearImpulse, to: command.entity, wake: command.wake)
            }
            if command.angularImpulse != .zero {
                _ = applyAngularImpulse(command.angularImpulse, to: command.entity, wake: command.wake)
            }
        }
        for command in frame.characterCommands.sorted(by: { $0.entity.rawValue < $1.entity.rawValue }) {
            submitCharacterCommand(command.command, for: command.entity)
        }
        for command in frame.vehicleCommands.sorted(by: { $0.entity.rawValue < $1.entity.rawValue }) {
            submitVehicleCommand(command.command, for: command.entity)
        }
        let report = tick(deltaTime: frame.deltaTimeSeconds)
        world.setDerivedResource(PhysicsCommandReplayControlResource())
        return report
    }

    public mutating func replayPhysicsCommands(_ tape: PhysicsCommandTape) -> PhysicsReplayReport {
        var hashes: [UInt64] = []
        var mismatches: [PhysicsReplayMismatch] = []
        hashes.reserveCapacity(tape.frames.count)
        for (index, frame) in tape.frames.enumerated() {
            _ = replayPhysicsCommandFrame(frame)
            let checkpoint = physicsStateHashFrame
            hashes.append(checkpoint.hash)
            if checkpoint.simulatedStep != frame.expectedSimulatedStep
                || checkpoint.hash != frame.expectedStateHash {
                mismatches.append(PhysicsReplayMismatch(
                    frameIndex: index,
                    expectedSimulatedStep: frame.expectedSimulatedStep,
                    actualSimulatedStep: checkpoint.simulatedStep,
                    expectedStateHash: frame.expectedStateHash,
                    actualStateHash: checkpoint.hash
                ))
            }
        }
        return PhysicsReplayReport(
            replayedFrameCount: tape.frames.count,
            checkpointHashes: hashes,
            mismatches: mismatches
        )
    }

    @discardableResult
    public mutating func setRagdollMode(
        _ mode: RagdollMode,
        for entity: EntityID,
        blendWeight: Float? = nil
    ) -> Bool {
        world.updateComponent(Ragdoll.self, for: entity) {
            $0.mode = mode
            if let blendWeight { $0.blendWeight = max(0, min(blendWeight, 1)) }
        }
    }

    @discardableResult
    public mutating func setRagdollBoneSimulation(
        _ enabled: Bool,
        paletteIndex: Int,
        for entity: EntityID
    ) -> Bool {
        guard let ragdoll = world.component(Ragdoll.self, for: entity),
              ragdoll.bones.contains(where: { $0.paletteIndex == paletteIndex })
        else { return false }
        return world.updateComponent(Ragdoll.self, for: entity) { ragdoll in
            guard let index = ragdoll.bones.firstIndex(where: { $0.paletteIndex == paletteIndex }) else { return }
            ragdoll.bones[index].isSimulationEnabled = enabled
        }
    }

    public mutating func applyParticleSimulationReadbackStats(_ report: ParticleSimulationEventApplyReport) {
        world.setResource(particleFrameStats.mergingGPUReadback(report))
    }

    @discardableResult
    public mutating func tick(
        deltaTime: Double = 0,
        frameIndex: UInt64 = 0,
        inputEvents: [InputEvent] = []
    ) -> RuntimeScheduleReport {
        world.setDerivedResource(
            InputFrameResource(
                frameIndex: frameIndex,
                deltaTimeSeconds: deltaTime,
                events: inputEvents
            )
        )
        return schedule.run(world: &world, commands: &commandBuffer, deltaTimeSeconds: deltaTime)
    }

    public func contains(_ entity: EntityID) -> Bool {
        world.contains(entity)
    }

    public func entities() -> [EntityID] {
        world.entities()
    }

    @discardableResult
    public mutating func createEntity() -> EntityID {
        world.createEntity()
    }

    @discardableResult
    public mutating func destroyEntity(_ entity: EntityID) -> Bool {
        world.destroyEntity(entity)
    }

    @discardableResult
    public mutating func setComponent<Component: RuntimeComponent>(
        _ component: Component,
        for entity: EntityID
    ) -> Bool {
        world.setComponent(component, for: entity)
    }

    public func component<Component: RuntimeComponent>(
        _ type: Component.Type,
        for entity: EntityID
    ) -> Component? {
        world.component(type, for: entity)
    }

    public func hasComponent<Component: RuntimeComponent>(
        _ type: Component.Type,
        for entity: EntityID
    ) -> Bool {
        world.hasComponent(type, for: entity)
    }

    public func componentCount<Component: RuntimeComponent>(_ type: Component.Type) -> Int {
        world.componentCount(type)
    }

    public func entities<Component: RuntimeComponent>(with type: Component.Type) -> [EntityID] {
        world.entities(with: type)
    }

    public func query<Component: RuntimeComponent>(
        _ type: Component.Type
    ) -> [RuntimeComponentQuery<Component>] {
        world.query(type)
    }

    public func query<Component: RuntimeComponent>(
        _ type: Component.Type,
        using jobSystem: JobSystem
    ) -> ([RuntimeComponentQuery<Component>], JobDispatchReport) {
        world.query(type, using: jobSystem)
    }

    public func query<A: RuntimeComponent, B: RuntimeComponent>(
        _ a: A.Type,
        _ b: B.Type
    ) -> [RuntimeComponentPairQuery<A, B>] {
        world.query(a, b)
    }

    public func query<A: RuntimeComponent, B: RuntimeComponent>(
        _ a: A.Type,
        _ b: B.Type,
        using jobSystem: JobSystem
    ) -> ([RuntimeComponentPairQuery<A, B>], JobDispatchReport) {
        world.query(a, b, using: jobSystem)
    }

    public func query<A: RuntimeComponent, B: RuntimeComponent, C: RuntimeComponent>(
        _ a: A.Type,
        _ b: B.Type,
        _ c: C.Type
    ) -> [RuntimeComponentTripleQuery<A, B, C>] {
        world.query(a, b, c)
    }

    public func query<A: RuntimeComponent, B: RuntimeComponent, C: RuntimeComponent>(
        _ a: A.Type,
        _ b: B.Type,
        _ c: C.Type,
        using jobSystem: JobSystem
    ) -> ([RuntimeComponentTripleQuery<A, B, C>], JobDispatchReport) {
        world.query(a, b, c, using: jobSystem)
    }

    @discardableResult
    public mutating func updateComponent<Component: RuntimeComponent>(
        _ type: Component.Type,
        for entity: EntityID,
        _ body: (inout Component) -> Void
    ) -> Bool {
        world.updateComponent(type, for: entity, body)
    }

    @discardableResult
    public mutating func updateComponents<Component: RuntimeComponent>(
        _ type: Component.Type,
        _ body: (EntityID, inout Component) -> Void
    ) -> Int {
        world.updateComponents(type, body)
    }

    @discardableResult
    public mutating func removeComponent<Component: RuntimeComponent>(
        _ type: Component.Type,
        from entity: EntityID
    ) -> Component? {
        world.removeComponent(type, from: entity)
    }

    @discardableResult
    public mutating func setLocalTransform(
        _ transform: LocalTransform,
        for entity: EntityID
    ) -> Bool {
        world.setLocalTransform(transform, for: entity)
    }

    public func localTransform(for entity: EntityID) -> LocalTransform? {
        world.localTransform(for: entity)
    }

    public func worldTransform(for entity: EntityID) -> WorldTransform? {
        world.worldTransform(for: entity)
    }

    public func parent(of entity: EntityID) -> EntityID? {
        world.parent(of: entity)
    }

    public func children(of entity: EntityID) -> [EntityID] {
        world.children(of: entity)
    }

    public func roots() -> [EntityID] {
        world.roots()
    }

    /// Returns the first entity whose `SceneNameComponent.value` matches `name`.
    public func findEntity(named name: String) -> EntityID? {
        for id in entities(with: SceneNameComponent.self) {
            if component(SceneNameComponent.self, for: id)?.value == name {
                return id
            }
        }
        return nil
    }

    /// Returns all entities whose `SceneKindComponent.value` matches `kind`.
    public func entities(kind: String) -> [EntityID] {
        entities(with: SceneKindComponent.self).filter { id in
            component(SceneKindComponent.self, for: id)?.value == kind
        }
    }

    @discardableResult
    public mutating func setParent(_ parent: EntityID?, for child: EntityID) -> Bool {
        world.setParent(parent, for: child)
    }

    @discardableResult
    public mutating func moveEntity(_ entity: EntityID,
                                    to parent: EntityID?,
                                    at index: Int) -> Bool {
        world.moveEntity(entity, to: parent, at: index)
    }

    public func hierarchyNeedsPropagation() -> Bool {
        world.hierarchyNeedsPropagation()
    }

    public mutating func propagateTransforms() {
        world.propagateTransforms()
    }

    public mutating func enqueue(_ command: RuntimeCommand) {
        commandBuffer.enqueue(command)
    }

    public mutating func createQueuedEntity() {
        commandBuffer.createEntity()
    }

    public mutating func destroyQueuedEntity(_ entity: EntityID) {
        commandBuffer.destroyEntity(entity)
    }

    public mutating func setQueuedParent(_ parent: EntityID?, for child: EntityID) {
        commandBuffer.setParent(parent, for: child)
    }

    public mutating func setQueuedLocalTransform(
        _ transform: LocalTransform,
        for entity: EntityID
    ) {
        commandBuffer.setLocalTransform(transform, for: entity)
    }

    public var physicsSettings: PhysicsSettingsResource {
        world.resource(PhysicsSettingsResource.self) ?? PhysicsSettingsResource()
    }

    public mutating func setPhysicsSettings(_ settings: PhysicsSettingsResource) {
        world.setResource(settings)
    }

    public var physicsClock: PhysicsStepClockResource {
        world.resource(PhysicsStepClockResource.self) ?? schedule.currentPhysicsClock
    }

    public var physicsFrameState: PhysicsFrameStateResource {
        world.resource(PhysicsFrameStateResource.self) ?? schedule.currentPhysicsFrameState
    }

    public var physicsContactFrame: PhysicsContactFrameResource {
        world.resource(PhysicsContactFrameResource.self) ?? schedule.currentPhysicsContactFrame
    }

    public var physicsQueryCacheStats: PhysicsQueryCacheStats {
        schedule.currentPhysicsQueryCacheStats
    }

    @discardableResult
    public mutating func applyForce(_ force: SIMD3<Float>, to entity: EntityID, wake: Bool = true) -> Bool {
        world.applyForce(force, to: entity, wake: wake)
    }

    @discardableResult
    public mutating func applyForce(
        _ force: SIMD3<Float>,
        at worldPoint: SIMD3<Float>,
        to entity: EntityID,
        wake: Bool = true
    ) -> Bool {
        world.applyForce(force, at: worldPoint, to: entity, wake: wake)
    }

    @discardableResult
    public mutating func applyTorque(_ torque: SIMD3<Float>, to entity: EntityID, wake: Bool = true) -> Bool {
        world.applyTorque(torque, to: entity, wake: wake)
    }

    @discardableResult
    public mutating func applyLinearImpulse(_ impulse: SIMD3<Float>, to entity: EntityID, wake: Bool = true) -> Bool {
        world.applyLinearImpulse(impulse, to: entity, wake: wake)
    }

    @discardableResult
    public mutating func applyLinearImpulse(
        _ impulse: SIMD3<Float>,
        at worldPoint: SIMD3<Float>,
        to entity: EntityID,
        wake: Bool = true
    ) -> Bool {
        world.applyLinearImpulse(impulse, at: worldPoint, to: entity, wake: wake)
    }

    @discardableResult
    public mutating func applyAngularImpulse(_ impulse: SIMD3<Float>, to entity: EntityID, wake: Bool = true) -> Bool {
        world.applyAngularImpulse(impulse, to: entity, wake: wake)
    }

    @discardableResult
    public mutating func wakeRigidBody(_ entity: EntityID) -> Bool {
        world.wakeRigidBody(entity)
    }

    @discardableResult
    public mutating func sleepRigidBody(_ entity: EntityID) -> Bool {
        world.sleepRigidBody(entity)
    }

    @discardableResult
    public mutating func clearForces(for entity: EntityID) -> Bool {
        world.clearForces(for: entity)
    }

    public func raycast(_ query: SceneRaycastQuery) -> SceneRaycastHit? {
        schedule.physicsQueryBackend(in: world)
            .raycast(
                PhysicsRaycastQuery(
                    origin: query.origin,
                    direction: query.direction,
                    maxDistance: query.maxDistance
                ),
                filter: PhysicsQueryFilter(includeTriggers: query.includeTriggers)
            )
            .map(makeSceneRaycastHit)
    }

    public func physicsRaycast(
        _ query: PhysicsRaycastQuery,
        filter: PhysicsQueryFilter = PhysicsQueryFilter()
    ) -> PhysicsRaycastHit? {
        schedule.physicsQueryBackend(in: world).raycast(query, filter: filter)
    }

    /// Physics v2 unified ray query. All-hit results are stable-sorted by
    /// distance, entity ID, then sub-shape ID.
    public func raycast(
        _ query: PhysicsRaycastQuery,
        options: PhysicsQueryOptions = PhysicsQueryOptions()
    ) -> [PhysicsHit] {
        let backend = schedule.physicsQueryBackend(in: world)
        let hits: [PhysicsRaycastHit]
        switch options.resultMode {
        case .nearest:
            hits = backend.raycast(query, filter: options.filter).map { [$0] } ?? []
        case .all:
            hits = backend.raycastAll(query, filter: options.filter, maxHits: options.maxHits)
        }
        return hits.prefix(options.maxHits).map {
            PhysicsHit(
                entity: $0.entity,
                subShapeID: $0.subShapeID,
                distance: $0.distance,
                fraction: query.maxDistance > 0 ? $0.distance / query.maxDistance : 0,
                position: $0.position,
                normal: $0.normal,
                bounds: $0.bounds,
                isTrigger: $0.isTrigger
            )
        }
    }

    /// Executes a stable batch using the same synchronized physics snapshot.
    public func raycastBatch(
        _ queries: [PhysicsRaycastQuery],
        options: PhysicsQueryOptions = PhysicsQueryOptions()
    ) -> [[PhysicsHit]] {
        queries.map { raycast($0, options: options) }
    }

    public func physicsRaycastWithStats(
        _ query: PhysicsRaycastQuery,
        filter: PhysicsQueryFilter = PhysicsQueryFilter(),
        scratch: SpatialQueryScratch? = nil
    ) -> (hit: PhysicsRaycastHit?, stats: SpatialQueryStats) {
        let hit = schedule.physicsQueryBackend(in: world).raycast(query, filter: filter)
        return (hit, SpatialQueryStats())
    }

    public func overlap(_ query: SceneOverlapQuery) -> [SceneOverlapHit] {
        schedule.physicsQueryBackend(in: world)
            .overlapAABB(
                PhysicsOverlapAABBQuery(bounds: query.bounds),
                filter: PhysicsQueryFilter(includeTriggers: query.includeTriggers)
            )
            .map(makeSceneOverlapHit)
    }

    public func overlap(_ query: SceneOverlapQuery,
                        scratch: SpatialQueryScratch) -> [SceneOverlapHit] {
        overlap(query)
    }

    public func overlapWithStats(_ query: SceneOverlapQuery,
                                 scratch: SpatialQueryScratch? = nil) -> (hits: [SceneOverlapHit], stats: SpatialQueryStats) {
        (overlap(query), SpatialQueryStats())
    }

    public func physicsOverlapAABB(
        _ query: PhysicsOverlapAABBQuery,
        filter: PhysicsQueryFilter = PhysicsQueryFilter()
    ) -> [PhysicsOverlapHit] {
        schedule.physicsQueryBackend(in: world).overlapAABB(query, filter: filter)
    }

    public func physicsOverlapAABB(
        _ query: PhysicsOverlapAABBQuery,
        filter: PhysicsQueryFilter = PhysicsQueryFilter(),
        scratch: SpatialQueryScratch
    ) -> [PhysicsOverlapHit] {
        physicsOverlapAABB(query, filter: filter)
    }

    public func physicsOverlapAABBWithStats(
        _ query: PhysicsOverlapAABBQuery,
        filter: PhysicsQueryFilter = PhysicsQueryFilter(),
        scratch: SpatialQueryScratch? = nil
    ) -> (hits: [PhysicsOverlapHit], stats: SpatialQueryStats) {
        (physicsOverlapAABB(query, filter: filter), SpatialQueryStats())
    }

    public func physicsOverlapShape(
        _ query: PhysicsOverlapShapeQuery,
        filter: PhysicsQueryFilter = PhysicsQueryFilter()
    ) -> [PhysicsOverlapHit] {
        schedule.physicsQueryBackend(in: world).overlapShape(query, filter: filter)
    }

    public func overlapShape(
        _ query: PhysicsOverlapShapeQuery,
        options: PhysicsQueryOptions = PhysicsQueryOptions(resultMode: .all)
    ) -> [PhysicsHit] {
        let limit = options.resultMode == .nearest ? 1 : options.maxHits
        var limitedQuery = query
        limitedQuery.maxResults = limit
        return schedule.physicsQueryBackend(in: world)
            .overlapShape(limitedQuery, filter: options.filter)
            .sorted {
                if $0.entity.rawValue != $1.entity.rawValue { return $0.entity.rawValue < $1.entity.rawValue }
                return $0.subShapeID < $1.subShapeID
            }
            .prefix(limit)
            .map {
                PhysicsHit(
                    entity: $0.entity,
                    subShapeID: $0.subShapeID,
                    bounds: $0.bounds,
                    isTrigger: $0.isTrigger
                )
            }
    }

    /// Executes shape overlaps against one synchronized physics snapshot.
    public func overlapShapeBatch(
        _ queries: [PhysicsOverlapShapeQuery],
        options: PhysicsQueryOptions = PhysicsQueryOptions(resultMode: .all)
    ) -> [[PhysicsHit]] {
        queries.map { overlapShape($0, options: options) }
    }

    public func physicsOverlapShapeWithStats(
        _ query: PhysicsOverlapShapeQuery,
        filter: PhysicsQueryFilter = PhysicsQueryFilter(),
        scratch: SpatialQueryScratch? = nil
    ) -> (hits: [PhysicsOverlapHit], stats: SpatialQueryStats) {
        (physicsOverlapShape(query, filter: filter), SpatialQueryStats())
    }

    public func sweep(_ query: SceneSweepQuery) -> SceneSweepHit? {
        schedule.physicsQueryBackend(in: world)
            .sweepAABB(
                PhysicsSweepAABBQuery(bounds: query.bounds, translation: query.translation),
                filter: PhysicsQueryFilter(includeTriggers: query.includeTriggers)
            )
            .map(makeSceneSweepHit)
    }

    public func physicsSweepAABB(
        _ query: PhysicsSweepAABBQuery,
        filter: PhysicsQueryFilter = PhysicsQueryFilter()
    ) -> PhysicsSweepHit? {
        schedule.physicsQueryBackend(in: world).sweepAABB(query, filter: filter)
    }

    public func physicsSweepAABBWithStats(
        _ query: PhysicsSweepAABBQuery,
        filter: PhysicsQueryFilter = PhysicsQueryFilter(),
        scratch: SpatialQueryScratch? = nil
    ) -> (hit: PhysicsSweepHit?, stats: SpatialQueryStats) {
        (physicsSweepAABB(query, filter: filter), SpatialQueryStats())
    }

    public func physicsSweepShape(
        _ query: PhysicsSweepShapeQuery,
        filter: PhysicsQueryFilter = PhysicsQueryFilter()
    ) -> PhysicsSweepHit? {
        schedule.physicsQueryBackend(in: world).sweepShape(query, filter: filter)
    }

    public func shapeCast(
        _ query: PhysicsSweepShapeQuery,
        options: PhysicsQueryOptions = PhysicsQueryOptions()
    ) -> [PhysicsHit] {
        let backend = schedule.physicsQueryBackend(in: world)
        let hits: [PhysicsSweepHit]
        switch options.resultMode {
        case .nearest:
            hits = backend.sweepShape(query, filter: options.filter).map { [$0] } ?? []
        case .all:
            hits = backend.sweepShapeAll(query, filter: options.filter, maxHits: options.maxHits)
        }
        return hits.prefix(options.maxHits).map {
            PhysicsHit(
                entity: $0.entity,
                subShapeID: $0.subShapeID,
                distance: $0.distance,
                fraction: $0.fraction,
                position: $0.position,
                normal: $0.normal,
                bounds: $0.bounds,
                isTrigger: $0.isTrigger
            )
        }
    }

    /// Executes shape casts against one synchronized physics snapshot.
    public func shapeCastBatch(
        _ queries: [PhysicsSweepShapeQuery],
        options: PhysicsQueryOptions = PhysicsQueryOptions()
    ) -> [[PhysicsHit]] {
        queries.map { shapeCast($0, options: options) }
    }

    public func physicsSweepShapeWithStats(
        _ query: PhysicsSweepShapeQuery,
        filter: PhysicsQueryFilter = PhysicsQueryFilter(),
        scratch: SpatialQueryScratch? = nil
    ) -> (hit: PhysicsSweepHit?, stats: SpatialQueryStats) {
        (physicsSweepShape(query, filter: filter), SpatialQueryStats())
    }

    public mutating func setPhysicsBackend(_ backend: any PhysicsBackend) {
        schedule.setPhysicsBackend(backend)
    }

    public mutating func clearPhysicsBackendOverride() {
        schedule.clearPhysicsBackendOverride()
    }

    public mutating func setScriptDriver(_ driver: any RuntimeScriptDriver) {
        schedule.setScriptDriver(driver)
    }

    public mutating func clearScriptDriver() {
        schedule.clearScriptDriver()
    }

    public mutating func setJobSystem(_ jobSystem: JobSystem) {
        schedule.setJobSystem(jobSystem)
    }

    public mutating func setResource<Resource: Sendable>(_ resource: Resource) {
        world.setResource(resource)
    }

    public mutating func submitCharacterCommand(_ command: CharacterCommand, for entity: EntityID) {
        var frame = world.resource(CharacterCommandFrameResource.self) ?? .empty
        frame.commands[entity] = command
        world.setResource(frame)
    }

    public mutating func submitVehicleCommand(_ command: VehicleCommand, for entity: EntityID) {
        var frame = world.resource(VehicleCommandFrameResource.self) ?? .empty
        frame.commands[entity] = command
        world.setResource(frame)
    }

    public func resource<Resource: Sendable>(_ type: Resource.Type) -> Resource? {
        world.resource(type)
    }

    @discardableResult
    public mutating func updateResource<Resource: Sendable>(
        _ type: Resource.Type,
        _ body: (inout Resource) -> Void
    ) -> Bool {
        world.updateResource(type, body)
    }

    @discardableResult
    public mutating func removeResource<Resource: Sendable>(_ type: Resource.Type) -> Resource? {
        world.removeResource(type)
    }

    /// Runs a script driver against this scene's world for one frame.
    /// Use this to drive lightweight single-system ticks (e.g. AnimationRuntime)
    /// outside of the main simulation thread.
    public mutating func runScriptDriver(_ driver: any RuntimeScriptDriver,
                                        deltaTime: Double) {
        withUnsafeMutablePointer(to: &world) { worldPointer in
            withUnsafeMutablePointer(to: &commandBuffer) { commandPointer in
                var context = RuntimeScriptPhaseContext(
                    world: worldPointer,
                    commands: commandPointer,
                    deltaTimeSeconds: deltaTime,
                    physicsQueryScene: schedule.physicsQuerySceneHandle
                )
                driver.run(context: &context)
            }
        }
    }
}

private func makeSceneRaycastHit(_ hit: PhysicsRaycastHit) -> SceneRaycastHit {
    SceneRaycastHit(
        entity: hit.entity,
        distance: hit.distance,
        position: hit.position,
        normal: hit.normal,
        bounds: hit.bounds,
        isTrigger: hit.isTrigger
    )
}

private func makeSceneOverlapHit(_ hit: PhysicsOverlapHit) -> SceneOverlapHit {
    SceneOverlapHit(entity: hit.entity, bounds: hit.bounds, isTrigger: hit.isTrigger)
}

private func makeSceneSweepHit(_ hit: PhysicsSweepHit) -> SceneSweepHit {
    SceneSweepHit(
        entity: hit.entity,
        fraction: hit.fraction,
        distance: hit.distance,
        position: hit.position,
        normal: hit.normal,
        bounds: hit.bounds,
        isTrigger: hit.isTrigger
    )
}
