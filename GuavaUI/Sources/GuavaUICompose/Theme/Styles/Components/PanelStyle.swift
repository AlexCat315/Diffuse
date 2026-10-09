import GuavaUIRuntime

public struct PanelStyleConfiguration {
    public let title: String
    public let accessory: AnyView
    public let content: AnyView
    public let isActive: Bool
    public let theme: Theme
}

public protocol PanelStyle {
    associatedtype Body: View
    @ViewBuilder
    func makeBody(configuration: PanelStyleConfiguration) -> Body
}

public struct AnyPanelStyle: @unchecked Sendable {
    public let makeBody: (PanelStyleConfiguration) -> any View
    public init<S: PanelStyle>(_ style: S) {
        self.makeBody = { config in style.makeBody(configuration: config) }
    }
}

public enum PanelStyleEnvironment {
    public static let key = CompositionLocal<AnyPanelStyle>(
        defaultValue: AnyPanelStyle(DefaultPanelStyle())
    )
}

public extension View {
    func panelStyle<S: PanelStyle>(_ style: S) -> some View {
        compositionLocal(PanelStyleEnvironment.key, AnyPanelStyle(style))
    }
}

public extension PanelStyle where Self == DefaultPanelStyle {
    static var `default`: DefaultPanelStyle { DefaultPanelStyle() }
}
