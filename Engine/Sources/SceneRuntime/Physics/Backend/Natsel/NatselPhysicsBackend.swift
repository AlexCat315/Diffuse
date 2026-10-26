import Foundation
import SIMDCompat
internal import Natsel

/// Owns an independent Swift physics world. Runtime descriptors remain the persistence boundary;
/// engine handles never escape into scene documents or ECS components.
public final class NatselPhysicsBackend: PhysicsBackend, @unchecked Sendable {
    struct BodyRecord {
        var id: Natsel.BodyID
        var descriptor: PhysicsBodyDescriptor
        var shapes: [Natsel.ShapeID]
    }
    struct ShapeOwner { var entity: EntityID; var child: UInt32 }
    struct Pair: Hashable, Comparable {
        var a: EntityID
        var b: EntityID
        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.a.rawValue == rhs.a.rawValue ? lhs.b.rawValue < rhs.b.rawValue : lhs.a.rawValue < rhs.a.rawValue
        }
    }
    var world = Natsel.World()
    var bodies: [EntityID: BodyRecord] = [:]
    var owners: [Natsel.ShapeID: ShapeOwner] = [:]
    var joints: [EntityID: Natsel.JointID] = [:]
    var jointDescriptors: [EntityID: PhysicsConstraintDescriptor] = [:]
    var contacts: [Pair: PhysicsContactEvent] = [:]
    var triggerPairs: Set<Pair> = []
    var settings = PhysicsSettingsResource()
    var characters: [EntityID: CharacterRecord] = [:]
    var vehicles: [EntityID: VehicleRecord] = [:]
    var softBodies: [EntityID: SoftRecord] = [:]
    var softQuerySurfaces: [EntityID: SoftQuerySurface] = [:]
    var softQuerySurfacesDirty = true
    var initialized = false

    public init() {}

    public var identifier: String { "natsel" }
    public var capabilities: PhysicsBackendCapabilities { .all }

    public func prepare(context: PhysicsPrepareContext) -> PhysicsPrepareResult {
        settings = context.settings
        world.gravity = nv(settings.gravity)
        world.enableSleep = settings.allowSleep
        world.enableDynamicContinuous = true
        world.workerCount = Int32(min(32, settings.capacity.workerThreadCount == 0
            ? max(1, ProcessInfo.processInfo.activeProcessorCount - 1) : settings.capacity.workerThreadCount))
        let full = context.isFullSnapshot || !initialized
        var result = PhysicsPrepareResult()
        guard context.activeBodies.count + context.activeSoftBodies.count <= settings.capacity.maxBodies else {
            result.error = PhysicsBackendError(code: .bodyCreationFailed, message: "Natsel body capacity exceeded")
            return result
        }
        var updates: [EntityID: PhysicsBodyDescriptor] = [:]
        var jointUpdates: [EntityID: PhysicsConstraintDescriptor] = [:]
        var removals: Set<EntityID> = []
        var jointRemovals: Set<EntityID> = []
        if full {
            updates = Dictionary(uniqueKeysWithValues: context.activeBodies.map { ($0.entity, $0) })
            jointUpdates = Dictionary(uniqueKeysWithValues: context.activeConstraints.map { ($0.entity, $0) })
            removals = Set(bodies.keys).subtracting(updates.keys)
            jointRemovals = Set(joints.keys).subtracting(jointUpdates.keys)
        } else {
            for event in context.syncEvents {
                switch event {
                case .bodyUpsert(let value): updates[value.entity] = value; removals.remove(value.entity)
                case .bodyRemove(let entity): removals.insert(entity); updates.removeValue(forKey: entity)
                case .constraintUpsert(let value): jointUpdates[value.entity] = value; jointRemovals.remove(value.entity)
                case .constraintRemove(let entity): jointRemovals.insert(entity); jointUpdates.removeValue(forKey: entity)
                default: break
                }
            }
        }
        // A rejected upsert can remove its old native body. Retry missing active descriptors
        // even when the next prepare contains no new ECS event.
        for descriptor in context.activeBodies where bodies[descriptor.entity] == nil && !removals.contains(descriptor.entity) {
            updates[descriptor.entity] = descriptor
        }
        for entity in jointRemovals.sorted(by: entityOrder) { removeJoint(entity); result.removedConstraints += 1 }
        for entity in removals.sorted(by: entityOrder) { removeBody(entity); result.removedBodies += 1 }
        do {
            for entity in updates.keys.sorted(by: entityOrder) {
                try upsertBody(updates[entity]!)
                result.synchronizedBodies += 1
            }
            // Recreate dependent constraints only when authored configuration or body handles change.
            for descriptor in context.activeConstraints.sorted(by: { entityOrder($0.entity, $1.entity) }) {
                if jointUpdates[descriptor.entity] != nil || joints[descriptor.entity] == nil {
                    try upsertJoint(descriptor)
                    result.synchronizedConstraints += 1
                }
            }
            try synchronizeFeatures(context, result: &result)
            initialized = true
        } catch let error as PhysicsBackendError { result.error = error }
        catch { result.error = PhysicsBackendError(code: .unknown, message: String(describing: error)) }
        return result
    }

    func upsertBody(_ descriptor: PhysicsBodyDescriptor) throws {
        let entity = descriptor.entity
        if let old = bodies[entity] {
            let shapeChanged = old.descriptor.collider != descriptor.collider
                || old.descriptor.meshGeometry != descriptor.meshGeometry
                || scale(old.descriptor.worldTransform.matrix) != scale(descriptor.worldTransform.matrix)
                || old.descriptor.rigidBody?.axisLocks != descriptor.rigidBody?.axisLocks
            if shapeChanged { removeBody(entity) }
        }
        let rigid = descriptor.rigidBody
        let isNew = bodies[entity] == nil
        if bodies[entity] == nil {
            var def = Natsel.BodyDef()
            def.type = bodyType(rigid?.motionType ?? .static)
            def.position = Natsel.Pos(nv(descriptor.worldTransform.translation))
            def.rotation = nq(rotation(descriptor.worldTransform.matrix).vector)
            def.linearVelocity = nv(rigid?.linearVelocity ?? .zero)
            def.angularVelocity = nv(rigid?.angularVelocity ?? .zero)
            def.linearDamping = max(0, rigid?.linearDamping ?? 0)
            def.angularDamping = max(0, rigid?.angularDamping ?? 0)
            def.gravityScale = rigid?.gravityScale ?? 0
            def.enableSleep = settings.allowSleep && (rigid?.allowSleep ?? true)
            def.isAwake = !(rigid?.isSleeping ?? false)
            def.isBullet = rigid?.motionQuality == .linearCast || rigid?.continuousCollisionDetection == true
            def.allowFastRotation = true
            let locks = rigid?.axisLocks ?? []
            def.motionLocks = Natsel.MotionLocks(linearX: locks.contains(.translationX), linearY: locks.contains(.translationY),
                linearZ: locks.contains(.translationZ), angularX: locks.contains(.rotationX),
                angularY: locks.contains(.rotationY), angularZ: locks.contains(.rotationZ))
            let id = world.createBody(def)
            guard world.bodyIsValid(id) else { throw failure(.bodyCreationFailed, "Could not create Natsel body") }
            do {
                let shapes = try createShapes(descriptor, body: id)
                bodies[entity] = BodyRecord(id: id, descriptor: descriptor, shapes: shapes)
                for (child, shape) in shapes.enumerated() { owners[shape] = ShapeOwner(entity: entity, child: UInt32(child)) }
            } catch { world.destroyBody(id); throw error }
        }
        guard var record = bodies[entity] else { return }
        world.setBodyType(record.id, bodyType(rigid?.motionType ?? .static))
        if record.descriptor.worldTransform != descriptor.worldTransform {
            world.setBodyTransform(record.id, Natsel.Pos(nv(descriptor.worldTransform.translation)), nq(rotation(descriptor.worldTransform.matrix).vector))
        }
        if let rigid {
            world.setBodyLinearDamping(record.id, max(0, rigid.linearDamping))
            world.setBodyAngularDamping(record.id, max(0, rigid.angularDamping))
            world.setBodyGravityScale(record.id, rigid.gravityScale)
            world.setBodyBullet(record.id, rigid.motionQuality == .linearCast || rigid.continuousCollisionDetection)
            world.enableBodySleep(record.id, settings.allowSleep && rigid.allowSleep)
            if record.descriptor.rigidBody?.isSleeping != rigid.isSleeping { world.setBodyAwake(record.id, !rigid.isSleeping) }
            let previous = record.descriptor.rigidBody
            if rigid.motionType == .dynamic && (isNew || previous?.motionType != .dynamic
                || previous?.mass != rigid.mass || previous?.massMode != rigid.massMode
                || previous?.centerOfMassOverride != rigid.centerOfMassOverride
                || previous?.inertiaDiagonalOverride != rigid.inertiaDiagonalOverride) {
                configureMass(record.id, rigid)
            }
        }
        record.descriptor = descriptor
        bodies[entity] = record
    }

    func configureMass(_ id: Natsel.BodyID, _ rigid: RigidBody) {
        world.applyBodyMassFromShapes(id)
        var data = world.bodyMassData(id)
        if rigid.massMode == .mass {
            let ratio = data.mass > 0 ? max(0.0001, rigid.mass) / data.mass : 1
            data.mass = max(0.0001, rigid.mass)
            data.inertia = Natsel.mulSM(ratio, data.inertia)
        }
        if let center = rigid.centerOfMassOverride { data.center = nv(center) }
        if let inertia = rigid.inertiaDiagonalOverride {
            data.inertia = Natsel.Matrix3(nv(SIMD3<Float>(inertia.x, 0, 0)), nv(SIMD3<Float>(0, inertia.y, 0)), nv(SIMD3<Float>(0, 0, inertia.z)))
        }
        world.setBodyMassData(id, data)
    }

    func removeJoint(_ entity: EntityID) {
        if let id = joints.removeValue(forKey: entity), world.jointIsValid(id) {
            // Natsel 0.2 exposes joint destruction by pool index. Validate the generation before
            // decoding its public stored-id format, keeping that detail inside this adapter.
            world.destroyJoint(Int32(truncatingIfNeeded: id.stored >> 32) - 1, true)
        }
        jointDescriptors.removeValue(forKey: entity)
    }

    func removeBody(_ entity: EntityID) {
        for (joint, descriptor) in jointDescriptors where descriptor.constraint.entityA == entity || descriptor.constraint.entityB == entity {
            removeJoint(joint)
        }
        if let vehicle = vehicles.removeValue(forKey: entity) { world.destroyVehicle(vehicle.id) }
        guard let record = bodies.removeValue(forKey: entity) else { return }
        for shape in record.shapes { owners.removeValue(forKey: shape) }
        world.destroyBody(record.id)
    }

    public func step(context: PhysicsStepContext) -> PhysicsStepResult {
        for (entity, command) in context.vehicleCommands {
            guard let gear = command.manualGear, let config = vehicles[entity]?.descriptor.vehicle.transmission else { continue }
            if gear > config.gearRatios.count || gear < -config.reverseGearRatios.count {
                return PhysicsStepResult(error: failure(.invalidArgument, "Vehicle gear is outside the configured transmission"))
            }
        }
        world.gravity = nv(context.settings.gravity)
        world.enableSleep = context.settings.allowSleep
        var maximumSpeed: Float = 1
        for descriptor in context.activeBodies {
            guard let record = bodies[descriptor.entity], let rigid = descriptor.rigidBody else { continue }
            maximumSpeed = max(maximumSpeed, rigid.maxLinearVelocity)
            if let target = rigid.kinematicTarget, rigid.motionType == .kinematic {
                world.setBodyTargetTransform(record.id, Natsel.WorldTransform(Natsel.Pos(nv(target.position)), nq(target.rotation)), timeStep: Float(context.stepDeltaSeconds))
            } else if context.stepIndex == 0 {
                world.setBodyLinearVelocity(record.id, nv(clamped(rigid.linearVelocity, rigid.maxLinearVelocity)))
                world.setBodyAngularVelocity(record.id, nv(clamped(rigid.angularVelocity, rigid.maxAngularVelocity)))
            }
            if context.stepIndex == 0 {
                if rigid.accumulatedLinearImpulse != .zero { world.applyBodyLinearImpulseToCenter(record.id, nv(rigid.accumulatedLinearImpulse), true) }
                if rigid.accumulatedAngularImpulse != .zero { world.applyBodyAngularImpulse(record.id, nv(rigid.accumulatedAngularImpulse), true) }
                if rigid.accumulatedForce != .zero { world.applyBodyForceToCenter(record.id, nv(rigid.accumulatedForce), true) }
                if rigid.accumulatedTorque != .zero { world.applyBodyTorque(record.id, nv(rigid.accumulatedTorque), true) }
            }
        }
        if !characters.isEmpty { ensureSoftQuerySurfaces() }
        let characterStates = stepCharacters(context)
        for record in characters.values {
            maximumSpeed = max(maximumSpeed, Natsel.length(world.bodyLinearVelocity(record.character.innerBodyId)))
        }
        world.maxLinearSpeed = maximumSpeed
        applyVehicleCommands(context)
        var jointErrors: [EntityID: Float] = [:]
        for (entity, descriptor) in jointDescriptors where descriptor.constraint.breakForce < .greatestFiniteMagnitude {
            jointErrors[entity] = jointPositionError(descriptor.constraint)
        }
        world.step(Float(context.stepDeltaSeconds), subStepCount: Int32(context.settings.collisionSteps))
        softQuerySurfacesDirty = true
        var events = collectContacts()
        let triggers = detectTriggerFrame(maxEventCount: Int.max)
        let entered = Set(triggers.enters.map { Pair(a: $0.triggerEntity, b: $0.otherEntity) })
        events += triggers.enters.map { PhysicsContactEvent(entityA: $0.triggerEntity, entityB: $0.otherEntity, kind: .began) }
        events += triggers.active.filter { !entered.contains(Pair(a: $0.triggerEntity, b: $0.otherEntity)) }.map {
            PhysicsContactEvent(entityA: $0.triggerEntity, entityB: $0.otherEntity, kind: .stayed)
        }
        events += triggers.exits.map { PhysicsContactEvent(entityA: $0.triggerEntity, entityB: $0.otherEntity, kind: .ended) }
        var breaks: [PhysicsJointBreakEvent] = []
        for entity in joints.keys.sorted(by: entityOrder) {
            guard let id = joints[entity], let joint = jointDescriptors[entity]?.constraint else { continue }
            var force = Natsel.length(world.jointConstraintForce(id) ?? .zero)
            // Natsel's split position solve removes its bias velocity in the relax pass. Account
            // for that positional reaction when evaluating authored break thresholds.
            if let before = jointErrors[entity], let a = bodies[joint.entityA], let b = bodies[joint.entityB] {
                let inverseMass = world.bodyInverseMass(a.id) + world.bodyInverseMass(b.id)
                let correction = max(0, before - jointPositionError(joint))
                if inverseMass > 0 { force = max(force, correction / (inverseMass * Float(context.stepDeltaSeconds * context.stepDeltaSeconds))) }
            }
            let torque = Natsel.length(world.jointConstraintTorque(id) ?? .zero)
            if force > joint.breakForce || torque > joint.breakTorque {
                breaks.append(PhysicsJointBreakEvent(jointEntity: entity, entityA: joint.entityA, entityB: joint.entityB, force: force, torque: torque))
                removeJoint(entity)
            }
        }
        let writebacks = context.activeBodies.compactMap { descriptor -> PhysicsBodyWriteback? in
            guard var record = bodies[descriptor.entity], let rigid = descriptor.rigidBody, rigid.motionType != .static else { return nil }
            let pose = world.bodyTransform(record.id)
            let rotation = simd_quatf(vector: SIMD4<Float>(sv(pose.q.v), pose.q.s))
            let matrix = matrix(translation: sv(pose.p), rotation: rotation, scale: scale(descriptor.worldTransform.matrix))
            let transform = WorldTransform(matrix: matrix)
            let linear = clamped(sv(world.bodyLinearVelocity(record.id)), rigid.maxLinearVelocity)
            let angular = clamped(sv(world.bodyAngularVelocity(record.id)), rigid.maxAngularVelocity)
            let asleep = !world.isBodyAwake(record.id)
            // ECS writebacks must not look like authored teleports on the next prepare.
            record.descriptor.worldTransform = transform
            record.descriptor.rigidBody?.linearVelocity = linear
            record.descriptor.rigidBody?.angularVelocity = angular
            record.descriptor.rigidBody?.isSleeping = asleep
            bodies[descriptor.entity] = record
            let completeWriteback = context.stepIndex > 0
            guard completeWriteback || transform != descriptor.worldTransform || linear != rigid.linearVelocity
                || angular != rigid.angularVelocity || asleep != rigid.isSleeping else { return nil }
            // Later substeps must overwrite earlier values even if they return to the initial state.
            return PhysicsBodyWriteback(entity: descriptor.entity, worldTransform: completeWriteback || transform != descriptor.worldTransform ? transform : nil,
                linearVelocity: completeWriteback || linear != rigid.linearVelocity ? linear : nil,
                angularVelocity: completeWriteback || angular != rigid.angularVelocity ? angular : nil,
                isSleeping: completeWriteback || asleep != rigid.isSleeping ? asleep : nil)
        }
        return PhysicsStepResult(bodyCount: bodies.count + softBodies.count, constraintCount: joints.count,
            contactCount: max(world.touchingContactCount().asInt, contacts.count), writebacks: writebacks, contactEvents: events,
            jointBreakEvents: breaks, characterStates: characterStates, vehicleStates: vehicleStates(), softBodyStates: softStates())
    }

    func collectContacts() -> [PhysicsContactEvent] {
        var current: [Pair: PhysicsContactEvent] = [:]
        for entity in bodies.keys.sorted(by: entityOrder) {
            let record = bodies[entity]!
            for contact in world.bodyContactData(record.id, capacity: Int.max) {
                guard let a = shapeOwner(contact.shapeIdA), let b = shapeOwner(contact.shapeIdB), a.entity != b.entity else { continue }
                let pair = Pair(a: a.entity.rawValue < b.entity.rawValue ? a.entity : b.entity,
                                b: a.entity.rawValue < b.entity.rawValue ? b.entity : a.entity)
                guard current[pair] == nil else { continue }
                var event = PhysicsContactEvent(entityA: a.entity, entityB: b.entity, subShapeIDA: a.child, subShapeIDB: b.child,
                    kind: contacts[pair] == nil ? .began : .stayed)
                if let manifold = contact.manifolds.first, manifold.pointCount > 0 {
                    let point = manifold.points[0]
                    event.normal = sv(manifold.normal)
                    event.position = sv(Natsel.offsetPos(world.bodyWorldCenter(world.shapeBody(contact.shapeIdA)), point.anchorA))
                    event.penetrationDepth = max(0, -point.separation)
                    event.impulse = point.normalImpulse
                }
                event.relativeVelocity = sv(world.bodyLinearVelocity(world.shapeBody(contact.shapeIdB)) - world.bodyLinearVelocity(world.shapeBody(contact.shapeIdA)))
                current[pair] = event
            }
        }
        // CCD may stop at impact before a persistent manifold exists. Publish that contact in
        // the same frame; the pair cache then supplies stayed/ended transitions as usual.
        for impact in world.continuousImpacts() {
            guard let a = shapeOwner(impact.shapeIdA), let b = shapeOwner(impact.shapeIdB), a.entity != b.entity else { continue }
            let pair = Pair(a: a.entity.rawValue < b.entity.rawValue ? a.entity : b.entity,
                            b: a.entity.rawValue < b.entity.rawValue ? b.entity : a.entity)
            guard current[pair] == nil else { continue }
            current[pair] = PhysicsContactEvent(entityA: a.entity, entityB: b.entity,
                subShapeIDA: a.child, subShapeIDB: b.child, kind: contacts[pair] == nil ? .began : .stayed,
                position: sv(impact.point), normal: sv(impact.normal),
                relativeVelocity: sv(world.bodyLinearVelocity(world.shapeBody(impact.shapeIdB)) - world.bodyLinearVelocity(world.shapeBody(impact.shapeIdA))))
        }
        var result = current.keys.sorted().map { current[$0]! }
        for pair in contacts.keys.sorted() where current[pair] == nil { var event = contacts[pair]!; event.kind = .ended; result.append(event) }
        contacts = current
        return result
    }

    public func reset() {
        for record in characters.values { record.character.destroy() }
        characters.removeAll(); vehicles.removeAll(); softBodies.removeAll()
        softQuerySurfaces.removeAll(); softQuerySurfacesDirty = true
        bodies.removeAll(); owners.removeAll(); joints.removeAll(); jointDescriptors.removeAll()
        contacts.removeAll(); triggerPairs.removeAll()
        world = Natsel.World()
        initialized = false
    }

    func failure(_ code: PhysicsBackendErrorCode, _ message: String) -> PhysicsBackendError { PhysicsBackendError(code: code, message: message) }
    func entityOrder(_ a: EntityID, _ b: EntityID) -> Bool { a.rawValue < b.rawValue }
    func nv(_ v: SIMD3<Float>) -> Natsel.Vec3 { Natsel.Vec3(v.x, v.y, v.z) }
    func sv(_ v: Natsel.Vec3) -> SIMD3<Float> { SIMD3(v.x, v.y, v.z) }
    func sv(_ v: Natsel.Pos) -> SIMD3<Float> { SIMD3(Float(v.x), Float(v.y), Float(v.z)) }
    func nq(_ q: SIMD4<Float>) -> Natsel.Quat { Natsel.normalizeQuat(Natsel.Quat(Natsel.Vec3(q.x, q.y, q.z), q.w)) }
    func bodyType(_ type: RigidBodyMotionType) -> Natsel.BodyType {
        switch type { case .static: .staticBody; case .dynamic: .dynamicBody; case .kinematic: .kinematicBody }
    }
    func clamped(_ value: SIMD3<Float>, _ maximum: Float) -> SIMD3<Float> {
        let length = simd_length(value)
        return length > maximum && length > 0 ? value * (maximum / length) : value
    }
    func scale(_ matrix: simd_float4x4) -> SIMD3<Float> {
        SIMD3(simd_length(SIMD3(matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z)),
              simd_length(SIMD3(matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z)),
              simd_length(SIMD3(matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z)))
    }
    func rotation(_ matrix: simd_float4x4) -> simd_quatf {
        let s = scale(matrix)
        return simd_quatf(simd_float3x3(columns: (
            SIMD3(matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z) / max(s.x, 0.000001),
            SIMD3(matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z) / max(s.y, 0.000001),
            SIMD3(matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z) / max(s.z, 0.000001))))
    }
    func matrix(translation: SIMD3<Float>, rotation: simd_quatf, scale: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(columns: (SIMD4(rotation.act(SIMD3(1, 0, 0)) * scale.x, 0),
            SIMD4(rotation.act(SIMD3(0, 1, 0)) * scale.y, 0), SIMD4(rotation.act(SIMD3(0, 0, 1)) * scale.z, 0), SIMD4(translation, 1)))
    }
}

private extension Int32 { var asInt: Int { Int(self) } }
