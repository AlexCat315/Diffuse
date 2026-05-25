import Foundation
import SceneRuntime
import ScriptRuntime
import SIMDCompat

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
            var scale: [Float]?
            var eulerDegrees: [Float]?
            var worldPosition: [Float]?
            var worldEulerDegrees: [Float]?
            var worldScale: [Float]?
            if let lt = scene.localTransform(for: entity) {
                let t = lt.translation
                position = [t.x, t.y, t.z]
                let s = extractScale(lt.matrix)
                let isUniformOne = abs(s.x - 1) < 0.0001 && abs(s.y - 1) < 0.0001 && abs(s.z - 1) < 0.0001
                if !isUniformOne { scale = [s.x, s.y, s.z] }
                let e = extractEulerXYZDegrees(lt.matrix)
                let isZeroRotation = abs(e.x) < 0.01 && abs(e.y) < 0.01 && abs(e.z) < 0.01
                if !isZeroRotation { eulerDegrees = [e.x, e.y, e.z] }
                let wm = worldMatrix(scene, entity: entity)
                worldPosition = [wm.columns.3.x, wm.columns.3.y, wm.columns.3.z]
                let we = extractEulerXYZDegrees(wm)
                let isZeroWorldRot = abs(we.x) < 0.01 && abs(we.y) < 0.01 && abs(we.z) < 0.01
                if !isZeroWorldRot { worldEulerDegrees = [we.x, we.y, we.z] }
                let ws = extractScale(wm)
                let isWorldUniformOne = abs(ws.x - 1) < 0.0001 && abs(ws.y - 1) < 0.0001 && abs(ws.z - 1) < 0.0001
                if !isWorldUniformOne { worldScale = [ws.x, ws.y, ws.z] }
            }

            var components: [String] = []
            if scene.hasComponent(LocalTransform.self, for: entity)      { components.append("transform") }
            if scene.hasComponent(RenderMeshComponent.self, for: entity) { components.append("mesh") }
            if scene.hasComponent(LightComponent.self, for: entity)      { components.append("light") }
            if scene.hasComponent(CameraComponent.self, for: entity)     { components.append("camera") }
            if scene.hasComponent(RigidBody.self, for: entity)           { components.append("rigidbody") }
            if scene.hasComponent(Collider.self, for: entity)            { components.append("collider") }
            if scene.hasComponent(AudioSource.self, for: entity)         { components.append("audio_source") }
            if scene.hasComponent(AnimationPlayer.self, for: entity)     { components.append("animation") }
            if scene.hasComponent(ScriptComponent.self, for: entity)     { components.append("script") }
            if scene.hasComponent(Constraint.self, for: entity)          { components.append("constraint") }

            var lightType: String?
            var lightIntensity: Float?
            var lightColor: [Float]?
            var lightRange: Float?
            var lightSpotInner: Float?
            var lightSpotOuter: Float?
            var lightCastShadows: Bool?
            if let lc = scene.component(LightComponent.self, for: entity) {
                lightType = lc.type.rawValue
                lightIntensity = lc.intensity
                lightColor = [lc.color.x, lc.color.y, lc.color.z]
                lightRange = lc.range
                if lc.type == .spot {
                    lightSpotInner = lc.spotInnerAngleDegrees
                    lightSpotOuter = lc.spotOuterAngleDegrees
                }
                if lc.castShadows { lightCastShadows = true }
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

            var materialMetallic: Float?
            var materialRoughness: Float?
            var materialEmissive: [Float]?
            if let mat = scene.component(RenderMaterialComponent.self, for: entity) {
                if mat.metallicFactor > 0.001 { materialMetallic = mat.metallicFactor }
                if abs(mat.roughnessFactor - 1.0) > 0.001 { materialRoughness = mat.roughnessFactor }
                let em = mat.emissiveFactor
                if em.x > 0.001 || em.y > 0.001 || em.z > 0.001 {
                    materialEmissive = [em.x, em.y, em.z]
                }
            }

            var rigidBodyMotionType: String?
            var rigidBodyMass: Float?
            var rigidBodyGravityScale: Float?
            var rigidBodyAllowSleep: Bool?
            if let rb = scene.component(RigidBody.self, for: entity) {
                rigidBodyMotionType = rb.motionType.rawValue
                rigidBodyMass = rb.mass
                rigidBodyGravityScale = rb.gravityScale
                rigidBodyAllowSleep = rb.allowSleep
            }

            var colliderShape: String?
            var colliderIsTrigger: Bool?
            var colliderFriction: Float?
            var colliderRestitution: Float?
            var colliderDensity: Float?
            var colliderLayerID: Int?
            var colliderLayerMask: Int?
            if let col = scene.component(Collider.self, for: entity) {
                colliderShape = col.shape.kind.rawValue
                colliderIsTrigger = col.isTrigger
                colliderFriction = col.material.friction
                colliderRestitution = col.material.restitution
                colliderDensity = col.material.density
                colliderLayerID = Int(col.layerID)
                colliderLayerMask = Int(col.layerMask)
            }

            var audioClip: String?
            var audioVolume: Float?
            var audioLoop: Bool?
            var audioPlayOnAwake: Bool?
            if let src = scene.component(AudioSource.self, for: entity) {
                audioClip = src.clipName.isEmpty ? nil : src.clipName
                audioVolume = src.volume
                audioLoop = src.loop
                audioPlayOnAwake = src.playOnAwake
            }

            var meshIsVisible: Bool?
            if let mesh = scene.component(RenderMeshComponent.self, for: entity), !mesh.isVisible {
                meshIsVisible = false
            }

            var animationClip: String?
            var animationSpeed: Float?
            var animationLoop: Bool?
            var animationIsPlaying: Bool?
            if let anim = scene.component(AnimationPlayer.self, for: entity) {
                animationClip = anim.clipName
                if abs(anim.speed - 1.0) > 0.0001 { animationSpeed = anim.speed }
                animationLoop = anim.loop
                animationIsPlaying = anim.isPlaying
            }

            var scriptBindings: [SceneSemanticSnapshot.ScriptBindingRecord]?
            if let sc = scene.component(ScriptComponent.self, for: entity), !sc.bindings.isEmpty {
                scriptBindings = sc.bindings.map {
                    SceneSemanticSnapshot.ScriptBindingRecord(
                        handle: $0.script.rawValue,
                        isEnabled: $0.isEnabled,
                        parametersJSON: $0.parametersJSON
                    )
                }
            }

            var constraintEnabled: Bool?
            if let con = scene.component(Constraint.self, for: entity) {
                constraintEnabled = con.isEnabled
            }

            records.append(SceneSemanticSnapshot.Entity(
                id: ref,
                name: name,
                kind: kind,
                parentRef: parentRef,
                childRefs: childRefs,
                isSelected: selectedRef == ref,
                position: position,
                scale: scale,
                eulerDegrees: eulerDegrees,
                worldPosition: worldPosition,
                worldEulerDegrees: worldEulerDegrees,
                worldScale: worldScale,
                components: components,
                lightType: lightType,
                lightIntensity: lightIntensity,
                lightColor: lightColor,
                lightRange: lightRange,
                lightSpotInner: lightSpotInner,
                lightSpotOuter: lightSpotOuter,
                lightCastShadows: lightCastShadows,
                cameraFovYDegrees: cameraFovYDegrees,
                cameraIsActive: cameraIsActive,
                meshColor: meshColor,
                materialMetallic: materialMetallic,
                materialRoughness: materialRoughness,
                materialEmissive: materialEmissive,
                rigidBodyMotionType: rigidBodyMotionType,
                rigidBodyMass: rigidBodyMass,
                rigidBodyGravityScale: rigidBodyGravityScale,
                rigidBodyAllowSleep: rigidBodyAllowSleep,
                colliderShape: colliderShape,
                colliderIsTrigger: colliderIsTrigger,
                colliderFriction: colliderFriction,
                colliderRestitution: colliderRestitution,
                colliderDensity: colliderDensity,
                colliderLayerID: colliderLayerID,
                colliderLayerMask: colliderLayerMask,
                audioClip: audioClip,
                audioVolume: audioVolume,
                audioLoop: audioLoop,
                audioPlayOnAwake: audioPlayOnAwake,
                meshIsVisible: meshIsVisible,
                animationClip: animationClip,
                animationSpeed: animationSpeed,
                animationLoop: animationLoop,
                animationIsPlaying: animationIsPlaying,
                scriptBindings: scriptBindings,
                constraintEnabled: constraintEnabled
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

    /// Extracts XYZ intrinsic Euler angles in degrees from a TRS matrix.
    /// Returns zero when the rotation is identity or near-identity.
    private func extractEulerXYZDegrees(_ m: simd_float4x4) -> SIMD3<Float> {
        let s = extractScale(m)
        guard s.x > 0, s.y > 0, s.z > 0 else { return .zero }
        // Normalised rotation column elements (row-major R[row][col] = columns[col][row])
        let r02 = m.columns.2.x / s.z          // sin(y)
        let r12 = m.columns.2.y / s.z          // -sin(x)cos(y)
        let r22 = m.columns.2.z / s.z          // cos(x)cos(y)
        let r01 = m.columns.1.x / s.y          // -cos(y)sin(z)
        let r00 = m.columns.0.x / s.x          // cos(y)cos(z)
        let sinBeta = Float.maximum(-1, Float.minimum(1, r02))
        let beta = asin(sinBeta)
        let toDeg: Float = 180 / .pi
        if abs(sinBeta) < 0.9999 {
            let alpha = atan2(-r12, r22)
            let gamma = atan2(-r01, r00)
            return SIMD3(alpha * toDeg, beta * toDeg, gamma * toDeg)
        } else {
            let r10 = m.columns.0.y / s.x      // sin(x+z) when beta=+90°
            let r11 = m.columns.1.y / s.y      // cos(x+z) when beta=+90°
            let alpha = atan2(r10, r11)
            return SIMD3(alpha * toDeg, beta * toDeg, 0)
        }
    }

    private func extractScale(_ m: simd_float4x4) -> SIMD3<Float> {
        SIMD3(
            length(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z)),
            length(SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z)),
            length(SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z))
        )
    }

    /// Recursively computes the world-space transform by walking up the parent chain.
    private func worldMatrix(_ scene: SceneRuntime, entity: EntityID) -> simd_float4x4 {
        let local = scene.localTransform(for: entity)?.matrix
            ?? simd_float4x4(diagonal: SIMD4<Float>(1, 1, 1, 1))
        guard let parent = scene.parent(of: entity) else { return local }
        return worldMatrix(scene, entity: parent) * local
    }
}
