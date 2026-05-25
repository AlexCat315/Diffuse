import Foundation
import SceneRuntime
import ScriptRuntime
import IntentRuntime
import SIMDCompat

public enum SceneEditPlanExecutorError: Error, CustomStringConvertible, Sendable {
    case invalidEntityRef(String)
    case missingEntityRef(op: SceneEditOp)
    case entityNotFound(ref: String)
    case missingField(op: SceneEditOp, field: String)
    case invalidColor(op: SceneEditOp)
    case unknownLightType(String)
    case unknownMotionType(String)
    case unknownColliderShape(String)

    public var description: String {
        switch self {
        case let .invalidEntityRef(ref):
            return "invalid entity reference: '\(ref)' — expected format 'scene:<uint64>'"
        case let .missingEntityRef(op):
            return "op '\(op.rawValue)' requires entity_id"
        case let .entityNotFound(ref):
            return "entity '\(ref)' not found in scene"
        case let .missingField(op, field):
            return "op '\(op.rawValue)' requires field '\(field)'"
        case let .invalidColor(op):
            return "op '\(op.rawValue)' color must be [r, g, b] with 3 elements"
        case let .unknownLightType(s):
            return "unknown light type '\(s)' — expected 'directional', 'point', or 'spot'"
        case let .unknownMotionType(s):
            return "unknown motion type '\(s)' — expected 'static', 'dynamic', or 'kinematic'"
        case let .unknownColliderShape(s):
            return "unknown collider shape '\(s)' — expected 'box', 'sphere', 'capsule', 'mesh', or 'convex'"
        }
    }
}

/// Converts a `SceneEditPlan` (decoded from Claude) into an executable `TransactionIR`.
///
/// Each `SceneEditStep` produces one or more `SceneMutation`s. The resulting
/// `TransactionIR` has `intent: nil` and `provenance: .proposal`, signalling to the
/// coordinator that it came from an AI planner and bypasses the capability registry.
public struct SceneEditPlanExecutor: Sendable {
    public init() {}

    /// Builds a `TransactionIR` from the plan.
    ///
    /// - Parameters:
    ///   - plan: Decoded AI plan.
    ///   - scene: Live scene runtime — used to read current transforms and validate entity IDs.
    ///   - baseSceneRevision: Revision at which the AI generated the plan. Passing the
    ///     snapshot's revision prevents applying a plan against a scene that changed while
    ///     the API call was in flight. Pass `nil` to skip the revision check.
    ///   - approvalPolicy: Confirmation policy for the whole transaction.
    public func buildTransaction(
        from plan: SceneEditPlan,
        scene: SceneRuntime,
        baseSceneRevision: UInt64? = nil,
        approvalPolicy: TransactionApprovalPolicy = .automatic
    ) throws -> TransactionIR {
        var mutations: [SceneMutation] = []
        for step in plan.steps {
            let stepMutations = try buildMutations(step, scene: scene)
            mutations.append(contentsOf: stepMutations)
        }
        return TransactionIR(
            intent: nil,
            summary: plan.summary,
            operations: mutations.map(TransactionOperation.scene),
            baseRevisions: TransactionBaseRevisions(sceneRevision: baseSceneRevision),
            approvalPolicy: approvalPolicy,
            provenance: .proposal
        )
    }

    // MARK: - Per-step dispatch

    private func buildMutations(_ step: SceneEditStep, scene: SceneRuntime) throws -> [SceneMutation] {
        switch step.op {

        case .spawnEntity:
            let label = step.label ?? "AI Entity"
            let pos = simd3(step.spawnPosition) ?? .zero
            return [.spawnImportedMeshEntity(label: label,
                                             kindLabel: "Static Mesh",
                                             meshIndex: 0,
                                             position: pos)]

        case .deleteEntity:
            let id = try resolveEntityID(step, scene: scene)
            return [.deleteEntity(entityID: id)]

        case .duplicateEntity:
            let id = try resolveEntityID(step, scene: scene)
            return [.duplicateEntity(entityID: id)]

        case .reparentEntity:
            let id = try resolveEntityID(step, scene: scene)
            let parentID = try resolveOptionalRef(step.parentRef, op: step.op, scene: scene)
            return [.moveEntity(entityID: id, parentID: parentID, index: Int.max)]

        case .setName:
            let id = try resolveEntityID(step, scene: scene)
            guard let name = step.name, !name.isEmpty else {
                throw SceneEditPlanExecutorError.missingField(op: step.op, field: "name")
            }
            return [.setSceneName(entityID: id, value: name)]

        case .setTransform:
            let id = try resolveEntityID(step, scene: scene)
            let entity = entityID(fromRaw: id)
            var transform = scene.localTransform(for: entity) ?? LocalTransform()
            if let pos = simd3(step.position) {
                transform.matrix.columns.3 = SIMD4<Float>(pos, 1)
            }
            if let euler = step.eulerDegrees {
                let rot = rotationMatrix(eulerXYZDegrees: SIMD3(euler[0], euler[1], euler[2]))
                // Preserve scale, replace rotation
                let currentScale = extractScale(transform.matrix)
                transform.matrix = composeMatrix(translation: transform.translation,
                                                  rotation: rot,
                                                  scale: currentScale)
            }
            if let s = simd3(step.scale) {
                let rot = rotationOnly(transform.matrix)
                transform.matrix = composeMatrix(translation: transform.translation,
                                                  rotation: rot,
                                                  scale: s)
            }
            return [.setLocalTransform(entityID: id, transform: transform)]

        case .snapToGround:
            let id = try resolveEntityID(step, scene: scene)
            let entity = entityID(fromRaw: id)
            var transform = scene.localTransform(for: entity) ?? LocalTransform()
            transform.matrix.columns.3.y = 0
            return [.setLocalTransform(entityID: id, transform: transform)]

        case .setLightType:
            let id = try resolveEntityID(step, scene: scene)
            guard let typeStr = step.lightType else {
                throw SceneEditPlanExecutorError.missingField(op: step.op, field: "light_type")
            }
            guard let lt = LightType(rawValue: typeStr) else {
                throw SceneEditPlanExecutorError.unknownLightType(typeStr)
            }
            return [.setLightType(entityID: id, type: lt)]

        case .setLightIntensity:
            let id = try resolveEntityID(step, scene: scene)
            guard let v = step.intensity else {
                throw SceneEditPlanExecutorError.missingField(op: step.op, field: "intensity")
            }
            return [.setLightIntensity(entityID: id, intensity: v)]

        case .setMeshColor:
            let id = try resolveEntityID(step, scene: scene)
            guard let c = step.color, c.count == 3 else {
                throw SceneEditPlanExecutorError.invalidColor(op: step.op)
            }
            return [.setMeshColorTint(entityID: id, color: SIMD3(c[0], c[1], c[2]))]

        case .setMaterial:
            let id = try resolveEntityID(step, scene: scene)
            let base: SIMD4<Float>
            if let bc = step.materialBaseColor, bc.count == 4 {
                base = SIMD4(bc[0], bc[1], bc[2], bc[3])
            } else if let bc = step.materialBaseColor, bc.count == 3 {
                base = SIMD4(bc[0], bc[1], bc[2], 1.0)
            } else {
                base = SIMD4(1, 1, 1, 1)
            }
            let metallic   = step.materialMetallic  ?? 0.0
            let roughness  = step.materialRoughness ?? 0.5
            let em: SIMD3<Float>
            if let e = step.materialEmissive, e.count >= 3 {
                em = SIMD3(e[0], e[1], e[2])
            } else {
                em = .zero
            }
            return [.setRenderMaterialComponent(entityID: id,
                                                baseColorFactor: base,
                                                metallicFactor: metallic,
                                                roughnessFactor: roughness,
                                                emissiveFactor: em)]

        case .setLightColor:
            let id = try resolveEntityID(step, scene: scene)
            guard let c = step.color, c.count == 3 else {
                throw SceneEditPlanExecutorError.invalidColor(op: step.op)
            }
            return [.setLightColor(entityID: id, color: SIMD3(c[0], c[1], c[2]))]

        case .setLightRange:
            let id = try resolveEntityID(step, scene: scene)
            guard let v = step.range else {
                throw SceneEditPlanExecutorError.missingField(op: step.op, field: "range")
            }
            return [.setLightRange(entityID: id, range: v)]

        case .setLightSpotAngles:
            let id = try resolveEntityID(step, scene: scene)
            var result: [SceneMutation] = []
            if let inner = step.spotInnerAngleDegrees {
                result.append(.setLightSpotInnerAngle(entityID: id, angleDegrees: inner))
            }
            if let outer = step.spotOuterAngleDegrees {
                result.append(.setLightSpotOuterAngle(entityID: id, angleDegrees: outer))
            }
            if result.isEmpty {
                throw SceneEditPlanExecutorError.missingField(op: step.op,
                                                               field: "spot_inner_angle or spot_outer_angle")
            }
            return result

        case .setLightCastShadows:
            let id = try resolveEntityID(step, scene: scene)
            let cast = step.lightCastShadows ?? false
            return [.setLightCastShadows(entityID: id, value: cast)]

        case .setCameraPose:
            let id = try resolveEntityID(step, scene: scene)
            let pos = simd3(step.position) ?? .zero
            let target = simd3(step.cameraTarget) ?? SIMD3<Float>(0, 0, -1)
            let up = simd3(step.cameraUp) ?? SIMD3<Float>(0, 1, 0)
            let transform = LocalTransform(translation: pos)
            return [.setCameraPose(entityID: id, localTransform: transform, target: target, up: up)]

        case .setCameraFOV:
            let id = try resolveEntityID(step, scene: scene)
            guard let fov = step.cameraFovYDegrees else {
                throw SceneEditPlanExecutorError.missingField(op: step.op, field: "camera_fov_y")
            }
            return [.setCameraFOV(entityID: id, fovYDegrees: fov)]

        case .setCameraActive:
            let id = try resolveEntityID(step, scene: scene)
            let active = step.cameraIsActive ?? true
            return [.setCameraActive(entityID: id, isActive: active)]

        case .setRigidBodyMotion:
            let id = try resolveEntityID(step, scene: scene)
            guard let typeStr = step.motionType else {
                throw SceneEditPlanExecutorError.missingField(op: step.op, field: "motion_type")
            }
            guard let mt = RigidBodyMotionType(rawValue: typeStr) else {
                throw SceneEditPlanExecutorError.unknownMotionType(typeStr)
            }
            return [.setRigidBodyMotionType(entityID: id, value: mt)]

        case .setRigidBodyMass:
            let id = try resolveEntityID(step, scene: scene)
            guard let v = step.mass else {
                throw SceneEditPlanExecutorError.missingField(op: step.op, field: "mass")
            }
            return [.setRigidBodyMass(entityID: id, value: v)]

        case .setRigidBodyGravity:
            let id = try resolveEntityID(step, scene: scene)
            guard let v = step.gravityScale else {
                throw SceneEditPlanExecutorError.missingField(op: step.op, field: "gravity_scale")
            }
            return [.setRigidBodyGravityScale(entityID: id, value: v)]

        case .setColliderTrigger:
            let id = try resolveEntityID(step, scene: scene)
            guard let v = step.isTrigger else {
                throw SceneEditPlanExecutorError.missingField(op: step.op, field: "is_trigger")
            }
            return [.setColliderTrigger(entityID: id, value: v)]

        case .setColliderLayer:
            let id = try resolveEntityID(step, scene: scene)
            var result: [SceneMutation] = []
            if let layerID = step.colliderLayerID {
                result.append(.setColliderLayer(entityID: id, layerID: UInt16(clamping: layerID)))
            }
            if let mask = step.colliderLayerMask {
                result.append(.setColliderLayerMask(entityID: id, layerMask: UInt16(clamping: mask)))
            }
            if result.isEmpty {
                throw SceneEditPlanExecutorError.missingField(op: step.op,
                                                               field: "collider_layer_id or collider_layer_mask")
            }
            return result

        case .setConstraintEnabled:
            let id = try resolveEntityID(step, scene: scene)
            guard let v = step.isEnabled else {
                throw SceneEditPlanExecutorError.missingField(op: step.op, field: "is_enabled")
            }
            return [.setConstraintEnabled(entityID: id, value: v)]

        case .setRigidBodyAllowSleep:
            let id = try resolveEntityID(step, scene: scene)
            guard let v = step.allowSleep else {
                throw SceneEditPlanExecutorError.missingField(op: step.op, field: "allow_sleep")
            }
            return [.setRigidBodyAllowSleep(entityID: id, value: v)]

        case .setColliderShape:
            let id = try resolveEntityID(step, scene: scene)
            guard let shapeStr = step.colliderShape else {
                throw SceneEditPlanExecutorError.missingField(op: step.op, field: "collider_shape")
            }
            guard let kind = ColliderShapeKind(rawValue: shapeStr) else {
                throw SceneEditPlanExecutorError.unknownColliderShape(shapeStr)
            }
            return [.setColliderShapeType(entityID: id, kind: kind)]

        case .setColliderBoxExtents:
            let id = try resolveEntityID(step, scene: scene)
            guard let ext = simd3(step.halfExtents) else {
                throw SceneEditPlanExecutorError.missingField(op: step.op, field: "half_extents")
            }
            return [.setColliderShapeBoxHalfExtents(entityID: id, halfExtents: ext)]

        case .setColliderSphereRadius:
            let id = try resolveEntityID(step, scene: scene)
            guard let r = step.radius else {
                throw SceneEditPlanExecutorError.missingField(op: step.op, field: "radius")
            }
            return [.setColliderShapeSphereRadius(entityID: id, radius: r)]

        case .setColliderCapsule:
            let id = try resolveEntityID(step, scene: scene)
            var result: [SceneMutation] = []
            if let r = step.radius {
                result.append(.setColliderShapeCapsuleRadius(entityID: id, radius: r))
            }
            if let hh = step.halfHeight {
                result.append(.setColliderShapeCapsuleHalfHeight(entityID: id, halfHeight: hh))
            }
            if result.isEmpty {
                throw SceneEditPlanExecutorError.missingField(op: step.op,
                                                               field: "radius or half_height")
            }
            return result

        case .setColliderMaterial:
            let id = try resolveEntityID(step, scene: scene)
            var result: [SceneMutation] = []
            if let f = step.friction    { result.append(.setColliderMaterialFriction(entityID: id, value: f)) }
            if let r = step.restitution { result.append(.setColliderMaterialRestitution(entityID: id, value: r)) }
            if let d = step.density     { result.append(.setColliderMaterialDensity(entityID: id, value: d)) }
            if result.isEmpty {
                throw SceneEditPlanExecutorError.missingField(op: step.op,
                                                               field: "friction, restitution, or density")
            }
            return result

        case .setAudioSource:
            let id = try resolveEntityID(step, scene: scene)
            let eid = entityID(fromRaw: id)
            var source = scene.component(AudioSource.self, for: eid) ?? AudioSource()
            if let clip  = step.audioClip        { source.clipName = clip }
            if let vol   = step.audioVolume       { source.volume = vol }
            if let pitch = step.audioPitch        { source.pitch = pitch }
            if let loop  = step.audioLoop         { source.loop = loop }
            if let poa   = step.audioPlayOnAwake  { source.playOnAwake = poa }
            if let blend = step.audioSpatialBlend { source.spatialBlend = blend }
            return [.setAudioSource(entityID: id, source: source)]

        case .setMeshVisibility:
            let id = try resolveEntityID(step, scene: scene)
            guard let v = step.isVisible else {
                throw SceneEditPlanExecutorError.missingField(op: step.op, field: "is_visible")
            }
            return [.setRenderMeshVisibility(entityID: id, isVisible: v)]

        case .setAnimationPlayer:
            let id = try resolveEntityID(step, scene: scene)
            let eid = entityID(fromRaw: id)
            var player = scene.component(AnimationPlayer.self, for: eid) ?? AnimationPlayer()
            if let clip    = step.animationClip     { player.clipName = clip.isEmpty ? nil : clip }
            if let speed   = step.animationSpeed    { player.speed = speed }
            if let loop    = step.animationLoop     { player.loop = loop }
            if let playing = step.animationIsPlaying { player.isPlaying = playing }
            return [.setAnimationPlayer(entityID: id, clipName: player.clipName,
                                        speed: player.speed, loop: player.loop,
                                        isPlaying: player.isPlaying)]

        case .setScriptProperty:
            let id = try resolveEntityID(step, scene: scene)
            let eid = entityID(fromRaw: id)
            guard let propName = step.scriptPropertyName, !propName.isEmpty else {
                throw SceneEditPlanExecutorError.missingField(op: step.op, field: "script_property_name")
            }
            guard let propValue = step.scriptPropertyValue else {
                throw SceneEditPlanExecutorError.missingField(op: step.op, field: "script_property_value")
            }
            let bindingIdx = step.scriptIndex ?? 0
            var component = scene.component(ScriptComponent.self, for: eid) ?? ScriptComponent()
            while component.bindings.count <= bindingIdx {
                component.bindings.append(ScriptBinding(ScriptHandle(rawValue: 0)))
            }
            let updatedJSON = mergeScriptProperty(
                into: component.bindings[bindingIdx].parametersJSON,
                key: propName,
                value: propValue
            )
            component.bindings[bindingIdx].parametersJSON = updatedJSON
            return [.setScriptBindings(entityID: id, bindings: component.bindings)]
        }
    }

    // MARK: - Script helpers

    private func mergeScriptProperty(into json: String, key: String, value: JSONValue) -> String {
        guard let data = json.data(using: .utf8),
              var dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return "{\"\(key)\":\(value.jsonFragment)}"
        }
        switch value {
        case .string(let s): dict[key] = s
        case .number(let n): dict[key] = n
        case .bool(let b):   dict[key] = b
        }
        guard let out = try? JSONSerialization.data(withJSONObject: dict),
              let str = String(data: out, encoding: .utf8) else {
            return "{\"\(key)\":\(value.jsonFragment)}"
        }
        return str
    }

    // MARK: - Entity ID resolution

    private func resolveOptionalRef(_ ref: String?, op: SceneEditOp, scene: SceneRuntime) throws -> UInt64? {
        guard let ref else { return nil }
        guard ref.hasPrefix("scene:"), let raw = UInt64(ref.dropFirst("scene:".count)) else {
            throw SceneEditPlanExecutorError.invalidEntityRef(ref)
        }
        let eid = entityID(fromRaw: raw)
        guard scene.contains(eid) else {
            throw SceneEditPlanExecutorError.entityNotFound(ref: ref)
        }
        return raw
    }

    private func resolveEntityID(_ step: SceneEditStep, scene: SceneRuntime) throws -> UInt64 {
        guard let ref = step.entityRef else {
            throw SceneEditPlanExecutorError.missingEntityRef(op: step.op)
        }
        guard ref.hasPrefix("scene:"), let raw = UInt64(ref.dropFirst("scene:".count)) else {
            throw SceneEditPlanExecutorError.invalidEntityRef(ref)
        }
        let eid = entityID(fromRaw: raw)
        guard scene.contains(eid) else {
            throw SceneEditPlanExecutorError.entityNotFound(ref: ref)
        }
        return raw
    }

    private func entityID(fromRaw raw: UInt64) -> EntityID {
        EntityID(index: UInt32(raw & 0xFFFF_FFFF),
                 generation: UInt32(raw >> 32))
    }

    // MARK: - Math helpers

    private func simd3(_ arr: [Float]?) -> SIMD3<Float>? {
        guard let a = arr, a.count >= 3 else { return nil }
        return SIMD3(a[0], a[1], a[2])
    }

    /// Builds a 4脳4 rotation matrix from XYZ intrinsic Euler angles (degrees).
    private func rotationMatrix(eulerXYZDegrees e: SIMD3<Float>) -> simd_float4x4 {
        let toRad: Float = .pi / 180
        let rx = simd_float4x4(simd_quatf(angle: e.x * toRad, axis: SIMD3(1, 0, 0)))
        let ry = simd_float4x4(simd_quatf(angle: e.y * toRad, axis: SIMD3(0, 1, 0)))
        let rz = simd_float4x4(simd_quatf(angle: e.z * toRad, axis: SIMD3(0, 0, 1)))
        return rx * ry * rz
    }

    private func extractScale(_ m: simd_float4x4) -> SIMD3<Float> {
        SIMD3(
            length(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z)),
            length(SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z)),
            length(SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z))
        )
    }

    private func rotationOnly(_ m: simd_float4x4) -> simd_float4x4 {
        let s = extractScale(m)
        var r = m
        r.columns.0 = SIMD4(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z) / s.x, 0)
        r.columns.1 = SIMD4(SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z) / s.y, 0)
        r.columns.2 = SIMD4(SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z) / s.z, 0)
        r.columns.3 = SIMD4(0, 0, 0, 1)
        return r
    }

    private func composeMatrix(translation: SIMD3<Float>,
                               rotation: simd_float4x4,
                               scale: SIMD3<Float>) -> simd_float4x4 {
        var m = rotation
        m.columns.0 *= scale.x
        m.columns.1 *= scale.y
        m.columns.2 *= scale.z
        m.columns.3 = SIMD4(translation, 1)
        return m
    }
}
