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

public struct AnyTreeRowStyle: @unchecked Sendable {
    public let makeBody: (TreeRowStyleConfiguration) -> any View
    public init<S: TreeRowStyle>(_ style: S) {
        self.makeBody = { config in style.makeBody(configuration: config) }
    }
}

public enum TreeRowStyleEnvironment {
    public static let key = CompositionLocal<AnyTreeRowStyle>(
        defaultValue: AnyTreeRowStyle(DefaultTreeRowStyle())
    )
}

public extension View {
    func treeRowStyle<S: TreeRowStyle>(_ style: S) -> some View {
        compositionLocal(TreeRowStyleEnvironment.key, AnyTreeRowStyle(style))
    }
}

public extension TreeRowStyle where Self == DefaultTreeRowStyle {
    static var `default`: DefaultTreeRowStyle { DefaultTreeRowStyle() }
}
