import CapabilityRuntime
import Foundation
import SceneRuntime
import ScriptRuntime
import SIMDCompat

public struct CapabilityInvocationContext: Sendable, Equatable {
    public var selectedEntityID: UInt64?
    public var sceneEntityIDs: Set<UInt64>
    public var componentTypesByEntityID: [UInt64: Set<String>]
    public var isSceneEditable: Bool
    public var defaultSource: IntentSource
    public var defaultConfidence: Double
    public var defaultEvidence: [IntentEvidence]

    public init(selectedEntityID: UInt64? = nil,
                sceneEntityIDs: Set<UInt64> = [],
                componentTypesByEntityID: [UInt64: Set<String>] = [:],
                isSceneEditable: Bool = true,
                defaultSource: IntentSource = .system,
                defaultConfidence: Double = 1.0,
                defaultEvidence: [IntentEvidence] = []) {
        self.selectedEntityID = selectedEntityID
        self.sceneEntityIDs = sceneEntityIDs
        self.componentTypesByEntityID = componentTypesByEntityID
        self.isSceneEditable = isSceneEditable
        self.defaultSource = defaultSource
        self.defaultConfidence = defaultConfidence
        self.defaultEvidence = defaultEvidence
    }

    public init(sceneRuntime: SceneRuntime,
                selectedEntityID: UInt64? = nil,
                isSceneEditable: Bool = true,
                defaultSource: IntentSource = .system,
                defaultConfidence: Double = 1.0,
                defaultEvidence: [IntentEvidence] = []) {
        let entities = sceneRuntime.entities()
        var componentTypesByEntityID: [UInt64: Set<String>] = [:]
        componentTypesByEntityID.reserveCapacity(entities.count)
        for entity in entities {
            componentTypesByEntityID[entity.rawValue] = Self.componentTypeNames(for: entity,
                                                                                in: sceneRuntime)
        }
        self.init(selectedEntityID: selectedEntityID,
                  sceneEntityIDs: Set(entities.map(\.rawValue)),
                  componentTypesByEntityID: componentTypesByEntityID,
                  isSceneEditable: isSceneEditable,
                  defaultSource: defaultSource,
                  defaultConfidence: defaultConfidence,
                  defaultEvidence: defaultEvidence)
    }

    private static func componentTypeNames(for entity: EntityID,
                                           in sceneRuntime: SceneRuntime) -> Set<String> {
        var names: Set<String> = []
        insert(&names, "LocalTransform", if: sceneRuntime.hasComponent(LocalTransform.self, for: entity))
        insert(&names, "WorldTransform", if: sceneRuntime.hasComponent(WorldTransform.self, for: entity))
        insert(&names, "Parent", if: sceneRuntime.hasComponent(Parent.self, for: entity))
        insert(&names, "Children", if: sceneRuntime.hasComponent(Children.self, for: entity))
        insert(&names, "RigidBody", if: sceneRuntime.hasComponent(RigidBody.self, for: entity))
        insert(&names, "Collider", if: sceneRuntime.hasComponent(Collider.self, for: entity))
        insert(&names, "Constraint", if: sceneRuntime.hasComponent(Constraint.self, for: entity))
        insert(&names, "SceneNameComponent", if: sceneRuntime.hasComponent(SceneNameComponent.self, for: entity))
        insert(&names, "SceneKindComponent", if: sceneRuntime.hasComponent(SceneKindComponent.self, for: entity))
        insert(&names, "AssetReferenceComponent", if: sceneRuntime.hasComponent(AssetReferenceComponent.self,
                                                                                 for: entity))
        insert(&names, "RenderMeshComponent", if: sceneRuntime.hasComponent(RenderMeshComponent.self, for: entity))
        insert(&names, "RenderMaterialComponent", if: sceneRuntime.hasComponent(RenderMaterialComponent.self,
                                                                                 for: entity))
        insert(&names, "CameraComponent", if: sceneRuntime.hasComponent(CameraComponent.self, for: entity))
        insert(&names, "LightComponent", if: sceneRuntime.hasComponent(LightComponent.self, for: entity))
        insert(&names, "AudioSource", if: sceneRuntime.hasComponent(AudioSource.self, for: entity))
        insert(&names, "AnimationPlayer", if: sceneRuntime.hasComponent(AnimationPlayer.self, for: entity))
        insert(&names, "ScriptComponent", if: sceneRuntime.hasComponent(ScriptComponent.self, for: entity))
        return names
    }

    private static func insert(_ names: inout Set<String>, _ name: String, if condition: Bool) {
        if condition {
            names.insert(name)
        }
    }
}

public struct CapabilityInvocationPlan: Sendable, Equatable {
    public var approvalPolicy: TransactionApprovalPolicy
    public var questions: [ConfirmationQuestion]
    public var warnings: [String]

    public init(approvalPolicy: TransactionApprovalPolicy,
                questions: [ConfirmationQuestion] = [],
                warnings: [String] = []) {
        self.approvalPolicy = approvalPolicy
        self.questions = questions
        self.warnings = warnings
    }
}

public struct CapabilityValidationFailure: Sendable, Equatable {
    public var verb: String
    public var reason: String

    public init(verb: String, reason: String) {
        self.verb = verb
        self.reason = reason
    }
}

public struct CapabilityInvocationPlanner: Sendable {
    private let registry: CapabilityRegistry
    private let validator: CapabilityValidator
    private let scorer: AmbiguityScorer

    public init(registry: CapabilityRegistry = .default,
                gate: ReleasePhaseGate = ReleasePhaseGate(),
                scorer: AmbiguityScorer = AmbiguityScorer()) {
        self.registry = registry
        self.validator = CapabilityValidator(registry: registry, gate: gate)
        self.scorer = scorer
    }

    public func plan(transaction: TransactionIR,
                     context: CapabilityInvocationContext) throws -> CapabilityInvocationPlan {
        let intents = capabilityIntents(for: transaction, context: context)
        guard !intents.isEmpty else {
            return CapabilityInvocationPlan(approvalPolicy: transaction.approvalPolicy)
        }

        var failures: [CapabilityValidationFailure] = []
        var questions: [ConfirmationQuestion] = []
        var warnings: [String] = []
        var approvalPolicy = transaction.approvalPolicy

        for intent in intents {
            guard let descriptor = registry.descriptor(for: intent.verb) else {
                failures.append(CapabilityValidationFailure(verb: intent.verb,
                                                            reason: "unknown capability verb"))
                continue
            }
            let targetParseResult = parseTargetEntityIDs(intent.targetObjectIDs)
            if let invalidTarget = targetParseResult.invalidTarget {
                failures.append(CapabilityValidationFailure(verb: intent.verb,
                                                            reason: "invalid target '\(invalidTarget)'"))
                continue
            }

            let input = PreconditionCheckInput(
                verb: intent.verb,
                argumentNames: Set(intent.arguments.keys),
                targetEntityIDs: targetParseResult.entityIDs,
                selectedEntityID: context.selectedEntityID,
                sceneEntityIDs: context.sceneEntityIDs,
                componentTypesByEntityID: context.componentTypesByEntityID,
                isSceneEditable: context.isSceneEditable
            )

            do {
                _ = try validator.validate(verb: intent.verb, input: input)
            } catch let error as CapabilityValidationError {
                failures.append(CapabilityValidationFailure(verb: intent.verb,
                                                            reason: error.description))
                continue
            }

            let score = scorer.score(
                intent,
                context: AmbiguityScoringContext(descriptor: descriptor,
                                                 candidateEntityIDs: context.sceneEntityIDs.sorted(),
                                                 selectedEntityID: context.selectedEntityID)
            )
            warnings.append(contentsOf: score.signals.map { "[\(intent.verb)] \($0.note)" })

            if descriptor.requiresConfirmation || descriptor.isDestructive || score.level >= .low {
                approvalPolicy = approvalPolicy.escalated(to: .requiresApproval)
                if let question = scorer.makeQuestion(for: intent, score: score) {
                    questions.append(question)
                } else {
                    questions.append(makeConfirmationQuestion(for: intent,
                                                              descriptor: descriptor,
                                                              score: score))
                }
            }
        }

        guard failures.isEmpty else {
            throw CapabilityInvocationPlannerError.capabilityDenied(failures)
        }

        return CapabilityInvocationPlan(approvalPolicy: approvalPolicy,
                                        questions: questions,
                                        warnings: warnings)
    }

    private func capabilityIntents(for transaction: TransactionIR,
                                   context: CapabilityInvocationContext) -> [IntentIR] {
        if let intent = transaction.intent {
            return [intent]
        }
        return transaction.operations.enumerated().map { offset, operation in
            capabilityIntent(for: operation,
                             transaction: transaction,
                             index: offset,
                             context: context)
        }
    }

    private func capabilityIntent(for operation: TransactionOperation,
                                  transaction: TransactionIR,
                                  index: Int,
                                  context: CapabilityInvocationContext) -> IntentIR {
        let projection = CapabilityOperationProjection(operation: operation)
        return IntentIR(
            id: "\(transaction.id):capability:\(index)",
            verb: projection.verb,
            summary: transaction.summary.isEmpty ? projection.verb : transaction.summary,
            targetObjectIDs: projection.targetEntityID.map { ["scene:\($0)"] } ?? [],
            arguments: projection.arguments,
            confidence: context.defaultConfidence,
            evidence: context.defaultEvidence,
            source: context.defaultSource,
            createdAt: transaction.createdAt
        )
    }

    private func makeConfirmationQuestion(for intent: IntentIR,
                                          descriptor: CapabilityDescriptor,
                                          score: AmbiguityScore) -> ConfirmationQuestion {
        ConfirmationQuestion(
            id: "capability:\(intent.id)",
            kind: descriptor.isDestructive ? .approveDestructive : .chooseOne,
            promptShort: intent.summary.isEmpty ? "Confirm: \(intent.verb)" : intent.summary,
            promptDetail: "Capability: \(intent.verb)",
            options: [
                ConfirmationOption(id: "confirm",
                                   labelShort: "Apply",
                                   labelDetail: "Proceed with '\(intent.verb)'"),
                ConfirmationOption(id: "skip",
                                   labelShort: "Discard",
                                   labelDetail: "Discard this intent"),
            ],
            defaultOptionID: "confirm",
            severity: descriptor.isDestructive ? .destructive : .warn,
            reversible: true,
            ambiguityScore: score.score,
            sourceProposalIDs: [intent.id]
        )
    }

    private func parseTargetEntityIDs(_ targets: [String]) -> (entityIDs: [UInt64], invalidTarget: String?) {
        var entityIDs: [UInt64] = []
        entityIDs.reserveCapacity(targets.count)
        for target in targets {
            let raw = target.hasPrefix("scene:")
                ? String(target.dropFirst("scene:".count))
                : target
            guard let id = UInt64(raw) else {
                return (entityIDs, target)
            }
            entityIDs.append(id)
        }
        return (entityIDs, nil)
    }
}

private struct CapabilityOperationProjection {
    var verb: String
    var targetEntityID: UInt64?
    var arguments: [String: IntentArgumentValue]

    init(operation: TransactionOperation) {
        switch operation {
        case let .scene(mutation):
            self = Self(sceneMutation: mutation)
        case let .sequence(mutation):
            self = Self(sequenceMutation: mutation)
        case let .asset(mutation):
            self = Self(assetMutation: mutation)
        }
    }

    private init(sceneMutation: SceneMutation) {
        self.targetEntityID = sceneMutation.entityID
        self.arguments = [:]

        switch sceneMutation {
        case let .spawnImportedMeshEntity(label, _, _, position),
             let .spawnEmptyEntity(label, position):
            self.verb = "scene.spawn_entity"
            self.arguments = [
                "label": .string(label),
                "position": .vec3(IntentVector3(position)),
            ]
        case let .spawnLightEntity(label, _, position):
            self.verb = "scene.spawn_light"
            self.arguments = [
                "label": .string(label),
                "position": .vec3(IntentVector3(position)),
            ]
        case let .spawnCameraEntity(label, position):
            self.verb = "scene.spawn_camera"
            self.arguments = [
                "label": .string(label),
                "position": .vec3(IntentVector3(position)),
            ]
        case .deleteEntity:
            self.verb = "scene.delete_entity"
        case .duplicateEntity:
            self.verb = "scene.duplicate_entity"
        case let .duplicateEntityWithOffset(_, offset):
            self.verb = "scene.duplicate_entity_offset"
            self.arguments["offset"] = .vec3(IntentVector3(offset))
        case let .moveEntity(_, parentID, index):
            self.verb = "scene.reparent_entity"
            if let parentID {
                self.arguments["parent_id"] = .stableID(parentID)
            }
            self.arguments["index"] = .integer(Int64(index))
        case let .setLocalTransform(_, transform):
            self.verb = "scene.set_transform"
            self.arguments["translation"] = .vec3(IntentVector3(transform.translation))
        case let .setSceneName(_, value):
            self.verb = "scene.set_name"
            self.arguments["name"] = .string(value)
        case let .setRigidBodyMotionType(_, value):
            self.verb = "scene.set_rigid_body_motion_type"
            self.arguments["motion_type"] = .string(value.rawValue)
        case let .setRigidBodyMass(_, value):
            self.verb = "scene.set_rigid_body_mass"
            self.arguments["mass"] = .number(Double(value))
        case let .setRigidBodyGravityScale(_, value):
            self.verb = "scene.set_rigid_body_gravity_scale"
            self.arguments["gravity_scale"] = .number(Double(value))
        case let .setRigidBodyAllowSleep(_, value):
            self.verb = "scene.set_rigid_body_allow_sleep"
            self.arguments["allow_sleep"] = .bool(value)
        case .setCollider:
            self.verb = "scene.set_collider"
        case let .setColliderTrigger(_, value):
            self.verb = "scene.set_collider_trigger"
            self.arguments["is_trigger"] = .bool(value)
        case let .setColliderShapeType(_, kind):
            self.verb = "scene.set_collider_shape"
            self.arguments["collider_shape"] = .string(kind.rawValue)
        case let .setColliderShapeBoxHalfExtents(_, halfExtents):
            self.verb = "scene.set_collider_box_extents"
            self.arguments["half_extents"] = .vec3(IntentVector3(halfExtents))
        case let .setColliderShapeSphereRadius(_, radius):
            self.verb = "scene.set_collider_sphere_radius"
            self.arguments["radius"] = .number(Double(radius))
        case let .setColliderShapeCapsuleRadius(_, radius):
            self.verb = "scene.set_collider_capsule"
            self.arguments["radius"] = .number(Double(radius))
        case let .setColliderShapeCapsuleHalfHeight(_, halfHeight):
            self.verb = "scene.set_collider_capsule"
            self.arguments["half_height"] = .number(Double(halfHeight))
        case let .setColliderMaterialFriction(_, value):
            self.verb = "scene.set_collider_material"
            self.arguments["friction"] = .number(Double(value))
        case let .setColliderMaterialRestitution(_, value):
            self.verb = "scene.set_collider_material"
            self.arguments["restitution"] = .number(Double(value))
        case let .setColliderMaterialDensity(_, value):
            self.verb = "scene.set_collider_material"
            self.arguments["density"] = .number(Double(value))
        case let .setColliderLayer(_, layerID):
            self.verb = "scene.set_collider_layer"
            self.arguments["layer_id"] = .integer(Int64(layerID))
        case let .setColliderLayerMask(_, layerMask):
            self.verb = "scene.set_collider_layer"
            self.arguments["layer_mask"] = .integer(Int64(layerMask))
        case let .setConstraintEnabled(_, value):
            self.verb = "scene.set_constraint_enabled"
            self.arguments["is_enabled"] = .bool(value)
        case let .setLightType(_, type):
            self.verb = "scene.set_light_type"
            self.arguments["light_type"] = .string(type.rawValue)
        case let .setLightColor(_, color):
            self.verb = "scene.set_light_color"
            self.arguments["color"] = .vec3(IntentVector3(color))
        case let .setLightIntensity(_, intensity):
            self.verb = "scene.set_light_intensity"
            self.arguments["intensity"] = .number(Double(intensity))
        case let .setLightRange(_, range):
            self.verb = "scene.set_light_range"
            self.arguments["range"] = .number(Double(range))
        case let .setLightSpotInnerAngle(_, angleDegrees):
            self.verb = "scene.set_light_spot_inner_angle"
            self.arguments["spot_inner_angle"] = .number(Double(angleDegrees))
        case let .setLightSpotOuterAngle(_, angleDegrees):
            self.verb = "scene.set_light_spot_outer_angle"
            self.arguments["spot_outer_angle"] = .number(Double(angleDegrees))
        case let .setLightCastShadows(_, value):
            self.verb = "scene.set_light_cast_shadows"
            self.arguments["cast_shadows"] = .bool(value)
        case let .setMeshColorTint(_, color):
            self.verb = "scene.set_mesh_color"
            self.arguments["color"] = .vec3(IntentVector3(color))
        case let .setRenderMeshVisibility(_, isVisible):
            self.verb = "scene.set_mesh_visibility"
            self.arguments["is_visible"] = .bool(isVisible)
        case let .setRenderMaterialComponent(_, baseColorFactor, metallicFactor, roughnessFactor, _):
            self.verb = "scene.set_render_material"
            self.arguments["base_color"] = .vec3(IntentVector3(SIMD3(baseColorFactor.x, baseColorFactor.y, baseColorFactor.z)))
            self.arguments["metallic"] = .number(Double(metallicFactor))
            self.arguments["roughness"] = .number(Double(roughnessFactor))
        case .setScriptBindings:
            self.verb = "scene.set_script_bindings"
        case let .setCameraPose(_, localTransform, target, _):
            self.verb = "scene.set_camera_pose"
            self.arguments["position"] = .vec3(IntentVector3(localTransform.translation))
            self.arguments["target"] = .vec3(IntentVector3(target))
        case let .setCameraFOV(_, fovYDegrees):
            self.verb = "scene.set_camera_fov"
            self.arguments["fov_y_degrees"] = .number(Double(fovYDegrees))
        case let .setCameraActive(_, isActive):
            self.verb = "scene.set_camera_active"
            self.arguments["is_active"] = .bool(isActive)
        case let .setAudioSource(_, source):
            self.verb = "scene.set_audio_source"
            self.arguments["audio_clip"] = .string(source.clipName)
        case let .setAnimationPlayer(_, clipName, speed, loop, isPlaying):
            self.verb = "scene.set_animation_player"
            if let clipName {
                self.arguments["clip_name"] = .string(clipName)
            }
            self.arguments["speed"] = .number(Double(speed))
            self.arguments["loop"] = .bool(loop)
            self.arguments["is_playing"] = .bool(isPlaying)
        }
    }

    private init(sequenceMutation: SequenceMutation) {
        switch sequenceMutation {
        case .replaceDocument:
            self.verb = "sequence.replace_document"
            self.targetEntityID = nil
            self.arguments = [:]
        }
    }

    private init(assetMutation: AssetMutation) {
        switch assetMutation {
        case let .scanProject(rootPath):
            self.verb = "asset.scan_project"
            self.targetEntityID = nil
            self.arguments = ["root_path": .string(rootPath)]
        }
    }
}

private extension TransactionApprovalPolicy {
    func escalated(to other: TransactionApprovalPolicy) -> TransactionApprovalPolicy {
        if self == .forbidden || other == .forbidden {
            return .forbidden
        }
        if self == .requiresApproval || other == .requiresApproval {
            return .requiresApproval
        }
        return .automatic
    }
}
