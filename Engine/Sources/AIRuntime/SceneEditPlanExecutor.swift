import Foundation
import SceneRuntime
import IntentRuntime
import simd

public enum SceneEditPlanExecutorError: Error, CustomStringConvertible, Sendable {
    case invalidEntityRef(String)
    case missingEntityRef(op: SceneEditOp)
    case entityNotFound(ref: String)
    case missingField(op: SceneEditOp, field: String)
    case invalidColor(op: SceneEditOp)
    case unknownLightType(String)
    case unknownMotionType(String)

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

        case .setCameraPose:
            let id = try resolveEntityID(step, scene: scene)
            let pos = simd3(step.position) ?? .zero
            let target = simd3(step.cameraTarget) ?? SIMD3<Float>(0, 0, -1)
            let up = simd3(step.cameraUp) ?? SIMD3<Float>(0, 1, 0)
            var transform = LocalTransform(translation: pos)
            return [.setCameraPose(entityID: id, localTransform: transform, target: target, up: up)]

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

        case .setConstraintEnabled:
            let id = try resolveEntityID(step, scene: scene)
            guard let v = step.isEnabled else {
                throw SceneEditPlanExecutorError.missingField(op: step.op, field: "is_enabled")
            }
            return [.setConstraintEnabled(entityID: id, value: v)]
        }
    }

    // MARK: - Entity ID resolution

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

    /// Builds a 4×4 rotation matrix from XYZ intrinsic Euler angles (degrees).
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
