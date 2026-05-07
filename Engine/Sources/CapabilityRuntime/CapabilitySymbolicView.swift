import Foundation

public struct CapabilitySymbolicArgument: Sendable, Equatable, Codable {
    public var name: String
    public var typeID: String
    public var required: Bool
    public var unit: String?
    public var enumChoices: [String]
    public var description: String?
    public var llmHint: String?

    public init(name: String,
                typeID: String,
                required: Bool = true,
                unit: String? = nil,
                enumChoices: [String] = [],
                description: String? = nil,
                llmHint: String? = nil) {
        self.name = name
        self.typeID = typeID
        self.required = required
        self.unit = unit
        self.enumChoices = enumChoices
        self.description = description
        self.llmHint = llmHint
    }

    public init(_ argument: CapabilityArgumentSpec) {
        self.init(name: argument.name,
                  typeID: argument.typeID,
                  required: argument.required,
                  unit: argument.unit,
                  enumChoices: argument.enumChoices,
                  description: argument.description,
                  llmHint: argument.llmHint)
    }

    enum CodingKeys: String, CodingKey {
        case name
        case typeID = "type"
        case required
        case unit
        case enumChoices = "enum_choices"
        case description
        case llmHint = "llm_hint"
    }
}

public struct CapabilitySymbolicPreviewSupport: Sendable, Equatable, Codable {
    public var mode: CapabilityPreviewMode

    public init(mode: CapabilityPreviewMode) {
        self.mode = mode
    }
}

public struct CapabilitySymbolicConfirmationPolicy: Sendable, Equatable, Codable {
    public var level: CapabilityConfirmationLevel

    public init(level: CapabilityConfirmationLevel) {
        self.level = level
    }
}

public struct CapabilitySymbolicFailureMode: Sendable, Equatable, Codable {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public init(_ failureMode: CapabilityFailureMode) {
        self.init(code: failureMode.id, message: failureMode.message)
    }
}

public struct CapabilitySymbolicView: Sendable, Equatable, Codable {
    public var verbID: String
    public var summary: String
    public var scope: CapabilityScopeID
    public var targetKind: String
    public var arguments: [CapabilitySymbolicArgument]
    public var reversible: Bool
    public var previewSupport: CapabilitySymbolicPreviewSupport
    public var confirmationPolicy: CapabilitySymbolicConfirmationPolicy
    public var failureModes: [CapabilitySymbolicFailureMode]
    public var costEstimate: CapabilityCostHint?

    public init(verbID: String,
                summary: String,
                scope: CapabilityScopeID,
                targetKind: String,
                arguments: [CapabilitySymbolicArgument],
                reversible: Bool,
                previewSupport: CapabilitySymbolicPreviewSupport,
                confirmationPolicy: CapabilitySymbolicConfirmationPolicy,
                failureModes: [CapabilitySymbolicFailureMode],
                costEstimate: CapabilityCostHint? = nil) {
        self.verbID = verbID
        self.summary = summary
        self.scope = scope
        self.targetKind = targetKind
        self.arguments = arguments
        self.reversible = reversible
        self.previewSupport = previewSupport
        self.confirmationPolicy = confirmationPolicy
        self.failureModes = failureModes
        self.costEstimate = costEstimate
    }

    public init(_ capability: CapabilitySpec) {
        self.init(verbID: capability.verbID,
                  summary: capability.summary,
                  scope: capability.scope,
                  targetKind: capability.targetKind,
                  arguments: capability.arguments
                    .filter { !$0.redactInPrompt }
                    .map(CapabilitySymbolicArgument.init),
                  reversible: capability.reversible,
                  previewSupport: CapabilitySymbolicPreviewSupport(mode: capability.previewSupport.mode),
                  confirmationPolicy: CapabilitySymbolicConfirmationPolicy(level: capability.confirmationPolicy.level),
                  failureModes: capability.failureModes.map(CapabilitySymbolicFailureMode.init),
                  costEstimate: capability.costEstimate)
    }

    enum CodingKeys: String, CodingKey {
        case verbID = "verb_id"
        case summary
        case scope
        case targetKind = "target_kind"
        case arguments
        case reversible
        case previewSupport = "preview_support"
        case confirmationPolicy = "confirmation_policy"
        case failureModes = "failure_modes"
        case costEstimate = "cost_estimate"
    }
}

public extension CapabilityRegistry {
    func promptSymbolicViews(for context: CapabilityQueryContext,
                             maxCount: Int? = nil) -> [CapabilitySymbolicView] {
        let views = defaultPromptCapabilities(for: context)
            .map(CapabilitySymbolicView.init)

        guard let maxCount else {
            return views
        }
        return Array(views.prefix(max(0, maxCount)))
    }
}
