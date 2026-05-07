import AssetPipeline
import CapabilityRuntime
import Foundation
import IntentRuntime
import ObservationBus
import SceneRuntime
import SequenceRuntime
import ScriptRuntime
import Testing
import simd

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

    @Test("deterministic natural language resolver emits typed IntentIR for common scene verbs")
    func naturalLanguageResolverEmitsTypedIntentIR() throws {
        let resolver = NaturalLanguageIntentResolver()
        let context = NaturalLanguageIntentContext(selectedObjectIDs: ["scene:42"])

        let rename = resolver.resolve(NaturalLanguageIntent(text: #"rename selected to "Boss""#),
                                      context: context)
        let move = resolver.resolve(NaturalLanguageIntent(text: "move selection to 1 2 3"),
                                    context: context)

        let renameIntent = try #require(rename.intent)
        let moveIntent = try #require(move.intent)

        #expect(renameIntent.verb == "scene.set_name")
        #expect(renameIntent.targetObjectIDs == ["scene:42"])
        #expect(renameIntent.arguments["name"] == .string("Boss"))
        #expect(renameIntent.confidence > 0)
        #expect(renameIntent.evidence.first?.kind == "natural_language")

        #expect(moveIntent.verb == "scene.set_transform")
        #expect(moveIntent.arguments["translation"] == .vec3(IntentVector3(x: 1, y: 2, z: 3)))
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

    @Test("natural language resolver returns actionable unresolved intents")
    func naturalLanguageResolverReturnsUnresolvedIntents() throws {
        let resolver = NaturalLanguageIntentResolver()

        let missingTarget = resolver.resolve(NaturalLanguageIntent(text: "delete selected"))
        let unsupported = resolver.resolve(NaturalLanguageIntent(text: "make it more cinematic"))

        let targetIssue = try #require(missingTarget.unresolved)
        let unsupportedIssue = try #require(unsupported.unresolved)

        #expect(targetIssue.reason == .missingTarget)
        #expect(targetIssue.candidateVerbIDs == ["scene.delete_entity"])
        #expect(targetIssue.missingArguments == ["entity_id"])
        #expect(unsupportedIssue.reason == .unsupportedVerb)
    }

    @Test("unresolved intent queue tracks open and dismissed items")
    func unresolvedIntentQueueTracksLifecycle() throws {
        let queue = UnresolvableIntentQueue()
        let item = UnresolvableIntent(
            naturalLanguageIntent: NaturalLanguageIntent(text: "delete selected"),
            reason: .missingTarget,
            message: "Select an entity before deleting it."
        )

        queue.append(item)
        #expect(queue.snapshot().map(\.id) == [item.id])

        queue.dismiss(id: item.id)
        #expect(queue.snapshot().isEmpty)
        #expect(queue.snapshot(includeClosed: true).first?.status == .dismissed)
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

    @Test("coordinator stores unresolvable natural language intents")
    func coordinatorStoresUnresolvableNaturalLanguageIntents() throws {
        let coordinator = try IntentRuntimeCoordinator.default()

        let result = coordinator.resolveNaturalLanguageIntent(
            NaturalLanguageIntent(text: "delete selected"),
            context: NaturalLanguageIntentContext()
        )

        let unresolved = try #require(result.unresolved)
        #expect(coordinator.unresolvedNaturalLanguageIntents().map(\.id) == [unresolved.id])

        coordinator.dismissUnresolvedIntent(id: unresolved.id)
        #expect(coordinator.unresolvedNaturalLanguageIntents().isEmpty)
    }

    @Test("coordinator exposes prompt-safe symbolic capabilities from its registry")
    func coordinatorExposesPromptSafeSymbolicCapabilities() throws {
        let coordinator = try IntentRuntimeCoordinator.default()
        let views = coordinator.promptCapabilitySymbolicViews(
            for: CapabilityInvocationContext(role: .editor,
                                             releasePhase: .beta,
                                             includeExperimental: true)
        )

        let spawn = try #require(views.first { $0.verbID == "scene.spawn_entity" })
        let draftCommit = try #require(views.first { $0.verbID == "scene.commit_inferred_draft" })

        #expect(spawn.arguments.contains { $0.name == "label" && $0.llmHint == "Entity label" })
        #expect(!draftCommit.arguments.contains { $0.name == "confirm_phrase" })
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

    @Test("capability invocation applies auto-confirm transactions immediately")
    func capabilityInvocationAppliesAutoConfirmTransactionsImmediately() throws {
        let coordinator = try IntentRuntimeCoordinator.default()
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
        var context = TransactionExecutionContext(sceneRuntime: SceneRuntime())

        let result = try coordinator.submit(transaction,
                                            capabilityContext: CapabilityInvocationContext(role: .editor,
                                                                                           releasePhase: .beta),
                                            executionContext: &context)

        #expect(result.disposition == .applied)
        #expect(result.readAfterWrite == [.sceneChanged])
        #expect(result.applyResult?.createdEntityIDs.count == 1)
        #expect(context.sceneRuntime?.snapshot.entityCount == 1)
    }

    @Test("capability invocation stages warn-level transactions and emits confirmation requests")
    func capabilityInvocationStagesWarnLevelTransactions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let bus = try ObservationBus(coldLogDirectory: root.path)
        let coordinator = try IntentRuntimeCoordinator.default()
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
                                        provenance: .authored)
        var context = TransactionExecutionContext(sceneRuntime: scene,
                                                  observationBus: bus,
                                                  eventOrigin: EventOrigin(process: .editor,
                                                                           host: "test-host",
                                                                           user: "alex"))

        let result = try coordinator.submit(transaction,
                                            capabilityContext: CapabilityInvocationContext(role: .editor,
                                                                                           releasePhase: .beta),
                                            executionContext: &context)
        let stagedEvents = transactionSubscription.drain()
        let confirmationEvents = confirmationSubscription.drain()

        #expect(result.disposition == .confirmationRequested)
        #expect(result.stagedResult?.transactionID == transaction.id)
        #expect(context.sceneRuntime?.snapshot.entityCount == 1)
        #expect(stagedEvents.map(\ .kind) == [.transactionStaged])
        #expect(confirmationEvents.map(\ .kind) == [.confirmationRequested])
        let payload = try #require(confirmationEvents.first?.payloadRef.inlineRecord)
        #expect(payload["batch_id"] == .string("cfm:\(transaction.id)"))
        #expect(payload["required_role"] == .string("editor"))
        #expect(result.readAfterWrite == [.sceneChanged])
    }

    @Test("confirmation resolution applies staged transactions and publishes UI resolution")
    func confirmationResolutionAppliesStagedTransactions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let bus = try ObservationBus(coldLogDirectory: root.path)
        let coordinator = try IntentRuntimeCoordinator.default()
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
                                        provenance: .authored)
        var context = TransactionExecutionContext(sceneRuntime: scene,
                                                  observationBus: bus,
                                                  eventOrigin: EventOrigin(process: .editor,
                                                                           host: "test-host",
                                                                           user: "alex"))

        let staged = try coordinator.submit(transaction,
                                            capabilityContext: CapabilityInvocationContext(role: .editor,
                                                                                           releasePhase: .beta),
                                            executionContext: &context)
        let request = try #require(staged.confirmationRequest)
        let resolution = ConfirmationResolution(batchID: request.batchID,
                                                correlationID: request.correlationID,
                                                answers: [ConfirmationAnswer(questionID: request.questions[0].id,
                                                                             outcome: .accepted,
                                                                             pickedOptionID: "confirm")],
                                                userID: "alex",
                                                partial: false)

        let applied = try coordinator.resolveConfirmation(resolution, executionContext: &context)
        let confirmationEvents = confirmationResolvedSubscription.drain()
        let sceneEvents = sceneSubscription.drain()

        #expect(applied.disposition == .applied)
        #expect(context.sceneRuntime?.snapshot.entityCount == 0)
        #expect(applied.readAfterWrite == [.sceneChanged])
        #expect(confirmationEvents.map(\ .kind) == [.confirmationResolved])
        #expect(sceneEvents.map(\ .kind) == [.sceneChanged])
    }

    @Test("capability invocation rejects insufficient roles before staging or apply")
    func capabilityInvocationRejectsInsufficientRoles() {
        let coordinator = try! IntentRuntimeCoordinator.default()
        let transaction = TransactionIR(intent: IntentIR(verb: "scene.spawn_entity",
                                                         summary: "Spawn imported mesh",
                                                         source: .human),
                                        summary: "Spawn imported mesh",
                                        operations: [
                                            .scene(.spawnImportedMeshEntity(label: "Hero",
                                                                           kindLabel: "Static Mesh",
                                                                           meshIndex: 9,
                                                                           position: .zero))
                                        ],
                                        baseRevisions: TransactionBaseRevisions(sceneRevision: 0),
                                        provenance: .authored)
        var context = TransactionExecutionContext(sceneRuntime: SceneRuntime())

        #expect(throws: CapabilityRegistryError.self) {
            try coordinator.submit(transaction,
                                   capabilityContext: CapabilityInvocationContext(role: .viewer,
                                                                                  releasePhase: .beta),
                                   executionContext: &context)
        }
        #expect(context.sceneRuntime?.snapshot.entityCount == 0)
    }

    @Test("capability invocation blocks transactions with failing preconditions")
    func capabilityInvocationBlocksFailingPreconditions() throws {
        let capability = CapabilitySpec(verbID: "scene.preconditioned_spawn",
                                        summary: "Spawn when selection exists",
                                        category: "scene",
                                        scope: .sceneInstance,
                                        targetKind: "scene_instance_id",
                                        preconditions: [
                                            Precondition(id: "selection",
                                                         kind: .targetState,
                                                         expr: .exists("editor.selection"),
                                                         message: "Selection required",
                                                         severity: .block)
                                        ],
                                        reversible: true,
                                        previewSupport: CapabilityPreviewSupport(mode: .ghostWorld),
                                        confirmationPolicy: CapabilityConfirmationPolicy(level: .auto),
                                        readAfterWrite: [.sceneChanged],
                                        sideBandEmits: [.transactionApplied, .sceneChanged, .sceneEntityAdded],
                                        requiredRole: .editor,
                                        status: .stable)
        let registry = try CapabilityRegistry(capabilities: [capability])
        let coordinator = IntentRuntimeCoordinator(registry: registry)
        let transaction = TransactionIR(intent: IntentIR(verb: "scene.preconditioned_spawn",
                                                         summary: "Spawn imported mesh",
                                                         source: .human),
                                        summary: "Spawn imported mesh",
                                        operations: [
                                            .scene(.spawnImportedMeshEntity(label: "Hero",
                                                                           kindLabel: "Static Mesh",
                                                                           meshIndex: 9,
                                                                           position: .zero))
                                        ],
                                        baseRevisions: TransactionBaseRevisions(sceneRevision: 0),
                                        provenance: .authored)
        var context = TransactionExecutionContext(sceneRuntime: SceneRuntime())

        #expect(throws: CapabilityInvocationPlannerError.self) {
            try coordinator.submit(transaction,
                                   capabilityContext: CapabilityInvocationContext(role: .editor,
                                                                                  releasePhase: .beta),
                                   executionContext: &context)
        }
        #expect(context.sceneRuntime?.snapshot.entityCount == 0)
    }

    @Test("capability invocation rejects release-gated verbs before staging")
    func capabilityInvocationRejectsReleaseGatedVerbs() {
        let coordinator = try! IntentRuntimeCoordinator.default()
        let transaction = TransactionIR(intent: IntentIR(verb: "scene.commit_inferred_draft",
                                                         summary: "Commit inferred draft",
                                                         source: .ai),
                                        summary: "Commit inferred draft",
                                        operations: [
                                            .scene(.spawnImportedMeshEntity(label: "Draft",
                                                                           kindLabel: "Static Mesh",
                                                                           meshIndex: 4,
                                                                           position: .zero))
                                        ],
                                        provenance: .inferred)
        var context = TransactionExecutionContext(sceneRuntime: SceneRuntime())

        #expect(throws: CapabilityRegistryError.self) {
            try coordinator.submit(transaction,
                                   capabilityContext: CapabilityInvocationContext(role: .editor,
                                                                                  releasePhase: .ship,
                                                                                  includeExperimental: true),
                                   executionContext: &context)
        }
    }

    @Test("capability invocation rejects unsupported provenance before staging")
    func capabilityInvocationRejectsUnsupportedProvenance() throws {
        let capability = CapabilitySpec(verbID: "scene.authored_only",
                                        summary: "Only authored inputs are allowed",
                                        category: "scene",
                                        scope: .sceneInstance,
                                        targetKind: "scene_instance_id",
                                        reversible: true,
                                        previewSupport: CapabilityPreviewSupport(mode: .ghostWorld),
                                        confirmationPolicy: CapabilityConfirmationPolicy(level: .auto),
                                        readAfterWrite: [.sceneChanged],
                                        sideBandEmits: [.transactionApplied, .sceneChanged],
                                        requiredRole: .editor,
                                        status: .stable,
                                        provenanceInputAllowed: [.authored])
        let registry = try CapabilityRegistry(config: CapabilityRegistryConfig(
            capabilities: [capability],
            scopes: ["scene_instance": CapabilityScopeSpec(scopeID: "scene_instance")],
            targetKinds: ["scene_instance_id": CapabilityTargetKindSpec(targetKindID: "scene_instance_id")]
        ))
        let coordinator = IntentRuntimeCoordinator(registry: registry)
        let transaction = TransactionIR(intent: IntentIR(verb: "scene.authored_only",
                                                         summary: "Try inferred mutation",
                                                         source: .ai),
                                        summary: "Try inferred mutation",
                                        operations: [
                                            .scene(.spawnImportedMeshEntity(label: "Draft",
                                                                           kindLabel: "Static Mesh",
                                                                           meshIndex: 1,
                                                                           position: .zero))
                                        ],
                                        provenance: .inferred)
        var context = TransactionExecutionContext(sceneRuntime: SceneRuntime())

        #expect(throws: CapabilityInvocationPlannerError.self) {
            try coordinator.submit(transaction,
                                   capabilityContext: CapabilityInvocationContext(role: .editor,
                                                                                  releasePhase: .beta),
                                   executionContext: &context)
        }
        #expect(context.sceneRuntime?.snapshot.entityCount == 0)
    }

    private func entityID(from rawID: UInt64) -> EntityID {
        EntityID(index: UInt32(rawID & 0xFFFF_FFFF),
                 generation: UInt32(rawID >> 32))
    }
}

// MARK: - End-to-end integration tests

@Suite("IntentRuntime end-to-end", .serialized)
struct IntentRuntimeEndToEndTests {

    @Test("ObservationBus → IntentIR → TransactionIR → SceneRuntime full pipeline")
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

        // 2. IntentIR — what the user/AI intends
        let intent = IntentIR(
            id: "intent-\(UUID().uuidString.prefix(8))",
            verb: "scene.spawn_entity",
            summary: "Spawn a hero mesh at the origin",
            targetObjectIDs: [],
            source: .human,
            createdAt: Date()
        )

        // 3. TransactionIR — structured operations
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

        // 4. SceneRuntime — target for mutation
        var context = TransactionExecutionContext(
            sceneRuntime: SceneRuntime(),
            observationBus: bus,
            eventOrigin: EventOrigin(process: .editor, host: "test", user: "e2e"),
            sceneStreamID: "scene:e2e")

        // 5. TransactionExecutor — applies transaction, emits events
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

        // 8. Cold log replay — at minimum sceneChanged events are recorded
        let replayed = try bus.replay(streamID: "scene:e2e", fromSeq: 1)
        #expect(replayed.count >= 1)
        #expect(replayed.contains { $0.kind == .sceneChanged })
    }

    @Test("Multi-step pipeline: spawn → setLocalTransform → verify via cold log replay")
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
        let coordinator = try IntentRuntimeCoordinator.default()
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
            provenance: .authored)

        let result = try coordinator.submit(
            tx,
            capabilityContext: CapabilityInvocationContext(role: .editor, releasePhase: .beta),
            executionContext: &context)

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
