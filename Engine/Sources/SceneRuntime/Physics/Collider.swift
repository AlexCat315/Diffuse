import Foundation
import SIMDCompat

public enum ColliderShapeKind: String, CaseIterable, Sendable, Equatable {
    case box
    case sphere
    case capsule
    case cylinder
    case heightField
    case mesh
    case convex
}

public enum ColliderShape: Sendable, Equatable {
    case box(halfExtents: SIMD3<Float>, center: SIMD3<Float>)
    case sphere(radius: Float, center: SIMD3<Float>)
    case capsule(radius: Float, halfHeight: Float, center: SIMD3<Float>)
    case cylinder(radius: Float, halfHeight: Float, center: SIMD3<Float>)
    case heightField(resourceID: String?, center: SIMD3<Float>)
    case mesh(resourceID: String?, center: SIMD3<Float>)
    case convex(resourceID: String?, center: SIMD3<Float>)

    public var kind: ColliderShapeKind {
        switch self {
        case .box: return .box
        case .sphere: return .sphere
        case .capsule: return .capsule
        case .cylinder: return .cylinder
        case .heightField: return .heightField
        case .mesh: return .mesh
        case .convex: return .convex
        }
    }

    public var center: SIMD3<Float> {
        switch self {
        case let .box(_, center),
             let .sphere(_, center),
             let .capsule(_, _, center),
             let .cylinder(_, _, center),
             let .heightField(_, center),
             let .mesh(_, center),
             let .convex(_, center):
            return center
        }
    }

    public var resourceID: String? {
        switch self {
        case let .mesh(resourceID, _),
             let .heightField(resourceID, _),
             let .convex(resourceID, _):
            return resourceID
        default:
            return nil
        }
    }

    public func replacingCenter(with center: SIMD3<Float>) -> ColliderShape {
        switch self {
        case let .box(halfExtents, _):
            return .box(halfExtents: halfExtents, center: center)
        case let .sphere(radius, _):
            return .sphere(radius: radius, center: center)
        case let .capsule(radius, halfHeight, _):
            return .capsule(radius: radius, halfHeight: halfHeight, center: center)
        case let .cylinder(radius, halfHeight, _):
            return .cylinder(radius: radius, halfHeight: halfHeight, center: center)
        case let .heightField(resourceID, _):
            return .heightField(resourceID: resourceID, center: center)
        case let .mesh(resourceID, _):
            return .mesh(resourceID: resourceID, center: center)
        case let .convex(resourceID, _):
            return .convex(resourceID: resourceID, center: center)
        }
    }
}

public struct ColliderShapeInstance: Sendable, Equatable {
    public var shape: ColliderShape
    public var localPosition: SIMD3<Float>
    /// Quaternion encoded as (x, y, z, w).
    public var localRotation: SIMD4<Float>
    public var localScale: SIMD3<Float>

    public init(
        shape: ColliderShape,
        localPosition: SIMD3<Float> = .zero,
        localRotation: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 1),
        localScale: SIMD3<Float> = SIMD3<Float>(repeating: 1)
    ) {
        self.shape = shape
        self.localPosition = localPosition
        self.localRotation = localRotation
        self.localScale = localScale
    }
}

public struct PhysicsMaterial: Sendable, Equatable {
    public var friction: Float
    public var restitution: Float
    public var density: Float

    public init(friction: Float = 0.6, restitution: Float = 0, density: Float = 1) {
        self.friction = max(0, friction)
        self.restitution = max(0, min(restitution, 1))
        self.density = max(0, density)
    }
}

public struct Collider: RuntimeComponent, Sendable, Equatable {
    public var shapes: [ColliderShapeInstance]
    /// Compatibility access to the first child. New code should author `shapes`.
    public var shape: ColliderShape {
        get { shapes.first?.shape ?? .box(halfExtents: SIMD3<Float>(repeating: 0.5), center: .zero) }
        set {
            if shapes.isEmpty { shapes = [ColliderShapeInstance(shape: newValue)] }
            else { shapes[0].shape = newValue }
        }
    }
    public var isTrigger: Bool
    public var layerID: UInt16
    public var layerMask: UInt16
    public var material: PhysicsMaterial

    public init(
        shape: ColliderShape,
        isTrigger: Bool = false,
        layerID: UInt16 = 0,
        layerMask: UInt16 = .max,
        material: PhysicsMaterial = PhysicsMaterial()
    ) {
        self.shapes = [ColliderShapeInstance(shape: shape)]
        self.isTrigger = isTrigger
        self.layerID = layerID
        self.layerMask = layerMask
        self.material = material
    }

    public init(
        shapes: [ColliderShapeInstance],
        isTrigger: Bool = false,
        layerID: UInt16 = 0,
        layerMask: UInt16 = .max,
        material: PhysicsMaterial = PhysicsMaterial()
    ) {
        self.shapes = shapes
        self.isTrigger = isTrigger
        self.layerID = layerID
        self.layerMask = layerMask
        self.material = material
    }
}
