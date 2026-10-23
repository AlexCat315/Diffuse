import Foundation

/// What an AI package adds to the editor. A package that contributes an agent
/// owns the assistant surface: when it is disabled, its panels and commands
/// disappear with it. The host still owns transport and credentials.
public struct AgentContribution: Codable, Sendable, Equatable {
    /// A panel the package adds to the workbench.
    public struct Panel: Codable, Sendable, Equatable {
        public var id: String
        public var title: String
        public var slot: String?
        public var icon: String?

        public init(id: String, title: String, slot: String? = nil, icon: String? = nil) {
            self.id = id
            self.title = title
            self.slot = slot
            self.icon = icon
        }
    }

    public var id: String
    public var title: String
    public var panels: [Panel]
    public var defaultModel: String?
    public var canAutoApprove: Bool?

    public init(id: String, title: String, panels: [Panel] = [],
                defaultModel: String? = nil, canAutoApprove: Bool? = nil) {
        self.id = id
        self.title = title
        self.panels = panels
        self.defaultModel = defaultModel
        self.canAutoApprove = canAutoApprove
    }
}

public enum AgentContributionPoint: ContributionPointSpec {
    public static let id = "guava.agent/v1"

    public static func validate(_ agent: AgentContribution, host: PluginHostPermissions) throws {
        guard ContributionValidation.identifier(agent.id), ContributionValidation.title(agent.title),
              agent.panels.count <= 8,
              Set(agent.panels.map(\.id)).count == agent.panels.count,
              agent.panels.allSatisfy({ panel in
                  ContributionValidation.identifier(panel.id) && ContributionValidation.title(panel.title)
                      && panel.slot.map({ ["leading", "center", "trailing", "bottom"].contains($0) }) ?? true
                      && panel.icon.map({ $0.range(of: #"^[a-z0-9_-]{1,64}$"#, options: .regularExpression) != nil }) ?? true
              }),
              agent.defaultModel.map({ !$0.isEmpty && $0.count <= 80 }) ?? true else {
            throw PluginManifestValidationError.invalidContribution(id)
        }
    }
}
