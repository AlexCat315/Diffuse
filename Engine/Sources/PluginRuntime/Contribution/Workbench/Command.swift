import Foundation

/// A command a package adds to the command palette and to its own panels. The
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
    /// False keeps a command that needs arguments, such as one row's action, out of the palette.
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
    public static let id = "guava.command/v1"

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

/// What the host does after a command ran. Every field is optional; an empty
/// object means the command finished with nothing to show.
public struct PluginCommandResult: Codable, Sendable, Equatable {
    /// Shown as a notification.
    public var message: String?
    /// Shown as a failure notification.
    public var error: String?
    /// One of the package's own panels to bring forward.
    public var panel: String?

    public init(message: String? = nil, error: String? = nil, panel: String? = nil) {
        self.message = message
        self.error = error
        self.panel = panel
    }

    /// Reads the JSON text a command entry point returned. `panels` are the
    /// package's own panel identifiers.
    public init(json: String, panels: Set<String>) throws {
        guard json.utf8.count <= 16 * 1_024,
              let result = try? JSONDecoder().decode(Self.self, from: Data(json.utf8)),
              result.message.map(PanelModel.isText) ?? true,
              result.error.map(PanelModel.isText) ?? true,
              result.panel.map(panels.contains) ?? true else {
            throw PluginWorkbenchResultError.invalidCommandResult
        }
        self = result
    }
}

public enum PluginWorkbenchResultError: Error, Sendable, Equatable, LocalizedError {
    case invalidCommandResult
    case invalidPanel

    public var errorDescription: String? {
        switch self {
        case .invalidCommandResult: "The plugin returned a command result the editor cannot use."
        case .invalidPanel: "The plugin returned panel content the editor cannot show."
        }
    }
}

/// `record { command: string, arguments: string }`: the command's identifier
/// and its arguments as a JSON object.
let commandInputType = WITValueType.record([WITRecordField(name: "command", type: .string),
                                            WITRecordField(name: "arguments", type: .string)])
