import AssetPipeline
import Foundation
import CapabilityRuntime
import SceneRuntime
import SequenceRuntime
import ScriptRuntime
import SIMDCompat

public enum TransactionDomain: String, Sendable, Equatable {
    case scene
    case sequence
    case asset
}

public enum TransactionApprovalPolicy: String, Sendable, Equatable {
    case automatic
    case requiresApproval
    case forbidden
}

public enum TransactionProvenance: String, Sendable, Equatable {
    case authored
    case inferred
    case proposal
    case baked
}

public struct TransactionBaseRevisions: Sendable, Equatable {
    public var sceneRevision: UInt64?
    public var sequenceRevisionID: String?
    public var assetRevisionID: String?

    public init(sceneRevision: UInt64? = nil,
                sequenceRevisionID: String? = nil,
                assetRevisionID: String? = nil) {
        self.sceneRevision = sceneRevision
        self.sequenceRevisionID = sequenceRevisionID
        self.assetRevisionID = assetRevisionID
    }
}

public struct TransactionPreviewResult: Sendable, Equatable {
    public var changedDomains: [TransactionDomain]
    public var createdEntityIDs: [UInt64]
    public var deletedEntityIDs: [UInt64]
    public var sceneRevision: UInt64?
    public var sequenceRevisionID: String?
    public var assetEntryCount: Int?
    public var mutationSummaries: [String]

    public init(changedDomains: [TransactionDomain],
                createdEntityIDs: [UInt64] = [],
                deletedEntityIDs: [UInt64] = [],
                sceneRevision: UInt64? = nil,
                sequenceRevisionID: String? = nil,
                assetEntryCount: Int? = nil,
                mutationSummaries: [String] = []) {
        self.changedDomains = changedDomains
        self.createdEntityIDs = createdEntityIDs
        self.deletedEntityIDs = deletedEntityIDs
        self.sceneRevision = sceneRevision
        self.sequenceRevisionID = sequenceRevisionID
        self.assetEntryCount = assetEntryCount
        self.mutationSummaries = mutationSummaries
    }
}

public enum SceneMutation: Sendable, Equatable {
    case spawnImportedMeshEntity(label: String,
                                 kindLabel: String,
                                 meshIndex: Int,
                                 position: SIMD3<Float>,
                                 parentID: UInt64? = nil)
    case spawnEmptyEntity(label: String, position: SIMD3<Float>, parentID: UInt64? = nil)
    case spawnLightEntity(label: String, lightType: LightType, position: SIMD3<Float>,
                          initialIntensity: Float? = nil,
                          initialColor: SIMD3<Float>? = nil,
                          initialRange: Float? = nil,
                          initialCastShadows: Bool? = nil,
                          parentID: UInt64? = nil)
    case spawnCameraEntity(label: String, position: SIMD3<Float>, initialFovYDegrees: Float? = nil,
                           parentID: UInt64? = nil)
    case deleteEntity(entityID: UInt64)
    case duplicateEntity(entityID: UInt64)
    /// Duplicate an entity and immediately apply a world-space position offset to the copy.
    /// The offset is applied in the same local space as the source (parent-relative).
    case duplicateEntityWithOffset(entityID: UInt64, positionOffset: SIMD3<Float>)
    case moveEntity(entityID: UInt64, parentID: UInt64?, index: Int)
    case setLocalTransform(entityID: UInt64, transform: LocalTransform)
    case setSceneName(entityID: UInt64, value: String)
    /// Replace a complete component document, or merge field edits into its current document.
    case setComponentData(entityID: UInt64, typeID: String, value: ComponentValue,
                          mode: ComponentWriteMode = .replace)
    case addComponent(entityID: UInt64, typeID: String)
    case removeComponentData(entityID: UInt64, typeID: String)

    public var entityID: UInt64? {
        switch self {
        case .spawnImportedMeshEntity, .spawnEmptyEntity, .spawnLightEntity, .spawnCameraEntity:
            nil
        case let .deleteEntity(id), let .duplicateEntity(id), let .duplicateEntityWithOffset(id, _),
             let .moveEntity(id, _, _), let .setLocalTransform(id, _), let .setSceneName(id, _),
             let .setComponentData(id, _, _, _), let .addComponent(id, _), let .removeComponentData(id, _):
            id
        }
    }

    public var componentKey: SceneComponentKey? {
        switch self {
        case let .setComponentData(id, typeID, _, _), let .addComponent(id, typeID),
             let .removeComponentData(id, typeID):
            SceneComponentKey(entityID: id, typeID: typeID)
        default: nil
        }
    }

}

public enum SequenceMutation: Sendable, Equatable {
    case replaceDocument(SequenceDocument)
}

public enum AssetMutation: Sendable, Equatable {
    case scanProject(rootPath: String)
}

public enum TransactionOperation: Sendable, Equatable {
    case scene(SceneMutation)
    case sequence(SequenceMutation)
    case asset(AssetMutation)

    public var domain: TransactionDomain {
        switch self {
        case .scene:
            return .scene
        case .sequence:
            return .sequence
        case .asset:
            return .asset
        }
    }
}

/// Exact capability provenance for operations produced by AI or a plugin.
/// Carrying this record prevents policy from having to infer a verb from a
/// lower-level mutation.
public struct CapabilityInvocationRecord: Codable, Sendable, Equatable {
    public var capabilityID: String
    public var capabilityVersion: Int
    public var schemaHash: String
    public var sourcePluginID: String?
    public var pluginAuthority: PluginCapabilityAuthority?
    public var inputDigest: String
    public var argumentNames: [String]
    public var targetReferences: [String]
    public var access: CapabilityAccess
    public var exposureSnapshotID: UUID

    public init(capabilityID: String,
                capabilityVersion: Int,
                schemaHash: String,
                sourcePluginID: String? = nil,
                pluginAuthority: PluginCapabilityAuthority? = nil,
                inputDigest: String,
                argumentNames: [String] = [],
                targetReferences: [String] = [],
                access: CapabilityAccess,
                exposureSnapshotID: UUID) {
        self.capabilityID = capabilityID
        self.capabilityVersion = capabilityVersion
        self.schemaHash = schemaHash
        self.sourcePluginID = sourcePluginID
        self.pluginAuthority = pluginAuthority
        self.inputDigest = inputDigest
        self.argumentNames = argumentNames.sorted()
        self.targetReferences = targetReferences
        self.access = access
        self.exposureSnapshotID = exposureSnapshotID
    }
}

/// Host-owned, deterministic checks evaluated after all operations have been
/// applied but before success is published. A failed assertion aborts the
/// transaction and restores the in-memory scene/sequence snapshots.
public enum TransactionVerificationAssertion: Codable, Sendable, Equatable {
    case entityExists(UInt64)
    case entityIsAbsent(UInt64)
    case createdEntityCount(Int)
    case deletedEntity(UInt64)
    case sceneRevisionAdvanced(from: UInt64)
    case sceneState(SceneStateAssertion)
    case componentData(entityID: UInt64, typeID: String, value: ComponentValue, mode: ComponentWriteMode)
    case componentPresence(entityID: UInt64, typeID: String, isPresent: Bool)
}

public struct TransactionIR: Sendable, Equatable {
    public var id: String
    public var intent: IntentIR?
    public var summary: String
    public var operations: [TransactionOperation]
    public var capabilityInvocations: [CapabilityInvocationRecord]
    public var verificationAssertions: [TransactionVerificationAssertion]
    public var baseRevisions: TransactionBaseRevisions
    public var approvalPolicy: TransactionApprovalPolicy
    public var preview: TransactionPreviewResult?
    public var rollbackHandle: String?
    public var provenance: TransactionProvenance
    public var createdAt: Date

    public init(id: String = UUID().uuidString,
                intent: IntentIR? = nil,
                summary: String,
                operations: [TransactionOperation],
                capabilityInvocations: [CapabilityInvocationRecord] = [],
                verificationAssertions: [TransactionVerificationAssertion] = [],
                baseRevisions: TransactionBaseRevisions = TransactionBaseRevisions(),
                approvalPolicy: TransactionApprovalPolicy = .automatic,
                preview: TransactionPreviewResult? = nil,
                rollbackHandle: String? = nil,
                provenance: TransactionProvenance,
                createdAt: Date = Date()) {
        self.id = id
        self.intent = intent
        self.summary = summary
        self.operations = operations
        self.capabilityInvocations = capabilityInvocations
        self.verificationAssertions = verificationAssertions
        self.baseRevisions = baseRevisions
        self.approvalPolicy = approvalPolicy
        self.preview = preview
        self.rollbackHandle = rollbackHandle
        self.provenance = provenance
        self.createdAt = createdAt
    }
}
