import Foundation

public enum CapabilityEffectKind: String, Sendable, Equatable, Codable {
    case writeField = "write_field"
    case createNode = "create_node"
    case deleteNode = "delete_node"
    case moveNode = "move_node"
    case replaceAsset = "replace_asset"
    case bakeCache = "bake_cache"
    case invalidateCache = "invalidate_cache"
    case emitEvent = "emit_event"
    case submitExternalJob = "submit_external_job"
}

public struct CapabilityEffectKindSpec: Sendable, Equatable, Codable {
    public var effectID: String
    public var kind: CapabilityEffectKind
    public var summary: String?

    public init(effectID: String, kind: CapabilityEffectKind, summary: String? = nil) {
        self.effectID = effectID
        self.kind = kind
        self.summary = summary
    }

    enum CodingKeys: String, CodingKey {
        case effectID = "effect_id"
        case kind
        case summary
    }
}

public struct CapabilityEffect: Sendable, Equatable, Codable {
    public var id: String
    public var kind: CapabilityEffectKind
    public var targetKind: String
    public var fieldPath: String?
    public var valueOrigin: String
    public var reversibleBy: String?

    public init(id: String,
                kind: CapabilityEffectKind,
                targetKind: String,
                fieldPath: String? = nil,
                valueOrigin: String = "argument",
                reversibleBy: String? = nil) {
        self.id = id
        self.kind = kind
        self.targetKind = targetKind
        self.fieldPath = fieldPath
        self.valueOrigin = valueOrigin
        self.reversibleBy = reversibleBy
    }

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case targetKind = "target_kind"
        case fieldPath = "field_path"
        case valueOrigin = "value_origin"
        case reversibleBy = "reversible_by"
    }
}

public struct EffectAnalyzer: Sendable {
    private let effectKinds: [String: CapabilityEffectKindSpec]

    public init(effectKinds: [String: CapabilityEffectKindSpec] = [:]) {
        self.effectKinds = effectKinds
    }

    public func validate(capability: CapabilitySpec) throws {
        for effect in capability.effects {
            if !effectKinds.isEmpty, effectKinds[effect.id] == nil {
                throw CapabilityRegistryError.unresolvedEffectKind(verbID: capability.verbID,
                                                                   effectKindID: effect.id)
            }

            guard capability.reversible else { continue }
            switch effect.kind {
            case .submitExternalJob:
                if effect.reversibleBy == nil {
                    throw CapabilityRegistryError.invalidReversibleEffect(verbID: capability.verbID,
                                                                          effectID: effect.id)
                }
            case .replaceAsset, .deleteNode, .bakeCache:
                // These effects usually require explicit rollback verbs to preserve round-trip semantics.
                if effect.reversibleBy == nil {
                    throw CapabilityRegistryError.invalidReversibleEffect(verbID: capability.verbID,
                                                                          effectID: effect.id)
                }
            case .writeField, .createNode, .moveNode, .invalidateCache, .emitEvent:
                break
            }
        }
    }
}
