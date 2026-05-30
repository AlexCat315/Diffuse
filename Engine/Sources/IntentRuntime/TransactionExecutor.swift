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
        self.sceneRuntime = sceneRuntime
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
                                        assetEntryCount: result.assetEntryCount)
    }

    public func apply(_ transaction: TransactionIR,
                      to context: inout TransactionExecutionContext) throws -> TransactionApplyResult {
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
            try publishSuccessEvents(for: transaction,
                                     result: result,
                                     sceneOps: sceneOps,
                                     sequenceDocument: context.sequenceDocument,
                                     context: context)
            return result
        } catch {
            try? publishFailureEvent(for: transaction, error: error, context: context)
            throw error
        }
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
                _ = scene.setLocalTransform(LocalTransform(translation: position), for: entity)
                var light = LightComponent(type: lightType)
                if let v = initialIntensity    { light.intensity    = v }
                if let v = initialColor        { light.color        = v }
                if let v = initialRange        { light.range        = v }
                if let v = initialCastShadows  { light.castShadows  = v }
                _ = scene.setComponent(light, for: entity)
                if let pid = parentID { _ = scene.setParent(EntityID(index: UInt32(pid & 0xFFFF_FFFF), generation: UInt32(pid >> 32)), for: entity) }
                createdEntityIDs.append(entity.rawValue)

            case let .spawnCameraEntity(label, position, initialFovYDegrees, parentID):
                let entity = scene.createEntity()
                _ = scene.setComponent(SceneNameComponent(value: label), for: entity)
                _ = scene.setComponent(SceneKindComponent(value: "Camera"), for: entity)
                _ = scene.setLocalTransform(LocalTransform(translation: position), for: entity)
                var cam = CameraComponent(isActive: false)
                if let fov = initialFovYDegrees { cam.fovYRadians = fov * .pi / 180 }
                _ = scene.setComponent(cam, for: entity)
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
                if let asset = scene.component(AssetReferenceComponent.self, for: source) {
                    _ = scene.setComponent(asset, for: entity)
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
                if let light = scene.component(LightComponent.self, for: source) {
                    _ = scene.setComponent(light, for: entity)
                }
                if let scripts = scene.component(ScriptComponent.self, for: source) {
                    _ = scene.setComponent(scripts, for: entity)
                }
                if let player = scene.component(AnimationPlayer.self, for: source) {
                    _ = scene.setComponent(player, for: entity)
                }
                createdEntityIDs.append(entity.rawValue)

            case let .duplicateEntityWithOffset(entityID, offset):
                let source = try requireEntity(entityID, in: scene)
                let entity = scene.createEntity()
                if let name = scene.component(SceneNameComponent.self, for: source) {
                    _ = scene.setComponent(SceneNameComponent(value: name.value + " Copy"), for: entity)
                }
                if let kind = scene.component(SceneKindComponent.self, for: source) {
                    _ = scene.setComponent(kind, for: entity)
                }
                var transform = scene.localTransform(for: source) ?? LocalTransform()
                transform.matrix.columns.3 += SIMD4<Float>(offset, 0)
                _ = scene.setLocalTransform(transform, for: entity)
                if let parent = scene.parent(of: source) {
                    _ = scene.setParent(parent, for: entity)
                }
                if let mesh = scene.component(RenderMeshComponent.self, for: source) {
                    _ = scene.setComponent(mesh, for: entity)
                }
                if let asset = scene.component(AssetReferenceComponent.self, for: source) {
                    _ = scene.setComponent(asset, for: entity)
                }
                if let body = scene.component(RigidBody.self, for: source) {
                    _ = scene.setComponent(body, for: entity)
                }
                if let collider = scene.component(Collider.self, for: source) {
                    _ = scene.setComponent(collider, for: entity)
                }
                if let camera = scene.component(CameraComponent.self, for: source) {
                    var copy = camera; copy.isActive = false
                    _ = scene.setComponent(copy, for: entity)
                }
                if let light = scene.component(LightComponent.self, for: source) {
                    _ = scene.setComponent(light, for: entity)
                }
                if let scripts = scene.component(ScriptComponent.self, for: source) {
                    _ = scene.setComponent(scripts, for: entity)
                }
                if let player = scene.component(AnimationPlayer.self, for: source) {
                    _ = scene.setComponent(player, for: entity)
                }
                createdEntityIDs.append(entity.rawValue)

            case let .moveEntity(entityID, parentID, index):
                let entity = try requireEntity(entityID, in: scene)
                let parent = try requireOptionalEntity(parentID, in: scene)
                guard scene.moveEntity(entity, to: parent, at: index) else {
                    throw TransactionExecutorError.invalidEntity(entityID)
                }

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

            case let .setRigidBodyMotionType(entityID, value):
                let entity = try requireEntity(entityID, in: scene)
                guard scene.updateComponent(RigidBody.self, for: entity, { $0.motionType = value }) else {
                    throw TransactionExecutorError.missingComponent(entityID: entityID,
                                                                   type: "RigidBody")
                }

            case let .setRigidBodyMass(entityID, value):
                let entity = try requireEntity(entityID, in: scene)
                guard scene.updateComponent(RigidBody.self, for: entity, { $0.mass = max(0, value) }) else {
                    throw TransactionExecutorError.missingComponent(entityID: entityID,
                                                                   type: "RigidBody")
                }

            case let .setRigidBodyGravityScale(entityID, value):
                let entity = try requireEntity(entityID, in: scene)
                guard scene.updateComponent(RigidBody.self, for: entity, { $0.gravityScale = value }) else {
                    throw TransactionExecutorError.missingComponent(entityID: entityID,
                                                                   type: "RigidBody")
                }

            case let .setRigidBodyAllowSleep(entityID, value):
                let entity = try requireEntity(entityID, in: scene)
                guard scene.updateComponent(RigidBody.self, for: entity, { $0.allowSleep = value }) else {
                    throw TransactionExecutorError.missingComponent(entityID: entityID,
                                                                   type: "RigidBody")
                }

            case let .setRigidBody(entityID, body):
                let entity = try requireEntity(entityID, in: scene)
                _ = scene.setComponent(body, for: entity)

            case let .setCollider(entityID, collider):
                let entity = try requireEntity(entityID, in: scene)
                guard scene.setComponent(collider, for: entity) else {
                    throw TransactionExecutorError.invalidEntity(entityID)
                }

            case let .setColliderTrigger(entityID, value):
                let entity = try requireEntity(entityID, in: scene)
                guard scene.updateComponent(Collider.self, for: entity, { $0.isTrigger = value }) else {
                    throw TransactionExecutorError.missingComponent(entityID: entityID,
                                                                   type: "Collider")
                }

            case let .setColliderShapeType(entityID, kind):
                let entity = try requireEntity(entityID, in: scene)
                guard let collider = scene.component(Collider.self, for: entity) else {
                    throw TransactionExecutorError.missingComponent(entityID: entityID,
                                                                   type: "Collider")
                }
                let center = collider.shape.center
                let newShape: ColliderShape
                switch kind {
                case .box:
                    newShape = .box(halfExtents: SIMD3<Float>(0.5, 0.5, 0.5), center: center)
                case .sphere:
                    newShape = .sphere(radius: 0.5, center: center)
                case .capsule:
                    newShape = .capsule(radius: 0.5, halfHeight: 0.5, center: center)
                case .mesh:
                    newShape = .mesh(resourceID: nil, center: center)
                case .convex:
                    newShape = .convex(resourceID: nil, center: center)
                }
                guard scene.updateComponent(Collider.self, for: entity, { $0.shape = newShape }) else {
                    throw TransactionExecutorError.invalidEntity(entityID)
                }

            case let .setColliderShapeBoxHalfExtents(entityID, halfExtents):
                let entity = try requireEntity(entityID, in: scene)
                guard scene.component(Collider.self, for: entity) != nil else {
                    throw TransactionExecutorError.missingComponent(entityID: entityID,
                                                                   type: "Collider")
                }
                guard scene.updateComponent(Collider.self, for: entity, {
                    if case .box(_, let center) = $0.shape {
                        $0.shape = .box(halfExtents: halfExtents, center: center)
                    }
                }) else {
                    throw TransactionExecutorError.invalidEntity(entityID)
                }

            case let .setColliderShapeSphereRadius(entityID, radius):
                let entity = try requireEntity(entityID, in: scene)
                guard scene.component(Collider.self, for: entity) != nil else {
                    throw TransactionExecutorError.missingComponent(entityID: entityID,
                                                                   type: "Collider")
                }
                guard scene.updateComponent(Collider.self, for: entity, {
                    if case .sphere(_, let center) = $0.shape {
                        $0.shape = .sphere(radius: radius, center: center)
                    }
                }) else {
                    throw TransactionExecutorError.invalidEntity(entityID)
                }

            case let .setColliderShapeCapsuleRadius(entityID, radius):
                let entity = try requireEntity(entityID, in: scene)
                guard scene.component(Collider.self, for: entity) != nil else {
                    throw TransactionExecutorError.missingComponent(entityID: entityID,
                                                                   type: "Collider")
                }
                guard scene.updateComponent(Collider.self, for: entity, {
                    if case .capsule(_, let halfHeight, let center) = $0.shape {
                        $0.shape = .capsule(radius: radius, halfHeight: halfHeight, center: center)
                    }
                }) else {
                    throw TransactionExecutorError.invalidEntity(entityID)
                }

            case let .setColliderShapeCapsuleHalfHeight(entityID, halfHeight):
                let entity = try requireEntity(entityID, in: scene)
                guard scene.component(Collider.self, for: entity) != nil else {
                    throw TransactionExecutorError.missingComponent(entityID: entityID,
                                                                   type: "Collider")
                }
                guard scene.updateComponent(Collider.self, for: entity, {
                    if case .capsule(let radius, _, let center) = $0.shape {
                        $0.shape = .capsule(radius: radius, halfHeight: halfHeight, center: center)
                    }
                }) else {
                    throw TransactionExecutorError.invalidEntity(entityID)
                }

            case let .setColliderMaterialFriction(entityID, value):
                let entity = try requireEntity(entityID, in: scene)
                guard scene.updateComponent(Collider.self, for: entity, {
                    $0.material.friction = max(0, value)
                }) else {
                    throw TransactionExecutorError.missingComponent(entityID: entityID,
                                                                   type: "Collider")
                }

            case let .setColliderMaterialRestitution(entityID, value):
                let entity = try requireEntity(entityID, in: scene)
                guard scene.updateComponent(Collider.self, for: entity, {
                    $0.material.restitution = max(0, min(value, 1))
                }) else {
                    throw TransactionExecutorError.missingComponent(entityID: entityID,
                                                                   type: "Collider")
                }

            case let .setColliderMaterialDensity(entityID, value):
                let entity = try requireEntity(entityID, in: scene)
                guard scene.updateComponent(Collider.self, for: entity, {
                    $0.material.density = max(0, value)
                }) else {
                    throw TransactionExecutorError.missingComponent(entityID: entityID,
                                                                   type: "Collider")
                }

            case let .setColliderLayer(entityID, layerID):
                let entity = try requireEntity(entityID, in: scene)
                guard scene.updateComponent(Collider.self, for: entity, {
                    $0.layerID = layerID
                }) else {
                    throw TransactionExecutorError.missingComponent(entityID: entityID,
                                                                   type: "Collider")
                }

            case let .setColliderLayerMask(entityID, layerMask):
                let entity = try requireEntity(entityID, in: scene)
                guard scene.updateComponent(Collider.self, for: entity, {
                    $0.layerMask = layerMask
                }) else {
                    throw TransactionExecutorError.missingComponent(entityID: entityID,
                                                                   type: "Collider")
                }

            case let .setConstraintEnabled(entityID, value):
                let entity = try requireEntity(entityID, in: scene)
                guard scene.updateComponent(Constraint.self, for: entity, { $0.isEnabled = value }) else {
                    throw TransactionExecutorError.missingComponent(entityID: entityID,
                                                                   type: "Constraint")
                }

            case let .setLightType(entityID, type):
                let entity = try requireEntity(entityID, in: scene)
                guard scene.updateComponent(LightComponent.self, for: entity, { $0.type = type }) else {
                    throw TransactionExecutorError.missingComponent(entityID: entityID,
                                                                   type: "LightComponent")
                }

            case let .setLightColor(entityID, color):
                let entity = try requireEntity(entityID, in: scene)
                guard scene.updateComponent(LightComponent.self, for: entity, { $0.color = color }) else {
                    throw TransactionExecutorError.missingComponent(entityID: entityID,
                                                                   type: "LightComponent")
                }

            case let .setLightIntensity(entityID, intensity):
                let entity = try requireEntity(entityID, in: scene)
                guard scene.updateComponent(LightComponent.self, for: entity, {
                    $0.intensity = max(0, intensity)
                }) else {
                    throw TransactionExecutorError.missingComponent(entityID: entityID,
                                                                   type: "LightComponent")
                }

            case let .setLightRange(entityID, range):
                let entity = try requireEntity(entityID, in: scene)
                guard scene.updateComponent(LightComponent.self, for: entity, {
                    $0.range = max(0, range)
                }) else {
                    throw TransactionExecutorError.missingComponent(entityID: entityID,
                                                                   type: "LightComponent")
                }

            case let .setLightSpotInnerAngle(entityID, angleDegrees):
                let entity = try requireEntity(entityID, in: scene)
                guard scene.updateComponent(LightComponent.self, for: entity, {
                    let inner = max(0, min(179, angleDegrees))
                    $0.spotInnerAngleDegrees = min(inner, $0.spotOuterAngleDegrees)
                }) else {
                    throw TransactionExecutorError.missingComponent(entityID: entityID,
                                                                   type: "LightComponent")
                }

            case let .setLightSpotOuterAngle(entityID, angleDegrees):
                let entity = try requireEntity(entityID, in: scene)
                guard scene.updateComponent(LightComponent.self, for: entity, {
                    let outer = max(1, min(179, angleDegrees))
                    $0.spotOuterAngleDegrees = outer
                    $0.spotInnerAngleDegrees = min($0.spotInnerAngleDegrees, outer)
                }) else {
                    throw TransactionExecutorError.missingComponent(entityID: entityID,
                                                                   type: "LightComponent")
                }

            case let .setLightCastShadows(entityID, value):
                let entity = try requireEntity(entityID, in: scene)
                guard scene.updateComponent(LightComponent.self, for: entity, {
                    $0.castShadows = value
                }) else {
                    throw TransactionExecutorError.missingComponent(entityID: entityID,
                                                                   type: "LightComponent")
                }

            case let .setMeshColorTint(entityID, color):
                let entity = try requireEntity(entityID, in: scene)
                guard scene.updateComponent(RenderMeshComponent.self, for: entity, {
                    $0.colorTint = SIMD3(max(0, color.x), max(0, color.y), max(0, color.z))
                }) else {
                    throw TransactionExecutorError.missingComponent(entityID: entityID,
                                                                   type: "RenderMeshComponent")
                }

            case let .setRenderMeshVisibility(entityID, isVisible):
                let entity = try requireEntity(entityID, in: scene)
                guard scene.updateComponent(RenderMeshComponent.self, for: entity, {
                    $0.isVisible = isVisible
                }) else {
                    throw TransactionExecutorError.missingComponent(entityID: entityID,
                                                                   type: "RenderMeshComponent")
                }

            case let .setRenderMaterialComponent(entityID, baseColorFactor, metallicFactor, roughnessFactor, emissiveFactor):
                let entity = try requireEntity(entityID, in: scene)
                let component = RenderMaterialComponent(
                    baseColorFactor: baseColorFactor,
                    metallicFactor: metallicFactor,
                    roughnessFactor: roughnessFactor,
                    emissiveFactor: emissiveFactor
                )
                _ = scene.setComponent(component, for: entity)

            case let .setScriptBindings(entityID, bindings):
                let entity = try requireEntity(entityID, in: scene)
                _ = scene.setComponent(ScriptComponent(bindings: bindings), for: entity)

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

            case let .setCameraFOV(entityID, fovYDegrees):
                let entity = try requireEntity(entityID, in: scene)
                guard scene.updateComponent(CameraComponent.self, for: entity, { camera in
                    camera.fovYRadians = fovYDegrees * .pi / 180.0
                }) else {
                    throw TransactionExecutorError.missingComponent(entityID: entityID,
                                                                   type: "CameraComponent")
                }

            case let .setCameraActive(entityID, isActive):
                let entity = try requireEntity(entityID, in: scene)
                guard scene.updateComponent(CameraComponent.self, for: entity, { camera in
                    camera.isActive = isActive
                }) else {
                    throw TransactionExecutorError.missingComponent(entityID: entityID,
                                                                   type: "CameraComponent")
                }

            case let .setAudioSource(entityID, source):
                let entity = try requireEntity(entityID, in: scene)
                _ = scene.setComponent(source, for: entity)

            case let .setAnimationPlayer(entityID, clipName, speed, loop, isPlaying):
                let entity = try requireEntity(entityID, in: scene)
                _ = scene.setComponent(
                    AnimationPlayer(clipName: clipName, speed: speed,
                                    loop: loop, isPlaying: isPlaying),
                    for: entity)

            case let .setAudioListener(entityID, masterVolume):
                let entity = try requireEntity(entityID, in: scene)
                _ = scene.setComponent(AudioListener(masterVolume: masterVolume), for: entity)

            case let .setParticleEmitter(entityID, emitter):
                let entity = try requireEntity(entityID, in: scene)
                _ = scene.setComponent(emitter, for: entity)
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
        case let .setRigidBodyMotionType(id, _):
            return "scene:rigidbody_motion:\(id)"
        case let .setRigidBodyMass(id, _):
            return "scene:rigidbody_mass:\(id)"
        case let .setRigidBodyGravityScale(id, _):
            return "scene:rigidbody_gravity:\(id)"
        case let .setRigidBodyAllowSleep(id, _):
            return "scene:rigidbody_sleep:\(id)"
        case let .setRigidBody(id, _):
            return "scene:rigidbody_full:\(id)"
        case let .setCollider(id, _):
            return "scene:collider_set:\(id)"
        case let .setColliderTrigger(id, _):
            return "scene:collider_trigger:\(id)"
        case let .setColliderShapeType(id, _):
            return "scene:collider_shape:\(id)"
        case let .setColliderShapeBoxHalfExtents(id, _):
            return "scene:collider_box:\(id)"
        case let .setColliderShapeSphereRadius(id, _):
            return "scene:collider_sphere:\(id)"
        case let .setColliderShapeCapsuleRadius(id, _):
            return "scene:collider_capsule_r:\(id)"
        case let .setColliderShapeCapsuleHalfHeight(id, _):
            return "scene:collider_capsule_h:\(id)"
        case let .setColliderMaterialFriction(id, _):
            return "scene:collider_friction:\(id)"
        case let .setColliderMaterialRestitution(id, _):
            return "scene:collider_restitution:\(id)"
        case let .setColliderMaterialDensity(id, _):
            return "scene:collider_density:\(id)"
        case let .setColliderLayer(id, _):
            return "scene:collider_layer:\(id)"
        case let .setColliderLayerMask(id, _):
            return "scene:collider_mask:\(id)"
        case let .setConstraintEnabled(id, _):
            return "scene:constraint:\(id)"
        case let .setLightType(id, _):
            return "scene:light_type:\(id)"
        case let .setLightColor(id, _):
            return "scene:light_color:\(id)"
        case let .setLightIntensity(id, _):
            return "scene:light_intensity:\(id)"
        case let .setLightRange(id, _):
            return "scene:light_range:\(id)"
        case let .setLightSpotInnerAngle(id, _):
            return "scene:light_spot_inner:\(id)"
        case let .setLightSpotOuterAngle(id, _):
            return "scene:light_spot_outer:\(id)"
        case let .setLightCastShadows(id, _):
            return "scene:light_cast_shadows:\(id)"
        case let .setMeshColorTint(id, _):
            return "scene:mesh_color:\(id)"
        case let .setRenderMeshVisibility(id, _):
            return "scene:mesh_visibility:\(id)"
        case let .setRenderMaterialComponent(id, _, _, _, _):
            return "scene:render_material:\(id)"
        case let .setScriptBindings(id, _):
            return "scene:scripts:\(id)"
        case let .setCameraPose(id, _, _, _):
            return "scene:camera_pose:\(id)"
        case let .setCameraFOV(id, _):
            return "scene:camera_fov:\(id)"
        case let .setCameraActive(id, _):
            return "scene:camera_active:\(id)"
        case let .setAudioSource(id, _):
            return "scene:audio_source:\(id)"
        case let .setAnimationPlayer(id, _, _, _, _):
            return "scene:animation_player:\(id)"
        case let .setAudioListener(id, _):
            return "scene:audio_listener:\(id)"
        case let .setParticleEmitter(id, _):
            return "scene:particle_emitter:\(id)"
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

            case let .spawnLightEntity(label, lightType, position, initialIntensity, initialColor, initialRange, initialCastShadows, parentID):
                if createdIndex < createdEntityIDs.count {
                    let rawID = createdEntityIDs[createdIndex]
                    let ref = "scene:\(rawID)"
                    events.append(.entityAdded(ref: ref, name: label, kind: "Light"))
                    events.append(.entityAuthoredChanged(ref: ref, property: "position",
                        value: .vec3(position.x, position.y, position.z)))
                    events.append(.entityAuthoredChanged(ref: ref, property: "lightType",
                        value: .string(lightType.rawValue)))
                    if let v = initialIntensity {
                        events.append(.entityAuthoredChanged(ref: ref, property: "lightIntensity", value: .float(v)))
                    }
                    if let v = initialColor {
                        events.append(.entityAuthoredChanged(ref: ref, property: "lightColor",
                            value: .vec3(v.x, v.y, v.z)))
                    }
                    if let v = initialRange {
                        events.append(.entityAuthoredChanged(ref: ref, property: "lightRange", value: .float(v)))
                    }
                    if let v = initialCastShadows {
                        events.append(.entityAuthoredChanged(ref: ref, property: "lightCastShadows", value: .bool(v)))
                    }
                    if let pid = parentID {
                        events.append(.entityAuthoredChanged(ref: ref, property: "parentRef",
                            value: .string("scene:\(pid)")))
                    }
                    events.append(contentsOf: worldTransformEvents(for: rawID, in: scene))
                    createdIndex += 1
                }

            case let .spawnCameraEntity(label, position, initialFovYDegrees, parentID):
                if createdIndex < createdEntityIDs.count {
                    let rawID = createdEntityIDs[createdIndex]
                    let ref = "scene:\(rawID)"
                    events.append(.entityAdded(ref: ref, name: label, kind: "Camera"))
                    events.append(.entityAuthoredChanged(ref: ref, property: "position",
                        value: .vec3(position.x, position.y, position.z)))
                    if let fov = initialFovYDegrees {
                        events.append(.entityAuthoredChanged(ref: ref, property: "cameraFovYDegrees", value: .float(fov)))
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

            case let .setRigidBodyMotionType(entityID, value):
                events.append(.entityAuthoredChanged(
                    ref: "scene:\(entityID)", property: "rigidBodyMotionType",
                    value: .string(value.rawValue)))

            case let .setMeshColorTint(entityID, color):
                events.append(.entityAuthoredChanged(
                    ref: "scene:\(entityID)", property: "meshColor",
                    value: .vec3(color.x, color.y, color.z)))

            case let .setRenderMeshVisibility(entityID, isVisible):
                events.append(.entityAuthoredChanged(
                    ref: "scene:\(entityID)", property: "meshIsVisible",
                    value: .bool(isVisible)))

            case let .setRenderMaterialComponent(entityID, baseColorFactor, metallicFactor, roughnessFactor, emissiveFactor):
                let ref = "scene:\(entityID)"
                events.append(.entityAuthoredChanged(ref: ref, property: "materialBaseColor",
                    value: .vec4(baseColorFactor.x, baseColorFactor.y, baseColorFactor.z, baseColorFactor.w)))
                events.append(.entityAuthoredChanged(ref: ref, property: "materialMetallic",
                    value: .float(metallicFactor)))
                events.append(.entityAuthoredChanged(ref: ref, property: "materialRoughness",
                    value: .float(roughnessFactor)))
                events.append(.entityAuthoredChanged(ref: ref, property: "materialEmissive",
                    value: .vec3(emissiveFactor.x, emissiveFactor.y, emissiveFactor.z)))

            case let .setLightType(entityID, type):
                events.append(.entityAuthoredChanged(
                    ref: "scene:\(entityID)", property: "lightType",
                    value: .string(type.rawValue)))

            case let .setLightColor(entityID, color):
                events.append(.entityAuthoredChanged(
                    ref: "scene:\(entityID)", property: "lightColor",
                    value: .vec3(color.x, color.y, color.z)))

            case let .setLightIntensity(entityID, intensity):
                events.append(.entityAuthoredChanged(
                    ref: "scene:\(entityID)", property: "lightIntensity",
                    value: .float(max(0, intensity))))

            case let .setLightRange(entityID, range):
                events.append(.entityAuthoredChanged(
                    ref: "scene:\(entityID)", property: "lightRange",
                    value: .float(max(0, range))))

            case let .setLightSpotInnerAngle(entityID, angle):
                events.append(.entityAuthoredChanged(
                    ref: "scene:\(entityID)", property: "lightSpotInner",
                    value: .float(max(0, min(179, angle)))))

            case let .setLightSpotOuterAngle(entityID, angle):
                events.append(.entityAuthoredChanged(
                    ref: "scene:\(entityID)", property: "lightSpotOuter",
                    value: .float(max(1, min(179, angle)))))

            case let .setLightCastShadows(entityID, value):
                events.append(.entityAuthoredChanged(
                    ref: "scene:\(entityID)", property: "lightCastShadows",
                    value: .bool(value)))

            case let .setCameraPose(entityID, localTransform, _, _):
                let t = localTransform.translation
                events.append(.entityAuthoredChanged(
                    ref: "scene:\(entityID)", property: "position",
                    value: .vec3(t.x, t.y, t.z)))
                events.append(contentsOf: worldTransformEvents(for: entityID, in: scene))

            case let .setCameraFOV(entityID, fovYDegrees):
                events.append(.entityAuthoredChanged(
                    ref: "scene:\(entityID)", property: "cameraFovYDegrees",
                    value: .float(max(1, min(179, fovYDegrees)))))

            case let .setCameraActive(entityID, isActive):
                events.append(.entityAuthoredChanged(
                    ref: "scene:\(entityID)", property: "cameraIsActive",
                    value: .bool(isActive)))

            case let .setRigidBodyMass(entityID, mass):
                events.append(.entityAuthoredChanged(
                    ref: "scene:\(entityID)", property: "rigidBodyMass",
                    value: .float(max(0, mass))))

            case let .setRigidBodyGravityScale(entityID, scale):
                events.append(.entityAuthoredChanged(
                    ref: "scene:\(entityID)", property: "rigidBodyGravityScale",
                    value: .float(scale)))

            case let .setRigidBodyAllowSleep(entityID, allow):
                events.append(.entityAuthoredChanged(
                    ref: "scene:\(entityID)", property: "rigidBodyAllowSleep",
                    value: .bool(allow)))

            case let .setRigidBody(entityID, body):
                let ref = "scene:\(entityID)"
                events.append(.entityAuthoredChanged(ref: ref, property: "rigidBodyMotionType",
                    value: .string(body.motionType.rawValue)))
                events.append(.entityAuthoredChanged(ref: ref, property: "rigidBodyMass",
                    value: .float(body.mass)))
                events.append(.entityAuthoredChanged(ref: ref, property: "rigidBodyGravityScale",
                    value: .float(body.gravityScale)))
                events.append(.entityAuthoredChanged(ref: ref, property: "rigidBodyAllowSleep",
                    value: .bool(body.allowSleep)))

            case let .setColliderShapeType(entityID, kind):
                events.append(.entityAuthoredChanged(
                    ref: "scene:\(entityID)", property: "colliderShape",
                    value: .string(kind.rawValue)))

            case let .setColliderTrigger(entityID, isTrigger):
                events.append(.entityAuthoredChanged(
                    ref: "scene:\(entityID)", property: "colliderIsTrigger",
                    value: .bool(isTrigger)))

            case let .setColliderMaterialFriction(entityID, friction):
                events.append(.entityAuthoredChanged(ref: "scene:\(entityID)",
                    property: "colliderFriction", value: .float(max(0, friction))))

            case let .setColliderMaterialRestitution(entityID, restitution):
                events.append(.entityAuthoredChanged(ref: "scene:\(entityID)",
                    property: "colliderRestitution", value: .float(max(0, restitution))))

            case let .setColliderMaterialDensity(entityID, density):
                events.append(.entityAuthoredChanged(ref: "scene:\(entityID)",
                    property: "colliderDensity", value: .float(max(0, density))))

            case let .setColliderLayer(entityID, layerID):
                events.append(.entityAuthoredChanged(ref: "scene:\(entityID)",
                    property: "colliderLayerID", value: .float(Float(layerID))))

            case let .setColliderLayerMask(entityID, layerMask):
                events.append(.entityAuthoredChanged(ref: "scene:\(entityID)",
                    property: "colliderLayerMask", value: .float(Float(layerMask))))

            case let .setAudioSource(entityID, source):
                let ref = "scene:\(entityID)"
                if !source.clipName.isEmpty {
                    events.append(.entityAuthoredChanged(ref: ref, property: "audioClip",
                        value: .string(source.clipName)))
                }
                events.append(.entityAuthoredChanged(ref: ref, property: "audioVolume",
                    value: .float(source.volume)))
                events.append(.entityAuthoredChanged(ref: ref, property: "audioLoop",
                    value: .bool(source.loop)))
                events.append(.entityAuthoredChanged(ref: ref, property: "audioPlayOnAwake",
                    value: .bool(source.playOnAwake)))

            case let .setAnimationPlayer(entityID, clipName, speed, loop, isPlaying):
                let ref = "scene:\(entityID)"
                if let clip = clipName, !clip.isEmpty {
                    events.append(.entityAuthoredChanged(ref: ref, property: "animationClip",
                        value: .string(clip)))
                }
                events.append(.entityAuthoredChanged(ref: ref, property: "animationSpeed",
                    value: .float(speed)))
                events.append(.entityAuthoredChanged(ref: ref, property: "animationLoop",
                    value: .bool(loop)))
                events.append(.entityAuthoredChanged(ref: ref, property: "animationIsPlaying",
                    value: .bool(isPlaying)))

            case let .setAudioListener(entityID, masterVolume):
                events.append(.entityAuthoredChanged(ref: "scene:\(entityID)",
                    property: "audioListenerMasterVolume", value: .float(masterVolume)))

            case let .setParticleEmitter(entityID, emitter):
                let ref = "scene:\(entityID)"
                events.append(.entityAuthoredChanged(ref: ref, property: "particleEmissionRate",
                    value: .float(emitter.emissionRate)))
                events.append(.entityAuthoredChanged(ref: ref, property: "particleMaxParticles",
                    value: .float(Float(emitter.maxParticles))))
                events.append(.entityAuthoredChanged(ref: ref, property: "particleEmitting",
                    value: .bool(emitter.isEmitting)))

            case let .setConstraintEnabled(entityID, value):
                events.append(.entityAuthoredChanged(
                    ref: "scene:\(entityID)", property: "constraintEnabled",
                    value: .bool(value)))

            case let .setCollider(entityID, collider):
                let ref = "scene:\(entityID)"
                events.append(.entityAuthoredChanged(ref: ref, property: "colliderShape",
                    value: .string(collider.shape.kind.rawValue)))
                switch collider.shape {
                case let .box(he, _):
                    events.append(.entityAuthoredChanged(ref: ref, property: "colliderBoxHalfExtents",
                        value: .vec3(he.x, he.y, he.z)))
                case let .sphere(r, _):
                    events.append(.entityAuthoredChanged(ref: ref, property: "colliderSphereRadius",
                        value: .float(r)))
                case let .capsule(r, hh, _):
                    events.append(.entityAuthoredChanged(ref: ref, property: "colliderCapsuleRadius",
                        value: .float(r)))
                    events.append(.entityAuthoredChanged(ref: ref, property: "colliderCapsuleHalfHeight",
                        value: .float(hh)))
                default:
                    break
                }
                events.append(.entityAuthoredChanged(ref: ref, property: "colliderIsTrigger",
                    value: .bool(collider.isTrigger)))
                events.append(.entityAuthoredChanged(ref: ref, property: "colliderFriction",
                    value: .float(collider.material.friction)))
                events.append(.entityAuthoredChanged(ref: ref, property: "colliderRestitution",
                    value: .float(collider.material.restitution)))
                events.append(.entityAuthoredChanged(ref: ref, property: "colliderDensity",
                    value: .float(collider.material.density)))
                events.append(.entityAuthoredChanged(ref: ref, property: "colliderLayerID",
                    value: .float(Float(collider.layerID))))
                events.append(.entityAuthoredChanged(ref: ref, property: "colliderLayerMask",
                    value: .float(Float(collider.layerMask))))

            case let .setScriptBindings(entityID, bindings):
                let ref = "scene:\(entityID)"
                let records = bindings.map { b -> [String: Any] in
                    ["handle": b.script.rawValue,
                     "isEnabled": b.isEnabled,
                     "parametersJSON": b.parametersJSON]
                }
                if let data = try? JSONSerialization.data(withJSONObject: records),
                   let json = String(data: data, encoding: .utf8) {
                    events.append(.entityAuthoredChanged(ref: ref, property: "scriptBindings",
                        value: .string(json)))
                }

            default:
                break
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
