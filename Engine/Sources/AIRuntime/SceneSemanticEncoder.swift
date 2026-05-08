import Foundation
import SceneRuntime

/// Converts a live `SceneRuntime` into a `SceneSemanticSnapshot` for AI planning.
///
/// Reads SceneNameComponent, SceneKindComponent, LocalTransform, LightComponent,
/// CameraComponent, RenderMeshComponent, RigidBody, Collider, and the parent/children
/// hierarchy. Runs synchronously — call before crossing an async boundary and pass
/// the snapshot value (not the runtime reference) into the async task.
public struct SceneSemanticEncoder: Sendable {
    public init() {}

    public func encode(
        _ scene: SceneRuntime,
        selectedEntityID: UInt64? = nil,
        workspaceMode: String? = nil,
        localeIdentifier: String? = nil
    ) -> SceneSemanticSnapshot {
        let selectedRef = selectedEntityID.map { "scene:\($0)" }
        var records: [SceneSemanticSnapshot.Entity] = []

        for entity in scene.entities() {
            let raw = rawID(entity)
            let ref = "scene:\(raw)"

            let name = scene.component(SceneNameComponent.self, for: entity)?.value
                ?? "Entity \(raw)"
            let kind = entityKind(scene, entity: entity)

            let parentRef = scene.parent(of: entity).map { "scene:\(rawID($0))" }
            let childRefs = scene.children(of: entity).map { "scene:\(rawID($0))" }

            var position: [Float]?
            if let lt = scene.localTransform(for: entity) {
                let t = lt.translation
                position = [t.x, t.y, t.z]
            }

            var components: [String] = []
            if scene.hasComponent(LocalTransform.self, for: entity)      { components.append("transform") }
            if scene.hasComponent(RenderMeshComponent.self, for: entity) { components.append("mesh") }
            if scene.hasComponent(LightComponent.self, for: entity)      { components.append("light") }
            if scene.hasComponent(CameraComponent.self, for: entity)     { components.append("camera") }
            if scene.hasComponent(RigidBody.self, for: entity)           { components.append("rigidbody") }
            if scene.hasComponent(Collider.self, for: entity)            { components.append("collider") }

            var lightType: String?
            var lightIntensity: Float?
            var lightColor: [Float]?
            var lightRange: Float?
            if let lc = scene.component(LightComponent.self, for: entity) {
                lightType = lc.type.rawValue
                lightIntensity = lc.intensity
                lightColor = [lc.color.x, lc.color.y, lc.color.z]
                lightRange = lc.range
            }

            var cameraFovYDegrees: Float?
            var cameraIsActive: Bool?
            if let cam = scene.component(CameraComponent.self, for: entity) {
                cameraFovYDegrees = cam.fovYRadians * (180 / .pi)
                cameraIsActive = cam.isActive
            }

            var meshColor: [Float]?
            if let mesh = scene.component(RenderMeshComponent.self, for: entity) {
                let c = mesh.colorTint
                let isWhite = abs(c.x - 1) < 0.001 && abs(c.y - 1) < 0.001 && abs(c.z - 1) < 0.001
                if !isWhite { meshColor = [c.x, c.y, c.z] }
            }

            var rigidBodyMotionType: String?
            if let rb = scene.component(RigidBody.self, for: entity) {
                rigidBodyMotionType = rb.motionType.rawValue
            }

            records.append(SceneSemanticSnapshot.Entity(
                id: ref,
                name: name,
                kind: kind,
                parentRef: parentRef,
                childRefs: childRefs,
                isSelected: selectedRef == ref,
                position: position,
                components: components,
                lightType: lightType,
                lightIntensity: lightIntensity,
                lightColor: lightColor,
                lightRange: lightRange,
                cameraFovYDegrees: cameraFovYDegrees,
                cameraIsActive: cameraIsActive,
                meshColor: meshColor,
                rigidBodyMotionType: rigidBodyMotionType
            ))
        }

        return SceneSemanticSnapshot(
            sceneRevision: scene.snapshot.revision,
            entityCount: scene.snapshot.entityCount,
            entities: records,
            selectedRef: selectedRef,
            workspaceMode: workspaceMode,
            localeIdentifier: localeIdentifier
        )
    }

    // MARK: - Private

    private func entityKind(_ scene: SceneRuntime, entity: EntityID) -> String {
        if let k = scene.component(SceneKindComponent.self, for: entity) { return k.value }
        if scene.hasComponent(CameraComponent.self, for: entity) { return "Camera" }
        if let lc = scene.component(LightComponent.self, for: entity) {
            switch lc.type {
            case .directional: return "Directional Light"
            case .point:       return "Point Light"
            case .spot:        return "Spot Light"
            }
        }
        if scene.hasComponent(RenderMeshComponent.self, for: entity) { return "Static Mesh" }
        if !scene.children(of: entity).isEmpty                       { return "Group" }
        return "Entity"
    }

    private func rawID(_ entity: EntityID) -> UInt64 {
        UInt64(entity.index) | (UInt64(entity.generation) << 32)
    }
}
