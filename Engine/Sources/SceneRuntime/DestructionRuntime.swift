import Foundation
import SIMDCompat

func advanceDestructionPrePhysics(
    in world: inout RuntimeWorld,
    deltaTimeSeconds: Double,
    frame: inout DestructionEventFrameResource
) {
    var runtime = world.resource(DestructionRuntimeStateResource.self)
        ?? DestructionRuntimeStateResource()
    runtime.elapsedSeconds += max(0, deltaTimeSeconds)
    recycleDestructionFragments(in: &world, runtime: &runtime, frame: &frame)

    let indexedCommands = (world.resource(DestructionCommandFrameResource.self)?.commands ?? [])
        .enumerated()
        .sorted {
            let lhs = ($0.element.entity.rawValue, $0.offset)
            let rhs = ($1.element.entity.rawValue, $1.offset)
            return lhs < rhs
        }
    var changedHierarchy = false
    for (_, command) in indexedCommands {
        changedHierarchy = applyDestruction(
            command,
            contactDriven: false,
            in: &world,
            runtime: &runtime,
            frame: &frame
        ) || changedHierarchy
    }
    if changedHierarchy {
        world.propagateTransforms()
    }
    publishDestructionState(in: &world, runtime: runtime)
    world.setDerivedResource(runtime)
    world.setDerivedResource(frame)
}

func applyDestructionContacts(
    _ contacts: [PhysicsContactEvent],
    in world: inout RuntimeWorld,
    frame: inout DestructionEventFrameResource
) {
    var runtime = world.resource(DestructionRuntimeStateResource.self)
        ?? DestructionRuntimeStateResource()
    struct ContactCommand {
        var command: DestructionCommand
        var otherEntity: EntityID
        var subShapeID: UInt32
    }
    var commands: [ContactCommand] = []
    commands.reserveCapacity(contacts.count * 2)
    for contact in contacts where contact.kind != .ended && contact.impulse > 0 {
        let normal = safeNormalized(contact.normal, fallback: contact.relativeVelocity)
        if world.component(Destructible.self, for: contact.entityA) != nil {
            commands.append(ContactCommand(
                command: DestructionCommand(
                    entity: contact.entityA,
                    impulse: -normal * contact.impulse,
                    worldPoint: contact.position
                ),
                otherEntity: contact.entityB,
                subShapeID: contact.subShapeIDA
            ))
        }
        if world.component(Destructible.self, for: contact.entityB) != nil {
            commands.append(ContactCommand(
                command: DestructionCommand(
                    entity: contact.entityB,
                    impulse: normal * contact.impulse,
                    worldPoint: contact.position
                ),
                otherEntity: contact.entityA,
                subShapeID: contact.subShapeIDB
            ))
        }
    }
    commands.sort {
        ($0.command.entity.rawValue, $0.otherEntity.rawValue, $0.subShapeID)
            < ($1.command.entity.rawValue, $1.otherEntity.rawValue, $1.subShapeID)
    }
    var changedHierarchy = false
    for candidate in commands {
        changedHierarchy = applyDestruction(
            candidate.command,
            contactDriven: true,
            in: &world,
            runtime: &runtime,
            frame: &frame
        ) || changedHierarchy
    }
    if changedHierarchy {
        world.propagateTransforms()
    }
    publishDestructionState(in: &world, runtime: runtime)
    world.setDerivedResource(runtime)
    world.setDerivedResource(frame)
}

private func applyDestruction(
    _ command: DestructionCommand,
    contactDriven: Bool,
    in world: inout RuntimeWorld,
    runtime: inout DestructionRuntimeStateResource,
    frame: inout DestructionEventFrameResource
) -> Bool {
    guard world.contains(command.entity),
          let destructible = world.component(Destructible.self, for: command.entity),
          destructible.isEnabled
    else { return false }
    var sourceState = runtime.sources[command.entity] ?? DestructionRuntimeSourceState()
    guard !sourceState.hasFractured else { return false }

    guard isValidDestructionCommand(command) else {
        appendFailure(
            DestructionFailureEvent(
                sourceEntity: command.entity,
                reason: .invalidCommand,
                message: "Destruction command contains a non-finite or negative value"
            ),
            in: world,
            frame: &frame
        )
        return false
    }
    guard isValidDestructibleConfiguration(destructible) else {
        appendFailure(
            DestructionFailureEvent(
                sourceEntity: command.entity,
                reason: .invalidConfiguration,
                message: "Destructible configuration contains an invalid value"
            ),
            in: world,
            frame: &frame
        )
        return false
    }

    guard let asset = world.resource(DestructibleAssetResource.self)?
        .asset(for: destructible.assetResourceID) else {
        appendFailure(
            DestructionFailureEvent(
                sourceEntity: command.entity,
                reason: .missingAsset,
                message: "Missing destructible asset '\(destructible.assetResourceID)'"
            ),
            in: world,
            frame: &frame
        )
        return false
    }
    if let invalidReason = validateDestructibleAsset(asset, in: world) {
        appendFailure(
            DestructionFailureEvent(
                sourceEntity: command.entity,
                reason: .invalidAsset,
                message: invalidReason
            ),
            in: world,
            frame: &frame
        )
        return false
    }

    sourceState.accumulatedDamage = min(
        Float.greatestFiniteMagnitude,
        sourceState.accumulatedDamage + command.damage
    )
    let impulseMagnitude = simd_length(command.impulse)
    let sourceTransform = world.worldTransform(for: command.entity)?.matrix
        ?? world.localTransform(for: command.entity)?.matrix
        ?? matrix_identity_float4x4
    let eligibleConnections = asset.connections
        .sorted { $0.connectionID < $1.connectionID }
        .filter { connection in
            guard !sourceState.brokenConnectionIDs.contains(connection.connectionID) else {
                return false
            }
            let damageThreshold = connection.damageThreshold > 0
                ? connection.damageThreshold : destructible.damageThreshold
            let impulseThreshold = connection.impulseThreshold > 0
                ? connection.impulseThreshold : destructible.impulseThreshold
            let damageBreak = damageThreshold > 0
                && sourceState.accumulatedDamage >= damageThreshold
            let impulseBreak = impulseThreshold > 0
                && impulseMagnitude >= impulseThreshold
            return damageBreak || impulseBreak || command.forceFracture
        }
    let connectionsToBreak: [DestructibleConnectionAsset]
    if !command.forceFracture,
       let worldPoint = command.worldPoint,
       let nearest = nearestConnection(
           to: worldPoint,
           among: eligibleConnections,
           in: asset,
           sourceTransform: sourceTransform
       ) {
        connectionsToBreak = [nearest]
    } else {
        connectionsToBreak = eligibleConnections
    }
    let newlyBrokenConnectionIDs = connectionsToBreak.map(\.connectionID)
    for connectionID in newlyBrokenConnectionIDs {
        sourceState.brokenConnectionIDs.insert(connectionID)
    }
    runtime.sources[command.entity] = sourceState

    let damageExceeded = destructible.damageThreshold > 0
        && sourceState.accumulatedDamage >= destructible.damageThreshold
    let impulseExceeded = destructible.impulseThreshold > 0
        && impulseMagnitude >= destructible.impulseThreshold
    let connectionDisconnected = !asset.connections.isEmpty
        && graphIsDisconnected(asset, brokenConnections: sourceState.brokenConnectionIDs)
    guard command.forceFracture || damageExceeded || impulseExceeded || connectionDisconnected else {
        if !newlyBrokenConnectionIDs.isEmpty {
            appendEvent(
                DestructionEvent(
                    sourceEntity: command.entity,
                    cause: .connectionBreak,
                    fragmentEntities: [],
                    fragmentIDs: [],
                    brokenConnectionIDs: newlyBrokenConnectionIDs,
                    appliedDamage: sourceState.accumulatedDamage,
                    appliedImpulse: impulseMagnitude
                ),
                in: world,
                frame: &frame
            )
        }
        return false
    }

    let settings = world.resource(DestructionSettingsResource.self)
        ?? DestructionSettingsResource()
    let activeCount = world.entities(with: DestructibleFragment.self).count
    let globalAvailable = max(0, settings.maximumActiveFragmentCount - activeCount)
    let orderedFragments = asset.fragments.sorted { $0.fragmentID < $1.fragmentID }
    let allowedCount = min(globalAvailable, destructible.fragmentBudget, orderedFragments.count)
    guard allowedCount > 0 else {
        appendFailure(
            DestructionFailureEvent(
                sourceEntity: command.entity,
                reason: .fragmentBudgetExhausted,
                message: "No fragment capacity is available"
            ),
            in: world,
            frame: &frame
        )
        return false
    }

    let fragments = Array(orderedFragments.prefix(allowedCount))
    let sourcePosition = SIMD3<Float>(
        sourceTransform.columns.3.x,
        sourceTransform.columns.3.y,
        sourceTransform.columns.3.z
    )
    let sourceBody = world.component(RigidBody.self, for: command.entity)
    let sourceCollider = world.component(Collider.self, for: command.entity)
    let sourceRenderMesh = world.component(RenderMeshComponent.self, for: command.entity)
    let sourceMaterial = world.component(RenderMaterialComponent.self, for: command.entity)
    let totalMass = fragments.reduce(Float(0)) { $0 + $1.mass }
    var fragmentEntities: [EntityID] = []
    var fragmentIDs: [UInt32] = []
    fragmentEntities.reserveCapacity(fragments.count)
    fragmentIDs.reserveCapacity(fragments.count)

    for fragment in fragments {
        let entity = world.createEntity()
        let fragmentMatrix = sourceTransform * fragment.localTransform.matrix
        _ = world.setLocalTransform(LocalTransform(matrix: fragmentMatrix), for: entity)
        _ = world.setComponent(
            SceneNameComponent(value: "Fragment \(fragment.fragmentID)"),
            for: entity
        )
        _ = world.setComponent(
            DestructibleFragment(
                sourceEntity: command.entity,
                fragmentID: fragment.fragmentID,
                spawnedAtSeconds: runtime.elapsedSeconds,
                maximumLifetimeSeconds: destructible.maximumFragmentLifetimeSeconds,
                sleepingRecycleDelaySeconds: destructible.sleepingRecycleDelaySeconds
            ),
            for: entity
        )
        var body = sourceBody ?? RigidBody()
        body.motionType = .dynamic
        body.massMode = .mass
        body.mass = fragment.mass
        body.centerOfMassOverride = nil
        body.inertiaDiagonalOverride = nil
        body.isSleeping = false
        body.kinematicTarget = nil
        body.accumulatedForce = .zero
        body.accumulatedTorque = .zero
        body.accumulatedLinearImpulse = .zero
        body.accumulatedAngularImpulse = .zero
        _ = world.setComponent(body, for: entity)
        _ = world.setComponent(
            Collider(
                shape: .convex(resourceID: fragment.colliderResourceID, center: .zero),
                isTrigger: false,
                layerID: sourceCollider?.layerID ?? 0,
                layerMask: sourceCollider?.layerMask ?? .max,
                material: sourceCollider?.material ?? PhysicsMaterial()
            ),
            for: entity
        )
        if let renderMesh = fragment.renderMesh {
            _ = world.setComponent(renderMesh, for: entity)
        }
        if let renderMaterial = fragment.renderMaterial ?? sourceMaterial {
            _ = world.setComponent(renderMaterial, for: entity)
        }

        if totalMass > 0, impulseMagnitude > 0 {
            let distributedImpulse = command.impulse * (fragment.mass / totalMass)
            if let worldPoint = command.worldPoint {
                _ = world.applyLinearImpulse(distributedImpulse, at: worldPoint, to: entity)
            } else {
                _ = world.applyLinearImpulse(distributedImpulse, to: entity)
            }
        }
        if destructible.separationImpulse > 0 {
            let fragmentPosition = SIMD3<Float>(
                fragmentMatrix.columns.3.x,
                fragmentMatrix.columns.3.y,
                fragmentMatrix.columns.3.z
            )
            let direction = safeNormalized(fragmentPosition - sourcePosition, fallback: .zero)
            if direction != .zero {
                _ = world.applyLinearImpulse(
                    direction * destructible.separationImpulse * fragment.mass,
                    to: entity
                )
            }
        }
        fragmentEntities.append(entity)
        fragmentIDs.append(fragment.fragmentID)
    }

    if !sourceState.hasAuthoredSourceSnapshot {
        sourceState.hasAuthoredSourceSnapshot = true
        sourceState.authoredRigidBody = sourceBody
        sourceState.authoredCollider = sourceCollider
        sourceState.authoredRenderMesh = sourceRenderMesh
    }
    _ = world.removeComponent(Collider.self, from: command.entity)
    _ = world.removeComponent(RigidBody.self, from: command.entity)
    _ = world.updateComponent(RenderMeshComponent.self, for: command.entity) {
        $0.isVisible = false
    }
    let allConnectionIDs = asset.connections.map(\.connectionID).sorted()
    sourceState.hasFractured = true
    sourceState.brokenConnectionIDs = Set(allConnectionIDs)
    runtime.sources[command.entity] = sourceState

    let cause: DestructionCause
    if command.forceFracture {
        cause = .forced
    } else if connectionDisconnected && !damageExceeded && !impulseExceeded {
        cause = .connectionBreak
    } else if contactDriven || impulseExceeded {
        cause = .contactImpulse
    } else {
        cause = .damage
    }
    appendEvent(
        DestructionEvent(
            sourceEntity: command.entity,
            cause: cause,
            fragmentEntities: fragmentEntities,
            fragmentIDs: fragmentIDs,
            brokenConnectionIDs: allConnectionIDs,
            appliedDamage: sourceState.accumulatedDamage,
            appliedImpulse: impulseMagnitude,
            droppedFragmentCount: orderedFragments.count - fragments.count
        ),
        in: world,
        frame: &frame
    )
    return true
}

private func recycleDestructionFragments(
    in world: inout RuntimeWorld,
    runtime: inout DestructionRuntimeStateResource,
    frame: inout DestructionEventFrameResource
) {
    let fragments = world.entities(with: DestructibleFragment.self)
        .sorted { $0.rawValue < $1.rawValue }
    for entity in fragments {
        guard let fragment = world.component(DestructibleFragment.self, for: entity) else { continue }
        let reason: DestructionRecycleReason?
        if !world.contains(fragment.sourceEntity) {
            reason = .sourceRemoved
        } else if fragment.maximumLifetimeSeconds > 0,
                  runtime.elapsedSeconds - fragment.spawnedAtSeconds
                    >= Double(fragment.maximumLifetimeSeconds) {
            reason = .lifetimeExpired
        } else if fragment.sleepingRecycleDelaySeconds > 0,
                  world.component(RigidBody.self, for: entity)?.isSleeping == true {
            let sleepingSince = runtime.sleepingSinceByFragment[entity] ?? runtime.elapsedSeconds
            runtime.sleepingSinceByFragment[entity] = sleepingSince
            reason = runtime.elapsedSeconds - sleepingSince
                >= Double(fragment.sleepingRecycleDelaySeconds) ? .sleeping : nil
        } else {
            runtime.sleepingSinceByFragment.removeValue(forKey: entity)
            reason = nil
        }
        guard let reason else { continue }
        if world.destroyEntity(entity) {
            runtime.sleepingSinceByFragment.removeValue(forKey: entity)
            appendRecycle(
                DestructionRecycleEvent(
                    sourceEntity: fragment.sourceEntity,
                    fragmentEntity: entity,
                    fragmentID: fragment.fragmentID,
                    reason: reason
                ),
                in: world,
                frame: &frame
            )
        }
    }
    for source in runtime.sources.keys where !world.contains(source) {
        let stillOwned = world.entities(with: DestructibleFragment.self).contains {
            world.component(DestructibleFragment.self, for: $0)?.sourceEntity == source
        }
        if !stillOwned {
            runtime.sources.removeValue(forKey: source)
        }
    }
}

private func publishDestructionState(
    in world: inout RuntimeWorld,
    runtime: DestructionRuntimeStateResource
) {
    var fragmentsBySource: [EntityID: [(EntityID, UInt32)]] = [:]
    for entity in world.entities(with: DestructibleFragment.self) {
        guard let fragment = world.component(DestructibleFragment.self, for: entity) else { continue }
        fragmentsBySource[fragment.sourceEntity, default: []].append((entity, fragment.fragmentID))
    }
    var states: [EntityID: DestructionSourceState] = [:]
    for (source, sourceState) in runtime.sources where world.contains(source) {
        let fragments = (fragmentsBySource[source] ?? []).sorted {
            ($0.1, $0.0.rawValue) < ($1.1, $1.0.rawValue)
        }
        states[source] = DestructionSourceState(
            sourceEntity: source,
            hasFractured: sourceState.hasFractured,
            accumulatedDamage: sourceState.accumulatedDamage,
            brokenConnectionIDs: sourceState.brokenConnectionIDs.sorted(),
            activeFragmentEntities: fragments.map(\.0),
            activeFragmentIDs: fragments.map(\.1)
        )
    }
    world.setDerivedResource(DestructionStateFrameResource(sources: states))
}

private func validateDestructibleAsset(
    _ asset: DestructibleAsset,
    in world: RuntimeWorld
) -> String? {
    guard !asset.fragments.isEmpty else { return "Destructible asset has no fragments" }
    let fragmentIDs = asset.fragments.map(\.fragmentID)
    guard Set(fragmentIDs).count == fragmentIDs.count else {
        return "Destructible asset contains duplicate fragment IDs"
    }
    let connectionIDs = asset.connections.map(\.connectionID)
    guard Set(connectionIDs).count == connectionIDs.count else {
        return "Destructible asset contains duplicate connection IDs"
    }
    let fragmentIDSet = Set(fragmentIDs)
    for connection in asset.connections.sorted(by: { $0.connectionID < $1.connectionID }) {
        guard connection.fragmentA != connection.fragmentB,
              fragmentIDSet.contains(connection.fragmentA),
              fragmentIDSet.contains(connection.fragmentB),
              connection.damageThreshold.isFinite,
              connection.damageThreshold >= 0,
              connection.impulseThreshold.isFinite,
              connection.impulseThreshold >= 0 else {
            return "Connection \(connection.connectionID) is invalid"
        }
    }
    let geometries = world.resource(MeshColliderGeometryResource.self)
    for fragment in asset.fragments.sorted(by: { $0.fragmentID < $1.fragmentID }) {
        guard fragment.mass.isFinite,
              fragment.mass > 0,
              isFinite(fragment.localTransform.matrix),
              !fragment.colliderResourceID.isEmpty,
              let geometry = geometries?.geometry(for: fragment.colliderResourceID),
              hasNonDegenerateConvexVolume(geometry.positions) else {
            return "Fragment \(fragment.fragmentID) has no valid convex geometry"
        }
    }
    return nil
}

private func nearestConnection(
    to worldPoint: SIMD3<Float>,
    among connections: [DestructibleConnectionAsset],
    in asset: DestructibleAsset,
    sourceTransform: simd_float4x4
) -> DestructibleConnectionAsset? {
    let positionsByFragmentID = Dictionary(uniqueKeysWithValues: asset.fragments.map {
        fragment -> (UInt32, SIMD3<Float>) in
        let transform = sourceTransform * fragment.localTransform.matrix
        return (
            fragment.fragmentID,
            SIMD3<Float>(
                transform.columns.3.x,
                transform.columns.3.y,
                transform.columns.3.z
            )
        )
    })
    func squaredDistance(_ connection: DestructibleConnectionAsset) -> Float {
        guard let positionA = positionsByFragmentID[connection.fragmentA],
              let positionB = positionsByFragmentID[connection.fragmentB]
        else { return .greatestFiniteMagnitude }
        let anchor = (positionA + positionB) * 0.5
        return simd_length_squared(worldPoint - anchor)
    }
    return connections.min { lhs, rhs in
        let lhsDistance = squaredDistance(lhs)
        let rhsDistance = squaredDistance(rhs)
        if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
        return lhs.connectionID < rhs.connectionID
    }
}

private func graphIsDisconnected(
    _ asset: DestructibleAsset,
    brokenConnections: Set<UInt32>
) -> Bool {
    guard let root = asset.fragments.map(\.fragmentID).min() else { return false }
    var adjacency: [UInt32: [UInt32]] = [:]
    for connection in asset.connections.sorted(by: { $0.connectionID < $1.connectionID })
    where !brokenConnections.contains(connection.connectionID) {
        adjacency[connection.fragmentA, default: []].append(connection.fragmentB)
        adjacency[connection.fragmentB, default: []].append(connection.fragmentA)
    }
    var visited: Set<UInt32> = [root]
    var queue = [root]
    var index = 0
    while index < queue.count {
        let current = queue[index]
        index += 1
        for neighbor in (adjacency[current] ?? []).sorted() where visited.insert(neighbor).inserted {
            queue.append(neighbor)
        }
    }
    return visited.count != asset.fragments.count
}

private func isValidDestructibleConfiguration(_ destructible: Destructible) -> Bool {
    !destructible.assetResourceID.isEmpty
        && destructible.damageThreshold.isFinite
        && destructible.damageThreshold >= 0
        && destructible.impulseThreshold.isFinite
        && destructible.impulseThreshold >= 0
        && destructible.fragmentBudget >= 0
        && destructible.maximumFragmentLifetimeSeconds.isFinite
        && destructible.maximumFragmentLifetimeSeconds >= 0
        && destructible.sleepingRecycleDelaySeconds.isFinite
        && destructible.sleepingRecycleDelaySeconds >= 0
        && destructible.separationImpulse.isFinite
        && destructible.separationImpulse >= 0
}

private func isValidDestructionCommand(_ command: DestructionCommand) -> Bool {
    command.damage.isFinite
        && command.damage >= 0
        && isFinite(command.impulse)
        && command.worldPoint.map(isFinite) ?? true
}

private func hasNonDegenerateConvexVolume(_ positions: [SIMD3<Float>]) -> Bool {
    guard positions.count >= 4, positions.allSatisfy(isFinite) else { return false }
    let origin = positions[0]
    guard let second = positions.dropFirst().first(where: {
        simd_length_squared($0 - origin) > 1.0e-12
    }) else { return false }
    let firstEdge = second - origin
    guard let third = positions.dropFirst().first(where: {
        simd_length_squared(simd_cross(firstEdge, $0 - origin)) > 1.0e-12
    }) else { return false }
    let normal = simd_cross(firstEdge, third - origin)
    return positions.dropFirst().contains {
        abs(simd_dot(normal, $0 - origin)) > 1.0e-9
    }
}

private func isFinite(_ value: SIMD3<Float>) -> Bool {
    value.x.isFinite && value.y.isFinite && value.z.isFinite
}

private func isFinite(_ matrix: simd_float4x4) -> Bool {
    [matrix.columns.0, matrix.columns.1, matrix.columns.2, matrix.columns.3]
        .allSatisfy { column in
            column.x.isFinite && column.y.isFinite && column.z.isFinite && column.w.isFinite
        }
}

private func safeNormalized(_ value: SIMD3<Float>, fallback: SIMD3<Float>) -> SIMD3<Float> {
    let length = simd_length(value)
    if length > 1.0e-6 { return value / length }
    let fallbackLength = simd_length(fallback)
    if fallbackLength > 1.0e-6 { return fallback / fallbackLength }
    return .zero
}

private func appendEvent(
    _ event: DestructionEvent,
    in world: RuntimeWorld,
    frame: inout DestructionEventFrameResource
) {
    guard destructionEventCount(frame) < destructionEventLimit(world) else {
        frame.didOverflow = true
        return
    }
    frame.events.append(event)
}

private func appendFailure(
    _ event: DestructionFailureEvent,
    in world: RuntimeWorld,
    frame: inout DestructionEventFrameResource
) {
    guard destructionEventCount(frame) < destructionEventLimit(world) else {
        frame.didOverflow = true
        return
    }
    frame.failures.append(event)
}

private func appendRecycle(
    _ event: DestructionRecycleEvent,
    in world: RuntimeWorld,
    frame: inout DestructionEventFrameResource
) {
    guard destructionEventCount(frame) < destructionEventLimit(world) else {
        frame.didOverflow = true
        return
    }
    frame.recycledFragments.append(event)
}

private func destructionEventCount(_ frame: DestructionEventFrameResource) -> Int {
    frame.events.count + frame.failures.count + frame.recycledFragments.count
}

private func destructionEventLimit(_ world: RuntimeWorld) -> Int {
    (world.resource(DestructionSettingsResource.self) ?? DestructionSettingsResource())
        .maximumEventCountPerFrame
}
