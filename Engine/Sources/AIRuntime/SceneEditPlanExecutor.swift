import Foundation
import CapabilityRuntime
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
    case capabilityUnavailable(String)
    case invalidCapabilityInput(capabilityID: String, reason: String)

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
            return "unknown collider shape '\(s)' — expected 'box', 'sphere', 'capsule', 'cylinder', 'heightField', 'mesh', or 'convex'"
        case let .capabilityUnavailable(id):
            return "capability '\(id)' is not registered for AI exposure"
        case let .invalidCapabilityInput(id, reason):
            return "invalid input for capability '\(id)': \(reason)"
        }
    }
}

/// Converts a `SceneEditPlan` (decoded from Claude) into an executable `TransactionIR`.
///
/// Each `SceneEditStep` produces one or more `SceneMutation`s. The resulting
/// `TransactionIR` has `intent: nil`, explicit capability invocation records, and
/// `provenance: .proposal`. The coordinator validates those records directly.
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
        approvalPolicy: TransactionApprovalPolicy = .automatic,
        exposureSnapshot: CapabilityExposureSnapshot? = nil,
        registry: CapabilityRegistry = .aiDefault
    ) throws -> TransactionIR {
        var mutations: [SceneMutation] = []
        var invocations: [CapabilityInvocationRecord] = []
        var assertions: [TransactionVerificationAssertion] = []
        let snapshotID = exposureSnapshot?.id ?? UUID()
        // Shadow copy — each step reads the post-previous-step state so multi-step
        // plans that touch the same component (e.g. set_collider_trigger then
        // set_collider_sphere_radius) don't silently overwrite each other's changes.
        var localScene = scene
        for step in plan.steps {
            let descriptor = registry.descriptor(for: step.op.capabilityID)
            guard let descriptor, descriptor.isAIExposed else {
                throw SceneEditPlanExecutorError.capabilityUnavailable(step.op.capabilityID)
            }
            let contract: CapabilityContract
            if let exposureSnapshot {
                guard let exposed = exposureSnapshot.contract(id: step.op.capabilityID),
                      exposed.version == descriptor.version,
                      exposed.schemaHash == descriptor.contract.schemaHash else {
                    throw SceneEditPlanExecutorError.capabilityUnavailable(step.op.capabilityID)
                }
                contract = exposed
            } else {
                contract = descriptor.contract
            }
            // SceneEditPlan is the compatibility transport while callers move
            // to direct capability Drafts. Preserve its established diagnostic
            // errors, but discard the legacy mutations: authority and actual
            // operations still come from strict validation + typed prepare.
            if let compatibilityError = legacyValidationError(for: step, scene: localScene) {
                throw compatibilityError
            }
            let input = try canonicalCapabilityInput(for: step)
            do {
                try JSONSchemaValidator.validate(data: input.data, against: contract.inputSchema)
            } catch {
                throw SceneEditPlanExecutorError.invalidCapabilityInput(
                    capabilityID: contract.id,
                    reason: String(describing: error)
                )
            }
            let stepMutations: [SceneMutation]
            let stepAssertions: [TransactionVerificationAssertion]
            if let registration = BuiltInTypedCapabilityCatalog.registration(for: contract.id) {
                guard registration.contract.schemaHash == contract.schemaHash else {
                    throw SceneEditPlanExecutorError.capabilityUnavailable(contract.id)
                }
                do {
                    let prepared = try registration.prepare(
                        validatedInput: input.data,
                        context: preparationContext(for: localScene)
                    )
                    stepMutations = try prepared.operations.map { operation in
                        guard case let .scene(mutation) = operation else {
                            throw SceneEditPlanExecutorError.invalidCapabilityInput(
                                capabilityID: contract.id,
                                reason: "a scene capability prepared a non-scene operation"
                            )
                        }
                        return mutation
                    }
                    stepAssertions = prepared.assertions
                } catch let error as SceneEditPlanExecutorError {
                    throw error
                } catch {
                    throw SceneEditPlanExecutorError.invalidCapabilityInput(
                        capabilityID: contract.id,
                        reason: String(describing: error)
                    )
                }
            } else {
                stepMutations = try buildMutations(step, scene: localScene)
                stepAssertions = verificationAssertions(for: stepMutations)
            }
            mutations.append(contentsOf: stepMutations)
            assertions.append(contentsOf: stepAssertions)
            invocations.append(CapabilityInvocationRecord(
                capabilityID: contract.id,
                capabilityVersion: contract.version,
                schemaHash: contract.schemaHash,
                sourcePluginID: contract.source.pluginID,
                pluginAuthority: contract.source.pluginID.flatMap {
                    exposureSnapshot?.authority(forPluginID: $0)
                },
                inputDigest: contract.inputDigest(input.data),
                argumentNames: input.argumentNames,
                targetReferences: step.entityRef.map { [$0] } ?? [],
                access: contract.access,
                exposureSnapshotID: snapshotID
            ))
            applyToLocalScene(&localScene, mutations: stepMutations)
        }
        let expectedCreatedCount = mutations.reduce(into: 0) { count, mutation in
            switch mutation {
            case .spawnImportedMeshEntity, .spawnEmptyEntity, .spawnLightEntity, .spawnCameraEntity,
                 .duplicateEntity, .duplicateEntityWithOffset:
                count += 1
            default:
                break
            }
        }
        if expectedCreatedCount > 0 {
            assertions.append(.createdEntityCount(expectedCreatedCount))
        }
        return TransactionIR(
            intent: nil,
            summary: plan.summary,
            operations: mutations.map(TransactionOperation.scene),
            capabilityInvocations: invocations,
            verificationAssertions: assertions + (baseSceneRevision.map {
                [.sceneRevisionAdvanced(from: $0)]
            } ?? []),
            baseRevisions: TransactionBaseRevisions(sceneRevision: baseSceneRevision),
            approvalPolicy: approvalPolicy,
            provenance: .proposal
        )
    }

    private func preparationContext(for scene: SceneRuntime) -> CapabilityPreparationContext {
        CapabilityPreparationContext(
            sceneRevision: scene.snapshot.revision,
            entities: scene.entities().map { entity in
                let transform = scene.localTransform(for: entity).flatMap { local in
                    let matrix = local.matrix
                    return CapabilityPreparationTransform(columnMajorMatrix: [
                        matrix.columns.0.x, matrix.columns.0.y,
                        matrix.columns.0.z, matrix.columns.0.w,
                        matrix.columns.1.x, matrix.columns.1.y,
                        matrix.columns.1.z, matrix.columns.1.w,
                        matrix.columns.2.x, matrix.columns.2.y,
                        matrix.columns.2.z, matrix.columns.2.w,
                        matrix.columns.3.x, matrix.columns.3.y,
                        matrix.columns.3.z, matrix.columns.3.w,
                    ])
                }
                var componentTypes: [String] = []
                if transform != nil { componentTypes.append("LocalTransform") }
                if scene.hasComponent(LightComponent.self, for: entity) {
                    componentTypes.append("LightComponent")
                }
                if scene.hasComponent(CameraComponent.self, for: entity) {
                    componentTypes.append("CameraComponent")
                }
                if scene.hasComponent(RenderMeshComponent.self, for: entity) {
                    componentTypes.append("RenderMeshComponent")
                }
                let rigidBody = scene.component(RigidBody.self, for: entity)
                if rigidBody != nil {
                    componentTypes.append("RigidBody")
                }
                let collider = scene.component(Collider.self, for: entity)
                if collider != nil {
                    componentTypes.append("Collider")
                }
                let renderMaterial = scene.component(RenderMaterialComponent.self, for: entity)
                    .flatMap { material in
                        CapabilityPreparationMaterial(
                            baseColor: [
                                material.baseColorFactor.x, material.baseColorFactor.y,
                                material.baseColorFactor.z, material.baseColorFactor.w,
                            ],
                            metallic: material.metallicFactor,
                            roughness: material.roughnessFactor,
                            emissive: [
                                material.emissiveFactor.x, material.emissiveFactor.y,
                                material.emissiveFactor.z,
                            ]
                        )
                    }
                return CapabilityPreparationEntity(
                    reference: "scene:\(entity.rawValue)",
                    componentTypes: componentTypes,
                    localTransform: transform,
                    renderMaterial: renderMaterial,
                    rigidBody: rigidBody,
                    collider: collider
                )
            }
        )
    }

    private func verificationAssertions(
        for mutations: [SceneMutation]
    ) -> [TransactionVerificationAssertion] {
        var assertions: [TransactionVerificationAssertion] = []
        for mutation in mutations {
            switch mutation {
            case .spawnImportedMeshEntity, .spawnEmptyEntity, .spawnLightEntity, .spawnCameraEntity,
                 .duplicateEntity, .duplicateEntityWithOffset:
                break
            case let .deleteEntity(entityID):
                assertions.append(.deletedEntity(entityID))
                assertions.append(.entityIsAbsent(entityID))
            default:
                if let entityID = mutation.entityID {
                    assertions.append(.entityExists(entityID))
                }
            }
        }
        return assertions
    }

    private func legacyValidationError(
        for step: SceneEditStep,
        scene: SceneRuntime
    ) -> SceneEditPlanExecutorError? {
        do {
            _ = try buildMutations(step, scene: scene)
            return nil
        } catch let error as SceneEditPlanExecutorError {
            return error
        } catch {
            return nil
        }
    }

    private func canonicalCapabilityInput(for step: SceneEditStep) throws
        -> (data: Data, argumentNames: [String]) {
        let encoded = try JSONEncoder().encode(step)
        guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            throw SceneEditPlanExecutorError.invalidCapabilityInput(
                capabilityID: step.op.capabilityID,
                reason: "input is not a JSON object"
            )
        }
        object.removeValue(forKey: "op")
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return (data, object.keys.sorted())
    }

    /// Applies the component-level side-effects of `mutations` to `scene` so that subsequent
    /// steps in the same plan see the accumulated state. Only updates the fields that
    /// read-modify-write operations care about (Collider, RigidBody, transform).
    private func applyToLocalScene(_ scene: inout SceneRuntime, mutations: [SceneMutation]) {
        for m in mutations {
            switch m {
            case let .deleteEntity(rawID):
                _ = scene.destroyEntity(entityID(fromRaw: rawID))
            case let .setSceneName(rawID, value):
                _ = scene.setComponent(SceneNameComponent(value: value),
                                       for: entityID(fromRaw: rawID))
            case let .setCollider(rawID, collider):
                _ = scene.setComponent(collider, for: entityID(fromRaw: rawID))
            case let .setRigidBody(rawID, body):
                _ = scene.setComponent(body, for: entityID(fromRaw: rawID))
            case let .setLocalTransform(rawID, transform):
                _ = scene.setLocalTransform(transform, for: entityID(fromRaw: rawID))
            case let .setRenderMaterialComponent(rawID, baseColor, metallic, roughness, emissive):
                _ = scene.setComponent(
                    RenderMaterialComponent(
                        baseColorFactor: baseColor,
                        metallicFactor: metallic,
                        roughnessFactor: roughness,
                        emissiveFactor: emissive
                    ),
                    for: entityID(fromRaw: rawID)
                )
            case let .setCameraPose(rawID, transform, target, up):
                let entity = entityID(fromRaw: rawID)
                _ = scene.setLocalTransform(transform, for: entity)
                _ = scene.updateComponent(CameraComponent.self, for: entity) { camera in
                    camera.target = target
                    if let up { camera.up = up }
                }
            case let .setCameraFOV(rawID, degrees):
                _ = scene.updateComponent(CameraComponent.self,
                                          for: entityID(fromRaw: rawID)) {
                    $0.fovYRadians = degrees * .pi / 180
                }
            case let .setCameraAspectRatio(rawID, aspectRatio):
                _ = scene.updateComponent(CameraComponent.self,
                                          for: entityID(fromRaw: rawID)) {
                    $0.aspectRatio = max(0.001, aspectRatio)
                }
            case let .setCameraActive(rawID, active):
                _ = scene.updateComponent(CameraComponent.self,
                                          for: entityID(fromRaw: rawID)) {
                    $0.isActive = active
                }
            case let .setScriptBindings(rawID, bindings):
                let comp = ScriptComponent(bindings: bindings)
                _ = scene.setComponent(comp, for: entityID(fromRaw: rawID))
            default:
                break
            }
        }
    }

    // MARK: - Per-step dispatch

    private func buildMutations(_ step: SceneEditStep, scene: SceneRuntime) throws -> [SceneMutation] {
        switch step.op {

        case .spawnEntity:
            let label = step.label ?? "AI Entity"
            let pos = simd3(step.spawnPosition) ?? .zero
            let parentID = try resolveOptionalRef(step.spawnParentRef, op: step.op, scene: scene)
            switch step.spawnKind ?? "mesh" {
            case "empty":
                return [.spawnEmptyEntity(label: label, position: pos, parentID: parentID)]
            case "light":
                let lt = step.lightType.flatMap(LightType.init(rawValue:)) ?? .point
                let color: SIMD3<Float>? = step.color.flatMap { c in
                    c.count >= 3 ? SIMD3(c[0], c[1], c[2]) : nil
                }
                return [.spawnLightEntity(label: label, lightType: lt, position: pos,
                                          initialIntensity: step.intensity,
                                          initialColor: color,
                                          initialRange: step.range,
                                          initialCastShadows: step.lightCastShadows,
                                          parentID: parentID)]
            case "camera":
                return [.spawnCameraEntity(label: label, position: pos,
                                           initialFovYDegrees: step.cameraFovYDegrees,
                                           parentID: parentID)]
            default:
                return [.spawnImportedMeshEntity(label: label,
                                                 kindLabel: "Static Mesh",
                                                 meshIndex: 0,
                                                 position: pos,
                                                 parentID: parentID)]
            }

        case .deleteEntity:
            let id = try resolveEntityID(step, scene: scene)
            return [.deleteEntity(entityID: id)]

        case .duplicateEntity:
            let id = try resolveEntityID(step, scene: scene)
            if let off = step.duplicateOffset, off.count >= 3 {
                return [.duplicateEntityWithOffset(entityID: id,
                                                   positionOffset: SIMD3(off[0], off[1], off[2]))]
            }
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
            if let euler = step.eulerDegrees, euler.count >= 3 {
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
            let eid = entityID(fromRaw: id)
            var mat = scene.component(RenderMaterialComponent.self, for: eid) ?? RenderMaterialComponent()
            if let bc = step.materialBaseColor {
                if bc.count >= 4 {
                    mat.baseColorFactor = SIMD4(bc[0], bc[1], bc[2], bc[3])
                } else if bc.count >= 3 {
                    mat.baseColorFactor = SIMD4(bc[0], bc[1], bc[2], mat.baseColorFactor.w)
                }
            }
            if let m = step.materialMetallic  { mat.metallicFactor  = m }
            if let r = step.materialRoughness { mat.roughnessFactor  = r }
            if let e = step.materialEmissive, e.count >= 3 {
                mat.emissiveFactor = SIMD3(e[0], e[1], e[2])
            }
            return [.setRenderMaterialComponent(entityID: id,
                                                baseColorFactor: mat.baseColorFactor,
                                                metallicFactor: mat.metallicFactor,
                                                roughnessFactor: mat.roughnessFactor,
                                                emissiveFactor: mat.emissiveFactor)]

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

        case .setCameraAspectRatio:
            let id = try resolveEntityID(step, scene: scene)
            guard let aspectRatio = step.cameraAspectRatio else {
                throw SceneEditPlanExecutorError.missingField(op: step.op, field: "camera_aspect_ratio")
            }
            return [.setCameraAspectRatio(entityID: id, aspectRatio: aspectRatio)]

        case .setCameraActive:
            let id = try resolveEntityID(step, scene: scene)
            let active = step.cameraIsActive ?? true
            return [.setCameraActive(entityID: id, isActive: active)]

        case .setRigidBodyMotion:
            let id = try resolveEntityID(step, scene: scene)
            let eid = entityID(fromRaw: id)
            guard let typeStr = step.motionType else {
                throw SceneEditPlanExecutorError.missingField(op: step.op, field: "motion_type")
            }
            guard let mt = RigidBodyMotionType(rawValue: typeStr) else {
                throw SceneEditPlanExecutorError.unknownMotionType(typeStr)
            }
            var body = scene.component(RigidBody.self, for: eid) ?? RigidBody()
            body.motionType = mt
            return [.setRigidBody(entityID: id, body: body)]

        case .setRigidBodyMass:
            let id = try resolveEntityID(step, scene: scene)
            let eid = entityID(fromRaw: id)
            guard let v = step.mass else {
                throw SceneEditPlanExecutorError.missingField(op: step.op, field: "mass")
            }
            var body = scene.component(RigidBody.self, for: eid) ?? RigidBody()
            body.mass = v
            return [.setRigidBody(entityID: id, body: body)]

        case .setRigidBodyGravity:
            let id = try resolveEntityID(step, scene: scene)
            let eid = entityID(fromRaw: id)
            guard let v = step.gravityScale else {
                throw SceneEditPlanExecutorError.missingField(op: step.op, field: "gravity_scale")
            }
            var body = scene.component(RigidBody.self, for: eid) ?? RigidBody()
            body.gravityScale = v
            return [.setRigidBody(entityID: id, body: body)]

        case .setColliderTrigger:
            let id = try resolveEntityID(step, scene: scene)
            let eid = entityID(fromRaw: id)
            guard let v = step.isTrigger else {
                throw SceneEditPlanExecutorError.missingField(op: step.op, field: "is_trigger")
            }
            var collider = scene.component(Collider.self, for: eid)
                ?? Collider(shape: .box(halfExtents: SIMD3(0.5, 0.5, 0.5), center: .zero))
            collider.isTrigger = v
            return [.setCollider(entityID: id, collider: collider)]

        case .setColliderLayer:
            let id = try resolveEntityID(step, scene: scene)
            let eid = entityID(fromRaw: id)
            guard step.colliderLayerID != nil || step.colliderLayerMask != nil else {
                throw SceneEditPlanExecutorError.missingField(op: step.op,
                                                               field: "collider_layer_id or collider_layer_mask")
            }
            var collider = scene.component(Collider.self, for: eid)
                ?? Collider(shape: .box(halfExtents: SIMD3(0.5, 0.5, 0.5), center: .zero))
            if let layerID = step.colliderLayerID  { collider.layerID  = UInt16(clamping: layerID) }
            if let mask    = step.colliderLayerMask { collider.layerMask = UInt16(clamping: mask) }
            return [.setCollider(entityID: id, collider: collider)]

        case .setConstraintEnabled:
            let id = try resolveEntityID(step, scene: scene)
            guard let v = step.isEnabled else {
                throw SceneEditPlanExecutorError.missingField(op: step.op, field: "is_enabled")
            }
            return [.setConstraintEnabled(entityID: id, value: v)]

        case .setRigidBodyAllowSleep:
            let id = try resolveEntityID(step, scene: scene)
            let eid = entityID(fromRaw: id)
            guard let v = step.allowSleep else {
                throw SceneEditPlanExecutorError.missingField(op: step.op, field: "allow_sleep")
            }
            var body = scene.component(RigidBody.self, for: eid) ?? RigidBody()
            body.allowSleep = v
            return [.setRigidBody(entityID: id, body: body)]

        case .setColliderShape:
            let id = try resolveEntityID(step, scene: scene)
            let eid = entityID(fromRaw: id)
            guard let shapeStr = step.colliderShape else {
                throw SceneEditPlanExecutorError.missingField(op: step.op, field: "collider_shape")
            }
            guard let kind = ColliderShapeKind(rawValue: shapeStr) else {
                throw SceneEditPlanExecutorError.unknownColliderShape(shapeStr)
            }
            var collider = scene.component(Collider.self, for: eid)
                ?? Collider(shape: .box(halfExtents: SIMD3(0.5, 0.5, 0.5), center: .zero))
            switch kind {
            case .box:
                if case let .box(he, c) = collider.shape { collider.shape = .box(halfExtents: he, center: c) }
                else { collider.shape = .box(halfExtents: SIMD3(0.5, 0.5, 0.5), center: .zero) }
            case .sphere:
                if case let .sphere(r, c) = collider.shape { collider.shape = .sphere(radius: r, center: c) }
                else { collider.shape = .sphere(radius: 0.5, center: .zero) }
            case .capsule:
                if case let .capsule(r, hh, c) = collider.shape { collider.shape = .capsule(radius: r, halfHeight: hh, center: c) }
                else { collider.shape = .capsule(radius: 0.25, halfHeight: 0.5, center: .zero) }
            case .cylinder:
                if case let .cylinder(r, hh, c) = collider.shape { collider.shape = .cylinder(radius: r, halfHeight: hh, center: c) }
                else { collider.shape = .cylinder(radius: 0.5, halfHeight: 0.5, center: .zero) }
            case .heightField:
                if case let .heightField(rid, c) = collider.shape { collider.shape = .heightField(resourceID: rid, center: c) }
                else { collider.shape = .heightField(resourceID: nil, center: .zero) }
            case .mesh:
                if case let .mesh(rid, c) = collider.shape { collider.shape = .mesh(resourceID: rid, center: c) }
                else { collider.shape = .mesh(resourceID: nil, center: .zero) }
            case .convex:
                if case let .convex(rid, c) = collider.shape { collider.shape = .convex(resourceID: rid, center: c) }
                else { collider.shape = .convex(resourceID: nil, center: .zero) }
            }
            return [.setCollider(entityID: id, collider: collider)]

        case .setColliderBoxExtents:
            let id = try resolveEntityID(step, scene: scene)
            let eid = entityID(fromRaw: id)
            guard let ext = simd3(step.halfExtents) else {
                throw SceneEditPlanExecutorError.missingField(op: step.op, field: "half_extents")
            }
            var collider = scene.component(Collider.self, for: eid)
                ?? Collider(shape: .box(halfExtents: ext, center: .zero))
            let boxCenter: SIMD3<Float>
            if case let .box(_, c) = collider.shape { boxCenter = c } else { boxCenter = .zero }
            collider.shape = .box(halfExtents: ext, center: boxCenter)
            return [.setCollider(entityID: id, collider: collider)]

        case .setColliderSphereRadius:
            let id = try resolveEntityID(step, scene: scene)
            let eid = entityID(fromRaw: id)
            guard let r = step.radius else {
                throw SceneEditPlanExecutorError.missingField(op: step.op, field: "radius")
            }
            var collider = scene.component(Collider.self, for: eid)
                ?? Collider(shape: .sphere(radius: r, center: .zero))
            let sphereCenter: SIMD3<Float>
            if case let .sphere(_, c) = collider.shape { sphereCenter = c } else { sphereCenter = .zero }
            collider.shape = .sphere(radius: r, center: sphereCenter)
            return [.setCollider(entityID: id, collider: collider)]

        case .setColliderCapsule:
            let id = try resolveEntityID(step, scene: scene)
            let eid = entityID(fromRaw: id)
            guard step.radius != nil || step.halfHeight != nil else {
                throw SceneEditPlanExecutorError.missingField(op: step.op,
                                                               field: "radius or half_height")
            }
            var collider = scene.component(Collider.self, for: eid)
                ?? Collider(shape: .capsule(radius: 0.25, halfHeight: 0.5, center: .zero))
            var capRadius: Float = 0.25
            var capHalfHeight: Float = 0.5
            var capCenter: SIMD3<Float> = .zero
            if case let .capsule(r, hh, c) = collider.shape { capRadius = r; capHalfHeight = hh; capCenter = c }
            if let r  = step.radius     { capRadius     = r }
            if let hh = step.halfHeight { capHalfHeight = hh }
            collider.shape = .capsule(radius: capRadius, halfHeight: capHalfHeight, center: capCenter)
            return [.setCollider(entityID: id, collider: collider)]

        case .setColliderMaterial:
            let id = try resolveEntityID(step, scene: scene)
            let eid = entityID(fromRaw: id)
            guard step.friction != nil || step.restitution != nil || step.density != nil else {
                throw SceneEditPlanExecutorError.missingField(op: step.op,
                                                               field: "friction, restitution, or density")
            }
            var collider = scene.component(Collider.self, for: eid)
                ?? Collider(shape: .box(halfExtents: SIMD3(0.5, 0.5, 0.5), center: .zero))
            if let f = step.friction    { collider.material.friction    = f }
            if let r = step.restitution { collider.material.restitution = r }
            if let d = step.density     { collider.material.density     = d }
            return [.setCollider(entityID: id, collider: collider)]

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

        case .setScriptEnabled:
            let id = try resolveEntityID(step, scene: scene)
            let eid = entityID(fromRaw: id)
            guard let enabled = step.isEnabled else {
                throw SceneEditPlanExecutorError.missingField(op: step.op, field: "is_enabled")
            }
            let bindingIdx = step.scriptIndex ?? 0
            var component = scene.component(ScriptComponent.self, for: eid) ?? ScriptComponent()
            while component.bindings.count <= bindingIdx {
                component.bindings.append(ScriptBinding(ScriptHandle(rawValue: 0)))
            }
            component.bindings[bindingIdx].isEnabled = enabled
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
        case .array:
            // Arrays must round-trip through JSON; use jsonFragment as the canonical form.
            if let fragData = "{\"\(key)\":\(value.jsonFragment)}".data(using: .utf8),
               let fragDict = (try? JSONSerialization.jsonObject(with: fragData)) as? [String: Any],
               let arrValue = fragDict[key] {
                dict[key] = arrValue
            }
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
