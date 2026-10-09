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
        insert(&names, "WorldTransform", if: sceneRuntime.hasComponent(WorldTransform.self, for: entity))
        insert(&names, "Parent", if: sceneRuntime.hasComponent(Parent.self, for: entity))
        insert(&names, "Children", if: sceneRuntime.hasComponent(Children.self, for: entity))
        insert(&names, "SceneNameComponent", if: sceneRuntime.hasComponent(SceneNameComponent.self, for: entity))
        insert(&names, "SceneKindComponent", if: sceneRuntime.hasComponent(SceneKindComponent.self, for: entity))
        for schema in sceneRuntime.componentRegistry.schemas {
            if sceneRuntime.hasComponent(typeID: schema.typeID, for: entity) {
                names.insert(schema.runtimeTypeName)
            }
        }
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
    private let allowExternalSideEffects: Bool
    private let pluginAuthorities: [String: PluginCapabilityAuthority]
    private let pluginAuthorityValidator: @Sendable (PluginCapabilityAuthority) -> Bool

    public init(registry: CapabilityRegistry = .aiDefault,
                gate: ReleasePhaseGate = ReleasePhaseGate(),
                scorer: AmbiguityScorer = AmbiguityScorer(),
                allowExternalSideEffects: Bool = false,
                pluginAuthorities: [String: PluginCapabilityAuthority] = [:],
                pluginAuthorityValidator: @escaping @Sendable
                    (PluginCapabilityAuthority) -> Bool = { _ in true }) {
        self.registry = registry
        self.validator = CapabilityValidator(registry: registry, gate: gate)
        self.scorer = scorer
        self.allowExternalSideEffects = allowExternalSideEffects
        self.pluginAuthorities = pluginAuthorities
        self.pluginAuthorityValidator = pluginAuthorityValidator
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

        for (index, intent) in intents.enumerated() {
            guard let descriptor = registry.descriptor(for: intent.verb) else {
                failures.append(CapabilityValidationFailure(verb: intent.verb,
                                                            reason: "unknown capability verb"))
                continue
            }
            if !transaction.capabilityInvocations.isEmpty {
                let record = transaction.capabilityInvocations[index]
                if let reason = invocationRecordDenialReason(record, descriptor: descriptor) {
                    failures.append(CapabilityValidationFailure(verb: intent.verb, reason: reason))
                    continue
                }
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

            let isModelOrPluginWrite = descriptor.access.isWrite
                && (!transaction.capabilityInvocations.isEmpty || intent.source == .ai)
            if isModelOrPluginWrite || descriptor.requiresConfirmation
                || descriptor.isDestructive || score.level >= .low {
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
        if !transaction.capabilityInvocations.isEmpty {
            return transaction.capabilityInvocations.enumerated().map { index, record in
                IntentIR(
                    id: "\(transaction.id):invocation:\(index)",
                    verb: record.capabilityID,
                    summary: transaction.summary,
                    targetObjectIDs: record.targetReferences,
                    arguments: Dictionary(uniqueKeysWithValues: record.argumentNames.map {
                        ($0, IntentArgumentValue.string("<validated>"))
                    }),
                    confidence: context.defaultConfidence,
                    evidence: context.defaultEvidence,
                    source: context.defaultSource,
                    createdAt: transaction.createdAt
                )
            }
        }
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

    private func invocationRecordDenialReason(_ record: CapabilityInvocationRecord,
                                              descriptor: CapabilityDescriptor) -> String? {
        let contract = descriptor.contract
        guard descriptor.isAIExposed else { return "capability is not approved for AI exposure" }
        if contract.access.isWrite && !contract.inputSchema.isStrictCapabilityInput {
            return "write capability schema contains an open or unsupported type"
        }
        guard record.capabilityVersion == contract.version else {
            return "capability version mismatch (expected \(contract.version), got \(record.capabilityVersion))"
        }
        guard record.schemaHash == contract.schemaHash else { return "capability schema hash mismatch" }
        guard record.access == contract.access else { return "capability access level mismatch" }
        guard record.sourcePluginID == contract.source.pluginID else { return "capability source mismatch" }
        if let pluginID = contract.source.pluginID {
            guard let authority = record.pluginAuthority,
                  authority == pluginAuthorities[pluginID],
                  pluginAuthorityValidator(authority) else {
                return "plugin authorisation or PluginHost generation changed"
            }
        } else if record.pluginAuthority != nil {
            return "built-in capability carried forged plugin authority"
        }
        if contract.access == .externalSideEffect && !allowExternalSideEffects {
            return "external side-effect capabilities are disabled"
        }
        return nil
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
        case let .spawnImportedMeshEntity(label, _, _, position, _),
             let .spawnEmptyEntity(label, position, _):
            self.verb = "scene.spawn_entity"
            self.arguments = [
                "label": .string(label),
                "position": .vec3(IntentVector3(position)),
            ]
        case let .spawnLightEntity(label, _, position, _, _, _, _, _):
            self.verb = "scene.spawn_light"
            self.arguments = [
                "label": .string(label),
                "position": .vec3(IntentVector3(position)),
            ]
        case let .spawnCameraEntity(label, position, _, _):
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
        case let .setComponentData(_, typeID, _, _):
            self.verb = "scene.set_component_data"
            self.arguments["type_id"] = .string(typeID)
        case let .addComponent(_, typeID):
            self.verb = "scene.add_component"
            self.arguments["type_id"] = .string(typeID)
        case let .removeComponentData(_, typeID):
            self.verb = "scene.remove_component_data"
            self.arguments["type_id"] = .string(typeID)
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
