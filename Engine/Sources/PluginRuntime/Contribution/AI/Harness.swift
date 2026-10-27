import Foundation

/// A turn loop a package offers to agents. Its entry point says what the
/// session does next; the host calls the model, runs tools and keeps every
/// approval.
public struct AIHarnessContribution: Codable, Sendable, Equatable {
    /// Unique among enabled packages; agents name it in `harness`.
    public var id: String
    public var title: String
    /// `func(input: record { turn: string }) -> string`.
    public var entryPoint: String

    public init(id: String, title: String, entryPoint: String) {
        self.id = id
        self.title = title
        self.entryPoint = entryPoint
    }
}

public enum AIHarnessContributionPoint: ContributionPointSpec {
    public static let id = "cove.ai.harness/v1"

    public static func validate(_ harness: AIHarnessContribution, host: PluginHostPermissions) throws {
        guard ContributionValidation.identifier(harness.id), ContributionValidation.title(harness.title),
              ContributionValidation.identifier(harness.entryPoint) else {
            throw PluginManifestValidationError.invalidContribution(id)
        }
    }

    public static func validateRuntime(_ harness: AIHarnessContribution, contract: PluginContract?) throws {
        guard contract?.capabilityInputs.first(where: { $0.name == harness.entryPoint })?.inputType == harnessInputType else {
            throw PluginManifestValidationError.invalidContribution(id)
        }
    }
}

/// `record { turn: string }`: the step's input as JSON.
let harnessInputType = PluginInputType.record([PluginInputField(name: "turn", type: .string)])
