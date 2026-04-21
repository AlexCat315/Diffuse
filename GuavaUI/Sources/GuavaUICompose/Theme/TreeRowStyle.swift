import GuavaUIRuntime

public struct TreeRowStyleConfiguration {
    public let content: AnyView
    public let depth: Int
    public let indentation: Float
    public let disclosureWidth: Float
    public let hasChildren: Bool
    public let isExpanded: Bool
    public let isSelected: Bool
    public let isHovered: Bool
    public let isEnabled: Bool
    public let theme: Theme
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
