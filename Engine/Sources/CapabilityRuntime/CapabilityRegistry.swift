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

public enum CapabilityIsolationLevel: String, Sendable, Equatable, Codable {
    case doc
    case runtime
    case hybrid
}

public enum CapabilityConflictStrategy: String, Sendable, Equatable, Codable {
    case serialize
    case optimistic
    case lastWriteWins = "last_write_wins"
    case mergeRequired = "merge_required"
}

public enum CapabilityIdentityStability: String, Sendable, Equatable, Codable {
    case stable
    case revisionScoped = "revision_scoped"
    case sessionScoped = "session_scoped"
}

public struct CapabilityScopeSpec: Sendable, Equatable, Codable {
    public var scopeID: String
    public var displayName: String?
    public var hierarchyParent: String?
    public var isolationLevel: CapabilityIsolationLevel
    public var defaultRequiredRole: CapabilityRole
    public var conflictStrategy: CapabilityConflictStrategy

    public init(scopeID: String,
                displayName: String? = nil,
                hierarchyParent: String? = nil,
                isolationLevel: CapabilityIsolationLevel = .hybrid,
                defaultRequiredRole: CapabilityRole = .editor,
                conflictStrategy: CapabilityConflictStrategy = .serialize) {
        self.scopeID = scopeID
        self.displayName = displayName
        self.hierarchyParent = hierarchyParent
        self.isolationLevel = isolationLevel
        self.defaultRequiredRole = defaultRequiredRole
        self.conflictStrategy = conflictStrategy
    }

    enum CodingKeys: String, CodingKey {
        case scopeID = "scope_id"
        case displayName = "display_name"
        case hierarchyParent = "hierarchy_parent"
        case isolationLevel = "isolation_level"
        case defaultRequiredRole = "default_required_role"
        case conflictStrategy = "conflict_strategy"
    }
}

public struct CapabilityTargetKindSpec: Sendable, Equatable, Codable {
    public var targetKindID: String
    public var resolvesTo: String?
    public var identityStability: CapabilityIdentityStability
    public var validators: [String]

    public init(targetKindID: String,
                resolvesTo: String? = nil,
                identityStability: CapabilityIdentityStability = .stable,
                validators: [String] = []) {
        self.targetKindID = targetKindID
        self.resolvesTo = resolvesTo
        self.identityStability = identityStability
        self.validators = validators
    }

    enum CodingKeys: String, CodingKey {
        case targetKindID = "target_kind_id"
        case resolvesTo = "resolves_to"
        case identityStability = "identity_stability"
        case validators
    }
}

public struct CapabilityArgumentTypeSpec: Sendable, Equatable, Codable {
    public var typeID: String
    public var family: String
    public var summary: String?

    public init(typeID: String, family: String, summary: String? = nil) {
        self.typeID = typeID
        self.family = family
        self.summary = summary
    }

    enum CodingKeys: String, CodingKey {
        case typeID = "type_id"
        case family
        case summary
    }
}

public struct CapabilityPolicySpec: Sendable, Equatable, Codable {
    public var policyID: String
    public var summary: String?

    public init(policyID: String, summary: String? = nil) {
        self.policyID = policyID
        self.summary = summary
    }

    enum CodingKeys: String, CodingKey {
        case policyID = "policy_id"
        case summary
    }
}

public struct CapabilityArgumentRange: Sendable, Equatable, Codable {
    public var min: Double?
    public var max: Double?
    public var step: Double?

    public init(min: Double? = nil, max: Double? = nil, step: Double? = nil) {
        self.min = min
        self.max = max
        self.step = step
    }
}

public struct CapabilityDeriveRule: Sendable, Equatable, Codable {
    public enum Source: String, Sendable, Equatable, Codable {
        case editorContext = "editor_context"
        case lastCapabilityCall = "last_capability_call"
        case semanticMemory = "semantic_memory"
        case clipRef = "clip_ref"
    }

    public enum Fallback: String, Sendable, Equatable, Codable {
        case required
        case useDefault = "use_default"
        case error
    }

    public var source: Source
    public var path: String
    public var fallback: Fallback

    public init(source: Source, path: String, fallback: Fallback = .required) {
        self.source = source
        self.path = path
        self.fallback = fallback
    }
}

public struct CapabilityArgumentSpec: Sendable, Equatable, Codable {
    public var name: String
    public var typeID: String
    public var required: Bool
    public var unit: String?
    public var range: CapabilityArgumentRange?
    public var enumChoices: [String]
    public var description: String?
    public var llmHint: String?
    public var deriveFrom: CapabilityDeriveRule?
    public var redactInPrompt: Bool

    public init(name: String,
                typeID: String,
                required: Bool = true,
                unit: String? = nil,
                range: CapabilityArgumentRange? = nil,
                enumChoices: [String] = [],
                description: String? = nil,
                llmHint: String? = nil,
                deriveFrom: CapabilityDeriveRule? = nil,
                redactInPrompt: Bool = false) {
        self.name = name
        self.typeID = typeID
        self.required = required
        self.unit = unit
        self.range = range
        self.enumChoices = enumChoices
        self.description = description
        self.llmHint = llmHint
        self.deriveFrom = deriveFrom
        self.redactInPrompt = redactInPrompt
    }

    enum CodingKeys: String, CodingKey {
        case name
        case typeID = "type"
        case required
        case unit
        case range
        case enumChoices = "enum_choices"
        case description
        case llmHint = "llm_hint"
        case deriveFrom = "derive_from"
        case redactInPrompt = "redact_in_prompt"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        typeID = try container.decode(String.self, forKey: .typeID)
        required = try container.decodeIfPresent(Bool.self, forKey: .required) ?? true
        unit = try container.decodeIfPresent(String.self, forKey: .unit)
        range = try container.decodeIfPresent(CapabilityArgumentRange.self, forKey: .range)
        enumChoices = try container.decodeIfPresent([String].self, forKey: .enumChoices) ?? []
        description = try container.decodeIfPresent(String.self, forKey: .description)
        llmHint = try container.decodeIfPresent(String.self, forKey: .llmHint)
        deriveFrom = try container.decodeIfPresent(CapabilityDeriveRule.self, forKey: .deriveFrom)
        redactInPrompt = try container.decodeIfPresent(Bool.self, forKey: .redactInPrompt) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(typeID, forKey: .typeID)
        try container.encode(required, forKey: .required)
        try container.encodeIfPresent(unit, forKey: .unit)
        try container.encodeIfPresent(range, forKey: .range)
        try container.encode(enumChoices, forKey: .enumChoices)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(llmHint, forKey: .llmHint)
        try container.encodeIfPresent(deriveFrom, forKey: .deriveFrom)
        try container.encode(redactInPrompt, forKey: .redactInPrompt)
    }
}

public struct CapabilityVersionTable: Sendable, Equatable, Codable {
    public var registryVersion: String

    public init(registryVersion: String = "0.1.0") {
        self.registryVersion = registryVersion
    }

    enum CodingKeys: String, CodingKey {
        case registryVersion = "registry_version"
    }
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

public struct CapabilityFailureMode: Sendable, Equatable, Codable {
    public var id: String
    public var message: String

    public init(id: String, message: String) {
        self.id = id
        self.message = message
    }
}

public struct CapabilityRateLimit: Sendable, Equatable, Codable {
    public var perSecond: Int

    public init(perSecond: Int) {
        self.perSecond = perSecond
    }

    enum CodingKeys: String, CodingKey {
        case perSecond = "per_second"
    }
}

public struct CapabilityCostHint: Sendable, Equatable, Codable {
    public var score: Double

    public init(score: Double) {
        self.score = score
    }
}

public enum CapabilityInputProvenance: String, Sendable, Equatable, Codable {
    case authored
    case inferred
    case baked
    case proposal

    public static func from(transactionProvenance: Any) -> CapabilityInputProvenance? {
        switch String(describing: transactionProvenance) {
        case "authored":
            return .authored
        case "inferred":
            return .inferred
        case "baked":
            return .baked
        case "proposal":
            return .proposal
        default:
            return nil
        }
    }
}

public struct CapabilitySpec: Sendable, Equatable, Codable {
    public var verbID: String
    public var displayName: String?
    public var summary: String
    public var description: String?
    public var category: String
    public var scope: CapabilityScopeID
    public var targetKind: String
    public var arguments: [CapabilityArgumentSpec]
        public var policyRefs: [String]
    public var preconditions: [Precondition]
    public var effects: [CapabilityEffect]
    public var reversible: Bool
    public var previewSupport: CapabilityPreviewSupport
    public var confirmationPolicy: CapabilityConfirmationPolicy
    public var readAfterWrite: [EventKindID]
    public var writesDocuments: [String]
    public var writesRuntime: Bool
    public var sideBandEmits: [EventKindID]
    public var failureModes: [CapabilityFailureMode]
    public var releasePhaseGate: ReleasePhaseGate
    public var requiredRole: CapabilityRole
    public var rateLimit: CapabilityRateLimit?
    public var costEstimate: CapabilityCostHint?
    public var version: String
    public var status: CapabilityStatus
    public var deprecates: [String]
    public var supersededBy: String?
    public var evidenceKinds: [String]
    public var auditRequired: Bool
    public var provenanceInputAllowed: [CapabilityInputProvenance]
    public var provenanceOutput: String

    public init(verbID: String,
                displayName: String? = nil,
                summary: String,
                description: String? = nil,
                category: String,
                scope: CapabilityScopeID,
                targetKind: String,
                arguments: [CapabilityArgumentSpec] = [],
                preconditions: [Precondition] = [],
                effects: [CapabilityEffect] = [],
                reversible: Bool,
                previewSupport: CapabilityPreviewSupport,
                confirmationPolicy: CapabilityConfirmationPolicy,
                policyRefs: [String] = [],
                readAfterWrite: [EventKindID] = [],
                writesDocuments: [String] = [],
                writesRuntime: Bool = false,
                sideBandEmits: [EventKindID] = [],
                failureModes: [CapabilityFailureMode] = [],
                releasePhaseGate: ReleasePhaseGate = ReleasePhaseGate(),
                requiredRole: CapabilityRole,
                rateLimit: CapabilityRateLimit? = nil,
                costEstimate: CapabilityCostHint? = nil,
                version: String = "0.1.0",
                status: CapabilityStatus,
                deprecates: [String] = [],
                supersededBy: String? = nil,
                evidenceKinds: [String] = [],
                auditRequired: Bool = false,
                provenanceInputAllowed: [CapabilityInputProvenance] = [.authored, .inferred, .baked, .proposal],
                provenanceOutput: String = "authored") {
        self.verbID = verbID
        self.displayName = displayName
        self.summary = summary
        self.description = description
        self.category = category
        self.scope = scope
        self.targetKind = targetKind
        self.arguments = arguments
        self.preconditions = preconditions
        self.effects = effects
        self.reversible = reversible
        self.previewSupport = previewSupport
        self.confirmationPolicy = confirmationPolicy
        self.policyRefs = policyRefs
        self.readAfterWrite = readAfterWrite
        self.writesDocuments = writesDocuments
        self.writesRuntime = writesRuntime
        self.sideBandEmits = sideBandEmits
        self.failureModes = failureModes
        self.releasePhaseGate = releasePhaseGate
        self.requiredRole = requiredRole
        self.rateLimit = rateLimit
        self.costEstimate = costEstimate
        self.version = version
        self.status = status
        self.deprecates = deprecates
        self.supersededBy = supersededBy
        self.evidenceKinds = evidenceKinds
        self.auditRequired = auditRequired
        self.provenanceInputAllowed = provenanceInputAllowed
        self.provenanceOutput = provenanceOutput
    }

    enum CodingKeys: String, CodingKey {
        case verbID = "verb_id"
        case displayName = "display_name"
        case summary
        case description
        case category
        case scope
        case targetKind = "target_kind"
        case arguments
        case preconditions
        case effects
        case reversible
        case previewSupport = "preview_support"
        case confirmationPolicy = "confirmation_policy"
        case policyRefs = "policies"
        case readAfterWrite = "read_after_write"
        case writesDocuments = "writes_documents"
        case writesRuntime = "writes_runtime"
        case sideBandEmits = "side_band_emits"
        case failureModes = "failure_modes"
        case releasePhaseGate = "release_phase_gate"
        case requiredRole = "required_role"
        case rateLimit = "rate_limit"
        case costEstimate = "cost_estimate"
        case version
        case status
        case deprecates
        case supersededBy = "superseded_by"
        case evidenceKinds = "evidence_kinds"
        case auditRequired = "audit_required"
        case provenanceInputAllowed = "provenance_input_allowed"
        case provenanceOutput = "provenance_output"
    }
}

public struct CapabilityRegistryConfig: Sendable, Equatable, Codable {
    public var capabilities: [CapabilitySpec]
    public var scopes: [String: CapabilityScopeSpec]
    public var targetKinds: [String: CapabilityTargetKindSpec]
    public var argumentTypes: [String: CapabilityArgumentTypeSpec]
    public var effectKinds: [String: CapabilityEffectKindSpec]
    public var policies: [String: CapabilityPolicySpec]
    public var versions: CapabilityVersionTable

    public init(capabilities: [CapabilitySpec],
                scopes: [String: CapabilityScopeSpec] = [:],
                targetKinds: [String: CapabilityTargetKindSpec] = [:],
                argumentTypes: [String: CapabilityArgumentTypeSpec] = [:],
                effectKinds: [String: CapabilityEffectKindSpec] = [:],
                policies: [String: CapabilityPolicySpec] = [:],
                versions: CapabilityVersionTable = CapabilityVersionTable()) {
        self.capabilities = capabilities
        self.scopes = scopes
        self.targetKinds = targetKinds
        self.argumentTypes = argumentTypes
        self.effectKinds = effectKinds
        self.policies = policies
        self.versions = versions
    }

    enum CodingKeys: String, CodingKey {
        case capabilities
        case scopes
        case targetKinds = "target_kinds"
        case argumentTypes = "argument_types"
        case effectKinds = "effect_kinds"
        case policies
        case versions
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
    case missingDefaultResource(String)
    case invalidResourceData(String)
    case unresolvedScope(verbID: String, scopeID: String)
    case unresolvedTargetKind(verbID: String, targetKindID: String)
    case unresolvedEffectKind(verbID: String, effectKindID: String)
    case unresolvedPolicy(verbID: String, policyID: String)
    case unresolvedArgumentType(verbID: String, argument: String, typeID: String)
    case invalidReversibleEffect(verbID: String, effectID: String)
    case incompatibleEffectTarget(verbID: String, effectID: String, expectedTargetKind: String, actualTargetKind: String)
    case invalidPreviewPolicy(verbID: String)
    case invalidDeprecatedStatus(verbID: String)

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
        case let .missingDefaultResource(path):
            return "missing default capability registry resource: \(path)"
        case let .invalidResourceData(path):
            return "invalid capability registry resource data: \(path)"
        case let .unresolvedScope(verbID, scopeID):
            return "capability \(verbID) references unresolved scope \(scopeID)"
        case let .unresolvedTargetKind(verbID, targetKindID):
            return "capability \(verbID) references unresolved target kind \(targetKindID)"
        case let .unresolvedEffectKind(verbID, effectKindID):
            return "capability \(verbID) references unresolved effect kind \(effectKindID)"
        case let .unresolvedPolicy(verbID, policyID):
            return "capability \(verbID) references unresolved policy \(policyID)"
        case let .unresolvedArgumentType(verbID, argument, typeID):
            return "capability \(verbID) argument \(argument) references unresolved type \(typeID)"
        case let .invalidReversibleEffect(verbID, effectID):
            return "capability \(verbID) has non-reversible external effect \(effectID)"
        case let .incompatibleEffectTarget(verbID, effectID, expectedTargetKind, actualTargetKind):
            return "capability \(verbID) effect \(effectID) has incompatible target \(actualTargetKind), expected \(expectedTargetKind)"
        case let .invalidPreviewPolicy(verbID):
            return "capability \(verbID) cannot require confirmation when preview support is none"
        case let .invalidDeprecatedStatus(verbID):
            return "capability \(verbID) is deprecated but missing superseded_by"
        }
    }
}

public struct CapabilityRegistry: Sendable {
    public let capabilities: [String: CapabilitySpec]
    public let config: CapabilityRegistryConfig

    public init(capabilities: [CapabilitySpec],
                eventKindRegistry: EventKindRegistry = .default) throws {
        let config = CapabilityRegistryConfig(capabilities: capabilities,
                              scopes: Self.defaultScopeSpecs(),
                              targetKinds: Self.defaultTargetKindSpecs())
        try self.init(config: config,
                      eventKindRegistry: eventKindRegistry)
    }

    public init(config: CapabilityRegistryConfig,
                eventKindRegistry: EventKindRegistry = .default) throws {
        let analyzer = EffectAnalyzer(effectKinds: config.effectKinds)
        var table: [String: CapabilitySpec] = [:]

        for capability in config.capabilities {
            guard table[capability.verbID] == nil else {
                throw CapabilityRegistryError.duplicateCapability(capability.verbID)
            }
            guard config.scopes[capability.scope.rawValue] != nil else {
                throw CapabilityRegistryError.unresolvedScope(verbID: capability.verbID,
                                                             scopeID: capability.scope.rawValue)
            }
            guard config.targetKinds[capability.targetKind] != nil else {
                throw CapabilityRegistryError.unresolvedTargetKind(verbID: capability.verbID,
                                                                   targetKindID: capability.targetKind)
            }
            for policyID in capability.policyRefs {
                guard config.policies[policyID] != nil else {
                    throw CapabilityRegistryError.unresolvedPolicy(verbID: capability.verbID,
                                                                   policyID: policyID)
                }
            }
            for argument in capability.arguments {
                guard config.argumentTypes[argument.typeID] != nil else {
                    throw CapabilityRegistryError.unresolvedArgumentType(verbID: capability.verbID,
                                                                         argument: argument.name,
                                                                         typeID: argument.typeID)
                }
            }
            if capability.previewSupport.mode == .none,
               capability.confirmationPolicy.level != .auto {
                throw CapabilityRegistryError.invalidPreviewPolicy(verbID: capability.verbID)
            }
            if capability.status == .deprecated,
               capability.supersededBy == nil {
                throw CapabilityRegistryError.invalidDeprecatedStatus(verbID: capability.verbID)
            }
            for eventKind in capability.sideBandEmits + capability.readAfterWrite {
                guard eventKindRegistry.contains(eventKind) else {
                    throw CapabilityRegistryError.unknownEventKind(verbID: capability.verbID, kind: eventKind)
                }
            }
            try analyzer.validate(capability: capability)
            for effect in capability.effects {
                guard effect.targetKind == capability.targetKind else {
                    throw CapabilityRegistryError.incompatibleEffectTarget(verbID: capability.verbID,
                                                                           effectID: effect.id,
                                                                           expectedTargetKind: capability.targetKind,
                                                                           actualTargetKind: effect.targetKind)
                }
            }
            table[capability.verbID] = capability
        }

        self.capabilities = table
        self.config = config
    }

    public static func `default`(eventKindRegistry: EventKindRegistry = .default,
                                 bundle: Bundle? = nil) throws -> CapabilityRegistry {
        let config = try loadDefaultConfig(bundle: bundle)
        return try CapabilityRegistry(config: config, eventKindRegistry: eventKindRegistry)
    }

    public static func loadDefaultConfig(bundle: Bundle? = nil) throws -> CapabilityRegistryConfig {
        let resourceBundle = bundle ?? .module
        return try loadSplitDefaultConfig(bundle: resourceBundle)
    }

    private static func loadSplitDefaultConfig(bundle: Bundle) throws -> CapabilityRegistryConfig {
        let versions: CapabilityVersionTable = try decodeSplitResource("versions", ext: "json", bundle: bundle)
        let scopes: [String: CapabilityScopeSpec] = try decodeSplitResource("scopes", ext: "json", bundle: bundle)
        let targetKinds: [String: CapabilityTargetKindSpec] = try decodeSplitResource("target_kinds", ext: "json", bundle: bundle)
        let argumentTypes: [String: CapabilityArgumentTypeSpec] = try decodeSplitResource("argument_types", ext: "json", bundle: bundle)
        let effectKinds: [String: CapabilityEffectKindSpec] = try decodeSplitResource("effect_kinds", ext: "json", bundle: bundle)
        let policies: [String: CapabilityPolicySpec] = try decodeSplitResource("policies", ext: "json", bundle: bundle)

        let sceneCapabilities: [CapabilitySpec] = try decodeSplitResource("capabilities.scene", ext: "json", bundle: bundle)
        let assetCapabilities: [CapabilitySpec] = try decodeSplitResource("capabilities.asset", ext: "json", bundle: bundle)
        let sequenceCapabilities: [CapabilitySpec] = try decodeSplitResource("capabilities.sequence", ext: "json", bundle: bundle)
        let miscCapabilities: [CapabilitySpec] = (try? decodeSplitResource("capabilities.misc", ext: "json", bundle: bundle)) ?? []

        return CapabilityRegistryConfig(
            capabilities: sceneCapabilities + assetCapabilities + sequenceCapabilities + miscCapabilities,
            scopes: scopes,
            targetKinds: targetKinds,
            argumentTypes: argumentTypes,
            effectKinds: effectKinds,
            policies: policies,
            versions: versions
        )
    }

    private static func decodeSplitResource<T: Decodable>(_ name: String,
                                                           ext: String,
                                                           bundle: Bundle) throws -> T {
        guard let url = resolveSplitResourceURL(name: name, ext: ext, bundle: bundle) else {
            throw CapabilityRegistryError.missingDefaultResource("CapabilityRegistry/default/\(name).\(ext)")
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw CapabilityRegistryError.invalidResourceData(url.path)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw CapabilityRegistryError.invalidResourceData(url.path)
        }
    }

    private static func resolveSplitResourceURL(name: String,
                                                ext: String,
                                                bundle: Bundle) -> URL? {
        let nested = bundle.url(forResource: name,
                                withExtension: ext,
                                subdirectory: "CapabilityRegistry/default")
        let prefixedFlat = bundle.url(forResource: "default/\(name)", withExtension: ext)
        let flat = bundle.url(forResource: name, withExtension: ext)
        return nested ?? prefixedFlat ?? flat
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

    private static func defaultScopeSpecs() -> [String: CapabilityScopeSpec] {
        [
            CapabilityScopeID.asset.rawValue: CapabilityScopeSpec(scopeID: CapabilityScopeID.asset.rawValue,
                                                                  isolationLevel: .doc,
                                                                  defaultRequiredRole: .editor,
                                                                  conflictStrategy: .serialize),
            CapabilityScopeID.prefab.rawValue: CapabilityScopeSpec(scopeID: CapabilityScopeID.prefab.rawValue,
                                                                   isolationLevel: .doc,
                                                                   defaultRequiredRole: .editor,
                                                                   conflictStrategy: .serialize),
            CapabilityScopeID.sceneInstance.rawValue: CapabilityScopeSpec(scopeID: CapabilityScopeID.sceneInstance.rawValue,
                                                                          isolationLevel: .hybrid,
                                                                          defaultRequiredRole: .editor,
                                                                          conflictStrategy: .serialize),
            CapabilityScopeID.sceneGraph.rawValue: CapabilityScopeSpec(scopeID: CapabilityScopeID.sceneGraph.rawValue,
                                                                       isolationLevel: .hybrid,
                                                                       defaultRequiredRole: .editor,
                                                                       conflictStrategy: .serialize),
            CapabilityScopeID.sequence.rawValue: CapabilityScopeSpec(scopeID: CapabilityScopeID.sequence.rawValue,
                                                                     isolationLevel: .doc,
                                                                     defaultRequiredRole: .editor,
                                                                     conflictStrategy: .serialize),
            CapabilityScopeID.shot.rawValue: CapabilityScopeSpec(scopeID: CapabilityScopeID.shot.rawValue,
                                                                 hierarchyParent: CapabilityScopeID.sequence.rawValue,
                                                                 isolationLevel: .doc,
                                                                 defaultRequiredRole: .editor,
                                                                 conflictStrategy: .serialize),
            CapabilityScopeID.track.rawValue: CapabilityScopeSpec(scopeID: CapabilityScopeID.track.rawValue,
                                                                  hierarchyParent: CapabilityScopeID.sequence.rawValue,
                                                                  isolationLevel: .doc,
                                                                  defaultRequiredRole: .editor,
                                                                  conflictStrategy: .serialize),
            CapabilityScopeID.clip.rawValue: CapabilityScopeSpec(scopeID: CapabilityScopeID.clip.rawValue,
                                                                 hierarchyParent: CapabilityScopeID.track.rawValue,
                                                                 isolationLevel: .doc,
                                                                 defaultRequiredRole: .editor,
                                                                 conflictStrategy: .serialize),
        ]
    }

    private static func defaultTargetKindSpecs() -> [String: CapabilityTargetKindSpec] {
        [
            "scene_instance_id": CapabilityTargetKindSpec(targetKindID: "scene_instance_id"),
            "scene_graph_id": CapabilityTargetKindSpec(targetKindID: "scene_graph_id"),
            "sequence_id": CapabilityTargetKindSpec(targetKindID: "sequence_id"),
            "shot_id": CapabilityTargetKindSpec(targetKindID: "shot_id"),
            "project_root": CapabilityTargetKindSpec(targetKindID: "project_root",
                                                      identityStability: .sessionScoped),
            "asset_uri": CapabilityTargetKindSpec(targetKindID: "asset_uri"),
        ]
    }
}
