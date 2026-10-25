import Foundation

/// Puts one of the package's own commands into a host menu, after the host's items.
public struct MenuContribution: Codable, Sendable, Equatable {
    /// A `guava.command/v1` identifier of the same package.
    public var command: String
    /// `file`, `edit`, `select`, `world`, `view`, `agent`, `run`, `window` or `help`.
    public var menu: String

    public init(command: String, menu: String) {
        self.command = command
        self.menu = menu
    }

    public static let menus: Set<String> = ["file", "edit", "select", "world", "view", "agent", "run", "window", "help"]
}

public enum MenuContributionPoint: ContributionPointSpec {
    public static let id = "guava.ui.menu/v1"

    public static func validate(_ item: MenuContribution, host: PluginHostPermissions) throws {
        guard ContributionValidation.identifier(item.command), MenuContribution.menus.contains(item.menu) else {
            throw PluginManifestValidationError.invalidContribution(id)
        }
    }
}

/// Puts one of the package's own commands on the title bar as an icon button;
/// the command's title is the tooltip.
public struct ToolbarContribution: Codable, Sendable, Equatable {
    /// A `guava.command/v1` identifier of the same package.
    public var command: String
    /// The name of one of the host's toolbar icons.
    public var icon: String

    public init(command: String, icon: String) {
        self.command = command
        self.icon = icon
    }
}

public enum ToolbarContributionPoint: ContributionPointSpec {
    public static let id = "guava.ui.toolbar/v1"

    public static func validate(_ item: ToolbarContribution, host: PluginHostPermissions) throws {
        guard ContributionValidation.identifier(item.command),
              item.icon.range(of: #"^[a-z0-9_-]{1,64}$"#, options: .regularExpression) != nil else {
            throw PluginManifestValidationError.invalidContribution(id)
        }
    }
}
