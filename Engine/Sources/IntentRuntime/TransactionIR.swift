import AssetPipeline
import Foundation
import SceneRuntime
import SequenceRuntime
import ScriptRuntime
import simd

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

    public init(changedDomains: [TransactionDomain],
                createdEntityIDs: [UInt64] = [],
                deletedEntityIDs: [UInt64] = [],
                sceneRevision: UInt64? = nil,
                sequenceRevisionID: String? = nil,
                assetEntryCount: Int? = nil) {
        self.changedDomains = changedDomains
        self.createdEntityIDs = createdEntityIDs
        self.deletedEntityIDs = deletedEntityIDs
        self.sceneRevision = sceneRevision
        self.sequenceRevisionID = sequenceRevisionID
        self.assetEntryCount = assetEntryCount
    }
}

public enum SceneMutation: Sendable, Equatable {
    case spawnImportedMeshEntity(label: String,
                                 kindLabel: String,
                                 meshIndex: Int,
                                 position: SIMD3<Float>)
    case deleteEntity(entityID: UInt64)
    case duplicateEntity(entityID: UInt64)
    case moveEntity(entityID: UInt64, parentID: UInt64?, index: Int)
    case setLocalTransform(entityID: UInt64, transform: LocalTransform)
    case setSceneName(entityID: UInt64, value: String)
    case setRigidBodyAllowSleep(entityID: UInt64, value: Bool)
    case setColliderTrigger(entityID: UInt64, value: Bool)
    case setConstraintEnabled(entityID: UInt64, value: Bool)
    case setLightType(entityID: UInt64, type: LightType)
    case setLightColor(entityID: UInt64, color: SIMD3<Float>)
    case setLightIntensity(entityID: UInt64, intensity: Float)
    case setLightRange(entityID: UInt64, range: Float)
    case setLightSpotInnerAngle(entityID: UInt64, angleDegrees: Float)
    case setLightSpotOuterAngle(entityID: UInt64, angleDegrees: Float)
    case setScriptBindings(entityID: UInt64, bindings: [ScriptBinding])
    case setCameraPose(entityID: UInt64,
                       localTransform: LocalTransform,
                       target: SIMD3<Float>,
                       up: SIMD3<Float>?)
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

public struct TransactionIR: Sendable, Equatable {
    public var id: String
    public var intent: IntentIR?
    public var summary: String
    public var operations: [TransactionOperation]
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
        self.baseRevisions = baseRevisions
        self.approvalPolicy = approvalPolicy
        self.preview = preview
        self.rollbackHandle = rollbackHandle
        self.provenance = provenance
        self.createdAt = createdAt
    }
}
