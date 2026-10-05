import Foundation
import AssetPipeline
import GuavaUIRuntime
import IntentRuntime
import RenderBackend
import SceneRuntime
import ScriptRuntime
import SIMDCompat

extension EditorSceneAdapter {
    public func entitySummary(id rawID: UInt64?) -> EditorSceneEntitySummary? {
        guard let entity = entity(from: rawID), scene.contains(entity) else {
            return nil
        }
        return EditorSceneEntitySummary(
            id: entity.rawValue,
            name: displayName(for: entity),
            kind: displayKind(for: entity)
        )
    }

    func displayName(for entity: EntityID) -> String {
        scene.component(SceneNameComponent.self, for: entity)?.value ?? fallbackName(for: entity)
    }

    func displayKind(for entity: EntityID) -> String {
        if let kind = scene.component(SceneKindComponent.self, for: entity)?.value {
            return kind
        }
        if scene.hasComponent(Constraint.self, for: entity) {
            return "Constraint"
        }
        if scene.hasComponent(Ragdoll.self, for: entity) {
            return "Ragdoll"
        }
        if scene.hasComponent(Vehicle.self, for: entity) {
            return "Vehicle"
        }
        if scene.hasComponent(Destructible.self, for: entity) {
            return "Destructible"
        }
        if scene.hasComponent(RigidBody.self, for: entity) || scene.hasComponent(Collider.self, for: entity) {
            return "Physics Entity"
        }
        if scene.hasComponent(ScriptComponent.self, for: entity) {
            return "Scripted Entity"
        }
        return "Entity"
    }

    func fallbackName(for entity: EntityID) -> String {
        "Entity \(entity.index)"
    }

    func manifestMeshColliderResourceID(for meshIndex: Int) -> String {
        "meshIndex:\(meshIndex)"
    }

    private func describe(_ shape: ColliderShape) -> String {
        switch shape {
        case let .box(halfExtents, _):
            return "Box \(format(halfExtents * 2))"
        case let .sphere(radius, _):
            return "Sphere r=\(format(radius))"
        case let .capsule(radius, halfHeight, _):
            return "Capsule r=\(format(radius)) h=\(format(halfHeight * 2))"
        case let .cylinder(radius, halfHeight, _):
            return "Cylinder r=\(format(radius)) h=\(format(halfHeight * 2))"
        case let .heightField(resourceID, _):
            return resourceID.map { "HeightField \($0)" } ?? "HeightField"
        case let .mesh(resourceID, _):
            return resourceID.map { "Mesh \($0)" } ?? "Mesh"
        case let .convex(resourceID, _):
            return resourceID.map { "Convex \($0)" } ?? "Convex"
        }
    }

    func format(_ value: SIMD3<Float>) -> String {
        "\(format(value.x)), \(format(value.y)), \(format(value.z))"
    }

    func format(_ value: Float) -> String {
        String(format: "%.2f", value)
    }

    func entity(from rawID: UInt64?) -> EntityID? {
        guard let rawID else { return nil }
        return EntityID(rawValue: rawID)
    }
}
