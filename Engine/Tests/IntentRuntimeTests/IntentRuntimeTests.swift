import AssetPipeline
import CapabilityRuntime
import Foundation
import IntentRuntime
import ObservationBus
import SceneRuntime
import SequenceRuntime
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

    private func entityID(from rawID: UInt64) -> EntityID {
        EntityID(index: UInt32(rawID & 0xFFFF_FFFF),
                 generation: UInt32(rawID >> 32))
    }
}