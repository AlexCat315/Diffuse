import AssetPipeline
import Foundation
import IntentRuntime
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

    private func entityID(from rawID: UInt64) -> EntityID {
        EntityID(index: UInt32(rawID & 0xFFFF_FFFF),
                 generation: UInt32(rawID >> 32))
    }
}