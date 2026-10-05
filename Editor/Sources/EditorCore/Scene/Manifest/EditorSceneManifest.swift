import Foundation
import AssetPipeline
import GuavaUIRuntime
import IntentRuntime
import RenderBackend
import SceneRuntime
import ScriptRuntime
import SIMDCompat

public struct EditorSceneManifest: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 5
    public let schemaVersion: Int
    public let revision: UInt64
    public let entityCount: Int
    public let selectedEntityID: UInt64?
    public let sceneKind: String?
    public let physicsSettings: EditorSceneManifestPhysicsSettings?
    public let particleScalability: EditorSceneManifestParticleScalability?
    public let particleScalabilityPolicy: EditorSceneManifestParticleScalabilityPolicy?
    public let projectAssetCount: Int?
    public let lastModifiedAt: String?
    /// Editor-only hierarchy locks. Optional so schema-v5 scenes written by
    /// older Editor builds remain decodable without a migration.
    public let lockedEntityIDs: [UInt64]?
    public let roots: [EditorSceneManifestNode]

    public init(schemaVersion: Int = EditorSceneManifest.currentSchemaVersion,
                revision: UInt64,
                entityCount: Int,
                selectedEntityID: UInt64? = nil,
                sceneKind: String? = nil,
                physicsSettings: EditorSceneManifestPhysicsSettings? = nil,
                particleScalability: EditorSceneManifestParticleScalability? = nil,
                particleScalabilityPolicy: EditorSceneManifestParticleScalabilityPolicy? = nil,
                projectAssetCount: Int? = nil,
                lastModifiedAt: String? = nil,
                lockedEntityIDs: [UInt64]? = nil,
                roots: [EditorSceneManifestNode]) {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.entityCount = entityCount
        self.selectedEntityID = selectedEntityID
        self.sceneKind = sceneKind
        self.physicsSettings = physicsSettings
        self.particleScalability = particleScalability
        self.particleScalabilityPolicy = particleScalabilityPolicy
        self.projectAssetCount = projectAssetCount
        self.lastModifiedAt = lastModifiedAt
        self.lockedEntityIDs = lockedEntityIDs
        self.roots = roots
    }
}

public struct EditorSceneManifestLoadResult: Sendable, Equatable {
    public let entityCount: Int
    public let selectedEntityID: UInt64?
    public let error: EditorSceneManifestLoadError?

    public init(
        entityCount: Int,
        selectedEntityID: UInt64?,
        error: EditorSceneManifestLoadError? = nil
    ) {
        self.entityCount = entityCount
        self.selectedEntityID = selectedEntityID
        self.error = error
    }

    public var succeeded: Bool { error == nil }
}

public enum EditorSceneManifestLoadError: Error, Sendable, Equatable {
    case unsupportedVersion(Int)
}
