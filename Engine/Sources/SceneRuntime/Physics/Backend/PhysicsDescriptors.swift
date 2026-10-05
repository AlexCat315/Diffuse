import Foundation
import SIMDCompat

public struct PhysicsBodyDescriptor: Sendable, Equatable {
    public var entity: EntityID
    public var localTransform: LocalTransform
    public var worldTransform: WorldTransform
    public var rigidBody: RigidBody?
    public var collider: Collider?
    public var meshGeometry: MeshColliderGeometry?

    public init(
        entity: EntityID,
        localTransform: LocalTransform,
        worldTransform: WorldTransform,
        rigidBody: RigidBody?,
        collider: Collider?,
        meshGeometry: MeshColliderGeometry? = nil
    ) {
        self.entity = entity
        self.localTransform = localTransform
        self.worldTransform = worldTransform
        self.rigidBody = rigidBody
        self.collider = collider
        self.meshGeometry = meshGeometry
    }
}

public struct PhysicsConstraintDescriptor: Sendable, Equatable {
    public var entity: EntityID
    public var worldTransform: WorldTransform
    public var constraint: Constraint

    public init(entity: EntityID, worldTransform: WorldTransform, constraint: Constraint) {
        self.entity = entity
        self.worldTransform = worldTransform
        self.constraint = constraint
    }
}

public struct PhysicsCharacterDescriptor: Sendable, Equatable {
    public var entity: EntityID
    public var worldTransform: WorldTransform
    public var controller: CharacterController

    public init(entity: EntityID, worldTransform: WorldTransform, controller: CharacterController) {
        self.entity = entity
        self.worldTransform = worldTransform
        self.controller = controller
    }
}

public struct PhysicsVehicleDescriptor: Sendable, Equatable {
    public var entity: EntityID
    public var vehicle: Vehicle

    public init(entity: EntityID, vehicle: Vehicle) {
        self.entity = entity
        self.vehicle = vehicle
    }
}

public enum PhysicsSoftBodyTopology: Sendable, Equatable {
    case cloth(Cloth)
    case surfaceMesh(SoftBodyMesh, MeshColliderGeometry?)
    case invalid

    public var vertexCount: Int {
        switch self {
        case let .cloth(cloth):
            return cloth.vertexCount
        case let .surfaceMesh(_, geometry):
            return geometry?.positions.count ?? 0
        case .invalid:
            return 0
        }
    }

    public var triangleIndices: [UInt32] {
        switch self {
        case let .cloth(cloth):
            return cloth.triangleIndices
        case let .surfaceMesh(_, geometry):
            return geometry?.triangleIndices ?? []
        case .invalid:
            return []
        }
    }

    public var fixedVertexIndices: [Int] {
        switch self {
        case let .cloth(cloth):
            return cloth.fixedVertexIndices
        case let .surfaceMesh(mesh, _):
            return mesh.fixedVertexIndices
        case .invalid:
            return []
        }
    }
}

public struct PhysicsSoftBodyDescriptor: Sendable, Equatable {
    public var entity: EntityID
    public var worldTransform: WorldTransform
    public var softBody: SoftBody
    public var topology: PhysicsSoftBodyTopology

    public init(
        entity: EntityID,
        worldTransform: WorldTransform,
        softBody: SoftBody,
        topology: PhysicsSoftBodyTopology
    ) {
        self.entity = entity
        self.worldTransform = worldTransform
        self.softBody = softBody
        self.topology = topology
    }

    public init(
        entity: EntityID,
        worldTransform: WorldTransform,
        softBody: SoftBody,
        cloth: Cloth
    ) {
        self.init(
            entity: entity,
            worldTransform: worldTransform,
            softBody: softBody,
            topology: .cloth(cloth)
        )
    }
}
