import Foundation

/// An agent profile: how the host's session behaves for this agent. It is
/// configuration only; the host runs the session, the tools and every approval.
public struct AgentContribution: Codable, Sendable, Equatable {
    public struct ModelPolicy: Codable, Sendable, Equatable {
        /// Used when the selected provider offers it and the user chose no model.
        public var preferred: String?
        /// Caps the provider model's own output limit.
        public var maxOutputTokens: Int?

        public init(preferred: String? = nil, maxOutputTokens: Int? = nil) {
            self.preferred = preferred
            self.maxOutputTokens = maxOutputTokens
        }
    }

    public var id: String
    public var title: String
    /// Added to the host's own instructions, never replacing them.
    public var instructions: String?
    public var model: ModelPolicy?
    /// Tool names the agent may call: host tools, capability IDs and package
    /// tools. Absent means every tool the workspace allows.
    public var tools: [String]?
    /// Context the agent sees: host sources (`scene`, `selection`, `edits`,
    /// `memory`, `transactions`, `workflow`, `assets`) and `cove.ai.context/v1`
    /// IDs. Absent means every host source and no package context.
    public var context: [String]?
    /// False keeps writes on review even when the user turned automatic approval on.
    public var canAutoApprove: Bool?
    /// A `cove.ai.harness/v1` that runs the agent's turns; the host's loop when absent.
    public var harness: String?

    public init(id: String, title: String, instructions: String? = nil, model: ModelPolicy? = nil,
                tools: [String]? = nil, context: [String]? = nil, canAutoApprove: Bool? = nil, harness: String? = nil) {
        self.id = id
        self.title = title
        self.instructions = instructions
        self.model = model
        self.tools = tools
        self.context = context
        self.canAutoApprove = canAutoApprove
        self.harness = harness
    }
}

public enum AgentContributionPoint: ContributionPointSpec {
    public static let id = "cove.ai.agent/v1"

    public static func validate(_ agent: AgentContribution, host: PluginHostPermissions) throws {
        guard ContributionValidation.identifier(agent.id), ContributionValidation.title(agent.title),
              agent.instructions.map({ !$0.isEmpty && $0.count <= 8_000 }) ?? true,
              agent.model?.preferred.map({ !$0.isEmpty && $0.count <= 80 }) ?? true,
              agent.model?.maxOutputTokens.map({ $0 > 0 }) ?? true,
              agent.tools.map({ tools in
                  tools.count <= 256 && Set(tools).count == tools.count
                      && tools.allSatisfy { $0.range(of: #"^[a-z][a-z0-9_.-]{0,127}$"#, options: .regularExpression) != nil }
              }) ?? true,
              agent.context.map({ sources in
                  sources.count <= 32 && Set(sources).count == sources.count
                      && sources.allSatisfy(ContributionValidation.identifier)
              }) ?? true,
              agent.harness.map(ContributionValidation.identifier) ?? true else {
            throw PluginManifestValidationError.invalidContribution(id)
        }
    }
}
