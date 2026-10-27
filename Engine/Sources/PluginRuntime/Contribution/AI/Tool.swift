import Foundation

/// Offers one of the package's capabilities to the model. A capability no tool
/// names stays with the editor. Calls still go through the capability's
/// permissions, drafts and approvals.
public struct AIToolContribution: Codable, Sendable, Equatable {
    /// The capability in `capabilities.wit`.
    public var entryPoint: String
    public var title: String
    /// What the model reads when deciding whether to call it.
    public var description: String

    public init(entryPoint: String, title: String, description: String) {
        self.entryPoint = entryPoint
        self.title = title
        self.description = description
    }
}

public enum AIToolContributionPoint: ContributionPointSpec {
    public static let id = "cove.ai.tool/v1"

    public static func validate(_ tool: AIToolContribution, host: PluginHostPermissions) throws {
        guard ContributionValidation.identifier(tool.entryPoint), tool.entryPoint != "components",
              !host.entryPoints.contains(tool.entryPoint),
              ContributionValidation.title(tool.title),
              !tool.description.isEmpty, tool.description.count <= 1_024 else {
            throw PluginManifestValidationError.invalidContribution(id)
        }
    }

    public static func validateRuntime(_ tool: AIToolContribution, contract: PluginContract?) throws {
        guard contract?.capabilityInputs.contains(where: { $0.name == tool.entryPoint }) == true else {
            throw PluginManifestValidationError.invalidContribution(id)
        }
    }
}
