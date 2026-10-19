internal import GuavaUIRuntime

/// A flat document surface for text/code editors whose caller owns the chrome.
/// Focus stays visible through the caret, selection and active code line.
public struct EditorTextFieldStyle: TextFieldStyle {
    public init() {}

    public func makeBody(configuration: TextFieldStyleConfiguration) -> some View {
        configuration.content.background(.surfaceSunken)
            .opacity(configuration.isEnabled || configuration.theme.textEmphasis.disabled != nil ? 1 : 0.55)
    }
}

public extension TextFieldStyle where Self == EditorTextFieldStyle {
    static var editor: EditorTextFieldStyle { EditorTextFieldStyle() }
}
