import Foundation
import SIMDCompat

public enum PhysicsContactEventKind: String, Sendable, Equatable {
    case began
    case stayed
    case ended
}

public struct PhysicsContactEvent: Sendable, Equatable {
    public var entityA: EntityID
    public var entityB: EntityID
    public var subShapeIDA: UInt32
    public var subShapeIDB: UInt32
    public var kind: PhysicsContactEventKind
    public var position: SIMD3<Float>
    public var normal: SIMD3<Float>
    public var penetrationDepth: Float
    public var relativeVelocity: SIMD3<Float>
    public var impulse: Float

    public init(
        entityA: EntityID,
        entityB: EntityID,
        subShapeIDA: UInt32 = 0,
        subShapeIDB: UInt32 = 0,
        kind: PhysicsContactEventKind,
        position: SIMD3<Float> = .zero,
        normal: SIMD3<Float> = .zero,
        penetrationDepth: Float = 0,
        relativeVelocity: SIMD3<Float> = .zero,
        impulse: Float = 0
    ) {
        self.entityA = entityA
        self.entityB = entityB
        self.subShapeIDA = subShapeIDA
        self.subShapeIDB = subShapeIDB
        self.kind = kind
        self.position = position
        self.normal = normal
        self.penetrationDepth = penetrationDepth
        self.relativeVelocity = relativeVelocity
        self.impulse = impulse
    }
}

public struct PhysicsEventFrameResource: Sendable, Equatable {
    public var contacts: [PhysicsContactEvent]
    public var triggers: [TriggerEvent]
    public var jointBreaks: [PhysicsJointBreakEvent]
    public var didOverflow: Bool

    public init(
        contacts: [PhysicsContactEvent] = [],
        triggers: [TriggerEvent] = [],
        jointBreaks: [PhysicsJointBreakEvent] = [],
        didOverflow: Bool = false
    ) {
        self.contacts = contacts
        self.triggers = triggers
        self.jointBreaks = jointBreaks
        self.didOverflow = didOverflow
    }

    public static let empty = PhysicsEventFrameResource()
}

public struct PhysicsJointBreakEvent: Sendable, Equatable {
    public var jointEntity: EntityID
    public var entityA: EntityID
    public var entityB: EntityID
    public var force: Float
    public var torque: Float

    public init(jointEntity: EntityID, entityA: EntityID, entityB: EntityID,
                force: Float, torque: Float) {
        self.jointEntity = jointEntity
        self.entityA = entityA
        self.entityB = entityB
        self.force = force
        self.torque = torque
    }
}

public struct PhysicsContactFrameResource: Sendable, Equatable {
    public var began: [PhysicsContactEvent]
    public var stayed: [PhysicsContactEvent]
    public var ended: [PhysicsContactEvent]

    public init(
        began: [PhysicsContactEvent] = [],
        stayed: [PhysicsContactEvent] = [],
        ended: [PhysicsContactEvent] = []
    ) {
        self.began = began
        self.stayed = stayed
        self.ended = ended
    }

    public init(events: [PhysicsContactEvent]) {
        began = events.filter { $0.kind == .began }
        stayed = events.filter { $0.kind == .stayed }
        ended = events.filter { $0.kind == .ended }
    }

    public var events: [PhysicsContactEvent] {
        began + stayed + ended
    }

    public static let empty = PhysicsContactFrameResource()
}
