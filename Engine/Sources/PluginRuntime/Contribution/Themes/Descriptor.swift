import Foundation

public struct ThemeContribution: Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var appearance: String
    public var path: String

    public init(id: String, title: String, appearance: String = "dual", path: String) {
        self.id = id
        self.title = title
        self.appearance = appearance
        self.path = path
    }
}

public enum ThemeContributionPoint: ContributionPointSpec {
    public static let id = "guava.theme/v1"

    public static func validate(_ descriptor: ThemeContribution, host: PluginHostPermissions) throws {
        guard descriptor.id.range(of: #"^[a-z][a-z0-9.-]{2,63}$"#, options: .regularExpression) != nil,
              ContributionValidation.title(descriptor.title),
              ["light", "dark", "dual"].contains(descriptor.appearance),
              PluginResource.isValidPath(descriptor.path) else {
            throw PluginManifestValidationError.invalidContribution(id)
        }
    }
}

