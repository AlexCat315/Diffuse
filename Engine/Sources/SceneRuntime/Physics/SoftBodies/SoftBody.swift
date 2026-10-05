import Foundation
import SIMDCompat

/// An arbitrary triangle surface used as Jolt soft-body topology.
///
/// Geometry remains in `MeshColliderGeometryResource`, keyed by `resourceID`,
/// so scenes and prefabs serialize only a stable asset reference and constraint
/// configuration instead of duplicating large vertex/index arrays. A geometry
/// with four-index `tetrahedronIndices` additionally creates internal edge and
/// volume constraints.
public struct SoftBodyMesh: RuntimeComponent, Sendable, Equatable {
    public var resourceID: String?
    public var fixedVertexIndices: [Int]
    public var compliance: Float
    public var shearCompliance: Float
    public var bendCompliance: Float
    public var volumeCompliance: Float
    public var bendType: ClothBendType

    public init(
        resourceID: String? = nil,
        fixedVertexIndices: [Int] = [],
        compliance: Float = 1.0e-5,
        shearCompliance: Float = 1.0e-5,
        bendCompliance: Float = 1.0e-5,
        volumeCompliance: Float = 1.0e-6,
        bendType: ClothBendType = .dihedral
    ) {
        let trimmedResourceID = resourceID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.resourceID = trimmedResourceID?.isEmpty == false ? trimmedResourceID : nil
        self.fixedVertexIndices = Array(Set(fixedVertexIndices.filter { $0 >= 0 })).sorted()
        self.compliance = max(0, compliance)
        self.shearCompliance = max(0, shearCompliance)
        self.bendCompliance = max(0, bendCompliance)
        self.volumeCompliance = max(0, volumeCompliance)
        self.bendType = bendType
    }
}

/// Simulation and collision settings shared by deformable assets.
/// M6 supports `Cloth` and arbitrary triangle-surface `SoftBodyMesh` topologies;
/// volumetric assets can use the same component without changing the state stream.
public struct SoftBody: RuntimeComponent, Sendable, Equatable {
    public var vertexMass: Float
    public var pressure: Float
    public var linearDamping: Float
    public var friction: Float
    public var restitution: Float
    public var gravityScale: Float
    public var vertexRadius: Float
    public var solverIterations: Int
    public var maxLinearVelocity: Float
    public var layerID: UInt16
    public var layerMask: UInt16
    public var allowSleep: Bool
    public var facesDoubleSided: Bool
    public var selfCollision: Bool
    public var isEnabled: Bool

    public init(
        vertexMass: Float = 1,
        pressure: Float = 0,
        linearDamping: Float = 0.1,
        friction: Float = 0.2,
        restitution: Float = 0,
        gravityScale: Float = 1,
        vertexRadius: Float = 0.02,
        solverIterations: Int = 5,
        maxLinearVelocity: Float = 500,
        layerID: UInt16 = 0,
        layerMask: UInt16 = .max,
        allowSleep: Bool = true,
        facesDoubleSided: Bool = true,
        selfCollision: Bool = false,
        isEnabled: Bool = true
    ) {
        self.vertexMass = max(0.0001, vertexMass)
        self.pressure = max(0, pressure)
        self.linearDamping = max(0, linearDamping)
        self.friction = max(0, friction)
        self.restitution = max(0, min(restitution, 1))
        self.gravityScale = gravityScale
        self.vertexRadius = max(0, vertexRadius)
        self.solverIterations = max(1, min(solverIterations, 128))
        self.maxLinearVelocity = max(0, maxLinearVelocity)
        self.layerID = layerID
        self.layerMask = layerMask
        self.allowSleep = allowSleep
        self.facesDoubleSided = facesDoubleSided
        self.selfCollision = selfCollision
        self.isEnabled = isEnabled
    }
}

/// Deformed vertices are streamed independently from ordinary ECS transforms.
public struct SoftBodyMeshState: Sendable, Equatable {
    public var entity: EntityID
    public var positions: [SIMD3<Float>]
    public var triangleIndices: [UInt32]
    public var isSleeping: Bool

    public init(
        entity: EntityID,
        positions: [SIMD3<Float>] = [],
        triangleIndices: [UInt32] = [],
        isSleeping: Bool = false
    ) {
        self.entity = entity
        self.positions = positions
        self.triangleIndices = triangleIndices
        self.isSleeping = isSleeping
    }
}

public struct SoftBodyStateFrameResource: Sendable, Equatable {
    public var states: [EntityID: SoftBodyMeshState]
    public var vertexCount: Int

    public init(states: [EntityID: SoftBodyMeshState] = [:]) {
        self.states = states
        vertexCount = states.values.reduce(0) { $0 + $1.positions.count }
    }

    public static let empty = SoftBodyStateFrameResource()
}
