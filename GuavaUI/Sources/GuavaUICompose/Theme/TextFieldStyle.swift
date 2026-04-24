import GuavaUIRuntime

/// Snapshot passed to `TextFieldStyle.makeBody` on every recompose. The
/// `content` slot is the type-erased visual produced by `TextField` itself —
/// styles wrap it with chrome (background, border, focus ring) instead of
/// owning the input pipeline.
public struct TextFieldStyleConfiguration {
    /// The actual editable surface. Step 8 will route the `TextField`
    /// primitive's draw/measure callbacks through this slot.
    public let content: AnyView
    public let placeholder: String
    public let isFocused: Bool
    public let isEditing: Bool
    public let isError: Bool
    public let isEnabled: Bool
    public let theme: Theme
}

/// Equatable interaction snapshot used by built-in text field styles to key
/// implicit transitions.
public struct _TextFieldInteractionKey: Equatable, Sendable {
    public let isFocused: Bool
    public let isEditing: Bool
    public let isError: Bool
    public let isEnabled: Bool
}

public extension TextFieldStyleConfiguration {
    var interactionKey: _TextFieldInteractionKey {
        _TextFieldInteractionKey(
            isFocused: isFocused,
            isEditing: isEditing,
            isError: isError,
            isEnabled: isEnabled
        )
    }
}

public protocol TextFieldStyle {
    associatedtype Body: View
    @ViewBuilder
    func makeBody(configuration: TextFieldStyleConfiguration) -> Body
}

/// Type-erased style ferried through `TextFieldStyleEnvironment`. See
/// `AnyButtonStyle` for the rationale behind `@unchecked Sendable`.
public struct AnyTextFieldStyle: @unchecked Sendable {
    public let makeBody: (TextFieldStyleConfiguration) -> any View
    public init<S: TextFieldStyle>(_ style: S) {
        self.makeBody = { config in style.makeBody(configuration: config) }
    }
}

public enum TextFieldStyleEnvironment {
    public static let key = CompositionLocal<AnyTextFieldStyle>(
        defaultValue: AnyTextFieldStyle(DefaultTextFieldStyle())
    )
}

public extension View {
    func textFieldStyle<S: TextFieldStyle>(_ style: S) -> some View {
        compositionLocal(TextFieldStyleEnvironment.key, AnyTextFieldStyle(style))
    }
}

public extension TextFieldStyle where Self == DefaultTextFieldStyle {
    static var `default`: DefaultTextFieldStyle { DefaultTextFieldStyle() }
}
