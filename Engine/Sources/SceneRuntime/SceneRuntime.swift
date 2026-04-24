import EngineKernel

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

    public var spatialIndexBuildSettings: SpatialIndexBuildSettings {
        world.resource(SpatialIndexBuildSettings.self) ?? SpatialIndexBuildSettings()
    }

    public mutating func setSpatialIndexBuildSettings(_ settings: SpatialIndexBuildSettings) {
        world.setResource(settings)
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

    @discardableResult
    public mutating func updateComponent<Component: RuntimeComponent>(
        _ type: Component.Type,
        for entity: EntityID,
        _ body: (inout Component) -> Void
    ) -> Bool {
        world.updateComponent(type, for: entity, body)
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

    public func raycast(_ query: SceneRaycastQuery) -> SceneRaycastHit? {
        performSpatialRaycast(query, using: spatialIndex)
    }

    public func physicsRaycast(
        _ query: PhysicsRaycastQuery,
        filter: PhysicsQueryFilter = PhysicsQueryFilter()
    ) -> PhysicsRaycastHit? {
        performPhysicsRaycast(query, filter: filter, using: spatialIndex)
    }

    public func physicsRaycastWithStats(
        _ query: PhysicsRaycastQuery,
        filter: PhysicsQueryFilter = PhysicsQueryFilter(),
        scratch: SpatialQueryScratch? = nil
    ) -> (hit: PhysicsRaycastHit?, stats: SpatialQueryStats) {
        let recorder = SpatialQueryStatsRecorder()
        let hit = performPhysicsRaycast(query,
                                        filter: filter,
                                        using: spatialIndex,
                                        scratch: scratch,
                                        statsRecorder: recorder)
        return (hit, recorder.stats)
    }

    public func overlap(_ query: SceneOverlapQuery) -> [SceneOverlapHit] {
        performSpatialOverlap(query, using: spatialIndex)
    }

    public func overlap(_ query: SceneOverlapQuery,
                        scratch: SpatialQueryScratch) -> [SceneOverlapHit] {
        performSpatialOverlap(query, using: spatialIndex, scratch: scratch)
    }

    public func overlapWithStats(_ query: SceneOverlapQuery,
                                 scratch: SpatialQueryScratch? = nil) -> (hits: [SceneOverlapHit], stats: SpatialQueryStats) {
        let recorder = SpatialQueryStatsRecorder()
        let hits = performSpatialOverlap(query,
                                         using: spatialIndex,
                                         scratch: scratch,
                                         statsRecorder: recorder)
        return (hits, recorder.stats)
    }

    public func physicsOverlapAABB(
        _ query: PhysicsOverlapAABBQuery,
        filter: PhysicsQueryFilter = PhysicsQueryFilter()
    ) -> [PhysicsOverlapHit] {
        performPhysicsOverlapAABB(query, filter: filter, using: spatialIndex)
    }

    public func physicsOverlapAABB(
        _ query: PhysicsOverlapAABBQuery,
        filter: PhysicsQueryFilter = PhysicsQueryFilter(),
        scratch: SpatialQueryScratch
    ) -> [PhysicsOverlapHit] {
        performPhysicsOverlapAABB(query,
                                  filter: filter,
                                  using: spatialIndex,
                                  scratch: scratch)
    }

    public func physicsOverlapAABBWithStats(
        _ query: PhysicsOverlapAABBQuery,
        filter: PhysicsQueryFilter = PhysicsQueryFilter(),
        scratch: SpatialQueryScratch? = nil
    ) -> (hits: [PhysicsOverlapHit], stats: SpatialQueryStats) {
        let recorder = SpatialQueryStatsRecorder()
        let hits = performPhysicsOverlapAABB(query,
                                             filter: filter,
                                             using: spatialIndex,
                                             scratch: scratch,
                                             statsRecorder: recorder)
        return (hits, recorder.stats)
    }

    public func sweep(_ query: SceneSweepQuery) -> SceneSweepHit? {
        performSpatialSweep(query, using: spatialIndex)
    }

    public func physicsSweepAABB(
        _ query: PhysicsSweepAABBQuery,
        filter: PhysicsQueryFilter = PhysicsQueryFilter()
    ) -> PhysicsSweepHit? {
        performPhysicsSweepAABB(query, filter: filter, using: spatialIndex)
    }

    public func physicsSweepAABBWithStats(
        _ query: PhysicsSweepAABBQuery,
        filter: PhysicsQueryFilter = PhysicsQueryFilter(),
        scratch: SpatialQueryScratch? = nil
    ) -> (hit: PhysicsSweepHit?, stats: SpatialQueryStats) {
        let recorder = SpatialQueryStatsRecorder()
        let hit = performPhysicsSweepAABB(query,
                                          filter: filter,
                                          using: spatialIndex,
                                          scratch: scratch,
                                          statsRecorder: recorder)
        return (hit, recorder.stats)
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
}
