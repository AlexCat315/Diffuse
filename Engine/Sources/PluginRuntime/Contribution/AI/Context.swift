import Foundation

/// Text a package adds to an agent's context. Only agents that list the source
/// receive it; the host bounds its size and sends it with the request.
public struct AIContextContribution: Codable, Sendable, Equatable {
    /// Unique among enabled packages; agents name it in their `context`.
    public var id: String
    public var title: String
    /// `func(input: record { workspace: string, selection: string }) -> string`,
    /// or a step-protocol entry point that serves the `context` operation.
    public var entryPoint: String
    /// Longer text is cut to this many UTF-8 bytes; 4 KiB when absent.
    public var maxBytes: Int?

    public init(id: String, title: String, entryPoint: String, maxBytes: Int? = nil) {
        self.id = id
        self.title = title
        self.entryPoint = entryPoint
        self.maxBytes = maxBytes
    }

    public var byteLimit: Int { maxBytes ?? 4 * 1_024 }
}

public enum AIContextContributionPoint: ContributionPointSpec {
    public static let id = "cove.ai.context/v1"

    public static func validate(_ context: AIContextContribution, host: PluginHostPermissions) throws {
        guard ContributionValidation.identifier(context.id), ContributionValidation.title(context.title),
              ContributionValidation.identifier(context.entryPoint),
              context.maxBytes.map({ (1...16 * 1_024).contains($0) }) ?? true else {
            throw PluginManifestValidationError.invalidContribution(id)
        }
    }

    /// A context entry point is either a plain call, or a step-protocol entry
    /// point whose commands the editor runs under the package's process permission.
    public static func validateRuntime(_ context: AIContextContribution, contract: WITContract?) throws {
        let inputType = contract?.capabilityInputs.first(where: { $0.name == context.entryPoint })?.inputType
        guard inputType == aiContextInputType || inputType == stepInputType else {
            throw PluginManifestValidationError.invalidContribution(id)
        }
    }
}

/// `record { content: string, selection: string }`: what the window centers on and
/// the selected scene references as a JSON array.
let aiContextInputType = WITValueType.record([WITRecordField(name: "content", type: .string),
                                              WITRecordField(name: "selection", type: .string)])
