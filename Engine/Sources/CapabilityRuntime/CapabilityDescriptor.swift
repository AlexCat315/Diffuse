import Foundation

/// The maturity stage a capability must reach before it is available to callers.
///
/// Ordered from most restricted to least restricted so that `>=` comparisons
/// express "at least this mature":
///   disabled < experimental < beta < stable
public enum CapabilityReleasePhase: String, Sendable, Codable, Comparable, CaseIterable {
    case disabled     = "disabled"
    case experimental = "experimental"
    case beta         = "beta"
    case stable       = "stable"

    private var order: Int {
        switch self {
        case .disabled:     return 0
        case .experimental: return 1
        case .beta:         return 2
        case .stable:       return 3
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.order < rhs.order
    }
}

/// A single precondition that must hold before a capability may be invoked.
public struct CapabilityPreconditionSpec: Sendable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable, Equatable {
        /// At least one target entity (from targetObjectIDs or selectedEntityID) must
        /// exist in the live scene.
        case entityExists = "entity_exists"
        /// At least one entity must be selected or listed as a target.
        case selectionRequired = "selection_required"
        /// A named argument must be present in the IntentIR argument map.
        case argumentPresent = "argument_present"
        /// The scene must be in an editable state (not locked by playback, etc.).
        case sceneEditable = "scene_editable"
        /// The target entity must carry a specific component, represented by type name.
        case entityHasComponent = "entity_has_component"
    }

    public var kind: Kind
    /// For `.argumentPresent`: the argument key that must exist.
    public var argumentName: String?
    /// For `.entityHasComponent`: the component type name (e.g. "RigidBody").
    public var componentType: String?

    public init(kind: Kind,
                argumentName: String? = nil,
                componentType: String? = nil) {
        self.kind = kind
        self.argumentName = argumentName
        self.componentType = componentType
    }
}

/// Static description of one capability registered in the system.
public struct CapabilityDescriptor: Sendable, Codable, Equatable {
    /// The intent verb this descriptor covers (e.g. `"scene.spawn_entity"`).
    public var verb: String
    /// Additional verb strings that map to this descriptor.
    public var aliases: [String]
    /// Minimum maturity stage required to invoke this capability.
    public var releasePhase: CapabilityReleasePhase
    /// Whether the coordinator must request user confirmation before applying.
    public var requiresConfirmation: Bool
    /// Whether applying this capability can cause data loss (triggers destructive
    /// styling in the confirmation UI).
    public var isDestructive: Bool
    /// The primary domain the capability operates on ("scene", "sequence", "asset").
    public var domain: String
    /// Ordered list of preconditions that must pass before building a TransactionIR.
    public var preconditions: [CapabilityPreconditionSpec]

    public init(verb: String,
                aliases: [String] = [],
                releasePhase: CapabilityReleasePhase = .stable,
                requiresConfirmation: Bool = false,
                isDestructive: Bool = false,
                domain: String = "scene",
                preconditions: [CapabilityPreconditionSpec] = []) {
        self.verb = verb
        self.aliases = aliases
        self.releasePhase = releasePhase
        self.requiresConfirmation = requiresConfirmation
        self.isDestructive = isDestructive
        self.domain = domain
        self.preconditions = preconditions
    }

    public var requiredArgumentNames: Set<String> {
        Set(preconditions.compactMap { spec in
            spec.kind == .argumentPresent ? spec.argumentName : nil
        })
    }

    public var requiredComponentTypes: Set<String> {
        Set(preconditions.compactMap { spec in
            spec.kind == .entityHasComponent ? spec.componentType : nil
        })
    }

    public var requiresTargetEntity: Bool {
        preconditions.contains { spec in
            switch spec.kind {
            case .entityExists, .selectionRequired, .entityHasComponent:
                return true
            case .argumentPresent, .sceneEditable:
                return false
            }
        }
    }
}
