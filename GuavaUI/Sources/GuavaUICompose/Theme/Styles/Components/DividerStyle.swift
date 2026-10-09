import GuavaUIRuntime

public enum DividerOrientation: Sendable, Equatable {
    case horizontal, vertical
}

public struct DividerStyleConfiguration {
    public let orientation: DividerOrientation
    public let thickness: Float
    public let theme: Theme
}

public protocol DividerStyle {
    associatedtype Body: View
    @ViewBuilder
    func makeBody(configuration: DividerStyleConfiguration) -> Body
}

public struct AnyDividerStyle: @unchecked Sendable {
    public let makeBody: (DividerStyleConfiguration) -> any View
    public init<S: DividerStyle>(_ style: S) {
        self.makeBody = { config in style.makeBody(configuration: config) }
    }
}

public enum DividerStyleEnvironment {
    public static let key = CompositionLocal<AnyDividerStyle>(
        defaultValue: AnyDividerStyle(DefaultDividerStyle())
    )
}

public extension View {
    func dividerStyle<S: DividerStyle>(_ style: S) -> some View {
        compositionLocal(DividerStyleEnvironment.key, AnyDividerStyle(style))
    }
}

public extension DividerStyle where Self == DefaultDividerStyle {
    static var `default`: DefaultDividerStyle { DefaultDividerStyle() }
}
