import GuavaUIRuntime

public struct ListRowStyleConfiguration {
    /// User-supplied row content (the closure body of `List`'s `rowContent`).
    public let content: AnyView
    public let isSelected: Bool
    public let isHovered: Bool
    public let isEnabled: Bool
    public let theme: Theme
}

public protocol ListRowStyle {
    associatedtype Body: View
    @ViewBuilder
    func makeBody(configuration: ListRowStyleConfiguration) -> Body
}

public struct AnyListRowStyle: @unchecked Sendable {
    public let makeBody: (ListRowStyleConfiguration) -> any View
    public init<S: ListRowStyle>(_ style: S) {
        self.makeBody = { config in style.makeBody(configuration: config) }
    }
}

public enum ListRowStyleEnvironment {
    public static let key = CompositionLocal<AnyListRowStyle>(
        defaultValue: AnyListRowStyle(DefaultListRowStyle())
    )
}

public extension View {
    func listRowStyle<S: ListRowStyle>(_ style: S) -> some View {
        compositionLocal(ListRowStyleEnvironment.key, AnyListRowStyle(style))
    }
}

public extension ListRowStyle where Self == DefaultListRowStyle {
    static var `default`: DefaultListRowStyle { DefaultListRowStyle() }
}
