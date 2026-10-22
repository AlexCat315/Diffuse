/// Optional simulation features a backend implements beyond rigid bodies,
/// colliders, basic joints, and queries.
public struct PhysicsBackendCapabilities: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let characters = PhysicsBackendCapabilities(rawValue: 1 << 0)
    public static let vehicles = PhysicsBackendCapabilities(rawValue: 1 << 1)
    public static let softBodies = PhysicsBackendCapabilities(rawValue: 1 << 2)
    public static let coneJoints = PhysicsBackendCapabilities(rawValue: 1 << 3)
    public static let sixDOFJoints = PhysicsBackendCapabilities(rawValue: 1 << 4)
    public static let cylinderColliders = PhysicsBackendCapabilities(rawValue: 1 << 5)

    public static let all: PhysicsBackendCapabilities = [
        .characters, .vehicles, .softBodies, .coneJoints, .sixDOFJoints, .cylinderColliders,
    ]
}

extension PhysicsBackendCapabilities {
    /// The optional features a frame's descriptors depend on.
    init(
        requiredByBodies bodies: [PhysicsBodyDescriptor],
        constraints: [PhysicsConstraintDescriptor],
        characters: [PhysicsCharacterDescriptor],
        vehicles: [PhysicsVehicleDescriptor],
        softBodies: [PhysicsSoftBodyDescriptor]
    ) {
        self = []
        if !characters.isEmpty { insert(.characters) }
        if !vehicles.isEmpty { insert(.vehicles) }
        if !softBodies.isEmpty { insert(.softBodies) }
        for descriptor in constraints {
            switch descriptor.constraint.configuration.kind {
            case .cone: insert(.coneJoints)
            case .sixDOF: insert(.sixDOFJoints)
            default: break
            }
        }
        let usesCylinders = bodies.contains { descriptor in
            descriptor.collider?.shapes.contains { $0.shape.kind == .cylinder } == true
        }
        if usesCylinders { insert(.cylinderColliders) }
    }
}
