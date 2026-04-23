import Foundation
import ObservationBus

public enum CapabilityRole: String, Sendable, Equatable, Codable, Comparable {
    case viewer
    case editor
    case `operator`
    case admin

    private var rank: Int {
        switch self {
        case .viewer:
            return 0
        case .editor:
            return 1
        case .operator:
            return 2
        case .admin:
            return 3
        }
    }

    public static func < (lhs: CapabilityRole, rhs: CapabilityRole) -> Bool {
        lhs.rank < rhs.rank
    }
}

public enum CapabilityStatus: String, Sendable, Equatable, Codable {
    case experimental
    case stable
    case deprecated
    case removed
}

public enum CapabilityScopeID: String, Sendable, Equatable, Codable {
    case asset
    case prefab
    case sceneInstance = "scene_instance"
    case sceneGraph = "scene_graph"
    case sequence
    case shot
    case track
    case clip
}

public enum CapabilityPreviewMode: String, Sendable, Equatable, Codable {
    case none
    case ghostWorld = "ghost_world"
    case overlay
    case numericDiff = "numeric_diff"
    case imageDiff = "image_diff"
}

public struct CapabilityPreviewSupport: Sendable, Equatable, Codable {
    public var mode: CapabilityPreviewMode

    public init(mode: CapabilityPreviewMode) {
        self.mode = mode
    }
}

public enum CapabilityConfirmationLevel: String, Sendable, Equatable, Codable {
    case auto
    case warn
    case required
    case destructiveRequired = "destructive_required"
}

public struct CapabilityConfirmationPolicy: Sendable, Equatable, Codable {
    public var level: CapabilityConfirmationLevel

    public init(level: CapabilityConfirmationLevel) {
        self.level = level
    }
}

public struct CapabilitySpec: Sendable, Equatable {
    public var verbID: String
    public var summary: String
    public var category: String
    public var scope: CapabilityScopeID
    public var targetKind: String
    public var preconditions: [Precondition]
    public var reversible: Bool
    public var previewSupport: CapabilityPreviewSupport
    public var confirmationPolicy: CapabilityConfirmationPolicy
    public var readAfterWrite: [EventKindID]
    public var sideBandEmits: [EventKindID]
    public var releasePhaseGate: ReleasePhaseGate
    public var requiredRole: CapabilityRole
    public var version: String
    public var status: CapabilityStatus

    public init(verbID: String,
                summary: String,
                category: String,
                scope: CapabilityScopeID,
                targetKind: String,
                preconditions: [Precondition] = [],
                reversible: Bool,
                previewSupport: CapabilityPreviewSupport,
                confirmationPolicy: CapabilityConfirmationPolicy,
                readAfterWrite: [EventKindID] = [],
                sideBandEmits: [EventKindID] = [],
                releasePhaseGate: ReleasePhaseGate = ReleasePhaseGate(),
                requiredRole: CapabilityRole,
                version: String = "0.1.0",
                status: CapabilityStatus) {
        self.verbID = verbID
        self.summary = summary
        self.category = category
        self.scope = scope
        self.targetKind = targetKind
        self.preconditions = preconditions
        self.reversible = reversible
        self.previewSupport = previewSupport
        self.confirmationPolicy = confirmationPolicy
        self.readAfterWrite = readAfterWrite
        self.sideBandEmits = sideBandEmits
        self.releasePhaseGate = releasePhaseGate
        self.requiredRole = requiredRole
        self.version = version
        self.status = status
    }
}

public struct CapabilityQueryContext: Sendable, Equatable {
    public var role: CapabilityRole
    public var phase: ReleasePhase
    public var includeExperimental: Bool
    public var isHotfix: Bool

    public init(role: CapabilityRole,
                phase: ReleasePhase,
                includeExperimental: Bool = false,
                isHotfix: Bool = false) {
        self.role = role
        self.phase = phase
        self.includeExperimental = includeExperimental
        self.isHotfix = isHotfix
    }
}

public struct CapabilityResolution: Sendable, Equatable {
    public var spec: CapabilitySpec
    public var warnings: [String]

    public init(spec: CapabilitySpec, warnings: [String] = []) {
        self.spec = spec
        self.warnings = warnings
    }
}

public enum CapabilityRegistryError: Error, CustomStringConvertible {
    case duplicateCapability(String)
    case missingCapability(String)
    case roleDenied(verbID: String, required: CapabilityRole, actual: CapabilityRole)
    case releasePhaseDenied(verbID: String, phase: ReleasePhase)
    case removedCapability(String)
    case unknownEventKind(verbID: String, kind: EventKindID)

    public var description: String {
        switch self {
        case let .duplicateCapability(verbID):
            return "duplicate capability: \(verbID)"
        case let .missingCapability(verbID):
            return "missing capability: \(verbID)"
        case let .roleDenied(verbID, required, actual):
            return "capability \(verbID) requires role \(required.rawValue), actual \(actual.rawValue)"
        case let .releasePhaseDenied(verbID, phase):
            return "capability \(verbID) is denied in release phase \(phase.rawValue)"
        case let .removedCapability(verbID):
            return "capability \(verbID) has status removed"
        case let .unknownEventKind(verbID, kind):
            return "capability \(verbID) references unknown event kind \(kind.rawValue)"
        }
    }
}

public struct CapabilityRegistry: Sendable {
    public let capabilities: [String: CapabilitySpec]

    public init(capabilities: [CapabilitySpec],
                eventKindRegistry: EventKindRegistry = .default) throws {
        var table: [String: CapabilitySpec] = [:]
        for capability in capabilities {
            guard table[capability.verbID] == nil else {
                throw CapabilityRegistryError.duplicateCapability(capability.verbID)
            }
            for eventKind in capability.sideBandEmits + capability.readAfterWrite {
                guard eventKindRegistry.contains(eventKind) else {
                    throw CapabilityRegistryError.unknownEventKind(verbID: capability.verbID, kind: eventKind)
                }
            }
            table[capability.verbID] = capability
        }
        self.capabilities = table
    }

    public static func `default`(eventKindRegistry: EventKindRegistry = .default) throws -> CapabilityRegistry {
        try CapabilityRegistry(capabilities: [
            CapabilitySpec(
                verbID: "scene.spawn_entity",
                summary: "Spawn an imported mesh entity",
                category: "scene",
                scope: .sceneInstance,
                targetKind: "scene_instance_id",
                reversible: true,
                previewSupport: CapabilityPreviewSupport(mode: .ghostWorld),
                confirmationPolicy: CapabilityConfirmationPolicy(level: .auto),
                readAfterWrite: [.sceneChanged],
                sideBandEmits: [.transactionApplied, .sceneChanged, .sceneEntityAdded],
                requiredRole: .editor,
                status: .stable
            ),
            CapabilitySpec(
                verbID: "scene.delete_entity",
                summary: "Delete a scene entity",
                category: "scene",
                scope: .sceneInstance,
                targetKind: "scene_instance_id",
                reversible: true,
                previewSupport: CapabilityPreviewSupport(mode: .ghostWorld),
                confirmationPolicy: CapabilityConfirmationPolicy(level: .warn),
                readAfterWrite: [.sceneChanged],
                sideBandEmits: [.transactionApplied, .sceneChanged, .sceneEntityRemoved],
                requiredRole: .editor,
                status: .stable
            ),
            CapabilitySpec(
                verbID: "scene.duplicate_entity",
                summary: "Duplicate a scene entity",
                category: "scene",
                scope: .sceneInstance,
                targetKind: "scene_instance_id",
                reversible: true,
                previewSupport: CapabilityPreviewSupport(mode: .ghostWorld),
                confirmationPolicy: CapabilityConfirmationPolicy(level: .auto),
                readAfterWrite: [.sceneChanged],
                sideBandEmits: [.transactionApplied, .sceneChanged, .sceneEntityAdded],
                requiredRole: .editor,
                status: .stable
            ),
            CapabilitySpec(
                verbID: "scene.set_local_transform",
                summary: "Set a scene entity local transform",
                category: "scene",
                scope: .sceneInstance,
                targetKind: "scene_instance_id",
                reversible: true,
                previewSupport: CapabilityPreviewSupport(mode: .ghostWorld),
                confirmationPolicy: CapabilityConfirmationPolicy(level: .auto),
                readAfterWrite: [.sceneChanged],
                sideBandEmits: [.transactionApplied, .sceneChanged],
                requiredRole: .editor,
                status: .stable
            ),
            CapabilitySpec(
                verbID: "scene.set_name",
                summary: "Rename a scene entity",
                category: "scene",
                scope: .sceneInstance,
                targetKind: "scene_instance_id",
                reversible: true,
                previewSupport: CapabilityPreviewSupport(mode: .ghostWorld),
                confirmationPolicy: CapabilityConfirmationPolicy(level: .auto),
                readAfterWrite: [.sceneChanged],
                sideBandEmits: [.transactionApplied, .sceneChanged],
                requiredRole: .editor,
                status: .stable
            ),
            CapabilitySpec(
                verbID: "scene.set_rigidbody_allow_sleep",
                summary: "Set a rigid body sleep flag",
                category: "scene",
                scope: .sceneInstance,
                targetKind: "scene_instance_id",
                reversible: true,
                previewSupport: CapabilityPreviewSupport(mode: .ghostWorld),
                confirmationPolicy: CapabilityConfirmationPolicy(level: .auto),
                readAfterWrite: [.sceneChanged],
                sideBandEmits: [.transactionApplied, .sceneChanged],
                requiredRole: .editor,
                status: .stable
            ),
            CapabilitySpec(
                verbID: "scene.set_collider_trigger",
                summary: "Set a collider trigger flag",
                category: "scene",
                scope: .sceneInstance,
                targetKind: "scene_instance_id",
                reversible: true,
                previewSupport: CapabilityPreviewSupport(mode: .ghostWorld),
                confirmationPolicy: CapabilityConfirmationPolicy(level: .auto),
                readAfterWrite: [.sceneChanged],
                sideBandEmits: [.transactionApplied, .sceneChanged],
                requiredRole: .editor,
                status: .stable
            ),
            CapabilitySpec(
                verbID: "scene.set_constraint_enabled",
                summary: "Set a constraint enabled flag",
                category: "scene",
                scope: .sceneInstance,
                targetKind: "scene_instance_id",
                reversible: true,
                previewSupport: CapabilityPreviewSupport(mode: .ghostWorld),
                confirmationPolicy: CapabilityConfirmationPolicy(level: .auto),
                readAfterWrite: [.sceneChanged],
                sideBandEmits: [.transactionApplied, .sceneChanged],
                requiredRole: .editor,
                status: .stable
            ),
            CapabilitySpec(
                verbID: "scene.set_camera_pose",
                summary: "Set a camera pose",
                category: "scene",
                scope: .sceneInstance,
                targetKind: "scene_instance_id",
                reversible: true,
                previewSupport: CapabilityPreviewSupport(mode: .ghostWorld),
                confirmationPolicy: CapabilityConfirmationPolicy(level: .auto),
                readAfterWrite: [.sceneChanged],
                sideBandEmits: [.transactionApplied, .sceneChanged],
                requiredRole: .editor,
                status: .stable
            ),
            CapabilitySpec(
                verbID: "sequence.replace_document",
                summary: "Replace the active sequence document",
                category: "sequence",
                scope: .sequence,
                targetKind: "sequence_id",
                reversible: true,
                previewSupport: CapabilityPreviewSupport(mode: .ghostWorld),
                confirmationPolicy: CapabilityConfirmationPolicy(level: .auto),
                readAfterWrite: [.sequenceChanged],
                sideBandEmits: [.transactionApplied, .sequenceChanged],
                requiredRole: .editor,
                status: .stable
            ),
            CapabilitySpec(
                verbID: "asset.scan_project",
                summary: "Scan a project directory for importable assets",
                category: "asset",
                scope: .asset,
                targetKind: "project_root",
                reversible: true,
                previewSupport: CapabilityPreviewSupport(mode: .none),
                confirmationPolicy: CapabilityConfirmationPolicy(level: .auto),
                readAfterWrite: [.assetImportFinished],
                sideBandEmits: [.transactionApplied, .assetImportFinished],
                requiredRole: .editor,
                status: .stable
            ),
            CapabilitySpec(
                verbID: "scene.create_instance",
                summary: "Create a scene instance",
                category: "scene",
                scope: .sceneInstance,
                targetKind: "scene_instance_id",
                reversible: true,
                previewSupport: CapabilityPreviewSupport(mode: .ghostWorld),
                confirmationPolicy: CapabilityConfirmationPolicy(level: .auto),
                readAfterWrite: [.sceneChanged],
                sideBandEmits: [.transactionApplied, .sceneChanged, .sceneEntityAdded],
                requiredRole: .editor,
                status: .stable
            ),
            CapabilitySpec(
                verbID: "scene.delete_instance",
                summary: "Delete a scene instance",
                category: "scene",
                scope: .sceneInstance,
                targetKind: "scene_instance_id",
                reversible: true,
                previewSupport: CapabilityPreviewSupport(mode: .ghostWorld),
                confirmationPolicy: CapabilityConfirmationPolicy(level: .warn),
                readAfterWrite: [.sceneChanged],
                sideBandEmits: [.transactionApplied, .sceneChanged, .sceneEntityRemoved],
                requiredRole: .editor,
                status: .stable
            ),
            CapabilitySpec(
                verbID: "scene.set_transform",
                summary: "Set a scene instance transform",
                category: "scene",
                scope: .sceneInstance,
                targetKind: "scene_instance_id",
                reversible: true,
                previewSupport: CapabilityPreviewSupport(mode: .ghostWorld),
                confirmationPolicy: CapabilityConfirmationPolicy(level: .auto),
                readAfterWrite: [.sceneChanged],
                sideBandEmits: [.transactionApplied, .sceneChanged],
                requiredRole: .editor,
                status: .stable
            ),
            CapabilitySpec(
                verbID: "asset.import",
                summary: "Import an asset into the project",
                category: "asset",
                scope: .asset,
                targetKind: "asset_uri",
                reversible: true,
                previewSupport: CapabilityPreviewSupport(mode: .ghostWorld),
                confirmationPolicy: CapabilityConfirmationPolicy(level: .warn),
                readAfterWrite: [.assetImportFinished],
                sideBandEmits: [.transactionApplied, .assetImportFinished],
                requiredRole: .editor,
                status: .stable
            ),
            CapabilitySpec(
                verbID: "sequence.add_shot",
                summary: "Add a shot to the current sequence",
                category: "sequence",
                scope: .shot,
                targetKind: "shot_id",
                reversible: true,
                previewSupport: CapabilityPreviewSupport(mode: .ghostWorld),
                confirmationPolicy: CapabilityConfirmationPolicy(level: .auto),
                readAfterWrite: [.sequenceChanged],
                sideBandEmits: [.transactionApplied, .sequenceChanged],
                requiredRole: .editor,
                status: .stable
            ),
            CapabilitySpec(
                verbID: "scene.commit_inferred_draft",
                summary: "Commit an inferred draft into the scene",
                category: "scene",
                scope: .sceneGraph,
                targetKind: "scene_graph_id",
                reversible: true,
                previewSupport: CapabilityPreviewSupport(mode: .ghostWorld),
                confirmationPolicy: CapabilityConfirmationPolicy(level: .required),
                readAfterWrite: [.sceneChanged],
                sideBandEmits: [.transactionApplied, .sceneChanged],
                releasePhaseGate: ReleasePhaseGate(ship: .deny),
                requiredRole: .editor,
                status: .experimental
            ),
            CapabilitySpec(
                verbID: "scene.snap_to_ground",
                summary: "Snap the current instance to ground",
                category: "scene",
                scope: .sceneInstance,
                targetKind: "scene_instance_id",
                reversible: true,
                previewSupport: CapabilityPreviewSupport(mode: .ghostWorld),
                confirmationPolicy: CapabilityConfirmationPolicy(level: .auto),
                readAfterWrite: [.sceneChanged],
                sideBandEmits: [.transactionApplied, .sceneChanged, .diagnosticsWarningRaised],
                requiredRole: .editor,
                status: .deprecated
            ),
        ], eventKindRegistry: eventKindRegistry)
    }

    public func capability(for verbID: String) -> CapabilitySpec? {
        capabilities[verbID]
    }

    public func defaultPromptCapabilities(for context: CapabilityQueryContext) -> [CapabilitySpec] {
        capabilities.values
            .filter { capability in
                guard capability.status != .removed else { return false }
                guard capability.requiredRole <= context.role else { return false }
                if capability.status == .experimental && !context.includeExperimental {
                    return false
                }
                return capability.releasePhaseGate.decision(for: context.phase, isHotfix: context.isHotfix) != .deny
            }
            .sorted { $0.verbID < $1.verbID }
    }

    public func resolveInvocation(verbID: String,
                                  context: CapabilityQueryContext) throws -> CapabilityResolution {
        guard let capability = capabilities[verbID] else {
            throw CapabilityRegistryError.missingCapability(verbID)
        }
        guard capability.status != .removed else {
            throw CapabilityRegistryError.removedCapability(verbID)
        }
        guard context.role >= capability.requiredRole else {
            throw CapabilityRegistryError.roleDenied(verbID: verbID,
                                                    required: capability.requiredRole,
                                                    actual: context.role)
        }

        let gateDecision = capability.releasePhaseGate.decision(for: context.phase, isHotfix: context.isHotfix)
        guard gateDecision != .deny else {
            throw CapabilityRegistryError.releasePhaseDenied(verbID: verbID, phase: context.phase)
        }

        var warnings: [String] = []
        if capability.status == .deprecated {
            warnings.append("capability \(verbID) is deprecated")
        }
        if gateDecision == .warn {
            warnings.append("capability \(verbID) is warning-gated in release phase \(context.phase.rawValue)")
        }
        if capability.status == .experimental {
            warnings.append("capability \(verbID) is experimental")
        }
        return CapabilityResolution(spec: capability, warnings: warnings)
    }
}