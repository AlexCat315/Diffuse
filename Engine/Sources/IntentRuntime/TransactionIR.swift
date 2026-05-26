import AssetPipeline
import Foundation
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
    case spawnEmptyEntity(label: String, position: SIMD3<Float>)
    case spawnLightEntity(label: String, lightType: LightType, position: SIMD3<Float>)
    case spawnCameraEntity(label: String, position: SIMD3<Float>)
    case deleteEntity(entityID: UInt64)
    case duplicateEntity(entityID: UInt64)
    /// Duplicate an entity and immediately apply a world-space position offset to the copy.
    /// The offset is applied in the same local space as the source (parent-relative).
    case duplicateEntityWithOffset(entityID: UInt64, positionOffset: SIMD3<Float>)
    case moveEntity(entityID: UInt64, parentID: UInt64?, index: Int)
    case setLocalTransform(entityID: UInt64, transform: LocalTransform)
    case setSceneName(entityID: UInt64, value: String)
    case setRigidBodyMotionType(entityID: UInt64, value: RigidBodyMotionType)
    case setRigidBodyMass(entityID: UInt64, value: Float)
    case setRigidBodyGravityScale(entityID: UInt64, value: Float)
    case setRigidBodyAllowSleep(entityID: UInt64, value: Bool)
    /// Full rigidbody replacement — creates the component if it doesn't exist yet.
    case setRigidBody(entityID: UInt64, body: RigidBody)
    case setCollider(entityID: UInt64, collider: Collider)
    case setColliderTrigger(entityID: UInt64, value: Bool)
    case setColliderShapeType(entityID: UInt64, kind: ColliderShapeKind)
    case setColliderShapeBoxHalfExtents(entityID: UInt64, halfExtents: SIMD3<Float>)
    case setColliderShapeSphereRadius(entityID: UInt64, radius: Float)
    case setColliderShapeCapsuleRadius(entityID: UInt64, radius: Float)
    case setColliderShapeCapsuleHalfHeight(entityID: UInt64, halfHeight: Float)
    case setColliderMaterialFriction(entityID: UInt64, value: Float)
    case setColliderMaterialRestitution(entityID: UInt64, value: Float)
    case setColliderMaterialDensity(entityID: UInt64, value: Float)
    case setColliderLayer(entityID: UInt64, layerID: UInt16)
    case setColliderLayerMask(entityID: UInt64, layerMask: UInt16)
    case setConstraintEnabled(entityID: UInt64, value: Bool)
    case setLightType(entityID: UInt64, type: LightType)
    case setLightColor(entityID: UInt64, color: SIMD3<Float>)
    case setLightIntensity(entityID: UInt64, intensity: Float)
    case setLightRange(entityID: UInt64, range: Float)
    case setLightSpotInnerAngle(entityID: UInt64, angleDegrees: Float)
    case setLightSpotOuterAngle(entityID: UInt64, angleDegrees: Float)
    case setLightCastShadows(entityID: UInt64, value: Bool)
    case setMeshColorTint(entityID: UInt64, color: SIMD3<Float>)
    case setRenderMeshVisibility(entityID: UInt64, isVisible: Bool)
    case setRenderMaterialComponent(entityID: UInt64,
                                    baseColorFactor: SIMD4<Float>,
                                    metallicFactor: Float,
                                    roughnessFactor: Float,
                                    emissiveFactor: SIMD3<Float>)
    case setScriptBindings(entityID: UInt64, bindings: [ScriptBinding])
    case setCameraPose(entityID: UInt64,
                       localTransform: LocalTransform,
                       target: SIMD3<Float>,
                       up: SIMD3<Float>?)
    case setCameraFOV(entityID: UInt64, fovYDegrees: Float)
    case setCameraActive(entityID: UInt64, isActive: Bool)
    case setAudioSource(entityID: UInt64, source: AudioSource)
    case setAnimationPlayer(entityID: UInt64, clipName: String?, speed: Float, loop: Bool, isPlaying: Bool)

    /// The primary entity targeted by this mutation, if any.
    /// `spawnImportedMeshEntity` returns `nil` because it creates entities
    /// rather than referencing an existing one.
    public var entityID: UInt64? {
        switch self {
        case .spawnImportedMeshEntity, .spawnEmptyEntity, .spawnLightEntity, .spawnCameraEntity,
             .duplicateEntityWithOffset:
            return nil
        case let .deleteEntity(id),
             let .duplicateEntity(id),
             let .setRigidBody(id, _),
             let .moveEntity(id, _, _),
             let .setLocalTransform(id, _),
             let .setSceneName(id, _),
             let .setRigidBodyMotionType(id, _),
             let .setRigidBodyMass(id, _),
             let .setRigidBodyGravityScale(id, _),
             let .setRigidBodyAllowSleep(id, _),
             let .setCollider(id, _),
             let .setColliderTrigger(id, _),
             let .setColliderShapeType(id, _),
             let .setColliderShapeBoxHalfExtents(id, _),
             let .setColliderShapeSphereRadius(id, _),
             let .setColliderShapeCapsuleRadius(id, _),
             let .setColliderShapeCapsuleHalfHeight(id, _),
             let .setColliderMaterialFriction(id, _),
             let .setColliderMaterialRestitution(id, _),
             let .setColliderMaterialDensity(id, _),
             let .setColliderLayer(id, _),
             let .setColliderLayerMask(id, _),
             let .setConstraintEnabled(id, _),
             let .setLightType(id, _),
             let .setLightColor(id, _),
             let .setLightIntensity(id, _),
             let .setLightRange(id, _),
             let .setLightSpotInnerAngle(id, _),
             let .setLightSpotOuterAngle(id, _),
             let .setLightCastShadows(id, _),
             let .setMeshColorTint(id, _),
             let .setRenderMeshVisibility(id, _),
             let .setRenderMaterialComponent(id, _, _, _, _),
             let .setScriptBindings(id, _),
             let .setCameraPose(id, _, _, _),
             let .setCameraFOV(id, _),
             let .setCameraActive(id, _),
             let .setAudioSource(id, _),
             let .setAnimationPlayer(id, _, _, _, _):
            return id
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
