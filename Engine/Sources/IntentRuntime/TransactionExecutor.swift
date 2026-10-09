import AssetPipeline
import Foundation
import ObservationBus
import SceneRuntime
import SequenceRuntime
import ScriptRuntime
import SIMDCompat

public struct TransactionExecutionContext {
    public var sceneRuntime: SceneRuntime?
    public var sequenceDocument: SequenceDocument?
    public var assetRegistry: AssetRegistry?
    public var observationBus: ObservationBus?
    public var eventOrigin: EventOrigin
    public var sceneStreamID: String
    public var transactionStreamID: String
    public var assetStreamID: String
    public var uiStreamID: String

    public init(sceneRuntime: SceneRuntime? = nil,
                sequenceDocument: SequenceDocument? = nil,
                assetRegistry: AssetRegistry? = nil,
                observationBus: ObservationBus? = nil,
                eventOrigin: EventOrigin = .tool(),
                sceneStreamID: String = "scene:main",
                transactionStreamID: String = "transaction",
                assetStreamID: String = "asset:project",
                uiStreamID: String = "ui:confirmation") {
        var scene = sceneRuntime
        scene?.componentRegistry.registerScriptCodec()
        self.sceneRuntime = scene
        self.sequenceDocument = sequenceDocument
        self.assetRegistry = assetRegistry
        self.observationBus = observationBus
        self.eventOrigin = eventOrigin
        self.sceneStreamID = sceneStreamID
        self.transactionStreamID = transactionStreamID
        self.assetStreamID = assetStreamID
        self.uiStreamID = uiStreamID
    }
}

public enum TransactionExecutorError: Error, CustomStringConvertible {
    case missingSceneRuntime
    case missingSequenceDocument
    case missingAssetRegistry
    case previewUnsupportedForAssets
    case sceneBaseRevisionMismatch(expected: UInt64, actual: UInt64)
    case sequenceBaseRevisionMismatch(expected: String, actual: String?)
    case assetBaseRevisionMismatch(expected: String, actual: String?)
    case invalidEntity(UInt64)
    case missingComponent(entityID: UInt64, type: String)
    case assetLoadFailed(path: String, message: String)
    case verificationFailed(String)

    public var description: String {
        switch self {
        case .missingSceneRuntime:
            return "missing SceneRuntime in TransactionExecutionContext"
        case .missingSequenceDocument:
            return "missing SequenceDocument in TransactionExecutionContext"
        case .missingAssetRegistry:
            return "missing AssetRegistry in TransactionExecutionContext"
        case .previewUnsupportedForAssets:
            return "asset mutations are not previewable with the current execution context"
        case let .sceneBaseRevisionMismatch(expected, actual):
            return "scene base revision mismatch: expected \(expected), actual \(actual)"
        case let .sequenceBaseRevisionMismatch(expected, actual):
            return "sequence base revision mismatch: expected \(expected), actual \(actual ?? "nil")"
        case let .assetBaseRevisionMismatch(expected, actual):
            return "asset base revision mismatch: expected \(expected), actual \(actual ?? "nil")"
        case let .invalidEntity(entityID):
            return "invalid entity id: \(entityID)"
        case let .missingComponent(entityID, type):
            return "missing component \(type) on entity \(entityID)"
        case let .assetLoadFailed(path, message):
            return "asset load failed at \(path): \(message)"
        case let .verificationFailed(message):
            return "transaction verification failed: \(message)"
        }
    }
}

public struct TransactionApplyResult: Sendable, Equatable {
    public var transactionID: String
    public var changedDomains: [TransactionDomain]
    public var createdEntityIDs: [UInt64]
    public var deletedEntityIDs: [UInt64]
    public var sceneRevision: UInt64?
    public var sequenceRevisionID: String?
    public var assetEntryCount: Int?
    public var edit: Edit
    /// Fine-grained authored-state changes produced by this transaction.
    /// Session feeds these into WorldView to maintain an incremental entity index.
    public var worldEvents: [WorldEvent]

    public init(transactionID: String,
                changedDomains: [TransactionDomain],
                createdEntityIDs: [UInt64] = [],
                deletedEntityIDs: [UInt64] = [],
                sceneRevision: UInt64? = nil,
                sequenceRevisionID: String? = nil,
                assetEntryCount: Int? = nil,
                edit: Edit,
                worldEvents: [WorldEvent] = []) {
        self.transactionID = transactionID
        self.changedDomains = changedDomains
        self.createdEntityIDs = createdEntityIDs
        self.deletedEntityIDs = deletedEntityIDs
        self.sceneRevision = sceneRevision
        self.sequenceRevisionID = sequenceRevisionID
        self.assetEntryCount = assetEntryCount
        self.edit = edit
        self.worldEvents = worldEvents
    }
}

public struct TransactionExecutor {
    public init() {}

    public func preview(_ transaction: TransactionIR,
                        from context: TransactionExecutionContext) throws -> TransactionPreviewResult {
        guard !transaction.operations.contains(where: {
            if case .asset = $0 { return true }
            return false
        }) else {
            throw TransactionExecutorError.previewUnsupportedForAssets
        }

        var previewContext = context
        previewContext.observationBus = nil
        let result = try apply(transaction, to: &previewContext)
        return TransactionPreviewResult(changedDomains: result.changedDomains,
                                        createdEntityIDs: result.createdEntityIDs,
                                        deletedEntityIDs: result.deletedEntityIDs,
                                        sceneRevision: result.sceneRevision,
                                        sequenceRevisionID: result.sequenceRevisionID,
                                        assetEntryCount: result.assetEntryCount,
                                        mutationSummaries: result.edit.mutationSummaries)
    }

    public func apply(_ transaction: TransactionIR,
                      to context: inout TransactionExecutionContext) throws -> TransactionApplyResult {
        // SceneRuntime and SequenceDocument are value snapshots. Keeping the
        // originals here makes post-apply assertion failure atomic for the
        // domains AI is allowed to mutate.
        let originalScene = context.sceneRuntime
        let originalSequence = context.sequenceDocument
        do {
            try validate(transaction, against: context)

            let revisionBefore = WorldRevisionSnapshot(
                sceneRevision: context.sceneRuntime?.snapshot.revision,
                sequenceRevisionID: context.sequenceDocument?.revision.id
            )

            var changedDomains: [TransactionDomain] = []
            var createdEntityIDs: [UInt64] = []
            var deletedEntityIDs: [UInt64] = []
            var sceneRevision: UInt64?
            var sequenceRevisionID: String?
            var assetEntryCount: Int?

            let sceneOps = transaction.operations.compactMap { operation -> SceneMutation? in
                guard case let .scene(mutation) = operation else { return nil }
                return mutation
            }
            if !sceneOps.isEmpty {
                guard var scene = context.sceneRuntime else {
                    throw TransactionExecutorError.missingSceneRuntime
                }
                try applyScene(sceneOps,
                               transaction: transaction,
                               to: &scene,
                               createdEntityIDs: &createdEntityIDs,
                               deletedEntityIDs: &deletedEntityIDs)
                context.sceneRuntime = scene
                sceneRevision = scene.snapshot.revision
                changedDomains.append(.scene)
            }

            let sequenceOps = transaction.operations.compactMap { operation -> SequenceMutation? in
                guard case let .sequence(mutation) = operation else { return nil }
                return mutation
            }
            if !sequenceOps.isEmpty {
                guard var document = context.sequenceDocument else {
                    throw TransactionExecutorError.missingSequenceDocument
                }
                for mutation in sequenceOps {
                    switch mutation {
                    case let .replaceDocument(next):
                        document = appliedSequenceDocument(next,
                                                           previous: document,
                                                           transaction: transaction)
                    }
                }
                context.sequenceDocument = document
                sequenceRevisionID = document.revision.id
                changedDomains.append(.sequence)
            }

            let assetOps = transaction.operations.compactMap { operation -> AssetMutation? in
                guard case let .asset(mutation) = operation else { return nil }
                return mutation
            }
            if !assetOps.isEmpty {
                guard let registry = context.assetRegistry else {
                    throw TransactionExecutorError.missingAssetRegistry
                }
                for mutation in assetOps {
                    switch mutation {
                    case let .scanProject(rootPath):
                        do {
                            _ = try registry.loadProject(at: rootPath)
                        } catch {
                            throw TransactionExecutorError.assetLoadFailed(path: rootPath,
                                                                          message: String(describing: error))
                        }
                    }
                }
                assetEntryCount = registry.entriesSnapshot().count
                changedDomains.append(.asset)
            }

            let revisionAfter = WorldRevisionSnapshot(
                sceneRevision: sceneRevision,
                sequenceRevisionID: sequenceRevisionID
            )
            let edit = Edit(
                transactionID: transaction.id,
                summary: transaction.summary,
                mutationSummaries: transaction.operations.map(operationSummary),
                changedDomains: changedDomains.map(\.rawValue),
                provenance: EditProvenance(authorKind: transaction.provenance.editAuthorKind),
                revisionBefore: revisionBefore,
                revisionAfter: revisionAfter
            )
            let derivedWorldEvents = deriveWorldEvents(
                from: sceneOps,
                createdEntityIDs: createdEntityIDs,
                scene: context.sceneRuntime,
                edit: edit
            )
            let result = TransactionApplyResult(transactionID: transaction.id,
                                                changedDomains: changedDomains,
                                                createdEntityIDs: createdEntityIDs,
                                                deletedEntityIDs: deletedEntityIDs,
                                                sceneRevision: sceneRevision,
                                                sequenceRevisionID: sequenceRevisionID,
                                                assetEntryCount: assetEntryCount,
                                                edit: edit,
                                                worldEvents: derivedWorldEvents)
            try verify(transaction.verificationAssertions,
                       result: result,
                       context: context)
            try publishSuccessEvents(for: transaction,
                                     result: result,
                                     sceneOps: sceneOps,
                                     sequenceDocument: context.sequenceDocument,
                                     context: context)
            return result
        } catch {
            context.sceneRuntime = originalScene
            context.sequenceDocument = originalSequence
            try? publishFailureEvent(for: transaction, error: error, context: context)
            throw error
        }
    }

    private func verify(_ assertions: [TransactionVerificationAssertion],
                        result: TransactionApplyResult,
                        context: TransactionExecutionContext) throws {
        var retainedSceneStateIndices = Set<Int>()
        var seenSceneStateKeys = Set<String>()
        var supersededSceneStateKeys = Set<String>()
        for (index, assertion) in assertions.enumerated().reversed() {
            guard case let .sceneState(state) = assertion,
                  !supersededSceneStateKeys.contains(state.verificationKey),
                  seenSceneStateKeys.insert(state.verificationKey).inserted else { continue }
            retainedSceneStateIndices.insert(index)
            supersededSceneStateKeys.formUnion(state.supersededVerificationKeys)
        }
        var componentChecks: [SceneComponentKey: TransactionVerificationAssertion] = [:]
        for assertion in assertions {
            switch assertion {
            case let .componentData(entityID, typeID, value, mode):
                let key = SceneComponentKey(entityID: entityID, typeID: typeID)
                if mode == .merge,
                   case let .componentData(_, _, previous, previousMode) = componentChecks[key] {
                    let merged = previousMode == .replace
                        ? try (context.sceneRuntime?.componentRegistry[typeID]?.merge(previous, value) ?? previous.merging(value))
                        : try previous.merging(value)
                    componentChecks[key] = .componentData(entityID: entityID, typeID: typeID,
                        value: merged, mode: previousMode)
                } else { componentChecks[key] = assertion }
            case let .componentPresence(entityID, typeID, _):
                componentChecks[SceneComponentKey(entityID: entityID, typeID: typeID)] = assertion
            default: break
            }
        }
        for (key, assertion) in componentChecks {
            guard let scene = context.sceneRuntime else { throw TransactionExecutorError.missingSceneRuntime }
            let actual = scene.componentData(key.typeID, for: entityID(fromRaw: key.entityID))
            let matched: Bool
            switch assertion {
            case let .componentData(_, _, expected, mode):
                matched = mode == .merge ? actual?.containsFields(expected) == true : actual == expected
            case let .componentPresence(_, _, isPresent): matched = (actual != nil) == isPresent
            default: preconditionFailure("Unexpected component assertion")
            }
            guard matched else {
                throw TransactionExecutorError.verificationFailed("component \(key.typeID) on \(key.entityID) did not match")
            }
        }
        for (index, assertion) in assertions.enumerated() {
            switch assertion {
            case let .entityExists(rawID):
                guard let scene = context.sceneRuntime,
                      scene.contains(entityID(fromRaw: rawID)) else {
                    throw TransactionExecutorError.verificationFailed(
                        "expected entity \(rawID) to exist"
                    )
                }
            case let .entityIsAbsent(rawID):
                if let scene = context.sceneRuntime,
                   scene.contains(entityID(fromRaw: rawID)) {
                    throw TransactionExecutorError.verificationFailed(
                        "expected entity \(rawID) to be absent"
                    )
                }
            case let .createdEntityCount(expected):
                guard result.createdEntityIDs.count == expected else {
                    throw TransactionExecutorError.verificationFailed(
                        "expected \(expected) created entities, got \(result.createdEntityIDs.count)"
                    )
                }
            case let .deletedEntity(rawID):
                guard result.deletedEntityIDs.contains(rawID) else {
                    throw TransactionExecutorError.verificationFailed(
                        "expected entity \(rawID) in the deletion result"
                    )
                }
            case let .sceneRevisionAdvanced(previous):
                guard let actual = result.sceneRevision, actual > previous else {
                    throw TransactionExecutorError.verificationFailed(
                        "expected scene revision after \(previous), got \(result.sceneRevision.map(String.init) ?? "nil")"
                    )
                }
            case .componentData, .componentPresence:
                break
            case let .sceneState(state):
                guard retainedSceneStateIndices.contains(index) else { continue }
                guard let scene = context.sceneRuntime else {
                    throw TransactionExecutorError.missingSceneRuntime
                }
                if let failure = state.failureDescription(in: scene) {
                    throw TransactionExecutorError.verificationFailed(failure)
                }
            }
        }
    }

    private func validate(_ transaction: TransactionIR,
                          against context: TransactionExecutionContext) throws {
        let domains = transaction.operations.reduce(into: Set<TransactionDomain>()) { partial, operation in
            switch operation {
            case .scene:
                partial.insert(.scene)
            case .sequence:
                partial.insert(.sequence)
            case .asset:
                partial.insert(.asset)
            }
        }

        if domains.contains(.scene), let expected = transaction.baseRevisions.sceneRevision {
            guard let actual = context.sceneRuntime?.snapshot.revision else {
                throw TransactionExecutorError.missingSceneRuntime
            }
            guard actual == expected else {
                throw TransactionExecutorError.sceneBaseRevisionMismatch(expected: expected,
                                                                        actual: actual)
            }
        }

        if domains.contains(.sequence), let expected = transaction.baseRevisions.sequenceRevisionID {
            guard let actual = context.sequenceDocument?.revision.id else {
                throw TransactionExecutorError.missingSequenceDocument
            }
            guard actual == expected else {
                throw TransactionExecutorError.sequenceBaseRevisionMismatch(expected: expected,
                                                                           actual: actual)
            }
        }

        if domains.contains(.asset), let expected = transaction.baseRevisions.assetRevisionID {
            guard let registry = context.assetRegistry else {
                throw TransactionExecutorError.missingAssetRegistry
            }
            let actual = registry.currentProjectRoot()
            guard actual == expected else {
                throw TransactionExecutorError.assetBaseRevisionMismatch(expected: expected,
                                                                        actual: actual)
            }
        }
    }

    private func applyScene(_ operations: [SceneMutation],
                            transaction: TransactionIR,
                            to scene: inout SceneRuntime,
                            createdEntityIDs: inout [UInt64],
                            deletedEntityIDs: inout [UInt64]) throws {
        for mutation in operations {
            switch mutation {
            case .spawnImportedMeshEntity, .spawnEmptyEntity, .spawnLightEntity,
                 .spawnCameraEntity, .deleteEntity, .duplicateEntity,
                 .duplicateEntityWithOffset:
                try applyEntityMutation(mutation,
                                        to: &scene,
                                        createdEntityIDs: &createdEntityIDs,
                                        deletedEntityIDs: &deletedEntityIDs)

            case let .moveEntity(rawID, parentID, index):
                let entity = try requireEntity(rawID, in: scene)
                let parent = try requireOptionalEntity(parentID, in: scene)
                guard scene.moveEntity(entity, to: parent, at: index) else {
                    throw TransactionExecutorError.invalidEntity(rawID)
                }
            case let .setLocalTransform(rawID, transform):
                let entity = try requireEntity(rawID, in: scene)
                _ = scene.setLocalTransform(transform, for: entity)
            case let .setSceneName(rawID, name):
                let entity = try requireEntity(rawID, in: scene)
                _ = scene.setComponent(SceneNameComponent(value: name), for: entity)
            case let .setComponentData(rawID, typeID, value, mode):
                let entity = try requireEntity(rawID, in: scene)
                try scene.setComponentData(value, typeID: typeID, for: entity, mode: mode)
            case let .addComponent(rawID, typeID):
                let entity = try requireEntity(rawID, in: scene)
                try scene.addComponent(typeID: typeID, for: entity)
            case let .removeComponentData(rawID, typeID):
                let entity = try requireEntity(rawID, in: scene)
                try scene.removeComponentData(typeID: typeID, for: entity)
            }
        }

        scene.propagateTransforms()
        _ = transaction
    }

    /// Keep mutation execution split into bounded stack frames. A single switch
    /// over every SceneMutation makes Swift's unoptimised build reserve storage
    /// for all generic component-update temporaries at once, which can exceed a
    /// cooperative task's stack before the selected case even starts.
    private func applyEntityMutation(_ mutation: SceneMutation,
                                     to scene: inout SceneRuntime,
                                     createdEntityIDs: inout [UInt64],
                                     deletedEntityIDs: inout [UInt64]) throws {
        switch mutation {
            case let .spawnImportedMeshEntity(label, kindLabel, meshIndex, position, parentID):
                let entity = scene.createEntity()
                _ = scene.setComponent(SceneNameComponent(value: label), for: entity)
                _ = scene.setComponent(SceneKindComponent(value: kindLabel), for: entity)
                _ = scene.setLocalTransform(LocalTransform(translation: position), for: entity)
                _ = scene.setComponent(RenderMeshComponent(meshIndex: meshIndex), for: entity)
                if let pid = parentID { _ = scene.setParent(EntityID(index: UInt32(pid & 0xFFFF_FFFF), generation: UInt32(pid >> 32)), for: entity) }
                createdEntityIDs.append(entity.rawValue)

            case let .spawnEmptyEntity(label, position, parentID):
                let entity = scene.createEntity()
                _ = scene.setComponent(SceneNameComponent(value: label), for: entity)
                _ = scene.setComponent(SceneKindComponent(value: "Empty"), for: entity)
                _ = scene.setLocalTransform(LocalTransform(translation: position), for: entity)
                if let pid = parentID { _ = scene.setParent(EntityID(index: UInt32(pid & 0xFFFF_FFFF), generation: UInt32(pid >> 32)), for: entity) }
                createdEntityIDs.append(entity.rawValue)

            case let .spawnLightEntity(label, lightType, position, initialIntensity, initialColor, initialRange, initialCastShadows, parentID):
                let entity = scene.createEntity()
                _ = scene.setComponent(SceneNameComponent(value: label), for: entity)
                _ = scene.setComponent(SceneKindComponent(value: "Light"), for: entity)
                try scene.addComponent(typeID: "light", for: entity)
                _ = scene.updateComponent(LightComponent.self, for: entity) { light in
                    light.type = lightType
                    if let v = initialIntensity { light.intensity = v }
                    if let v = initialColor { light.color = v }
                    if let v = initialRange { light.range = v }
                    if let v = initialCastShadows { light.castShadows = v }
                }
                _ = scene.setLocalTransform(LocalTransform(translation: position), for: entity)
                if let pid = parentID { _ = scene.setParent(EntityID(index: UInt32(pid & 0xFFFF_FFFF), generation: UInt32(pid >> 32)), for: entity) }
                createdEntityIDs.append(entity.rawValue)

            case let .spawnCameraEntity(label, position, initialFovYDegrees, parentID):
                let entity = scene.createEntity()
                _ = scene.setComponent(SceneNameComponent(value: label), for: entity)
                _ = scene.setComponent(SceneKindComponent(value: "Camera"), for: entity)
                try scene.addComponent(typeID: "camera", for: entity)
                if let fov = initialFovYDegrees {
                    _ = scene.updateComponent(CameraComponent.self, for: entity) { $0.fovYRadians = fov * .pi / 180 }
                }
                _ = scene.setLocalTransform(LocalTransform(translation: position), for: entity)
                if let pid = parentID { _ = scene.setParent(EntityID(index: UInt32(pid & 0xFFFF_FFFF), generation: UInt32(pid >> 32)), for: entity) }
                createdEntityIDs.append(entity.rawValue)

            case let .deleteEntity(entityID):
                let entity = try requireEntity(entityID, in: scene)
                guard scene.destroyEntity(entity) else {
                    throw TransactionExecutorError.invalidEntity(entityID)
                }
                deletedEntityIDs.append(entityID)

            case let .duplicateEntity(entityID):
                let source = try requireEntity(entityID, in: scene)
                createdEntityIDs.append(duplicateEntity(source, offset: nil, in: &scene).rawValue)
            case let .duplicateEntityWithOffset(entityID, offset):
                let source = try requireEntity(entityID, in: scene)
                createdEntityIDs.append(duplicateEntity(source, offset: offset, in: &scene).rawValue)

            default:
                preconditionFailure("non-entity mutation routed to applyEntityMutation")
        }
    }

    private func duplicateEntity(_ source: EntityID, offset: SIMD3<Float>?,
                                 in scene: inout SceneRuntime) -> EntityID {
        let entity = scene.createEntity()
        if let name = scene.component(SceneNameComponent.self, for: source) {
            _ = scene.setComponent(SceneNameComponent(value: name.value + " Copy"), for: entity)
        }
        if let kind = scene.component(SceneKindComponent.self, for: source) {
            _ = scene.setComponent(kind, for: entity)
        }
        if let local = scene.localTransform(for: source) { _ = scene.setLocalTransform(local, for: entity) }
        if let offset {
            var transform = scene.localTransform(for: source) ?? LocalTransform()
            transform.matrix.columns.3 += SIMD4<Float>(offset, 0)
            _ = scene.setLocalTransform(transform, for: entity)
        }
        if let parent = scene.parent(of: source) { _ = scene.setParent(parent, for: entity) }
        scene.duplicateComponentData(from: source, to: entity)
        return entity
    }

    private func requireEntity(_ rawID: UInt64,
                               in scene: SceneRuntime) throws -> EntityID {
        let entity = entityID(fromRaw: rawID)
        guard scene.contains(entity) else {
            throw TransactionExecutorError.invalidEntity(rawID)
        }
        return entity
    }

    private func entityID(fromRaw rawID: UInt64) -> EntityID {
        EntityID(index: UInt32(rawID & 0xFFFF_FFFF),
                 generation: UInt32(rawID >> 32))
    }

    private func requireOptionalEntity(_ rawID: UInt64?,
                                       in scene: SceneRuntime) throws -> EntityID? {
        guard let rawID else { return nil }
        return try requireEntity(rawID, in: scene)
    }

    private func appliedSequenceDocument(_ next: SequenceDocument,
                                         previous: SequenceDocument,
                                         transaction: TransactionIR) -> SequenceDocument {
        var document = next
        let revision = SequenceRevision(id: UUID().uuidString,
                                        parentID: previous.revision.id,
                                        author: transaction.intent?.source.rawValue ?? "system",
                                        createdAt: Date(),
                                        baseSceneRevisionID: document.revision.baseSceneRevisionID ?? previous.revision.baseSceneRevisionID,
                                        baseSequenceRevisionID: previous.revision.id,
                                        transactionIDs: previous.revision.transactionIDs + [transaction.id])
        document.revision = revision
        return document
    }

    private func publishSuccessEvents(for transaction: TransactionIR,
                                      result: TransactionApplyResult,
                                      sceneOps: [SceneMutation],
                                      sequenceDocument: SequenceDocument?,
                                      context: TransactionExecutionContext) throws {
        guard let bus = context.observationBus else { return }
        let relay = OutboxRelay()
        relay.enqueue(EventDraft(kind: .transactionApplied,
                                 streamID: context.transactionStreamID,
                                 origin: context.eventOrigin,
                                 causationID: transaction.id,
                                 provenance: eventProvenance(for: transaction.provenance),
                                 payloadRef: .inline(transactionLifecyclePayload(transaction: transaction,
                                                                                status: "applied",
                                                                                changedDomains: result.changedDomains,
                                                                                sceneRevision: result.sceneRevision,
                                                                                sequenceRevisionID: result.sequenceRevisionID,
                                                                                assetEntryCount: result.assetEntryCount,
                                                                                message: nil))))

        if result.changedDomains.contains(.scene) {
            let entityIDs = changedEntityIDs(from: sceneOps,
                                             createdEntityIDs: result.createdEntityIDs,
                                             deletedEntityIDs: result.deletedEntityIDs)
            relay.enqueue(EventDraft(kind: .sceneChanged,
                                     streamID: context.sceneStreamID,
                                     origin: context.eventOrigin,
                                     causationID: transaction.id,
                                     provenance: eventProvenance(for: transaction.provenance),
                                     payloadRef: .inline(sceneChangedPayload(transactionID: transaction.id,
                                                                            entityIDs: entityIDs,
                                                                            revision: result.sceneRevision))))
            if !result.createdEntityIDs.isEmpty {
                relay.enqueue(EventDraft(kind: .sceneEntityAdded,
                                         streamID: context.sceneStreamID,
                                         origin: context.eventOrigin,
                                         causationID: transaction.id,
                                         provenance: eventProvenance(for: transaction.provenance),
                                         payloadRef: .inline(sceneEntityPayload(entityIDs: result.createdEntityIDs,
                                                                              revision: result.sceneRevision))))
            }
            if !result.deletedEntityIDs.isEmpty {
                relay.enqueue(EventDraft(kind: .sceneEntityRemoved,
                                         streamID: context.sceneStreamID,
                                         origin: context.eventOrigin,
                                         causationID: transaction.id,
                                         provenance: eventProvenance(for: transaction.provenance),
                                         payloadRef: .inline(sceneEntityPayload(entityIDs: result.deletedEntityIDs,
                                                                              revision: result.sceneRevision))))
            }
        }

        if result.changedDomains.contains(.sequence) {
            relay.enqueue(EventDraft(kind: .sequenceChanged,
                                     streamID: "sequence:\(sequenceDocument?.id ?? "main")",
                                     origin: context.eventOrigin,
                                     causationID: transaction.id,
                                     provenance: eventProvenance(for: transaction.provenance),
                                     payloadRef: .inline(sequenceChangedPayload(document: sequenceDocument,
                                                                               transactionID: transaction.id))))
        }

        if result.changedDomains.contains(.asset) {
            relay.enqueue(EventDraft(kind: .assetImportFinished,
                                     streamID: context.assetStreamID,
                                     origin: context.eventOrigin,
                                     causationID: transaction.id,
                                     provenance: eventProvenance(for: transaction.provenance),
                                     payloadRef: .inline(assetImportPayload(entryCount: result.assetEntryCount,
                                                                           transactionID: transaction.id,
                                                                           projectRoot: context.assetRegistry?.currentProjectRoot()))))
        }

        _ = try relay.flush(into: bus)
    }

    private func publishFailureEvent(for transaction: TransactionIR,
                                     error: Error,
                                     context: TransactionExecutionContext) throws {
        guard let bus = context.observationBus else { return }
        _ = try bus.publish(kind: .transactionFailed,
                            streamID: context.transactionStreamID,
                            payload: .inline(transactionLifecyclePayload(transaction: transaction,
                                                                         status: "failed",
                                                                         changedDomains: [],
                                                                         sceneRevision: nil,
                                                                         sequenceRevisionID: nil,
                                                                         assetEntryCount: nil,
                                                                         message: String(describing: error))),
                            origin: context.eventOrigin,
                            causationID: transaction.id,
                            provenance: eventProvenance(for: transaction.provenance))
    }

    private func eventProvenance(for provenance: TransactionProvenance) -> EventProvenance {
        switch provenance {
        case .authored:
            return .authored
        case .inferred:
            return .inferred
        case .proposal:
            return .evaluated
        case .baked:
            return .baked
        }
    }

    private func transactionLifecyclePayload(transaction: TransactionIR,
                                             status: String,
                                             changedDomains: [TransactionDomain],
                                             sceneRevision: UInt64?,
                                             sequenceRevisionID: String?,
                                             assetEntryCount: Int?,
                                             message: String?) -> EventPayloadRecord {
        var payload: EventPayloadRecord = [
            "transaction_id": .string(transaction.id),
            "summary": .string(transaction.summary),
            "status": .string(status),
            "approval_policy": .string(transaction.approvalPolicy.rawValue),
            "provenance": .string(transaction.provenance.rawValue),
            "changed_domains": .array(changedDomains.map { .string($0.rawValue) }),
        ]
        if let sceneRevision {
            payload["scene_revision"] = .integer(Int64(sceneRevision))
        }
        if let sequenceRevisionID {
            payload["sequence_revision_id"] = .string(sequenceRevisionID)
        }
        if let assetEntryCount {
            payload["asset_entry_count"] = .integer(Int64(assetEntryCount))
        }
        if let message {
            payload["message"] = .string(message)
        }
        return payload
    }

    private func sceneChangedPayload(transactionID: String,
                                     entityIDs: [UInt64],
                                     revision: UInt64?) -> EventPayloadRecord {
        var payload: EventPayloadRecord = [
            "transaction_id": .string(transactionID),
            "entity_ids": .array(entityIDs.map { .integer(Int64($0)) }),
        ]
        if let revision {
            payload["scene_revision"] = .integer(Int64(revision))
        }
        return payload
    }

    private func sceneEntityPayload(entityIDs: [UInt64], revision: UInt64?) -> EventPayloadRecord {
        var payload: EventPayloadRecord = [
            "entity_ids": .array(entityIDs.map { .integer(Int64($0)) }),
        ]
        if let revision {
            payload["scene_revision"] = .integer(Int64(revision))
        }
        return payload
    }

    private func sequenceChangedPayload(document: SequenceDocument?,
                                        transactionID: String) -> EventPayloadRecord {
        var payload: EventPayloadRecord = [
            "transaction_id": .string(transactionID),
        ]
        if let document {
            payload["sequence_id"] = .string(document.id)
            payload["sequence_revision_id"] = .string(document.revision.id)
            payload["shot_count"] = .integer(Int64(document.shots.count))
        }
        return payload
    }

    private func assetImportPayload(entryCount: Int?,
                                    transactionID: String,
                                    projectRoot: String?) -> EventPayloadRecord {
        var payload: EventPayloadRecord = [
            "transaction_id": .string(transactionID),
        ]
        if let entryCount {
            payload["entry_count"] = .integer(Int64(entryCount))
        }
        if let projectRoot {
            payload["project_root"] = .string(projectRoot)
        }
        return payload
    }

    private func changedEntityIDs(from sceneOps: [SceneMutation],
                                  createdEntityIDs: [UInt64],
                                  deletedEntityIDs: [UInt64]) -> [UInt64] {
        var ids = Set(createdEntityIDs + deletedEntityIDs)
        for operation in sceneOps {
            if let entityID = operation.entityID {
                ids.insert(entityID)
            }
        }
        return ids.sorted()
    }

    private func operationSummary(_ operation: TransactionOperation) -> String {
        switch operation {
        case let .scene(mutation):
            return sceneMutationSummary(mutation)
        case .sequence:
            return "sequence:replace"
        case let .asset(mutation):
            switch mutation {
            case let .scanProject(rootPath):
                return "asset:scan:\(rootPath)"
            }
        }
    }

    private func sceneMutationSummary(_ mutation: SceneMutation) -> String {
        switch mutation {
        case let .spawnImportedMeshEntity(label, _, _, _, _):
            return "scene:spawn:\(label)"
        case let .spawnEmptyEntity(label, _, _):
            return "scene:spawn_empty:\(label)"
        case let .spawnLightEntity(label, _, _, _, _, _, _, _):
            return "scene:spawn_light:\(label)"
        case let .spawnCameraEntity(label, _, _, _):
            return "scene:spawn_camera:\(label)"
        case let .deleteEntity(id):
            return "scene:delete:\(id)"
        case let .duplicateEntity(id):
            return "scene:duplicate:\(id)"
        case let .duplicateEntityWithOffset(id, _):
            return "scene:duplicate_offset:\(id)"
        case let .moveEntity(id, _, _):
            return "scene:move:\(id)"
        case let .setLocalTransform(id, _):
            return "scene:transform:\(id)"
        case let .setSceneName(id, name):
            return "scene:rename:\(id):\(name)"
        case let .setComponentData(id, typeID, _, _):
            return "scene:component:\(typeID):\(id)"
        case let .addComponent(id, typeID):
            return "scene:add_component:\(typeID):\(id)"
        case let .removeComponentData(id, typeID):
            return "scene:remove_component:\(typeID):\(id)"
        }
    }

    // MARK: - WorldEvent derivation

    /// Derives WorldEvents from applied SceneMutations without re-querying the scene
    /// for most mutations. Spawn and duplicate operations query the post-apply scene
    /// to retrieve the created entity's properties by ID.
    private func deriveWorldEvents(from sceneOps: [SceneMutation],
                                   createdEntityIDs: [UInt64],
                                   scene: SceneRuntime?,
                                   edit: Edit) -> [WorldEvent] {
        var events: [WorldEvent] = []
        var createdIndex = 0

        for op in sceneOps {
            switch op {
            case let .spawnImportedMeshEntity(label, kindLabel, _, position, parentID):
                if createdIndex < createdEntityIDs.count {
                    let rawID = createdEntityIDs[createdIndex]
                    let ref = "scene:\(rawID)"
                    events.append(.entityAdded(ref: ref, name: label, kind: kindLabel))
                    events.append(.entityAuthoredChanged(ref: ref, property: "position",
                        value: .vec3(position.x, position.y, position.z)))
                    if let pid = parentID {
                        events.append(.entityAuthoredChanged(ref: ref, property: "parentRef",
                            value: .string("scene:\(pid)")))
                    }
                    events.append(contentsOf: worldTransformEvents(for: rawID, in: scene))
                    createdIndex += 1
                }

            case let .spawnEmptyEntity(label, position, parentID):
                if createdIndex < createdEntityIDs.count {
                    let rawID = createdEntityIDs[createdIndex]
                    let ref = "scene:\(rawID)"
                    events.append(.entityAdded(ref: ref, name: label, kind: "Empty"))
                    events.append(.entityAuthoredChanged(ref: ref, property: "position",
                        value: .vec3(position.x, position.y, position.z)))
                    if let pid = parentID {
                        events.append(.entityAuthoredChanged(ref: ref, property: "parentRef",
                            value: .string("scene:\(pid)")))
                    }
                    events.append(contentsOf: worldTransformEvents(for: rawID, in: scene))
                    createdIndex += 1
                }

            case let .spawnLightEntity(label, _, position, _, _, _, _, parentID):
                if createdIndex < createdEntityIDs.count {
                    let rawID = createdEntityIDs[createdIndex]
                    let ref = "scene:\(rawID)"
                    events.append(.entityAdded(ref: ref, name: label, kind: "Light"))
                    events.append(.entityAuthoredChanged(ref: ref, property: "position",
                        value: .vec3(position.x, position.y, position.z)))
                    if let data = scene?.componentData("light", for: self.entityID(fromRaw: rawID)) {
                        events.append(contentsOf: WorldEvent.componentChanges(entityID: rawID, typeID: "light", value: data))
                    }
                    if let pid = parentID {
                        events.append(.entityAuthoredChanged(ref: ref, property: "parentRef",
                            value: .string("scene:\(pid)")))
                    }
                    events.append(contentsOf: worldTransformEvents(for: rawID, in: scene))
                    createdIndex += 1
                }

            case let .spawnCameraEntity(label, position, _, parentID):
                if createdIndex < createdEntityIDs.count {
                    let rawID = createdEntityIDs[createdIndex]
                    let ref = "scene:\(rawID)"
                    events.append(.entityAdded(ref: ref, name: label, kind: "Camera"))
                    events.append(.entityAuthoredChanged(ref: ref, property: "position",
                        value: .vec3(position.x, position.y, position.z)))
                    if let data = scene?.componentData("camera", for: self.entityID(fromRaw: rawID)) {
                        events.append(contentsOf: WorldEvent.componentChanges(entityID: rawID, typeID: "camera", value: data))
                    }
                    if let pid = parentID {
                        events.append(.entityAuthoredChanged(ref: ref, property: "parentRef",
                            value: .string("scene:\(pid)")))
                    }
                    events.append(contentsOf: worldTransformEvents(for: rawID, in: scene))
                    createdIndex += 1
                }

            case let .deleteEntity(entityID):
                events.append(.entityRemoved(ref: "scene:\(entityID)"))

            case .duplicateEntity, .duplicateEntityWithOffset:
                if createdIndex < createdEntityIDs.count, let scene {
                    let rawID = createdEntityIDs[createdIndex]
                    let ref = "scene:\(rawID)"
                    let entity = EntityID(index: UInt32(rawID & 0xFFFF_FFFF),
                                          generation: UInt32(rawID >> 32))
                    let name = scene.component(SceneNameComponent.self, for: entity)?.value ?? ""
                    let kind = scene.component(SceneKindComponent.self, for: entity)?.value
                    events.append(.entityAdded(ref: ref, name: name, kind: kind))
                    if let t = scene.localTransform(for: entity)?.translation {
                        events.append(.entityAuthoredChanged(ref: ref, property: "position",
                            value: .vec3(t.x, t.y, t.z)))
                    }
                    events.append(contentsOf: worldTransformEvents(for: rawID, in: scene))
                    createdIndex += 1
                }

            case let .moveEntity(entityID, parentID, _):
                events.append(.entityAuthoredChanged(
                    ref: "scene:\(entityID)", property: "parentRef",
                    value: .string(parentID.map { "scene:\($0)" } ?? "")))
                events.append(contentsOf: worldTransformEvents(for: entityID, in: scene))

            case let .setLocalTransform(entityID, transform):
                let t = transform.translation
                events.append(.entityAuthoredChanged(
                    ref: "scene:\(entityID)", property: "position",
                    value: .vec3(t.x, t.y, t.z)))
                let euler = extractEulerXYZDegrees(transform.matrix)
                let isZeroRot = abs(euler.x) < 0.01 && abs(euler.y) < 0.01 && abs(euler.z) < 0.01
                if !isZeroRot {
                    events.append(.entityAuthoredChanged(
                        ref: "scene:\(entityID)", property: "eulerDegrees",
                        value: .vec3(euler.x, euler.y, euler.z)))
                }
                let sc = extractScale(transform.matrix)
                let isUniform1 = abs(sc.x - 1) < 0.0001 && abs(sc.y - 1) < 0.0001 && abs(sc.z - 1) < 0.0001
                if !isUniform1 {
                    events.append(.entityAuthoredChanged(
                        ref: "scene:\(entityID)", property: "scale",
                        value: .vec3(sc.x, sc.y, sc.z)))
                }
                events.append(contentsOf: worldTransformEvents(for: entityID, in: scene))

            case let .setSceneName(entityID, value):
                events.append(.entityAuthoredChanged(
                    ref: "scene:\(entityID)", property: "name",
                    value: .string(value)))

            case let .setComponentData(entityID, typeID, _, _),
                 let .addComponent(entityID, typeID), let .removeComponentData(entityID, typeID):
                let entity = self.entityID(fromRaw: entityID)
                let dependencies = (try? scene?.componentRegistry.requiredSchemas(for: typeID)) ?? []
                for id in [typeID] + dependencies.filter({ !$0.isStructural }).map(\.typeID) {
                    let data = scene?.componentData(id, for: entity) ?? .null
                    events.append(contentsOf: WorldEvent.componentChanges(entityID: entityID, typeID: id, value: data))
                }
            }
        }

        events.append(.editApplied(editID: edit.id, summary: edit.summary,
                                   revision: edit.revisionAfter.sceneRevision ?? 0))
        return events
    }

    /// Returns evaluated WorldEvents for an entity's post-propagation world transform:
    /// worldPosition always, worldEulerDegrees when non-trivial, worldScale when non-uniform.
    private func worldTransformEvents(for entityID: UInt64, in scene: SceneRuntime?) -> [WorldEvent] {
        guard let scene else { return [] }
        let entity = EntityID(index: UInt32(entityID & 0xFFFF_FFFF),
                              generation: UInt32(entityID >> 32))
        guard let wt = scene.worldTransform(for: entity) else { return [] }
        let ref = "scene:\(entityID)"
        let t = wt.translation
        var result: [WorldEvent] = [
            .entityEvaluatedChanged(ref: ref, property: "worldPosition",
                                    value: .vec3(t.x, t.y, t.z)),
        ]
        let euler = extractEulerXYZDegrees(wt.matrix)
        if abs(euler.x) >= 0.01 || abs(euler.y) >= 0.01 || abs(euler.z) >= 0.01 {
            result.append(.entityEvaluatedChanged(ref: ref, property: "worldEulerDegrees",
                                                  value: .vec3(euler.x, euler.y, euler.z)))
        }
        let s = extractScale(wt.matrix)
        if abs(s.x - 1) >= 0.001 || abs(s.y - 1) >= 0.001 || abs(s.z - 1) >= 0.001 {
            result.append(.entityEvaluatedChanged(ref: ref, property: "worldScale",
                                                  value: .vec3(s.x, s.y, s.z)))
        }
        return result
    }

    private func extractEulerXYZDegrees(_ m: simd_float4x4) -> SIMD3<Float> {
        let sx = length(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z))
        let sy = length(SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z))
        let sz = length(SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z))
        guard sx > 0, sy > 0, sz > 0 else { return .zero }
        let r02 = m.columns.2.x / sz
        let r12 = m.columns.2.y / sz
        let r22 = m.columns.2.z / sz
        let r01 = m.columns.1.x / sy
        let r00 = m.columns.0.x / sx
        let sinBeta = Float.maximum(-1, Float.minimum(1, r02))
        let beta = asin(sinBeta)
        let toDeg: Float = 180 / .pi
        if abs(sinBeta) < 0.9999 {
            return SIMD3(atan2(-r12, r22) * toDeg, beta * toDeg, atan2(-r01, r00) * toDeg)
        } else {
            let r10 = m.columns.0.y / sx
            let r11 = m.columns.1.y / sy
            return SIMD3(atan2(r10, r11) * toDeg, beta * toDeg, 0)
        }
    }

    private func extractScale(_ m: simd_float4x4) -> SIMD3<Float> {
        SIMD3(
            length(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z)),
            length(SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z)),
            length(SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z))
        )
    }
}
