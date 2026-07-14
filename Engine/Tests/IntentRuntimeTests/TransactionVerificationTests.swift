import CapabilityRuntime
import Foundation
import IntentRuntime
import SceneRuntime
import Testing

@Suite("Transaction verification")
struct TransactionVerificationTests {
    private struct RenameInput: GuavaCapabilityInput {
        var entityID: UInt64
        var name: String

        enum CodingKeys: String, CodingKey {
            case entityID = "entity_id"
            case name
        }

        static let inputSchema = JSONSchema.object(properties: [
            "entity_id": .integer(minimum: 0),
            "name": .string(minLength: 1, maxLength: 128),
        ], required: ["entity_id", "name"])
    }

    private struct RenameCapability: GuavaCapability {
        static let id = "test.rename"
        static let title = "Rename"
        static let description = "Rename an entity"
        static let domain = "scene"
        static let access = CapabilityAccess.reversibleWrite
        static let releasePhase = CapabilityReleasePhase.stable

        static func prepare(input: RenameInput,
                            context: CapabilityPreparationContext) throws -> PreparedCapability {
            PreparedCapability(
                operations: [.scene(.setSceneName(entityID: input.entityID, value: input.name))],
                preview: CapabilityPreview(summary: "Rename", targetReferences: ["scene:\(input.entityID)"]),
                assertions: [.entityExists(input.entityID)]
            )
        }
    }

    private struct UnsafeInput: GuavaCapabilityInput {
        var payload: String
        static let inputSchema = JSONSchema.object(properties: ["payload": .any()],
                                                   required: ["payload"])
    }

    private struct UnsafeCapability: GuavaCapability {
        static let id = "test.unsafe"
        static let title = "Unsafe"
        static let description = "Contains an open value"
        static let domain = "scene"
        static let access = CapabilityAccess.reversibleWrite
        static let releasePhase = CapabilityReleasePhase.stable

        static func prepare(input: UnsafeInput,
                            context: CapabilityPreparationContext) throws -> PreparedCapability {
            PreparedCapability(operations: [.scene(.setSceneName(entityID: 1, value: input.payload))],
                               preview: CapabilityPreview(summary: "Unsafe"),
                               assertions: [.entityExists(1)])
        }
    }

    private struct DeclaredTransformInput: DeclaredCapabilityInput {
        @EntityReference(requires: [.localTransform])
        var entity: SceneEntityRef

        @AIField(description: "New world position")
        var position: Vec3?

        @ValueRange(min: 0.001, max: 1_000)
        var scale: Vec3?

        init() {}
    }

    private struct DeclaredTransformCapability: GuavaCapability {
        static let id = "test.declared_transform"
        static let title = "Declared transform"
        static let description = "Exercises generated input metadata"
        static let domain = "scene"
        static let access = CapabilityAccess.reversibleWrite
        static let releasePhase = CapabilityReleasePhase.stable

        static func prepare(input: DeclaredTransformInput,
                            context: CapabilityPreparationContext) throws -> PreparedCapability {
            let rawID = UInt64(input.entity.rawValue.dropFirst("scene:".count)) ?? 0
            return PreparedCapability(
                operations: [.scene(.setSceneName(entityID: rawID, value: "Declared"))],
                preview: CapabilityPreview(summary: "Declared input", targetReferences: [input.entity.rawValue]),
                assertions: [.entityExists(rawID)]
            )
        }
    }

    @Test("typed registration derives contract decoder and prepared transaction")
    func typedRegistrationUsesOneContract() throws {
        let registration = try AnyCapabilityRegistration(RenameCapability.self)
        let input = try JSONSerialization.data(withJSONObject: [
            "entity_id": 42,
            "name": "Renamed",
        ], options: [.sortedKeys])
        let prepared = try registration.prepare(validatedInput: input,
                                                context: CapabilityPreparationContext(sceneRevision: 7))
        #expect(registration.contract.id == "test.rename")
        #expect(registration.descriptor.contract.schemaHash == registration.contract.schemaHash)
        #expect(prepared.operations == [.scene(.setSceneName(entityID: 42, value: "Renamed"))])
        #expect(prepared.assertions == [.entityExists(42)])

        #expect(throws: CapabilityRegistrationError.writeSchemaContainsUnsupportedType("test.unsafe")) {
            try AnyCapabilityRegistration(UnsafeCapability.self)
        }
    }

    @Test("field declarations generate strict schema and the matching decoder")
    func declaredInputGeneratesSchemaAndDecoder() throws {
        let registration = try AnyCapabilityRegistration(DeclaredTransformCapability.self)
        let schema = registration.contract.inputSchema
        #expect(schema.additionalProperties == false)
        #expect(schema.required == ["entity"])
        #expect(schema.properties["position"]?.description == nil)
        let positionAlternatives = try #require(schema.properties["position"]?.oneOf)
        #expect(positionAlternatives.contains { $0.description == "New world position" })
        let scaleAlternatives = try #require(schema.properties["scale"]?.oneOf)
        let scaleSchema = try #require(scaleAlternatives.first { $0.type == .array })
        #expect(scaleSchema.items.first?.minimum == 0.001)
        #expect(scaleSchema.items.first?.maximum == 1_000)

        let input = Data(#"{"entity":"scene:42","position":[1,2,3]}"#.utf8)
        let prepared = try registration.prepare(
            validatedInput: input,
            context: CapabilityPreparationContext(sceneRevision: 1)
        )
        #expect(prepared.preview.targetReferences == ["scene:42"])
        #expect(prepared.assertions == [.entityExists(42)])

        #expect(throws: CapabilityRegistrationError.self) {
            try registration.prepare(
                validatedInput: Data(#"{"entity":"not-a-scene-ref"}"#.utf8),
                context: CapabilityPreparationContext(sceneRevision: 1)
            )
        }
    }

    @Test("failed post-apply assertion restores the scene snapshot")
    func assertionFailureRollsBack() throws {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        _ = scene.setComponent(SceneNameComponent(value: "Original"), for: entity)
        let originalRevision = scene.snapshot.revision
        let transaction = TransactionIR(
            summary: "Rename with a deliberately failing assertion",
            operations: [.scene(.setSceneName(entityID: entity.rawValue, value: "Changed"))],
            verificationAssertions: [.entityIsAbsent(entity.rawValue)],
            baseRevisions: TransactionBaseRevisions(sceneRevision: originalRevision),
            provenance: .proposal
        )
        var context = TransactionExecutionContext(sceneRuntime: scene)

        #expect(throws: TransactionExecutorError.self) {
            try TransactionExecutor().apply(transaction, to: &context)
        }
        #expect(context.sceneRuntime?.snapshot.revision == originalRevision)
        #expect(context.sceneRuntime?.component(SceneNameComponent.self, for: entity)?.value == "Original")
    }

    @Test("explicit destructive AI invocation requires plan and destructive confirmations")
    func destructiveAIUsesTwoRounds() throws {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        let descriptor = try #require(CapabilityRegistry.aiDefault.descriptor(for: "scene.delete_entity"))
        let snapshotID = UUID()
        let transaction = TransactionIR(
            summary: "Delete entity",
            operations: [.scene(.deleteEntity(entityID: entity.rawValue))],
            capabilityInvocations: [CapabilityInvocationRecord(
                capabilityID: descriptor.verb,
                capabilityVersion: descriptor.version,
                schemaHash: descriptor.contract.schemaHash,
                inputDigest: descriptor.contract.inputDigest(Data("{}".utf8)),
                argumentNames: ["entity_id"],
                targetReferences: ["scene:\(entity.rawValue)"],
                access: .destructiveWrite,
                exposureSnapshotID: snapshotID
            )],
            verificationAssertions: [.deletedEntity(entity.rawValue), .entityIsAbsent(entity.rawValue)],
            baseRevisions: TransactionBaseRevisions(sceneRevision: scene.snapshot.revision),
            approvalPolicy: .automatic,
            provenance: .proposal
        )
        let coordinator = IntentRuntimeCoordinator()
        var context = TransactionExecutionContext(sceneRuntime: scene)
        let capabilityContext = CapabilityInvocationContext(sceneRuntime: scene,
                                                            defaultSource: .ai)

        let first = try coordinator.submitPlan(transaction,
                                               executionContext: &context,
                                               capabilityContext: capabilityContext)
        let firstRequest = try #require(first.confirmationRequest)
        #expect(firstRequest.questions.first?.severity == .warn)
        #expect(first.stagedResult?.preview.mutationSummaries == ["scene:delete:\(entity.rawValue)"])
        let second = try coordinator.resolvePlanConfirmation(
            ConfirmationResolution(batchID: firstRequest.batchID,
                                   correlationID: firstRequest.correlationID,
                                   answers: [ConfirmationAnswer(questionID: firstRequest.questions[0].id,
                                                                outcome: .accepted,
                                                                pickedOptionID: "confirm")],
                                   partial: false),
            executionContext: &context
        )
        let secondRequest = try #require(second.confirmationRequest)
        #expect(second.disposition == .confirmationRequested)
        #expect(secondRequest.questions.first?.severity == .destructive)
        #expect(context.sceneRuntime?.contains(entity) == true)

        let applied = try coordinator.resolvePlanConfirmation(
            ConfirmationResolution(batchID: secondRequest.batchID,
                                   correlationID: secondRequest.correlationID,
                                   answers: [ConfirmationAnswer(questionID: secondRequest.questions[0].id,
                                                                outcome: .accepted,
                                                                pickedOptionID: "confirm")],
                                   partial: false),
            executionContext: &context
        )
        #expect(applied.disposition == .applied)
        #expect(context.sceneRuntime?.contains(entity) == false)
    }

    @Test("AI capability authority is checked again after confirmation")
    func permissionRevocationBeforeApplyFailsClosed() throws {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        _ = scene.setComponent(SceneNameComponent(value: "Original"), for: entity)
        let descriptor = try #require(CapabilityRegistry.aiDefault.descriptor(for: "scene.set_name"))
        let transaction = TransactionIR(
            summary: "Rename entity",
            operations: [.scene(.setSceneName(entityID: entity.rawValue, value: "Changed"))],
            capabilityInvocations: [CapabilityInvocationRecord(
                capabilityID: descriptor.verb,
                capabilityVersion: descriptor.version,
                schemaHash: descriptor.contract.schemaHash,
                inputDigest: descriptor.contract.inputDigest(Data("{}".utf8)),
                argumentNames: ["entity_id", "name"],
                targetReferences: ["scene:\(entity.rawValue)"],
                access: .reversibleWrite,
                exposureSnapshotID: UUID()
            )],
            verificationAssertions: [.entityExists(entity.rawValue)],
            baseRevisions: TransactionBaseRevisions(sceneRevision: scene.snapshot.revision),
            approvalPolicy: .automatic,
            provenance: .proposal
        )
        let coordinator = IntentRuntimeCoordinator()
        var context = TransactionExecutionContext(sceneRuntime: scene)
        let submitted = try coordinator.submitPlan(
            transaction,
            executionContext: &context,
            capabilityContext: CapabilityInvocationContext(sceneRuntime: scene, defaultSource: .ai)
        )
        let request = try #require(submitted.confirmationRequest)

        var revoked = descriptor
        revoked.isAIExposed = false
        coordinator.configureCapabilityPlanner(CapabilityInvocationPlanner(
            registry: CapabilityRegistry(capabilities: [revoked])
        ))

        #expect(throws: CapabilityInvocationPlannerError.self) {
            try coordinator.resolvePlanConfirmation(
                ConfirmationResolution(
                    batchID: request.batchID,
                    correlationID: request.correlationID,
                    answers: [ConfirmationAnswer(
                        questionID: request.questions[0].id,
                        outcome: .accepted,
                        pickedOptionID: "confirm"
                    )],
                    partial: false
                ),
                executionContext: &context
            )
        }
        #expect(context.sceneRuntime?.component(SceneNameComponent.self, for: entity)?.value == "Original")
        #expect(coordinator.pendingConfirmationRequest() == nil)
    }

    @Test("explicit AI authority cannot bypass the capability planner")
    func missingCapabilityContextFailsClosed() throws {
        let descriptor = try #require(CapabilityRegistry.aiDefault.descriptor(for: "scene.set_name"))
        let transaction = TransactionIR(
            summary: "Forged direct invocation",
            operations: [],
            capabilityInvocations: [CapabilityInvocationRecord(
                capabilityID: descriptor.verb,
                capabilityVersion: descriptor.version,
                schemaHash: descriptor.contract.schemaHash,
                inputDigest: descriptor.contract.inputDigest(Data("{}".utf8)),
                access: descriptor.access,
                exposureSnapshotID: UUID()
            )],
            approvalPolicy: .automatic,
            provenance: .proposal
        )
        var context = TransactionExecutionContext(sceneRuntime: SceneRuntime())
        #expect(throws: IntentRuntimeCoordinatorError.self) {
            try IntentRuntimeCoordinator().submitPlan(transaction, executionContext: &context)
        }
    }
}
