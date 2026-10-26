import Foundation

/// A command a package adds to the command palette, menus and toolbar. The
/// host calls the entry point with the command's identifier and arguments, and
/// carries out the result the plugin returns.
public struct CommandContribution: Codable, Sendable, Equatable {
    /// Unique within the package; the host qualifies it with the package ID.
    public var id: String
    public var title: String
    /// Extra words the palette matches, such as synonyms or translations.
    public var keywords: String?
    /// The capability that runs the command: `func(input: record { command: string, arguments: string }) -> string`.
    public var entryPoint: String
    /// False keeps a command out of the palette, for one that only menus or other commands use.
    public var palette: Bool?

    public init(id: String, title: String, keywords: String? = nil, entryPoint: String, palette: Bool? = nil) {
        self.id = id
        self.title = title
        self.keywords = keywords
        self.entryPoint = entryPoint
        self.palette = palette
    }
}

public enum CommandContributionPoint: ContributionPointSpec {
    public static let id = "cove.command/v1"

    public static func validate(_ command: CommandContribution, host: PluginHostPermissions) throws {
        guard ContributionValidation.identifier(command.id), ContributionValidation.title(command.title),
              command.keywords.map({ $0.count <= 160 }) ?? true,
              ContributionValidation.identifier(command.entryPoint) else {
            throw PluginManifestValidationError.invalidContribution(id)
        }
    }

    public static func validateRuntime(_ command: CommandContribution, contract: WITContract?) throws {
        guard contract?.capabilityInputs.first(where: { $0.name == command.entryPoint })?.inputType == commandInputType else {
            throw PluginManifestValidationError.invalidContribution(id)
        }
    }
}

/// What a command entry point returns: the effects for the host to carry out.
public struct PluginCommandResult: Sendable, Equatable {
    public var effects: [UIEffect]

    public init(effects: [UIEffect] = []) {
        self.effects = effects
    }

    /// Reads the JSON object a command entry point returned. `panels` are the
    /// package's own panel identifiers.
    public init(json: Data, panels: Set<String>) throws {
        struct Coding: Decodable { var effects: [UIEffect]? }
        guard json.count <= 64 * 1_024, let decoded = try? JSONDecoder().decode(Coding.self, from: json),
              (decoded.effects ?? []).count <= 16,
              (decoded.effects ?? []).allSatisfy({ $0.isValid(panels: panels) }) else {
            throw PluginWorkbenchResultError.invalidCommandResult
        }
        effects = decoded.effects ?? []
    }
}

public enum PluginWorkbenchResultError: Error, Sendable, Equatable, LocalizedError {
    case invalidCommandResult
    case invalidView

    public var errorDescription: String? {
        switch self {
        case .invalidCommandResult: "The plugin returned a command result the editor cannot use."
        case .invalidView: "The plugin returned a view the editor cannot show."
        }
    }
}

/// `record { command: string, arguments: string }`: the command's identifier
/// and its arguments as a JSON object.
let commandInputType = WITValueType.record([WITRecordField(name: "command", type: .string),
                                            WITRecordField(name: "arguments", type: .string)])
