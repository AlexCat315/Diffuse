import AssetPipeline
import CapabilityRuntime
import Foundation
import IntentRuntime
import ObservationBus
import SceneRuntime
import SequenceRuntime
import ScriptRuntime
import Testing
import SIMDCompat

@Suite("IntentRuntime")
struct IntentRuntimeTests {
    @Test("scene transactions preview without mutating the base scene and apply cleanly")
    func sceneTransactionsPreviewAndApply() throws {
        let executor = TransactionExecutor()
        let transaction = TransactionIR(intent: IntentIR(verb: "scene.spawn_entity",
                                                         summary: "Spawn imported mesh",
                                                         source: .human),
                                        summary: "Spawn imported mesh",
                                        operations: [
                                            .scene(.spawnImportedMeshEntity(label: "Hero",
                                                                           kindLabel: "Static Mesh",
                                                                           meshIndex: 9,
                                                                           position: SIMD3<Float>(0, 1, 0)))
                                        ],
                                        baseRevisions: TransactionBaseRevisions(sceneRevision: 0),
                                        provenance: .authored)
        let baseContext = TransactionExecutionContext(sceneRuntime: SceneRuntime())

        let preview = try executor.preview(transaction, from: baseContext)

        #expect(preview.changedDomains == [.scene])
        #expect(preview.createdEntityIDs.count == 1)
        #expect(baseContext.sceneRuntime?.snapshot.entityCount == 0)

        var applyContext = baseContext
        let applied = try executor.apply(transaction, to: &applyContext)
        let scene = try #require(applyContext.sceneRuntime)
        let createdRawID = try #require(applied.createdEntityIDs.first)
        let entity = entityID(from: createdRawID)

        #expect(scene.snapshot.entityCount == 1)
        #expect(applied.sceneRevision == scene.snapshot.revision)
        #expect(scene.component(SceneNameComponent.self, for: entity)?.value == "Hero")
        #expect(scene.component(RenderMeshComponent.self, for: entity)?.meshIndex == 9)
        #expect(scene.localTransform(for: entity)?.translation == SIMD3<Float>(0, 1, 0))
    }

    @Test("scene transactions reject stale base revisions")
    func sceneTransactionsRejectStaleBaseRevisions() {
        let executor = TransactionExecutor()
        var scene = SceneRuntime()
        _ = scene.createEntity()
        let actualRevision = scene.snapshot.revision
        var context = TransactionExecutionContext(sceneRuntime: scene)
        let transaction = TransactionIR(intent: IntentIR(verb: "scene.spawn_entity",
                                                         summary: "Spawn imported mesh",
                                                         source: .human),
                                        summary: "Spawn imported mesh",
                                        operations: [
                                            .scene(.spawnImportedMeshEntity(label: "Hero",
                                                                           kindLabel: "Static Mesh",
                                                                           meshIndex: 3,
                                                                           position: .zero))
                                        ],
                                        baseRevisions: TransactionBaseRevisions(sceneRevision: actualRevision + 1),
                                        provenance: .authored)

        #expect(throws: TransactionExecutorError.self) {
            try executor.apply(transaction, to: &context)
        }
    }

    @Test("scene transactions update script binding parameters")
    func sceneTransactionsUpdateScriptBindings() throws {
        let executor = TransactionExecutor()
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        let initial = ScriptBinding(ScriptHandle(rawValue: 7),
                                    isEnabled: false,
                                    parametersJSON: "{}")
        _ = scene.setComponent(ScriptComponent(bindings: [initial]), for: entity)

        let next = ScriptBinding(ScriptHandle(rawValue: 7),
                                 isEnabled: true,
                                 parametersJSON: "{\"speed\":3}")
        let transaction = TransactionIR(
            intent: IntentIR(verb: "scene.set_script_parameters",
                             summary: "Update script parameters",
                             source: .human),
            summary: "Update script parameters",
            operations: [.scene(.setScriptBindings(entityID: entity.rawValue, bindings: [next]))],
            baseRevisions: TransactionBaseRevisions(sceneRevision: scene.snapshot.revision),
            provenance: .authored
        )
        var context = TransactionExecutionContext(sceneRuntime: scene)

        let applied = try executor.apply(transaction, to: &context)
        let updated = try #require(context.sceneRuntime?.component(ScriptComponent.self, for: entity))

        #expect(applied.changedDomains == [.scene])
        #expect(updated.bindings == [next])
    }

    @Test("scene transactions update rigid body inspector fields")
    func sceneTransactionsUpdateRigidBodyInspectorFields() throws {
        let executor = TransactionExecutor()
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        _ = scene.setComponent(RigidBody(motionType: .dynamic,
                                         mass: 80,
                                         gravityScale: 1,
                                         allowSleep: true),
                               for: entity)

        let transaction = TransactionIR(
            intent: IntentIR(verb: "scene.update_rigidbody",
                             summary: "Update rigid body inspector fields",
                             source: .human),
            summary: "Update rigid body inspector fields",
            operations: [
                .scene(.setRigidBodyMotionType(entityID: entity.rawValue, value: .kinematic)),
                .scene(.setRigidBodyMass(entityID: entity.rawValue, value: 42)),
                .scene(.setRigidBodyGravityScale(entityID: entity.rawValue, value: 0.5)),
            ],
            baseRevisions: TransactionBaseRevisions(sceneRevision: scene.snapshot.revision),
            provenance: .authored
        )
        var context = TransactionExecutionContext(sceneRuntime: scene)

        let applied = try executor.apply(transaction, to: &context)
        let updated = try #require(context.sceneRuntime?.component(RigidBody.self, for: entity))

        #expect(applied.changedDomains == [.scene])
        #expect(updated.motionType == .kinematic)
        #expect(updated.mass == 42)
        #expect(updated.gravityScale == 0.5)
    }

    @Test("sequence transactions replace the document and issue a new revision")
    func sequenceTransactionsAdvanceRevisions() throws {
        let executor = TransactionExecutor()
        let previousRevision = SequenceRevision(id: "rev.0001",
                                               author: "human",
                                               transactionIDs: ["tx.old"])
        let current = SequenceDocument(name: "Sequence A",
                                       sceneDocumentURI: "scene://main",
                                       frameRange: FrameRange(start: 0, end: 48),
                                       revision: previousRevision)
        let replacement = SequenceDocument(name: "Sequence B",
                                           sceneDocumentURI: "scene://main",
                                           frameRange: FrameRange(start: 0, end: 96),
                                           revision: SequenceRevision(id: "draft.0002"))
        let transaction = TransactionIR(intent: IntentIR(verb: "sequence.replace_document",
                                                         summary: "Replace sequence document",
                                                         source: .human),
                                        summary: "Replace sequence document",
                                        operations: [.sequence(.replaceDocument(replacement))],
                                        baseRevisions: TransactionBaseRevisions(sequenceRevisionID: previousRevision.id),
                                        provenance: .authored)
        var context = TransactionExecutionContext(sequenceDocument: current)

        let applied = try executor.apply(transaction, to: &context)
        let document = try #require(context.sequenceDocument)

        #expect(applied.changedDomains == [.sequence])
        #expect(document.name == "Sequence B")
        #expect(document.revision.id != "draft.0002")
        #expect(document.revision.parentID == previousRevision.id)
        #expect(document.revision.baseSequenceRevisionID == previousRevision.id)
        #expect(document.revision.transactionIDs == ["tx.old", transaction.id])
    }

    @Test("asset transactions rescan a project directory through AssetRegistry")
    func assetTransactionsScanProjects() throws {
        let executor = TransactionExecutor()
        let registry = AssetRegistry()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let obj = root.appendingPathComponent("mesh.obj")
        try "v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n".write(to: obj,
                                                                  atomically: true,
                                                                  encoding: .utf8)

        let transaction = TransactionIR(intent: IntentIR(verb: "asset.scan_project",
                                                         summary: "Scan project assets",
                                                         source: .system),
                                        summary: "Scan project assets",
                                        operations: [.asset(.scanProject(rootPath: root.path))],
                                        provenance: .authored)
        var context = TransactionExecutionContext(assetRegistry: registry)

        let applied = try executor.apply(transaction, to: &context)

        #expect(applied.changedDomains == [.asset])
        #expect(applied.assetEntryCount == 1)
        #expect(registry.entriesSnapshot().map(\ .relativePath) == ["mesh.obj"])
    }

    @Test("IntentIR decodes legacy payloads without typed arguments")
    func intentIRDecodesLegacyPayloads() throws {
        let data = Data(#"{"verb":"scene.spawn_entity","summary":"Spawn","source":"human"}"#.utf8)

        let intent = try JSONDecoder().decode(IntentIR.self, from: data)

        #expect(intent.verb == "scene.spawn_entity")
        #expect(intent.targetObjectIDs.isEmpty)
        #expect(intent.arguments.isEmpty)
        #expect(intent.confidence == 1.0)
        #expect(intent.evidence.isEmpty)
    }

    @Test("IntentIR transaction builder converts typed intents to scene transactions")
    func intentTransactionBuilderBuildsSceneTransactions() throws {
        let builder = IntentTransactionBuilder()
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        _ = scene.setComponent(SceneNameComponent(value: "Hero"), for: entity)
        _ = scene.setLocalTransform(LocalTransform(translation: .zero), for: entity)

        let rename = IntentIR(verb: "scene.set_name",
                              summary: "Rename selected entity",
                              targetObjectIDs: ["scene:\(entity.rawValue)"],
                              arguments: ["name": .string("Boss")],
                              source: .human)
        let move = IntentIR(verb: "scene.set_transform",
                            summary: "Move selected entity",
                            targetObjectIDs: ["scene:\(entity.rawValue)"],
                            arguments: ["translation": .vec3(IntentVector3(x: 3, y: 4, z: 5))],
                            source: .human)
        let context = IntentTransactionBuildContext(sceneRuntime: scene,
                                                    selectedEntityID: entity.rawValue,
                                                    defaultSpawnMeshIndex: 7)

        let renameTx = try builder.buildTransaction(from: rename, context: context)
        let moveTx = try builder.buildTransaction(from: move, context: context)

        #expect(renameTx.operations == [.scene(.setSceneName(entityID: entity.rawValue, value: "Boss"))])
        guard case let .scene(.setLocalTransform(rawID, transform)) = moveTx.operations.first else {
            Issue.record("Expected setLocalTransform scene mutation")
            return
        }
        #expect(rawID == entity.rawValue)
        #expect(transform.translation == SIMD3<Float>(3, 4, 5))
    }

    @Test("AmbiguityScorer treats fully specified human intents as clear")
    func ambiguityScorerTreatsFullySpecifiedHumanIntentsAsClear() throws {
        let descriptor = try #require(CapabilityRegistry.default.descriptor(for: "scene.set_name"))
        let intent = IntentIR(
            verb: "scene.set_name",
            summary: "Rename selected entity",
            targetObjectIDs: ["scene:42"],
            arguments: ["name": .string("Boss")],
            source: .human
        )

        let score = AmbiguityScorer().score(
            intent,
            context: AmbiguityScoringContext(descriptor: descriptor)
        )

        #expect(score.score == 0)
        #expect(score.level == .clear)
        #expect(score.signals.isEmpty)
    }

    @Test("AmbiguityScorer does not require a target for spawn capabilities")
    func ambiguityScorerDoesNotRequireTargetForSpawnCapabilities() throws {
        let descriptor = try #require(CapabilityRegistry.default.descriptor(for: "scene.spawn_entity"))
        let intent = IntentIR(
            verb: "scene.spawn_entity",
            summary: "Spawn entity",
            source: .human
        )

        let score = AmbiguityScorer().score(
            intent,
            context: AmbiguityScoringContext(descriptor: descriptor)
        )

        #expect(score.score == 0)
        #expect(score.level == .clear)
    }

    @Test("AmbiguityScorer raises high ambiguity for underspecified AI target edits")
    func ambiguityScorerRaisesHighForUnderspecifiedAITargetEdits() throws {
        let descriptor = try #require(CapabilityRegistry.default.descriptor(for: "scene.set_name"))
        let intent = IntentIR(
            verb: "scene.set_name",
            summary: "Rename it",
            confidence: 0.4,
            source: .ai
        )

        let score = AmbiguityScorer().score(
            intent,
            context: AmbiguityScoringContext(descriptor: descriptor)
        )
        let signalKinds = Set(score.signals.map(\.kind))

        #expect(score.level == .high)
        #expect(signalKinds.contains(.aiLowConfidence))
        #expect(signalKinds.contains(.noTarget))
        #expect(signalKinds.contains(.missingRequiredArgument))
        #expect(signalKinds.contains(.noEvidence))
    }

    @Test("AmbiguityScorer builds destructive confirmation questions")
    func ambiguityScorerBuildsDestructiveConfirmationQuestions() throws {
        let descriptor = try #require(CapabilityRegistry.default.descriptor(for: "scene.delete_entity"))
        let intent = IntentIR(
            id: "delete-42",
            verb: "scene.delete_entity",
            summary: "Delete selected entity",
            targetObjectIDs: ["scene:42"],
            source: .human
        )
        let scorer = AmbiguityScorer()
        let score = scorer.score(intent, context: AmbiguityScoringContext(descriptor: descriptor))

        let question = try #require(scorer.makeQuestion(for: intent, score: score))

        #expect(score.level == .low)
        #expect(question.id == "ambiguity:delete-42")
        #expect(question.kind == .approveDestructive)
        #expect(question.severity == .destructive)
        #expect(question.ambiguityScore == score.score)
    }

    @Test("capability planning escalates automatic destructive transactions to confirmation")
    func capabilityPlanningEscalatesDestructiveTransactions() throws {
        let coordinator = IntentRuntimeCoordinator()
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        let transaction = TransactionIR(
            intent: IntentIR(verb: "scene.delete_entity",
                             summary: "Delete selected entity",
                             targetObjectIDs: ["scene:\(entity.rawValue)"],
                             source: .human),
            summary: "Delete selected entity",
            operations: [.scene(.deleteEntity(entityID: entity.rawValue))],
            approvalPolicy: .automatic,
            provenance: .authored
        )
        var executionContext = TransactionExecutionContext(sceneRuntime: scene)
        let capabilityContext = CapabilityInvocationContext(sceneRuntime: scene,
                                                            defaultSource: .human)

        let result = try coordinator.submitPlan(transaction,
                                                executionContext: &executionContext,
                                                capabilityContext: capabilityContext)

        #expect(result.disposition == .confirmationRequested)
        #expect(result.confirmationRequest?.questions.first?.severity == .destructive)
        #expect(executionContext.sceneRuntime?.snapshot.entityCount == 1)
    }

    @Test("capability planning blocks operations when required components are absent")
    func capabilityPlanningBlocksMissingComponents() throws {
        let coordinator = IntentRuntimeCoordinator()
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        let transaction = TransactionIR(
            summary: "Set light color",
            operations: [.scene(.setLightColor(entityID: entity.rawValue,
                                               color: SIMD3<Float>(1, 0, 0)))],
            approvalPolicy: .automatic,
            provenance: .proposal
        )
        var executionContext = TransactionExecutionContext(sceneRuntime: scene)
        let capabilityContext = CapabilityInvocationContext(sceneRuntime: scene,
                                                            defaultSource: .ai,
                                                            defaultConfidence: 0.9)

        let error = try #require(
            { () throws -> CapabilityInvocationPlannerError? in
                do {
                    _ = try coordinator.submitPlan(transaction,
                                                   executionContext: &executionContext,
                                                   capabilityContext: capabilityContext)
                    return nil
                } catch let error as CapabilityInvocationPlannerError {
                    return error
                }
            }()
        )

        guard case let .capabilityDenied(failures) = error else {
            Issue.record("expected capabilityDenied, got \(error)")
            return
        }
        #expect(failures.count == 1)
        #expect(failures[0].verb == "scene.set_light_color")
        #expect(failures[0].reason.contains("LightComponent"))
    }

    @Test("capability planning escalates low-confidence AI plans")
    func capabilityPlanningEscalatesLowConfidenceAIPlans() throws {
        let coordinator = IntentRuntimeCoordinator()
        let transaction = TransactionIR(
            summary: "Spawn entity",
            operations: [
                .scene(.spawnImportedMeshEntity(label: "AI Entity",
                                                kindLabel: "Static Mesh",
                                                meshIndex: 0,
                                                position: .zero)),
            ],
            approvalPolicy: .automatic,
            provenance: .proposal
        )
        var executionContext = TransactionExecutionContext(sceneRuntime: SceneRuntime())
        let capabilityContext = CapabilityInvocationContext(sceneRuntime: SceneRuntime(),
                                                            defaultSource: .ai,
                                                            defaultConfidence: 0.4)

        let result = try coordinator.submitPlan(transaction,
                                                executionContext: &executionContext,
                                                capabilityContext: capabilityContext)

        #expect(result.disposition == .confirmationRequested)
        #expect(result.confirmationRequest?.questions.first?.ambiguityScore ?? 0 > 0)
        #expect(result.warnings.contains { $0.contains("AI confidence") })
    }

    @Test("capability planning can be reconfigured for beta capabilities")
    func capabilityPlanningCanBeReconfiguredForBetaCapabilities() throws {
        let coordinator = IntentRuntimeCoordinator()
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        _ = scene.setComponent(RigidBody(motionType: .dynamic, mass: 1), for: entity)
        let transaction = TransactionIR(
            summary: "Update rigid body mass",
            operations: [.scene(.setRigidBodyMass(entityID: entity.rawValue, value: 12))],
            approvalPolicy: .automatic,
            provenance: .authored
        )
        let capabilityContext = CapabilityInvocationContext(sceneRuntime: scene,
                                                            defaultSource: .human)
        var stableContext = TransactionExecutionContext(sceneRuntime: scene)

        let stableError = try #require(
            { () throws -> CapabilityInvocationPlannerError? in
                do {
                    _ = try coordinator.submitPlan(transaction,
                                                   executionContext: &stableContext,
                                                   capabilityContext: capabilityContext)
                    return nil
                } catch let error as CapabilityInvocationPlannerError {
                    return error
                }
            }()
        )
        guard case let .capabilityDenied(stableFailures) = stableError else {
            Issue.record("expected capabilityDenied, got \(stableError)")
            return
        }
        #expect(stableFailures.first?.reason.contains("beta") == true)

        coordinator.configureCapabilityPlanner(
            CapabilityInvocationPlanner(gate: ReleasePhaseGate(activePhase: .beta))
        )
        var betaContext = TransactionExecutionContext(sceneRuntime: scene)

        let result = try coordinator.submitPlan(transaction,
                                                executionContext: &betaContext,
                                                capabilityContext: capabilityContext)
        let updated = try #require(betaContext.sceneRuntime?.component(RigidBody.self, for: entity))

        #expect(result.disposition == .applied)
        #expect(updated.mass == 12)
    }

    @Test("scene apply emits transaction and scene bus events")
    func sceneApplyEmitsBusEvents() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let executor = TransactionExecutor()
        let bus = try ObservationBus(coldLogDirectory: root.path)
        let transactionStream = bus.subscribe(spec: SubscriptionSpec(filter: .kindIn([.transactionApplied]),
                                                                     startFrom: .latest,
                                                                     bufferPolicy: .dropOldest(size: 4)))
        let sceneStream = bus.subscribe(spec: SubscriptionSpec(filter: .kindIn([.sceneChanged]),
                                                               startFrom: .latest,
                                                               bufferPolicy: .dropOldest(size: 4)))
        let transaction = TransactionIR(intent: IntentIR(verb: "scene.spawn_entity",
                                                         summary: "Spawn imported mesh",
                                                         source: .human),
                                        summary: "Spawn imported mesh",
                                        operations: [
                                            .scene(.spawnImportedMeshEntity(label: "Hero",
                                                                           kindLabel: "Static Mesh",
                                                                           meshIndex: 9,
                                                                           position: SIMD3<Float>(0, 1, 0)))
                                        ],
                                        provenance: .authored)
        var context = TransactionExecutionContext(sceneRuntime: SceneRuntime(),
                                                  observationBus: bus,
                                                  eventOrigin: EventOrigin(process: .editor,
                                                                           host: "test-host",
                                                                           user: "alex"),
                                                  sceneStreamID: "scene:test")

        let result = try executor.apply(transaction, to: &context)
        let transactionEvents = transactionStream.drain()
        let sceneEvents = sceneStream.drain()

        #expect(result.changedDomains == [.scene])
        #expect(transactionEvents.map(\ .kind) == [.transactionApplied])
        #expect(sceneEvents.map(\ .kind) == [.sceneChanged])
        #expect(try bus.replay(streamID: "transaction", fromSeq: 1).map(\ .kind) == [.transactionApplied])
    }

    @Test("staged transaction store emits staged and applied events while deferring mutation until apply")
    func stagedTransactionStoreEmitsStagedAndAppliedEvents() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let bus = try ObservationBus(coldLogDirectory: root.path)
        let store = StagedTransactionStore()
        let transactionSubscription = bus.subscribe(spec: SubscriptionSpec(filter: .kindIn([.transactionStaged, .transactionApplied]),
                                                                           startFrom: .latest,
                                                                           bufferPolicy: .dropOldest(size: 8)))
        let sceneSubscription = bus.subscribe(spec: SubscriptionSpec(filter: .kindIn([.sceneChanged]),
                                                                     startFrom: .latest,
                                                                     bufferPolicy: .dropOldest(size: 8)))
        let transaction = TransactionIR(intent: IntentIR(verb: "scene.spawn_entity",
                                                         summary: "Stage hero spawn",
                                                         source: .human),
                                        summary: "Stage hero spawn",
                                        operations: [
                                            .scene(.spawnImportedMeshEntity(label: "Hero",
                                                                           kindLabel: "Static Mesh",
                                                                           meshIndex: 7,
                                                                           position: .zero))
                                        ],
                                        provenance: .authored)
        var context = TransactionExecutionContext(sceneRuntime: SceneRuntime(),
                                                  observationBus: bus,
                                                  eventOrigin: EventOrigin(process: .editor,
                                                                           host: "test-host",
                                                                           user: "alex"),
                                                  sceneStreamID: "scene:test")

        let staged = try store.stage(transaction, from: context)
        let stageEvents = transactionSubscription.drain()

        #expect(staged.transactionID == transaction.id)
        #expect(context.sceneRuntime?.snapshot.entityCount == 0)
        #expect(stageEvents.map(\ .kind) == [.transactionStaged])

        let applied = try store.applyStagedTransaction(to: &context)
        let appliedTransactionEvents = transactionSubscription.drain()
        let appliedSceneEvents = sceneSubscription.drain()

        #expect(applied.hadTransaction)
        #expect(context.sceneRuntime?.snapshot.entityCount == 1)
        #expect(appliedTransactionEvents.map(\ .kind) == [.transactionApplied])
        #expect(appliedSceneEvents.map(\ .kind) == [.sceneChanged])
    }

    @Test("discard staged transaction emits discarded event and leaves the scene untouched")
    func discardStagedTransactionEmitsDiscardedEvent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let bus = try ObservationBus(coldLogDirectory: root.path)
        let store = StagedTransactionStore()
        let subscription = bus.subscribe(spec: SubscriptionSpec(filter: .kindIn([.transactionStaged, .transactionDiscarded]),
                                                                startFrom: .latest,
                                                                bufferPolicy: .dropOldest(size: 8)))
        let transaction = TransactionIR(intent: IntentIR(verb: "scene.spawn_entity",
                                                         summary: "Stage hero spawn",
                                                         source: .human),
                                        summary: "Stage hero spawn",
                                        operations: [
                                            .scene(.spawnImportedMeshEntity(label: "Hero",
                                                                           kindLabel: "Static Mesh",
                                                                           meshIndex: 7,
                                                                           position: .zero))
                                        ],
                                        provenance: .authored)
        let context = TransactionExecutionContext(sceneRuntime: SceneRuntime(),
                                                  observationBus: bus,
                                                  eventOrigin: EventOrigin(process: .editor,
                                                                           host: "test-host",
                                                                           user: "alex"),
                                                  sceneStreamID: "scene:test")

        _ = try store.stage(transaction, from: context)
        _ = subscription.drain()
        let discarded = try store.discardStagedTransaction(using: context)
        let discardedEvents = subscription.drain()

        #expect(discarded.hadTransaction)
        #expect(discardedEvents.map(\ .kind) == [.transactionDiscarded])
    }

    @Test("submitPlan applies automatic transactions immediately")
    func submitPlanAppliesAutomaticTransactionsImmediately() throws {
        let coordinator = IntentRuntimeCoordinator()
        let transaction = TransactionIR(intent: IntentIR(verb: "scene.spawn_entity",
                                                         summary: "Spawn imported mesh",
                                                         source: .human),
                                        summary: "Spawn imported mesh",
                                        operations: [
                                            .scene(.spawnImportedMeshEntity(label: "Hero",
                                                                           kindLabel: "Static Mesh",
                                                                           meshIndex: 9,
                                                                           position: SIMD3<Float>(0, 1, 0)))
                                        ],
                                        baseRevisions: TransactionBaseRevisions(sceneRevision: 0),
                                        approvalPolicy: .automatic,
                                        provenance: .authored)
        var context = TransactionExecutionContext(sceneRuntime: SceneRuntime())

        let result = try coordinator.submitPlan(transaction, executionContext: &context)

        #expect(result.disposition == .applied)
        #expect(result.applyResult?.createdEntityIDs.count == 1)
        #expect(context.sceneRuntime?.snapshot.entityCount == 1)
    }

    @Test("submitPlan stages requiresApproval transactions and emits confirmation requests")
    func submitPlanStagesRequiresApprovalTransactions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let bus = try ObservationBus(coldLogDirectory: root.path)
        let coordinator = IntentRuntimeCoordinator()
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        let transactionSubscription = bus.subscribe(spec: SubscriptionSpec(filter: .kindIn([.transactionStaged]),
                                                                           startFrom: .latest,
                                                                           bufferPolicy: .dropOldest(size: 4)))
        let confirmationSubscription = bus.subscribe(spec: SubscriptionSpec(filter: .kindIn([.confirmationRequested]),
                                                                            startFrom: .latest,
                                                                            bufferPolicy: .dropOldest(size: 4)))
        let transaction = TransactionIR(intent: IntentIR(verb: "scene.delete_entity",
                                                         summary: "Delete selected entity",
                                                         targetObjectIDs: ["scene:\(entity.rawValue)"],
                                                         source: .human),
                                        summary: "Delete selected entity",
                                        operations: [.scene(.deleteEntity(entityID: entity.rawValue))],
                                        baseRevisions: TransactionBaseRevisions(sceneRevision: scene.snapshot.revision),
                                        approvalPolicy: .requiresApproval,
                                        provenance: .authored)
        var context = TransactionExecutionContext(sceneRuntime: scene,
                                                  observationBus: bus,
                                                  eventOrigin: EventOrigin(process: .editor,
                                                                           host: "test-host",
                                                                           user: "alex"))

        let result = try coordinator.submitPlan(transaction, executionContext: &context)
        let stagedEvents = transactionSubscription.drain()
        let confirmationEvents = confirmationSubscription.drain()

        #expect(result.disposition == .confirmationRequested)
        #expect(result.stagedResult?.transactionID == transaction.id)
        #expect(context.sceneRuntime?.snapshot.entityCount == 1)
        #expect(stagedEvents.map(\ .kind) == [.transactionStaged])
        #expect(confirmationEvents.map(\ .kind) == [.confirmationRequested])
        let payload = try #require(confirmationEvents.first?.payloadRef.inlineRecord)
        #expect(payload["batch_id"] == .string("cfm:\(transaction.id)"))
    }

    @Test("confirmation resolution applies staged transactions and publishes UI resolution")
    func confirmationResolutionAppliesStagedTransactions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let bus = try ObservationBus(coldLogDirectory: root.path)
        let coordinator = IntentRuntimeCoordinator()
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        let confirmationResolvedSubscription = bus.subscribe(spec: SubscriptionSpec(filter: .kindIn([.confirmationResolved]),
                                                                                    startFrom: .latest,
                                                                                    bufferPolicy: .dropOldest(size: 4)))
        let sceneSubscription = bus.subscribe(spec: SubscriptionSpec(filter: .kindIn([.sceneChanged]),
                                                                     startFrom: .latest,
                                                                     bufferPolicy: .dropOldest(size: 4)))
        let transaction = TransactionIR(intent: IntentIR(verb: "scene.delete_entity",
                                                         summary: "Delete selected entity",
                                                         targetObjectIDs: ["scene:\(entity.rawValue)"],
                                                         source: .human),
                                        summary: "Delete selected entity",
                                        operations: [.scene(.deleteEntity(entityID: entity.rawValue))],
                                        baseRevisions: TransactionBaseRevisions(sceneRevision: scene.snapshot.revision),
                                        approvalPolicy: .requiresApproval,
                                        provenance: .authored)
        var context = TransactionExecutionContext(sceneRuntime: scene,
                                                  observationBus: bus,
                                                  eventOrigin: EventOrigin(process: .editor,
                                                                           host: "test-host",
                                                                           user: "alex"))

        let staged = try coordinator.submitPlan(transaction, executionContext: &context)
        let request = try #require(staged.confirmationRequest)
        let resolution = ConfirmationResolution(batchID: request.batchID,
                                                correlationID: request.correlationID,
                                                answers: [ConfirmationAnswer(questionID: request.questions[0].id,
                                                                             outcome: .accepted,
                                                                             pickedOptionID: "confirm")],
                                                userID: "alex",
                                                partial: false)

        let applied = try coordinator.resolvePlanConfirmation(resolution, executionContext: &context)
        let confirmationEvents = confirmationResolvedSubscription.drain()
        let sceneEvents = sceneSubscription.drain()

        #expect(applied.disposition == .applied)
        #expect(context.sceneRuntime?.snapshot.entityCount == 0)
        #expect(confirmationEvents.map(\ .kind) == [.confirmationResolved])
        #expect(sceneEvents.map(\ .kind) == [.sceneChanged])
    }

    private func entityID(from rawID: UInt64) -> EntityID {
        EntityID(index: UInt32(rawID & 0xFFFF_FFFF),
                 generation: UInt32(rawID >> 32))
    }
}

// MARK: - End-to-end integration tests

@Suite("IntentRuntime end-to-end", .serialized)
struct IntentRuntimeEndToEndTests {

    @Test("ObservationBus 鈫?IntentIR 鈫?TransactionIR 鈫?SceneRuntime full pipeline")
    func fullPipelineSpawnEntity() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // 1. ObservationBus
        let bus = try ObservationBus(coldLogDirectory: root.path)
        let txSubscription = bus.subscribe(spec: SubscriptionSpec(
            filter: .kindIn([.transactionApplied]),
            startFrom: .latest,
            bufferPolicy: .dropOldest(size: 8)))
        let sceneSubscription = bus.subscribe(spec: SubscriptionSpec(
            filter: .kindIn([.sceneChanged]),
            startFrom: .latest,
            bufferPolicy: .dropOldest(size: 8)))

        // 2. IntentIR 鈥?what the user/AI intends
        let intent = IntentIR(
            id: "intent-\(UUID().uuidString.prefix(8))",
            verb: "scene.spawn_entity",
            summary: "Spawn a hero mesh at the origin",
            targetObjectIDs: [],
            source: .human,
            createdAt: Date()
        )

        // 3. TransactionIR 鈥?structured operations
        let tx = TransactionIR(
            intent: intent,
            summary: "Spawn hero mesh",
            operations: [
                .scene(.spawnImportedMeshEntity(
                    label: "Hero",
                    kindLabel: "Static Mesh",
                    meshIndex: 7,
                    position: SIMD3<Float>(2, 0, -3)))
            ],
            baseRevisions: TransactionBaseRevisions(sceneRevision: 0),
            provenance: .authored
        )

        // 4. SceneRuntime 鈥?target for mutation
        var context = TransactionExecutionContext(
            sceneRuntime: SceneRuntime(),
            observationBus: bus,
            eventOrigin: EventOrigin(process: .editor, host: "test", user: "e2e"),
            sceneStreamID: "scene:e2e")

        // 5. TransactionExecutor 鈥?applies transaction, emits events
        let executor = TransactionExecutor()
        let result = try executor.apply(tx, to: &context)

        // 6. Verify SceneRuntime state
        let scene = try #require(context.sceneRuntime)
        #expect(scene.snapshot.entityCount == 1)
        #expect(result.createdEntityIDs.count == 1)
        let entity = EntityID(index: UInt32(result.createdEntityIDs[0] & 0xFFFF_FFFF),
                             generation: UInt32(result.createdEntityIDs[0] >> 32))
        #expect(scene.component(SceneNameComponent.self, for: entity)?.value == "Hero")
        #expect(scene.localTransform(for: entity)?.translation == SIMD3<Float>(2, 0, -3))

        // 7. Verify ObservationBus events
        #expect(txSubscription.drain().map(\.kind) == [.transactionApplied])
        #expect(sceneSubscription.drain().map(\.kind) == [.sceneChanged])

        // 8. Cold log replay 鈥?at minimum sceneChanged events are recorded
        let replayed = try bus.replay(streamID: "scene:e2e", fromSeq: 1)
        #expect(replayed.count >= 1)
        #expect(replayed.contains { $0.kind == .sceneChanged })
    }

    @Test("Multi-step pipeline: spawn 鈫?setLocalTransform 鈫?verify via cold log replay")
    func multiStepSpawnAndTransform() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let bus = try ObservationBus(coldLogDirectory: root.path)
        let executor = TransactionExecutor()
        var scene = SceneRuntime()
        let origin = EventOrigin(process: .editor, host: "test", user: "e2e")

        // Step 1: Spawn entity
        var ctx = TransactionExecutionContext(
            sceneRuntime: scene, observationBus: bus,
            eventOrigin: origin, sceneStreamID: "scene:e2e")
        let spawnTx = TransactionIR(
            intent: IntentIR(verb: "scene.spawn_entity", summary: "Spawn",
                             source: .human),
            summary: "Spawn cube",
            operations: [.scene(.spawnImportedMeshEntity(
                label: "Cube", kindLabel: "Static Mesh",
                meshIndex: 2, position: SIMD3<Float>(1, 2, 3)))],
            provenance: .authored)
        let spawnResult = try executor.apply(spawnTx, to: &ctx)
        let entityID = EntityID(index: UInt32(spawnResult.createdEntityIDs[0] & 0xFFFF_FFFF),
                               generation: UInt32(spawnResult.createdEntityIDs[0] >> 32))
        let revision1 = ctx.sceneRuntime!.snapshot.revision
        #expect(ctx.sceneRuntime!.localTransform(for: entityID)?.translation == SIMD3<Float>(1, 2, 3))

        // Step 2: Set local transform
        scene = ctx.sceneRuntime!
        var ctx2 = TransactionExecutionContext(
            sceneRuntime: scene, observationBus: bus,
            eventOrigin: origin, sceneStreamID: "scene:e2e")
        let newTransform = LocalTransform(translation: SIMD3<Float>(10, 20, 30))
        let moveTx = TransactionIR(
            intent: IntentIR(verb: "scene.set_transform", summary: "Move",
                             source: .human),
            summary: "Move cube",
            operations: [.scene(.setLocalTransform(
                entityID: entityID.rawValue, transform: newTransform))],
            baseRevisions: TransactionBaseRevisions(sceneRevision: revision1),
            provenance: .authored)
        let moveResult = try executor.apply(moveTx, to: &ctx2)
        #expect(moveResult.changedDomains == [.scene])
        #expect(ctx2.sceneRuntime!.localTransform(for: entityID)?.translation == SIMD3<Float>(10, 20, 30))
        #expect(ctx2.sceneRuntime!.snapshot.revision > revision1)

        // Verify cold log captured both scene changes in sequence
        let replayed = try bus.replay(streamID: "scene:e2e", fromSeq: 1)
        let sceneChanges = replayed.filter { $0.kind == .sceneChanged }
        #expect(sceneChanges.count >= 2)
        #expect(sceneChanges[0].seq < sceneChanges[1].seq)
    }

    @Test("Spawn entity, set rigid-body via SceneRuntime, then update via transaction")
    func spawnEntityWithPhysicsViaDirectAPIThenTransaction() throws {
        let executor = TransactionExecutor()
        var scene = SceneRuntime()

        // Step 1: Spawn entity and directly set RigidBody
        let entity = scene.createEntity()
        scene.setLocalTransform(LocalTransform(translation: SIMD3<Float>(0, 5, 0)), for: entity)
        scene.setComponent(RigidBody(motionType: .static), for: entity)
        #expect(scene.snapshot.entityCount == 1)

        // Step 2: Use transaction to update rigid body fields and add collider
        var ctx = TransactionExecutionContext(sceneRuntime: scene)
        let rawID = entity.rawValue
        let collider = Collider(shape: .box(halfExtents: SIMD3<Float>(1, 1, 1),
                                           center: .zero))
        let tx = TransactionIR(
            intent: IntentIR(verb: "scene.update_entity", summary: "Add physics",
                             source: .human),
            summary: "Add physics components",
            operations: [
                .scene(.setRigidBodyMotionType(entityID: rawID, value: .dynamic)),
                .scene(.setRigidBodyMass(entityID: rawID, value: 2.0)),
                .scene(.setRigidBodyGravityScale(entityID: rawID, value: 1.0)),
                .scene(.setCollider(entityID: rawID, collider: collider)),
            ],
            baseRevisions: TransactionBaseRevisions(sceneRevision: scene.snapshot.revision),
            provenance: .authored)
        _ = try executor.apply(tx, to: &ctx)

        // Verify
        let body = try #require(ctx.sceneRuntime?.component(RigidBody.self, for: entity))
        #expect(body.motionType == .dynamic)
        #expect(body.mass == 2.0)
        let colliderComponent = try #require(ctx.sceneRuntime?.component(Collider.self, for: entity))
        #expect(colliderComponent.shape.kind == .box)

        // Apply force
        #expect(ctx.sceneRuntime?.applyForce(SIMD3<Float>(0, 9.8, 0), to: entity) == true)
        let updatedBody = ctx.sceneRuntime?.component(RigidBody.self, for: entity)
        #expect(updatedBody?.accumulatedForce == SIMD3<Float>(0, 9.8, 0))
    }

    @Test("Observable state hydration: bus events match scene mutations across coordinator")
    func coordinatorPipelineEmitsConsistentEvents() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let bus = try ObservationBus(coldLogDirectory: root.path)
        let coordinator = IntentRuntimeCoordinator()
        let sceneSubscription = bus.subscribe(spec: SubscriptionSpec(
            filter: .kindIn([.transactionApplied, .sceneChanged]),
            startFrom: .latest,
            bufferPolicy: .dropOldest(size: 16)))

        let scene = SceneRuntime()
        var context = TransactionExecutionContext(
            sceneRuntime: scene, observationBus: bus,
            eventOrigin: EventOrigin(process: .editor, host: "test", user: "e2e"),
            sceneStreamID: "scene:coordinator")

        let tx = TransactionIR(
            intent: IntentIR(verb: "scene.spawn_entity", summary: "Coordinator spawn",
                             source: .human),
            summary: "Coordinator spawn test",
            operations: [
                .scene(.spawnImportedMeshEntity(label: "CoordEntity",
                                               kindLabel: "Static Mesh",
                                               meshIndex: 5,
                                               position: .zero))
            ],
            approvalPolicy: .automatic,
            provenance: .authored)

        let result = try coordinator.submitPlan(tx, executionContext: &context)

        #expect(result.disposition == .applied)
        #expect(context.sceneRuntime?.snapshot.entityCount == 1)

        let events = sceneSubscription.drain()
        #expect(events.count == 2)
        #expect(events.map(\.kind) == [.transactionApplied, .sceneChanged])

        // Verify both event kinds are present
        let kinds = Set(events.map(\.kind))
        #expect(kinds.contains(.transactionApplied))
        #expect(kinds.contains(.sceneChanged))
    }
}

@Suite("UndoStack")
struct UndoStackTests {
    private func makeSpawnTransaction(revision: UInt64 = 0, label: String = "Entity") -> TransactionIR {
        TransactionIR(intent: IntentIR(verb: "scene.spawn_entity",
                                        summary: "Spawn \(label)",
                                        source: .human),
                      summary: "Spawn \(label)",
                      operations: [
                          .scene(.spawnImportedMeshEntity(label: label,
                                                         kindLabel: "Mesh",
                                                         meshIndex: 0,
                                                         position: .zero))
                      ],
                      baseRevisions: TransactionBaseRevisions(sceneRevision: revision),
                      provenance: .authored)
    }

    @Test("push / undo / redo round-trip restores snapshots in correct order")
    func pushUndoRedoRoundTrip() throws {
        let coordinator = IntentRuntimeCoordinator()
        var ctx = TransactionExecutionContext(sceneRuntime: SceneRuntime())

        let r0 = ctx.sceneRuntime!.snapshot.revision

        // Apply two transactions 鈥?each pushes a snapshot
        _ = try coordinator.submitPlan(makeSpawnTransaction(revision: r0), executionContext: &ctx)
        let r1 = ctx.sceneRuntime!.snapshot.revision

        _ = try coordinator.submitPlan(makeSpawnTransaction(revision: r1), executionContext: &ctx)
        let r2 = ctx.sceneRuntime!.snapshot.revision

        #expect(coordinator.undoStack.undoDepth == 2)
        #expect(coordinator.undoStack.canUndo)
        #expect(!coordinator.undoStack.canRedo)

        // Undo once 鈥?scene should go back to r1
        let didUndo = coordinator.undo(executionContext: &ctx)
        #expect(didUndo)
        #expect(ctx.sceneRuntime?.snapshot.revision == r1)
        #expect(coordinator.undoStack.undoDepth == 1)
        #expect(coordinator.undoStack.redoDepth == 1)

        // Undo again 鈥?scene should go back to r0
        coordinator.undo(executionContext: &ctx)
        #expect(ctx.sceneRuntime?.snapshot.revision == r0)
        #expect(coordinator.undoStack.undoDepth == 0)
        #expect(coordinator.undoStack.redoDepth == 2)

        // Redo once 鈥?back to r1
        coordinator.redo(executionContext: &ctx)
        #expect(ctx.sceneRuntime?.snapshot.revision == r1)

        // Redo again 鈥?back to r2
        coordinator.redo(executionContext: &ctx)
        #expect(ctx.sceneRuntime?.snapshot.revision == r2)
        #expect(coordinator.undoStack.redoDepth == 0)
    }

    @Test("push clears the redo stack")
    func pushClearsRedoStack() throws {
        let coordinator = IntentRuntimeCoordinator()
        var ctx = TransactionExecutionContext(sceneRuntime: SceneRuntime())

        let r0 = ctx.sceneRuntime!.snapshot.revision
        _ = try coordinator.submitPlan(makeSpawnTransaction(revision: r0), executionContext: &ctx)
        let r1 = ctx.sceneRuntime!.snapshot.revision

        coordinator.undo(executionContext: &ctx)
        #expect(coordinator.undoStack.canRedo)

        // New transaction clears redo
        _ = try coordinator.submitPlan(makeSpawnTransaction(revision: r0), executionContext: &ctx)
        #expect(!coordinator.undoStack.canRedo, "New push must clear redo stack")
        _ = r1
    }

    @Test("undo on empty stack returns false without modifying context")
    func undoOnEmptyStackReturnsFalse() throws {
        let coordinator = IntentRuntimeCoordinator()
        var ctx = TransactionExecutionContext(sceneRuntime: SceneRuntime())
        let revisionBefore = ctx.sceneRuntime!.snapshot.revision

        let result = coordinator.undo(executionContext: &ctx)
        #expect(!result)
        #expect(ctx.sceneRuntime?.snapshot.revision == revisionBefore)
    }

    @Test("setLocalTransform emits eulerDegrees authored and worldEulerDegrees evaluated events")
    func setLocalTransformEmitsRotationWorldEvents() throws {
        let executor = TransactionExecutor()
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        // Build a transform matrix with 45° Y rotation
        let angle: Float = 45 * (.pi / 180)
        let rotMatrix = simd_float4x4(columns: (
            SIMD4<Float>(cos(angle), 0, -sin(angle), 0),
            SIMD4<Float>(0,          1,  0,           0),
            SIMD4<Float>(sin(angle), 0,  cos(angle),  0),
            SIMD4<Float>(0,          0,  0,           1)
        ))
        let transform = LocalTransform(matrix: rotMatrix)
        let transaction = TransactionIR(
            summary: "Rotate entity",
            operations: [.scene(.setLocalTransform(entityID: entity.rawValue, transform: transform))],
            baseRevisions: TransactionBaseRevisions(sceneRevision: scene.snapshot.revision),
            provenance: .authored
        )
        var context = TransactionExecutionContext(sceneRuntime: scene)
        let result = try executor.apply(transaction, to: &context)

        let eulerEvent = result.worldEvents.first {
            if case .entityAuthoredChanged(_, "eulerDegrees", _) = $0 { return true }
            return false
        }
        #expect(eulerEvent != nil, "setLocalTransform with rotation must emit eulerDegrees authored event")
    }

    @Test("setRigidBodyMass and setAnimationPlayer emit authored world events")
    func physicsAndAnimationOpsEmitWorldEvents() throws {
        let executor = TransactionExecutor()
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        _ = scene.setComponent(RigidBody(motionType: .dynamic, mass: 10,
                                          gravityScale: 1, allowSleep: true), for: entity)
        _ = scene.setComponent(AnimationPlayer(), for: entity)
        let transaction = TransactionIR(
            summary: "Update mass and animation",
            operations: [
                .scene(.setRigidBodyMass(entityID: entity.rawValue, value: 50)),
                .scene(.setAnimationPlayer(entityID: entity.rawValue, clipName: "walk",
                                           speed: 1.5, loop: true, isPlaying: true)),
            ],
            baseRevisions: TransactionBaseRevisions(sceneRevision: scene.snapshot.revision),
            provenance: .authored
        )
        var context = TransactionExecutionContext(sceneRuntime: scene)
        let result = try executor.apply(transaction, to: &context)

        let massEvent = result.worldEvents.first {
            if case .entityAuthoredChanged(_, "rigidBodyMass", _) = $0 { return true }
            return false
        }
        let animClipEvent = result.worldEvents.first {
            if case .entityAuthoredChanged(_, "animationClip", _) = $0 { return true }
            return false
        }
        #expect(massEvent != nil, "setRigidBodyMass must emit rigidBodyMass authored event")
        #expect(animClipEvent != nil, "setAnimationPlayer must emit animationClip authored event")
    }

    @Test("setLocalTransform with non-uniform scale emits worldScale evaluated event")
    func setLocalTransformNonUniformScaleEmitsWorldScale() throws {
        let executor = TransactionExecutor()
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        let scaleMatrix = simd_float4x4(columns: (
            SIMD4<Float>(2, 0, 0, 0),
            SIMD4<Float>(0, 3, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(0, 0, 0, 1)
        ))
        let transaction = TransactionIR(
            summary: "Scale entity",
            operations: [.scene(.setLocalTransform(entityID: entity.rawValue,
                                                    transform: LocalTransform(matrix: scaleMatrix)))],
            baseRevisions: TransactionBaseRevisions(sceneRevision: scene.snapshot.revision),
            provenance: .authored
        )
        var context = TransactionExecutionContext(sceneRuntime: scene)
        let result = try executor.apply(transaction, to: &context)

        let scaleEvent = result.worldEvents.first {
            if case .entityEvaluatedChanged(_, "worldScale", _) = $0 { return true }
            return false
        }
        #expect(scaleEvent != nil, "non-uniform scale must emit worldScale evaluated event")
        if case let .entityEvaluatedChanged(_, _, .vec3(sx, sy, sz)) = scaleEvent {
            #expect(abs(sx - 2) < 0.01, "worldScale.x must be 2")
            #expect(abs(sy - 3) < 0.01, "worldScale.y must be 3")
            #expect(abs(sz - 1) < 0.01, "worldScale.z must be 1")
        }
    }

    @Test("setLocalTransform with uniform scale does not emit worldScale evaluated event")
    func setLocalTransformUniformScaleOmitsWorldScale() throws {
        let executor = TransactionExecutor()
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        let transaction = TransactionIR(
            summary: "Identity transform",
            operations: [.scene(.setLocalTransform(entityID: entity.rawValue,
                                                    transform: LocalTransform(matrix: simd_float4x4(1))))],
            baseRevisions: TransactionBaseRevisions(sceneRevision: scene.snapshot.revision),
            provenance: .authored
        )
        var context = TransactionExecutionContext(sceneRuntime: scene)
        let result = try executor.apply(transaction, to: &context)

        let scaleEvent = result.worldEvents.first {
            if case .entityEvaluatedChanged(_, "worldScale", _) = $0 { return true }
            return false
        }
        #expect(scaleEvent == nil, "identity transform must not emit worldScale")
    }

    @Test("setLightCastShadows emits lightCastShadows authored world event")
    func setLightCastShadowsEmitsWorldEvent() throws {
        let executor = TransactionExecutor()
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        _ = scene.setComponent(LightComponent(type: .directional, color: .one, intensity: 1, range: 100), for: entity)
        let transaction = TransactionIR(
            summary: "Enable shadow casting",
            operations: [.scene(.setLightCastShadows(entityID: entity.rawValue, value: true))],
            baseRevisions: TransactionBaseRevisions(sceneRevision: scene.snapshot.revision),
            provenance: .authored
        )
        var context = TransactionExecutionContext(sceneRuntime: scene)
        let result = try executor.apply(transaction, to: &context)

        let shadowEvent = result.worldEvents.first {
            if case .entityAuthoredChanged(_, "lightCastShadows", .bool(true)) = $0 { return true }
            return false
        }
        #expect(shadowEvent != nil, "setLightCastShadows must emit lightCastShadows authored event")
    }

    @Test("setColliderLayer and setColliderLayerMask emit colliderLayerID/Mask authored world events")
    func setColliderLayerEmitsWorldEvents() throws {
        let executor = TransactionExecutor()
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        _ = scene.setComponent(Collider(shape: .box(halfExtents: .one, center: .zero)), for: entity)
        let transaction = TransactionIR(
            summary: "Set layer",
            operations: [
                .scene(.setColliderLayer(entityID: entity.rawValue, layerID: 3)),
                .scene(.setColliderLayerMask(entityID: entity.rawValue, layerMask: 12)),
            ],
            baseRevisions: TransactionBaseRevisions(sceneRevision: scene.snapshot.revision),
            provenance: .authored
        )
        var context = TransactionExecutionContext(sceneRuntime: scene)
        let result = try executor.apply(transaction, to: &context)

        let layerEvent = result.worldEvents.first {
            if case .entityAuthoredChanged(_, "colliderLayerID", .float(3)) = $0 { return true }
            return false
        }
        let maskEvent = result.worldEvents.first {
            if case .entityAuthoredChanged(_, "colliderLayerMask", .float(12)) = $0 { return true }
            return false
        }
        #expect(layerEvent != nil, "setColliderLayer must emit colliderLayerID authored event")
        #expect(maskEvent != nil, "setColliderLayerMask must emit colliderLayerMask authored event")
    }

    @Test("setConstraintEnabled emits constraintEnabled authored world event")
    func setConstraintEnabledEmitsWorldEvent() throws {
        let executor = TransactionExecutor()
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        _ = scene.setComponent(
            Constraint(entityA: entity, entityB: entity),
            for: entity
        )
        let transaction = TransactionIR(
            summary: "Disable constraint",
            operations: [
                .scene(.setConstraintEnabled(entityID: entity.rawValue, value: false)),
            ],
            baseRevisions: TransactionBaseRevisions(sceneRevision: scene.snapshot.revision),
            provenance: .authored
        )
        var context = TransactionExecutionContext(sceneRuntime: scene)
        let result = try executor.apply(transaction, to: &context)

        let event = result.worldEvents.first {
            if case .entityAuthoredChanged(_, "constraintEnabled", .bool(false)) = $0 { return true }
            return false
        }
        #expect(event != nil, "setConstraintEnabled must emit constraintEnabled authored world event")
    }

    @Test("setRenderMaterialComponent emits four PBR material authored world events")
    func setRenderMaterialComponentEmitsWorldEvents() throws {
        let executor = TransactionExecutor()
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        _ = scene.setComponent(RenderMaterialComponent(), for: entity)
        let transaction = TransactionIR(
            summary: "Set PBR material",
            operations: [
                .scene(.setRenderMaterialComponent(
                    entityID: entity.rawValue,
                    baseColorFactor: SIMD4<Float>(0.8, 0.2, 0.1, 1.0),
                    metallicFactor: 0.9,
                    roughnessFactor: 0.3,
                    emissiveFactor: SIMD3<Float>(0.0, 0.5, 0.0)
                )),
            ],
            baseRevisions: TransactionBaseRevisions(sceneRevision: scene.snapshot.revision),
            provenance: .authored
        )
        var context = TransactionExecutionContext(sceneRuntime: scene)
        let result = try executor.apply(transaction, to: &context)

        let baseColorEvent = result.worldEvents.first {
            if case .entityAuthoredChanged(_, "materialBaseColor", .vec4(0.8, 0.2, 0.1, 1.0)) = $0 { return true }
            return false
        }
        let metallicEvent = result.worldEvents.first {
            if case .entityAuthoredChanged(_, "materialMetallic", .float(0.9)) = $0 { return true }
            return false
        }
        let roughnessEvent = result.worldEvents.first {
            if case .entityAuthoredChanged(_, "materialRoughness", .float(0.3)) = $0 { return true }
            return false
        }
        let emissiveEvent = result.worldEvents.first {
            if case .entityAuthoredChanged(_, "materialEmissive", .vec3(0.0, 0.5, 0.0)) = $0 { return true }
            return false
        }
        #expect(baseColorEvent != nil, "setRenderMaterialComponent must emit materialBaseColor authored event")
        #expect(metallicEvent != nil, "setRenderMaterialComponent must emit materialMetallic authored event")
        #expect(roughnessEvent != nil, "setRenderMaterialComponent must emit materialRoughness authored event")
        #expect(emissiveEvent != nil, "setRenderMaterialComponent must emit materialEmissive authored event")
    }

    @Test("setScriptBindings emits scriptBindings authored world event as JSON string")
    func setScriptBindingsEmitsWorldEvent() throws {
        let executor = TransactionExecutor()
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        _ = scene.setComponent(ScriptComponent(bindings: []), for: entity)
        let binding = ScriptBinding(ScriptHandle(rawValue: 42), isEnabled: true,
                                    parametersJSON: #"{"speed":5}"#)
        let transaction = TransactionIR(
            summary: "Attach script",
            operations: [.scene(.setScriptBindings(entityID: entity.rawValue, bindings: [binding]))],
            baseRevisions: TransactionBaseRevisions(sceneRevision: scene.snapshot.revision),
            provenance: .authored
        )
        var context = TransactionExecutionContext(sceneRuntime: scene)
        let result = try executor.apply(transaction, to: &context)

        let scriptEvent = result.worldEvents.first {
            if case .entityAuthoredChanged(_, "scriptBindings", .string(_)) = $0 { return true }
            return false
        }
        #expect(scriptEvent != nil, "setScriptBindings must emit a scriptBindings authored world event")
        if case let .entityAuthoredChanged(_, _, .string(json)) = scriptEvent {
            #expect(json.contains("42"))
            #expect(json.contains("speed"))
        }
    }

    @Test("setAudioSource emits audioClip, audioVolume, audioLoop, audioPlayOnAwake world events")
    func setAudioSourceEmitsWorldEvents() throws {
        let executor = TransactionExecutor()
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        _ = scene.setComponent(AudioSource(), for: entity)
        var src = AudioSource()
        src.clipName = "ambient"
        src.volume = 0.75
        src.loop = true
        src.playOnAwake = false
        let transaction = TransactionIR(
            summary: "Set audio",
            operations: [.scene(.setAudioSource(entityID: entity.rawValue, source: src))],
            baseRevisions: TransactionBaseRevisions(sceneRevision: scene.snapshot.revision),
            provenance: .authored
        )
        var context = TransactionExecutionContext(sceneRuntime: scene)
        let result = try executor.apply(transaction, to: &context)

        let clipEvent = result.worldEvents.first {
            if case .entityAuthoredChanged(_, "audioClip", .string("ambient")) = $0 { return true }
            return false
        }
        let volEvent = result.worldEvents.first {
            if case .entityAuthoredChanged(_, "audioVolume", .float(0.75)) = $0 { return true }
            return false
        }
        let loopEvent = result.worldEvents.first {
            if case .entityAuthoredChanged(_, "audioLoop", .bool(true)) = $0 { return true }
            return false
        }
        let awakEvent = result.worldEvents.first {
            if case .entityAuthoredChanged(_, "audioPlayOnAwake", .bool(false)) = $0 { return true }
            return false
        }
        #expect(clipEvent != nil, "setAudioSource must emit audioClip authored event")
        #expect(volEvent  != nil, "setAudioSource must emit audioVolume authored event")
        #expect(loopEvent != nil, "setAudioSource must emit audioLoop authored event")
        #expect(awakEvent != nil, "setAudioSource must emit audioPlayOnAwake authored event")
    }

    @Test("setCollider emits all seven collider authored world events")
    func setColliderEmitsWorldEvents() throws {
        let executor = TransactionExecutor()
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        let collider = Collider(
            shape: .sphere(radius: 1.5, center: .zero),
            isTrigger: true,
            layerID: 3,
            layerMask: 15,
            material: PhysicsMaterial(friction: 0.4, restitution: 0.2, density: 2.0)
        )
        let transaction = TransactionIR(
            summary: "Set collider",
            operations: [.scene(.setCollider(entityID: entity.rawValue, collider: collider))],
            baseRevisions: TransactionBaseRevisions(sceneRevision: scene.snapshot.revision),
            provenance: .authored
        )
        var context = TransactionExecutionContext(sceneRuntime: scene)
        let result = try executor.apply(transaction, to: &context)

        let shapeEvent = result.worldEvents.first {
            if case .entityAuthoredChanged(_, "colliderShape", .string("sphere")) = $0 { return true }
            return false
        }
        let triggerEvent = result.worldEvents.first {
            if case .entityAuthoredChanged(_, "colliderIsTrigger", .bool(true)) = $0 { return true }
            return false
        }
        let frictionEvent = result.worldEvents.first {
            if case .entityAuthoredChanged(_, "colliderFriction", .float(0.4)) = $0 { return true }
            return false
        }
        let restitutionEvent = result.worldEvents.first {
            if case .entityAuthoredChanged(_, "colliderRestitution", .float(0.2)) = $0 { return true }
            return false
        }
        let densityEvent = result.worldEvents.first {
            if case .entityAuthoredChanged(_, "colliderDensity", .float(2.0)) = $0 { return true }
            return false
        }
        let layerIDEvent = result.worldEvents.first {
            if case .entityAuthoredChanged(_, "colliderLayerID", .float(3)) = $0 { return true }
            return false
        }
        let layerMaskEvent = result.worldEvents.first {
            if case .entityAuthoredChanged(_, "colliderLayerMask", .float(15)) = $0 { return true }
            return false
        }
        #expect(shapeEvent      != nil, "setCollider must emit colliderShape authored event")
        #expect(triggerEvent    != nil, "setCollider must emit colliderIsTrigger authored event")
        #expect(frictionEvent   != nil, "setCollider must emit colliderFriction authored event")
        #expect(restitutionEvent != nil, "setCollider must emit colliderRestitution authored event")
        #expect(densityEvent    != nil, "setCollider must emit colliderDensity authored event")
        #expect(layerIDEvent    != nil, "setCollider must emit colliderLayerID authored event")
        #expect(layerMaskEvent  != nil, "setCollider must emit colliderLayerMask authored event")
    }

    @Test("setRigidBodyMotionType, setRigidBodyGravityScale, setRigidBodyAllowSleep emit authored world events")
    func rigidBodyOpsEmitWorldEvents() throws {
        let executor = TransactionExecutor()
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        _ = scene.setComponent(RigidBody(motionType: .dynamic, mass: 10,
                                          gravityScale: 1, allowSleep: true), for: entity)
        let transaction = TransactionIR(
            summary: "rb ops",
            operations: [
                .scene(.setRigidBodyMotionType(entityID: entity.rawValue, value: .kinematic)),
                .scene(.setRigidBodyGravityScale(entityID: entity.rawValue, value: 2.5)),
                .scene(.setRigidBodyAllowSleep(entityID: entity.rawValue, value: false)),
            ],
            baseRevisions: TransactionBaseRevisions(sceneRevision: scene.snapshot.revision),
            provenance: .authored
        )
        var context = TransactionExecutionContext(sceneRuntime: scene)
        let result = try executor.apply(transaction, to: &context)

        let motionEvent = result.worldEvents.first {
            if case .entityAuthoredChanged(_, "rigidBodyMotionType", .string("kinematic")) = $0 { return true }
            return false
        }
        let gravityEvent = result.worldEvents.first {
            if case .entityAuthoredChanged(_, "rigidBodyGravityScale", .float(2.5)) = $0 { return true }
            return false
        }
        let sleepEvent = result.worldEvents.first {
            if case .entityAuthoredChanged(_, "rigidBodyAllowSleep", .bool(false)) = $0 { return true }
            return false
        }
        #expect(motionEvent  != nil, "setRigidBodyMotionType must emit rigidBodyMotionType authored event")
        #expect(gravityEvent != nil, "setRigidBodyGravityScale must emit rigidBodyGravityScale authored event")
        #expect(sleepEvent   != nil, "setRigidBodyAllowSleep must emit rigidBodyAllowSleep authored event")
    }

    @Test("setMeshColorTint and setRenderMeshVisibility emit authored world events")
    func meshColorAndVisibilityEmitWorldEvents() throws {
        let executor = TransactionExecutor()
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        _ = scene.setComponent(RenderMeshComponent(meshIndex: 0), for: entity)
        let transaction = TransactionIR(
            summary: "mesh events",
            operations: [
                .scene(.setMeshColorTint(entityID: entity.rawValue,
                                          color: SIMD3<Float>(1, 0.5, 0))),
                .scene(.setRenderMeshVisibility(entityID: entity.rawValue, isVisible: false)),
            ],
            baseRevisions: TransactionBaseRevisions(sceneRevision: scene.snapshot.revision),
            provenance: .authored
        )
        var context = TransactionExecutionContext(sceneRuntime: scene)
        let result = try executor.apply(transaction, to: &context)

        let colorEvent = result.worldEvents.first {
            if case .entityAuthoredChanged(_, "meshColor", .vec3(1, 0.5, 0)) = $0 { return true }
            return false
        }
        let visibilityEvent = result.worldEvents.first {
            if case .entityAuthoredChanged(_, "meshIsVisible", .bool(false)) = $0 { return true }
            return false
        }
        #expect(colorEvent      != nil, "setMeshColorTint must emit meshColor authored event")
        #expect(visibilityEvent != nil, "setRenderMeshVisibility must emit meshIsVisible authored event")
    }

    @Test("light type, color, intensity, and range emit authored world events")
    func lightPropertyOpsEmitWorldEvents() throws {
        let executor = TransactionExecutor()
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        _ = scene.setComponent(LightComponent(type: .point, color: .one, intensity: 1, range: 10), for: entity)
        let transaction = TransactionIR(
            summary: "light ops",
            operations: [
                .scene(.setLightType(entityID: entity.rawValue, type: .spot)),
                .scene(.setLightColor(entityID: entity.rawValue,
                                       color: SIMD3<Float>(0.9, 0.8, 0.7))),
                .scene(.setLightIntensity(entityID: entity.rawValue, intensity: 500)),
                .scene(.setLightRange(entityID: entity.rawValue, range: 25)),
            ],
            baseRevisions: TransactionBaseRevisions(sceneRevision: scene.snapshot.revision),
            provenance: .authored
        )
        var context = TransactionExecutionContext(sceneRuntime: scene)
        let result = try executor.apply(transaction, to: &context)

        let typeEvent = result.worldEvents.first {
            if case .entityAuthoredChanged(_, "lightType", .string("spot")) = $0 { return true }
            return false
        }
        let colorEvent = result.worldEvents.first {
            if case .entityAuthoredChanged(_, "lightColor", .vec3(0.9, 0.8, 0.7)) = $0 { return true }
            return false
        }
        let intensityEvent = result.worldEvents.first {
            if case .entityAuthoredChanged(_, "lightIntensity", .float(500)) = $0 { return true }
            return false
        }
        let rangeEvent = result.worldEvents.first {
            if case .entityAuthoredChanged(_, "lightRange", .float(25)) = $0 { return true }
            return false
        }
        #expect(typeEvent      != nil, "setLightType must emit lightType authored event")
        #expect(colorEvent     != nil, "setLightColor must emit lightColor authored event")
        #expect(intensityEvent != nil, "setLightIntensity must emit lightIntensity authored event")
        #expect(rangeEvent     != nil, "setLightRange must emit lightRange authored event")
    }

    @Test("setLightSpotInnerAngle and setLightSpotOuterAngle emit authored world events")
    func lightSpotAnglesEmitWorldEvents() throws {
        let executor = TransactionExecutor()
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        _ = scene.setComponent(LightComponent(type: .spot, color: .one, intensity: 100, range: 20), for: entity)
        let transaction = TransactionIR(
            summary: "spot angles",
            operations: [
                .scene(.setLightSpotInnerAngle(entityID: entity.rawValue, angleDegrees: 20)),
                .scene(.setLightSpotOuterAngle(entityID: entity.rawValue, angleDegrees: 45)),
            ],
            baseRevisions: TransactionBaseRevisions(sceneRevision: scene.snapshot.revision),
            provenance: .authored
        )
        var context = TransactionExecutionContext(sceneRuntime: scene)
        let result = try executor.apply(transaction, to: &context)

        let innerEvent = result.worldEvents.first {
            if case .entityAuthoredChanged(_, "lightSpotInner", .float(20)) = $0 { return true }
            return false
        }
        let outerEvent = result.worldEvents.first {
            if case .entityAuthoredChanged(_, "lightSpotOuter", .float(45)) = $0 { return true }
            return false
        }
        #expect(innerEvent != nil, "setLightSpotInnerAngle must emit lightSpotInner authored event")
        #expect(outerEvent != nil, "setLightSpotOuterAngle must emit lightSpotOuter authored event")
    }

    @Test("setCameraFOV and setCameraActive emit authored world events")
    func cameraOpsEmitWorldEvents() throws {
        let executor = TransactionExecutor()
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        _ = scene.setComponent(CameraComponent(), for: entity)
        let transaction = TransactionIR(
            summary: "camera ops",
            operations: [
                .scene(.setCameraFOV(entityID: entity.rawValue, fovYDegrees: 75)),
                .scene(.setCameraActive(entityID: entity.rawValue, isActive: true)),
            ],
            baseRevisions: TransactionBaseRevisions(sceneRevision: scene.snapshot.revision),
            provenance: .authored
        )
        var context = TransactionExecutionContext(sceneRuntime: scene)
        let result = try executor.apply(transaction, to: &context)

        let fovEvent = result.worldEvents.first {
            if case .entityAuthoredChanged(_, "cameraFovYDegrees", .float(75)) = $0 { return true }
            return false
        }
        let activeEvent = result.worldEvents.first {
            if case .entityAuthoredChanged(_, "cameraIsActive", .bool(true)) = $0 { return true }
            return false
        }
        #expect(fovEvent    != nil, "setCameraFOV must emit cameraFovYDegrees authored event")
        #expect(activeEvent != nil, "setCameraActive must emit cameraIsActive authored event")
    }

    @Test("granular collider mutations emit individual authored world events")
    func granularColliderOpsEmitWorldEvents() throws {
        let executor = TransactionExecutor()
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        _ = scene.setComponent(Collider(shape: .box(halfExtents: .one, center: .zero)), for: entity)
        let transaction = TransactionIR(
            summary: "collider ops",
            operations: [
                .scene(.setColliderShapeType(entityID: entity.rawValue, kind: .sphere)),
                .scene(.setColliderTrigger(entityID: entity.rawValue, value: true)),
                .scene(.setColliderMaterialFriction(entityID: entity.rawValue, value: 0.3)),
                .scene(.setColliderMaterialRestitution(entityID: entity.rawValue, value: 0.6)),
                .scene(.setColliderMaterialDensity(entityID: entity.rawValue, value: 1.5)),
            ],
            baseRevisions: TransactionBaseRevisions(sceneRevision: scene.snapshot.revision),
            provenance: .authored
        )
        var context = TransactionExecutionContext(sceneRuntime: scene)
        let result = try executor.apply(transaction, to: &context)

        let shapeEvent = result.worldEvents.first {
            if case .entityAuthoredChanged(_, "colliderShape", .string("sphere")) = $0 { return true }
            return false
        }
        let triggerEvent = result.worldEvents.first {
            if case .entityAuthoredChanged(_, "colliderIsTrigger", .bool(true)) = $0 { return true }
            return false
        }
        let frictionEvent = result.worldEvents.first {
            if case .entityAuthoredChanged(_, "colliderFriction", .float(0.3)) = $0 { return true }
            return false
        }
        let restitutionEvent = result.worldEvents.first {
            if case .entityAuthoredChanged(_, "colliderRestitution", .float(0.6)) = $0 { return true }
            return false
        }
        let densityEvent = result.worldEvents.first {
            if case .entityAuthoredChanged(_, "colliderDensity", .float(1.5)) = $0 { return true }
            return false
        }
        #expect(shapeEvent      != nil, "setColliderShapeType must emit colliderShape authored event")
        #expect(triggerEvent    != nil, "setColliderTrigger must emit colliderIsTrigger authored event")
        #expect(frictionEvent   != nil, "setColliderMaterialFriction must emit colliderFriction authored event")
        #expect(restitutionEvent != nil, "setColliderMaterialRestitution must emit colliderRestitution authored event")
        #expect(densityEvent    != nil, "setColliderMaterialDensity must emit colliderDensity authored event")
    }

    @Test("setSceneName emits name authored world event")
    func setSceneNameEmitsWorldEvent() throws {
        let executor = TransactionExecutor()
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        let transaction = TransactionIR(
            summary: "rename",
            operations: [.scene(.setSceneName(entityID: entity.rawValue, value: "Hero"))],
            baseRevisions: TransactionBaseRevisions(sceneRevision: scene.snapshot.revision),
            provenance: .authored
        )
        var context = TransactionExecutionContext(sceneRuntime: scene)
        let result = try executor.apply(transaction, to: &context)

        let nameEvent = result.worldEvents.first {
            if case .entityAuthoredChanged(_, "name", .string("Hero")) = $0 { return true }
            return false
        }
        #expect(nameEvent != nil, "setSceneName must emit name authored event")
    }

    @Test("ring buffer discards oldest entry when capacity is exceeded")
    func ringBufferEvictsOldest() {
        let stack = UndoStack(capacity: 3)
        var scenes: [SceneRuntime] = (0..<4).map { _ in SceneRuntime() }

        stack.push(scenes[0])
        stack.push(scenes[1])
        stack.push(scenes[2])
        // Exceeds capacity 鈥?scenes[0] should be evicted
        stack.push(scenes[3])

        #expect(stack.undoDepth == 3)
        // Undo three times and verify oldest available is scenes[1]
        let popped1 = stack.undo(current: SceneRuntime())
        let popped2 = stack.undo(current: SceneRuntime())
        let popped3 = stack.undo(current: SceneRuntime())
        // popped1 = scenes[3], popped2 = scenes[2], popped3 = scenes[1]
        #expect(popped1 != nil)
        #expect(popped2 != nil)
        #expect(popped3 != nil)
        #expect(stack.undoDepth == 0)
        _ = scenes
    }
}
