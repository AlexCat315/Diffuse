public import Foundation

public struct PluginServiceContribution: Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var entryPoint: String
}
public enum PluginServiceContributionPoint: ContributionPointSpec {
    public static let id = "cove.service/v1"
    public static func validate(_ value: PluginServiceContribution, host: PluginHostPermissions) throws {
        guard validExtensionID(value.id), ContributionValidation.title(value.title), ContributionValidation.identifier(value.entryPoint) else {
            throw PluginManifestValidationError.invalidContribution(id)
        }
    }
    public static func validateRuntime(_ value: PluginServiceContribution, contract: PluginContract?) throws {
        guard contract?.capabilityInputs.contains(where: { $0.name == value.entryPoint && $0.inputType == .record([PluginInputField(name: "request", type: .string)]) }) == true else {
            throw PluginManifestValidationError.invalidContribution(id)
        }
    }
}
public struct PluginExtensionPointContribution: Codable, Sendable, Equatable {
    public var id: String
    public var title: String
}
public enum PluginExtensionPointContributionPoint: ContributionPointSpec {
    public static let id = "cove.extensionPoint/v1"
    public static func validate(_ value: PluginExtensionPointContribution, host: PluginHostPermissions) throws {
        guard validExtensionID(value.id), ContributionValidation.title(value.title) else { throw PluginManifestValidationError.invalidContribution(id) }
    }
}
public struct PluginExtensionContribution: Codable, Sendable, Equatable {
    public var id: String
    public var point: String
    public var data: PluginJSON
}
public enum PluginExtensionContributionPoint: ContributionPointSpec {
    public static let id = "cove.extension/v1"
    public static func validate(_ value: PluginExtensionContribution, host: PluginHostPermissions) throws {
        guard ContributionValidation.identifier(value.id), validExtensionID(value.point),
              (try JSONEncoder().encode(value.data)).count <= 65_536 else { throw PluginManifestValidationError.invalidContribution(id) }
    }
}
private func validExtensionID(_ value: String) -> Bool {
    value.range(of: #"^[a-z][a-z0-9.-]{2,95}/v[1-9][0-9]*$"#, options: .regularExpression) != nil
}
