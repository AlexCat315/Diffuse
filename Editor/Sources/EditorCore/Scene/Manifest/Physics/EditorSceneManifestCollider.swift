import Foundation
import AssetPipeline
import GuavaUIRuntime
import IntentRuntime
import RenderBackend
import SceneRuntime
import ScriptRuntime
import SIMDCompat

public struct EditorSceneManifestPhysicsMaterial: Codable, Sendable, Equatable {
    public let friction: Float
    public let restitution: Float
    public let density: Float

    public init(_ material: PhysicsMaterial) {
        self.friction = material.friction
        self.restitution = material.restitution
        self.density = material.density
    }

    var material: PhysicsMaterial {
        PhysicsMaterial(friction: friction, restitution: restitution, density: density)
    }
}

public struct EditorSceneManifestColliderShape: Codable, Sendable, Equatable {
    public let kind: String
    public let halfExtents: EditorSceneManifestVector3?
    public let radius: Float?
    public let halfHeight: Float?
    public let resourceID: String?
    public let center: EditorSceneManifestVector3

    public init(_ shape: ColliderShape) {
        switch shape {
        case let .box(halfExtents, center):
            self.kind = "box"
            self.halfExtents = EditorSceneManifestVector3(halfExtents)
            self.radius = nil
            self.halfHeight = nil
            self.resourceID = nil
            self.center = EditorSceneManifestVector3(center)
        case let .sphere(radius, center):
            self.kind = "sphere"
            self.halfExtents = nil
            self.radius = radius
            self.halfHeight = nil
            self.resourceID = nil
            self.center = EditorSceneManifestVector3(center)
        case let .capsule(radius, halfHeight, center):
            self.kind = "capsule"
            self.halfExtents = nil
            self.radius = radius
            self.halfHeight = halfHeight
            self.resourceID = nil
            self.center = EditorSceneManifestVector3(center)
        case let .cylinder(radius, halfHeight, center):
            self.kind = "cylinder"
            self.halfExtents = nil
            self.radius = radius
            self.halfHeight = halfHeight
            self.resourceID = nil
            self.center = EditorSceneManifestVector3(center)
        case let .heightField(resourceID, center):
            self.kind = "heightField"
            self.halfExtents = nil
            self.radius = nil
            self.halfHeight = nil
            self.resourceID = resourceID
            self.center = EditorSceneManifestVector3(center)
        case let .mesh(resourceID, center):
            self.kind = "mesh"
            self.halfExtents = nil
            self.radius = nil
            self.halfHeight = nil
            self.resourceID = resourceID
            self.center = EditorSceneManifestVector3(center)
        case let .convex(resourceID, center):
            self.kind = "convex"
            self.halfExtents = nil
            self.radius = nil
            self.halfHeight = nil
            self.resourceID = resourceID
            self.center = EditorSceneManifestVector3(center)
        }
    }

    var shape: ColliderShape {
        switch kind {
        case "box":
            return .box(halfExtents: halfExtents?.simdValue ?? SIMD3<Float>(0.5, 0.5, 0.5),
                        center: center.simdValue)
        case "sphere":
            return .sphere(radius: radius ?? 0.5, center: center.simdValue)
        case "capsule":
            return .capsule(radius: radius ?? 0.5,
                            halfHeight: halfHeight ?? 0.5,
                            center: center.simdValue)
        case "cylinder":
            return .cylinder(radius: radius ?? 0.5,
                             halfHeight: halfHeight ?? 0.5,
                             center: center.simdValue)
        case "heightField":
            return .heightField(resourceID: resourceID, center: center.simdValue)
        case "mesh":
            return .mesh(resourceID: resourceID, center: center.simdValue)
        case "convex":
            return .convex(resourceID: resourceID, center: center.simdValue)
        default:
            return .box(halfExtents: SIMD3<Float>(0.5, 0.5, 0.5), center: center.simdValue)
        }
    }
}

public struct EditorSceneManifestColliderShapeInstance: Codable, Sendable, Equatable {
    public let shape: EditorSceneManifestColliderShape
    public let localPosition: EditorSceneManifestVector3
    public let localRotation: EditorSceneManifestVector4
    public let localScale: EditorSceneManifestVector3

    public init(_ instance: ColliderShapeInstance) {
        shape = EditorSceneManifestColliderShape(instance.shape)
        localPosition = EditorSceneManifestVector3(instance.localPosition)
        localRotation = EditorSceneManifestVector4(instance.localRotation)
        localScale = EditorSceneManifestVector3(instance.localScale)
    }

    var instance: ColliderShapeInstance {
        ColliderShapeInstance(
            shape: shape.shape,
            localPosition: localPosition.simdValue,
            localRotation: localRotation.simdValue,
            localScale: localScale.simdValue
        )
    }
}

public struct EditorSceneManifestCollider: Codable, Sendable, Equatable {
    public let shape: EditorSceneManifestColliderShape
    public let shapes: [EditorSceneManifestColliderShapeInstance]
    public let isTrigger: Bool
    public let layerID: UInt16
    public let layerMask: UInt16
    public let material: EditorSceneManifestPhysicsMaterial

    public init(_ component: Collider) {
        self.shape = EditorSceneManifestColliderShape(component.shape)
        self.shapes = component.shapes.map(EditorSceneManifestColliderShapeInstance.init)
        self.isTrigger = component.isTrigger
        self.layerID = component.layerID
        self.layerMask = component.layerMask
        self.material = EditorSceneManifestPhysicsMaterial(component.material)
    }

    var component: Collider {
        Collider(shapes: shapes.isEmpty
                    ? [ColliderShapeInstance(shape: shape.shape)]
                    : shapes.map(\.instance),
                 isTrigger: isTrigger,
                 layerID: layerID,
                 layerMask: layerMask,
                 material: material.material)
    }
}
