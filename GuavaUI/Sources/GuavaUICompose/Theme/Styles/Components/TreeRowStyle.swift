import GuavaUIRuntime

public struct TreeRowStyleConfiguration {
    public let content: AnyView
    public let depth: Int
    public let indentation: Float
    public let disclosureWidth: Float
    public let hasChildren: Bool
    public let isExpanded: Bool
    public let isSearchHit: Bool
    public let isSelected: Bool
    public let isHovered: Bool
    public let isEnabled: Bool
    public let theme: Theme
}

/// Equatable interaction snapshot used by built-in tree row styles to key
/// implicit transitions.
public struct _TreeRowInteractionKey: Equatable, Sendable {
    public let isSearchHit: Bool
    public let isSelected: Bool
    public let isHovered: Bool
    public let isEnabled: Bool
}

public extension TreeRowStyleConfiguration {
    var interactionKey: _TreeRowInteractionKey {
        _TreeRowInteractionKey(
            isSearchHit: isSearchHit,
            isSelected: isSelected,
            isHovered: isHovered,
            isEnabled: isEnabled
        )
    }
}

public protocol TreeRowStyle {
    associatedtype Body: View
    @ViewBuilder
    func makeBody(configuration: TreeRowStyleConfiguration) -> Body
}

public enum TreeRowStyleScope: Sendable {
    /// Leave the disclosure, indentation and trailing controls outside the style.
    case content
    /// Style the whole row while preserving the slots' own input handling.
    case row
}

public struct AnyTreeRowStyle: @unchecked Sendable {
    public let makeBody: (TreeRowStyleConfiguration) -> any View
    public let requiresHoverRecompose: Bool
    public let scope: TreeRowStyleScope

    public init<S: TreeRowStyle>(_ style: S, scope: TreeRowStyleScope = .content) {
        self.makeBody = { config in style.makeBody(configuration: config) }
        self.requiresHoverRecompose = !(style is DefaultTreeRowStyle)
        self.scope = scope
    }
}

public enum TreeRowStyleEnvironment {
    public static let key = CompositionLocal<AnyTreeRowStyle>(
        defaultValue: AnyTreeRowStyle(DefaultTreeRowStyle())
    )
}

public extension View {
    func treeRowStyle<S: TreeRowStyle>(_ style: S, scope: TreeRowStyleScope = .content) -> some View {
        compositionLocal(TreeRowStyleEnvironment.key, AnyTreeRowStyle(style, scope: scope))
    }
}

public extension TreeRowStyle where Self == DefaultTreeRowStyle {
    static var `default`: DefaultTreeRowStyle { DefaultTreeRowStyle() }
}
