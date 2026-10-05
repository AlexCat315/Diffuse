import Foundation
import SIMDCompat

public protocol PhysicsBackend: AnyObject, Sendable {
    var identifier: String { get }
    func prepare(context: PhysicsPrepareContext) -> PhysicsPrepareResult
    func step(context: PhysicsStepContext) -> PhysicsStepResult
    func raycast(_ query: PhysicsRaycastQuery, filter: PhysicsQueryFilter) -> PhysicsRaycastHit?
    func raycastAll(_ query: PhysicsRaycastQuery, filter: PhysicsQueryFilter, maxHits: Int) -> [PhysicsRaycastHit]
    func overlapAABB(_ query: PhysicsOverlapAABBQuery, filter: PhysicsQueryFilter) -> [PhysicsOverlapHit]
    func overlapShape(_ query: PhysicsOverlapShapeQuery, filter: PhysicsQueryFilter) -> [PhysicsOverlapHit]
    func sweepAABB(_ query: PhysicsSweepAABBQuery, filter: PhysicsQueryFilter) -> PhysicsSweepHit?
    func sweepShape(_ query: PhysicsSweepShapeQuery, filter: PhysicsQueryFilter) -> PhysicsSweepHit?
    func sweepShapeAll(_ query: PhysicsSweepShapeQuery, filter: PhysicsQueryFilter, maxHits: Int) -> [PhysicsSweepHit]
    func detectTriggerFrame(maxEventCount: Int) -> TriggerFrameResource
    func reset()
}

public extension PhysicsBackend {
    func raycastAll(_ query: PhysicsRaycastQuery, filter: PhysicsQueryFilter, maxHits: Int) -> [PhysicsRaycastHit] {
        guard maxHits > 0, let hit = raycast(query, filter: filter) else { return [] }
        return [hit]
    }

    func sweepShapeAll(_ query: PhysicsSweepShapeQuery, filter: PhysicsQueryFilter, maxHits: Int) -> [PhysicsSweepHit] {
        guard maxHits > 0, let hit = sweepShape(query, filter: filter) else { return [] }
        return [hit]
    }
}
