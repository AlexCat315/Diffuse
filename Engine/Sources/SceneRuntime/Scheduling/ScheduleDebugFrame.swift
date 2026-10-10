import EngineKernel
import SIMDCompat

extension RuntimeWorldSchedule {
    func buildPhysicsDebugFrame(
        in world: RuntimeWorld,
        spatialIndex: SpatialIndexResource,
        contacts: [PhysicsContactEvent]
    ) -> PhysicsDebugFrameResource {
        let bodies = spatialIndex.entries.map { entry in
            let body = world.component(RigidBody.self, for: entry.entity)
            let collider = world.component(Collider.self, for: entry.entity)
            return PhysicsDebugBody(
                entity: entry.entity,
                shape: entry.shape,
                shapes: collider?.shapes,
                worldTransform: entry.worldTransform,
                bounds: entry.bounds,
                motionType: body?.motionType ?? .static,
                isTrigger: entry.isTrigger,
                isSleeping: body?.isSleeping ?? false
            )
        }
        let constraints = world.entities(with: Constraint.self).compactMap { entity in
            world.component(Constraint.self, for: entity).map {
                PhysicsDebugConstraint(entity: entity, constraint: $0)
            }
        }
        return PhysicsDebugFrameResource(
            bodies: bodies,
            constraints: constraints,
            contacts: contacts,
            characters: characterStateFrame.states.values.sorted {
                $0.entity.rawValue < $1.entity.rawValue
            },
            destructionConnections: buildPhysicsDebugDestructionConnections(in: world)
        )
    }

    func buildPhysicsDebugDestructionConnections(
        in world: RuntimeWorld
    ) -> [PhysicsDebugDestructionConnection] {
        guard let assets = world.resource(DestructibleAssetResource.self) else { return [] }
        let runtime = world.resource(DestructionRuntimeStateResource.self)
        var result: [PhysicsDebugDestructionConnection] = []
        for source in world.entities(with: Destructible.self)
            .sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let destructible = world.component(Destructible.self, for: source),
                  let asset = assets.asset(for: destructible.assetResourceID)
            else { continue }
            let sourceTransform = world.worldTransform(for: source)?.matrix
                ?? world.localTransform(for: source)?.matrix
                ?? matrix_identity_float4x4
            var positionsByFragmentID: [UInt32: SIMD3<Float>] = [:]
            for fragment in asset.fragments.sorted(by: { $0.fragmentID < $1.fragmentID }) {
                guard positionsByFragmentID[fragment.fragmentID] == nil else { continue }
                let transform = sourceTransform * fragment.localTransform.matrix
                positionsByFragmentID[fragment.fragmentID] = SIMD3<Float>(
                    transform.columns.3.x,
                    transform.columns.3.y,
                    transform.columns.3.z
                )
            }
            let sourceState = runtime?.sources[source]
            for connection in asset.connections.sorted(by: { lhs, rhs in
                if lhs.connectionID != rhs.connectionID {
                    return lhs.connectionID < rhs.connectionID
                }
                if lhs.fragmentA != rhs.fragmentA { return lhs.fragmentA < rhs.fragmentA }
                return lhs.fragmentB < rhs.fragmentB
            }) {
                guard let pointA = positionsByFragmentID[connection.fragmentA],
                      let pointB = positionsByFragmentID[connection.fragmentB]
                else { continue }
                result.append(PhysicsDebugDestructionConnection(
                    sourceEntity: source,
                    connectionID: connection.connectionID,
                    fragmentA: connection.fragmentA,
                    fragmentB: connection.fragmentB,
                    worldPointA: pointA,
                    worldPointB: pointB,
                    isBroken: sourceState?.brokenConnectionIDs.contains(
                        connection.connectionID
                    ) ?? false,
                    isSourceFractured: sourceState?.hasFractured ?? false
                ))
            }
        }
        return result
    }
}
