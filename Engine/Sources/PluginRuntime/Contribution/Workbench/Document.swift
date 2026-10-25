import Foundation

/// Another way to show a text document. The editor keeps the text and offers
/// the view beside it; the entry point serves it through the view protocol,
/// with the path and current text as context.
public struct DocumentViewContribution: Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    /// File extensions the view applies to, without the dot.
    public var extensions: [String]
    /// `func(input: record { view: string, state: string, event: string, context: string }) -> string`.
    public var entryPoint: String

    public init(id: String, title: String, extensions: [String], entryPoint: String) {
        self.id = id
        self.title = title
        self.extensions = extensions
        self.entryPoint = entryPoint
    }

    /// The largest document text the host hands to a view; with JSON escaping
    /// the context stays within the runtime's 65 536-character string inputs.
    public static let maximumTextBytes = 48 * 1_024
}

public enum DocumentViewContributionPoint: ContributionPointSpec {
    public static let id = "guava.ui.documentView/v1"

    public static func validate(_ view: DocumentViewContribution, host: PluginHostPermissions) throws {
        guard ContributionValidation.identifier(view.id), ContributionValidation.title(view.title),
              !view.extensions.isEmpty, view.extensions.count <= 16,
              Set(view.extensions).count == view.extensions.count,
              view.extensions.allSatisfy({ $0.range(of: #"^[a-z0-9_+-]{1,16}$"#, options: .regularExpression) != nil }),
              ContributionValidation.identifier(view.entryPoint) else {
            throw PluginManifestValidationError.invalidContribution(id)
        }
    }

    public static func validateRuntime(_ view: DocumentViewContribution, contract: WITContract?) throws {
        guard contract?.capabilityInputs.first(where: { $0.name == view.entryPoint })?.inputType == viewInputType else {
            throw PluginManifestValidationError.invalidContribution(id)
        }
    }
}
