import Foundation
import SIMDCompat

public final class NullPhysicsBackend: PhysicsBackend, @unchecked Sendable {
    public init() {}

    public var identifier: String {
        "none"
    }

    public func prepare(context: PhysicsPrepareContext) -> PhysicsPrepareResult {
        var upsertedBodies = 0
        var removedBodies = 0
        var upsertedConstraints = 0
        var removedConstraints = 0
        var upsertedVehicles = 0
        var removedVehicles = 0
        var upsertedSoftBodies = 0
        var removedSoftBodies = 0

        for event in context.syncEvents {
            switch event {
            case .bodyUpsert:
                upsertedBodies += 1
            case .bodyRemove:
                removedBodies += 1
            case .constraintUpsert:
                upsertedConstraints += 1
            case .constraintRemove:
                removedConstraints += 1
            case .vehicleUpsert:
                upsertedVehicles += 1
            case .vehicleRemove:
                removedVehicles += 1
            case .softBodyUpsert:
                upsertedSoftBodies += 1
            case .softBodyRemove:
                removedSoftBodies += 1
            }
        }

        return PhysicsPrepareResult(
            synchronizedBodies: upsertedBodies,
            synchronizedConstraints: upsertedConstraints,
            removedBodies: removedBodies,
            removedConstraints: removedConstraints,
            synchronizedVehicles: upsertedVehicles,
            removedVehicles: removedVehicles,
            synchronizedSoftBodies: upsertedSoftBodies,
            removedSoftBodies: removedSoftBodies
        )
    }

    public func step(context: PhysicsStepContext) -> PhysicsStepResult {
        PhysicsStepResult(
            bodyCount: context.activeBodies.count,
            constraintCount: context.activeConstraints.count,
            contactCount: 0,
            writebacks: []
        )
    }

    public func raycast(_ query: PhysicsRaycastQuery, filter: PhysicsQueryFilter) -> PhysicsRaycastHit? {
        nil
    }

    public func raycastAll(_ query: PhysicsRaycastQuery, filter: PhysicsQueryFilter, maxHits: Int) -> [PhysicsRaycastHit] { [] }

    public func overlapAABB(_ query: PhysicsOverlapAABBQuery, filter: PhysicsQueryFilter) -> [PhysicsOverlapHit] {
        []
    }

    public func overlapShape(_ query: PhysicsOverlapShapeQuery, filter: PhysicsQueryFilter) -> [PhysicsOverlapHit] {
        []
    }

    public func sweepAABB(_ query: PhysicsSweepAABBQuery, filter: PhysicsQueryFilter) -> PhysicsSweepHit? {
        nil
    }

    public func sweepShape(_ query: PhysicsSweepShapeQuery, filter: PhysicsQueryFilter) -> PhysicsSweepHit? {
        nil
    }

    public func sweepShapeAll(_ query: PhysicsSweepShapeQuery, filter: PhysicsQueryFilter, maxHits: Int) -> [PhysicsSweepHit] { [] }

    public func detectTriggerFrame(maxEventCount: Int) -> TriggerFrameResource {
        TriggerFrameResource()
    }

    public func reset() {}
}
