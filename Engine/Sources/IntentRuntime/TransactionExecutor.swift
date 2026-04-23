import AssetPipeline
import Foundation
import SceneRuntime
import SequenceRuntime
import simd

public struct TransactionExecutionContext {
    public var sceneRuntime: SceneRuntime?
    public var sequenceDocument: SequenceDocument?
    public var assetRegistry: AssetRegistry?

    public init(sceneRuntime: SceneRuntime? = nil,
                sequenceDocument: SequenceDocument? = nil,
                assetRegistry: AssetRegistry? = nil) {
        self.sceneRuntime = sceneRuntime
        self.sequenceDocument = sequenceDocument
        self.assetRegistry = assetRegistry
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

    public init(transactionID: String,
                changedDomains: [TransactionDomain],
                createdEntityIDs: [UInt64] = [],
                deletedEntityIDs: [UInt64] = [],
                sceneRevision: UInt64? = nil,
                sequenceRevisionID: String? = nil,
                assetEntryCount: Int? = nil) {
        self.transactionID = transactionID
        self.changedDomains = changedDomains
        self.createdEntityIDs = createdEntityIDs
        self.deletedEntityIDs = deletedEntityIDs
        self.sceneRevision = sceneRevision
        self.sequenceRevisionID = sequenceRevisionID
        self.assetEntryCount = assetEntryCount
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
        let result = try apply(transaction, to: &previewContext)
        return TransactionPreviewResult(changedDomains: result.changedDomains,
                                        createdEntityIDs: result.createdEntityIDs,
                                        deletedEntityIDs: result.deletedEntityIDs,
                                        sceneRevision: result.sceneRevision,
                                        sequenceRevisionID: result.sequenceRevisionID,
                                        assetEntryCount: result.assetEntryCount)
    }

    public func apply(_ transaction: TransactionIR,
                      to context: inout TransactionExecutionContext) throws -> TransactionApplyResult {
        try validate(transaction, against: context)

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

        return TransactionApplyResult(transactionID: transaction.id,
                                      changedDomains: changedDomains,
                                      createdEntityIDs: createdEntityIDs,
                                      deletedEntityIDs: deletedEntityIDs,
                                      sceneRevision: sceneRevision,
                                      sequenceRevisionID: sequenceRevisionID,
                                      assetEntryCount: assetEntryCount)
    }

    private func validate(_ transaction: TransactionIR,
                          against context: TransactionExecutionContext) throws {
        let domains = Set(transaction.operations.map(\ .domain))

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
            case let .spawnImportedMeshEntity(label, kindLabel, meshIndex, position):
                let entity = scene.createEntity()
                _ = scene.setComponent(SceneNameComponent(value: label), for: entity)
                _ = scene.setComponent(SceneKindComponent(value: kindLabel), for: entity)
                _ = scene.setLocalTransform(LocalTransform(translation: position), for: entity)
                _ = scene.setComponent(RenderMeshComponent(meshIndex: meshIndex), for: entity)
                createdEntityIDs.append(entity.rawValue)

            case let .deleteEntity(entityID):
                let entity = try requireEntity(entityID, in: scene)
                guard scene.destroyEntity(entity) else {
                    throw TransactionExecutorError.invalidEntity(entityID)
                }
                deletedEntityIDs.append(entityID)

            case let .duplicateEntity(entityID):
                let source = try requireEntity(entityID, in: scene)
                let entity = scene.createEntity()

                if let name = scene.component(SceneNameComponent.self, for: source) {
                    _ = scene.setComponent(SceneNameComponent(value: name.value + " Copy"), for: entity)
                }
                if let kind = scene.component(SceneKindComponent.self, for: source) {
                    _ = scene.setComponent(kind, for: entity)
                }
                if let local = scene.localTransform(for: source) {
                    _ = scene.setLocalTransform(local, for: entity)
                }
                if let parent = scene.parent(of: source) {
                    _ = scene.setParent(parent, for: entity)
                }
                if let mesh = scene.component(RenderMeshComponent.self, for: source) {
                    _ = scene.setComponent(mesh, for: entity)
                }
                if let body = scene.component(RigidBody.self, for: source) {
                    _ = scene.setComponent(body, for: entity)
                }
                if let collider = scene.component(Collider.self, for: source) {
                    _ = scene.setComponent(collider, for: entity)
                }
                if let camera = scene.component(CameraComponent.self, for: source) {
                    var copy = camera
                    copy.isActive = false
                    _ = scene.setComponent(copy, for: entity)
                }
                createdEntityIDs.append(entity.rawValue)

            case let .setLocalTransform(entityID, transform):
                let entity = try requireEntity(entityID, in: scene)
                guard scene.setLocalTransform(transform, for: entity) else {
                    throw TransactionExecutorError.invalidEntity(entityID)
                }

            case let .setSceneName(entityID, value):
                let entity = try requireEntity(entityID, in: scene)
                if scene.hasComponent(SceneNameComponent.self, for: entity) {
                    _ = scene.updateComponent(SceneNameComponent.self, for: entity) { $0.value = value }
                } else {
                    _ = scene.setComponent(SceneNameComponent(value: value), for: entity)
                }

            case let .setRigidBodyAllowSleep(entityID, value):
                let entity = try requireEntity(entityID, in: scene)
                guard scene.updateComponent(RigidBody.self, for: entity, { $0.allowSleep = value }) else {
                    throw TransactionExecutorError.missingComponent(entityID: entityID,
                                                                   type: "RigidBody")
                }

            case let .setColliderTrigger(entityID, value):
                let entity = try requireEntity(entityID, in: scene)
                guard scene.updateComponent(Collider.self, for: entity, { $0.isTrigger = value }) else {
                    throw TransactionExecutorError.missingComponent(entityID: entityID,
                                                                   type: "Collider")
                }

            case let .setConstraintEnabled(entityID, value):
                let entity = try requireEntity(entityID, in: scene)
                guard scene.updateComponent(Constraint.self, for: entity, { $0.isEnabled = value }) else {
                    throw TransactionExecutorError.missingComponent(entityID: entityID,
                                                                   type: "Constraint")
                }

            case let .setCameraPose(entityID, localTransform, target, up):
                let entity = try requireEntity(entityID, in: scene)
                guard scene.setLocalTransform(localTransform, for: entity) else {
                    throw TransactionExecutorError.invalidEntity(entityID)
                }
                guard scene.updateComponent(CameraComponent.self, for: entity, { camera in
                    camera.target = target
                    if let up {
                        camera.up = up
                    }
                }) else {
                    throw TransactionExecutorError.missingComponent(entityID: entityID,
                                                                   type: "CameraComponent")
                }
            }
        }

        scene.propagateTransforms()
        _ = transaction
    }

    private func requireEntity(_ rawID: UInt64,
                               in scene: SceneRuntime) throws -> EntityID {
        let entity = EntityID(index: UInt32(rawID & 0xFFFF_FFFF),
                              generation: UInt32(rawID >> 32))
        guard scene.contains(entity) else {
            throw TransactionExecutorError.invalidEntity(rawID)
        }
        return entity
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
}