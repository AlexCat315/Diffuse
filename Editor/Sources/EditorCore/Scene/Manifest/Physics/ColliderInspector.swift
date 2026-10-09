import Foundation
import AssetPipeline
import GuavaUIRuntime
import IntentRuntime
import RenderBackend
import SceneRuntime
import ScriptRuntime
import SIMDCompat

/// Inspector-side JSON round-trip for compound collider shapes. This is not part of
/// the scene document: the manifest stores colliders through the shared
/// SceneSerializer component document, while the inspector exposes this lossless
/// text representation as a debug editing surface over `ColliderShapeInstance`.
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