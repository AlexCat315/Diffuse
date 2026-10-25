import Foundation

/// A workbench panel a package adds. The host owns the panel's frame, tab,
/// focus and layout; the package chooses what fills it, either a view the host
/// provides or a component tree its entry point returns.
public struct PanelContribution: Codable, Sendable, Equatable {
    public enum Content: Sendable, Equatable {
        /// A view the host provides, such as `agent`.
        case view(String)
        /// A capability that serves the panel through the view protocol:
        /// `func(input: record { view: string, state: string, event: string, context: string }) -> string`.
        case entryPoint(String)
    }

    /// Unique among enabled packages; layouts persist it.
    public var id: String
    public var title: String
    /// `leading`, `center`, `trailing` or `bottom`; trailing when absent.
    public var slot: String?
    /// The name of one of the host's panel icons.
    public var icon: String?
    public var view: String?
    public var entryPoint: String?

    public init(id: String, title: String, slot: String? = nil, icon: String? = nil, content: Content) {
        self.id = id
        self.title = title
        self.slot = slot
        self.icon = icon
        switch content {
        case let .view(view): self.view = view
        case let .entryPoint(entryPoint): self.entryPoint = entryPoint
        }
    }

    /// Validation guarantees exactly one of `view` and `entryPoint`.
    public var content: Content {
        if let entryPoint { return .entryPoint(entryPoint) }
        return .view(view ?? "")
    }
}

public enum PanelContributionPoint: ContributionPointSpec {
    public static let id = "guava.ui.panel/v1"

    public static func validate(_ panel: PanelContribution, host: PluginHostPermissions) throws {
        guard ContributionValidation.identifier(panel.id), ContributionValidation.title(panel.title),
              panel.slot.map({ ["leading", "center", "trailing", "bottom"].contains($0) }) ?? true,
              panel.icon.map({ $0.range(of: #"^[a-z0-9_-]{1,64}$"#, options: .regularExpression) != nil }) ?? true,
              (panel.view == nil) != (panel.entryPoint == nil),
              panel.view.map({ $0.range(of: #"^[a-z][a-z0-9.-]{0,63}$"#, options: .regularExpression) != nil }) ?? true,
              panel.entryPoint.map(ContributionValidation.identifier) ?? true else {
            throw PluginManifestValidationError.invalidContribution(id)
        }
    }

    public static func validateRuntime(_ panel: PanelContribution, contract: WITContract?) throws {
        guard case let .entryPoint(entryPoint) = panel.content else { return }
        guard contract?.capabilityInputs.first(where: { $0.name == entryPoint })?.inputType == viewInputType else {
            throw PluginManifestValidationError.invalidContribution(id)
        }
    }
}
