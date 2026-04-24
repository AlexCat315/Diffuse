import GuavaUIRuntime

private struct _TextFieldVisualKey: Equatable, Sendable {
    let background: Color
    let border: Color
    let borderWidth: Float
    let alpha: Float
}

/// Recessed field chrome for dense desktop forms. The resting fill is a
/// sunken surface so inspector rows and toolbar fields read as inputs rather
/// than as generic cards.
public struct DefaultTextFieldStyle: TextFieldStyle {
    public init() {}

    public func makeBody(configuration: TextFieldStyleConfiguration) -> some View {
        let theme = configuration.theme
        let inputs = theme.inputs
        let bg: Color = configuration.isEnabled
            ? inputs.background
            : inputs.backgroundDisabled

        let border: Color = {
            if !configuration.isEnabled { return inputs.borderDisabled }
            if configuration.isError    { return inputs.borderError }
            if configuration.isFocused  { return inputs.borderFocused }
            return inputs.borderColor
        }()
        let borderWidth: Float = configuration.isFocused
            ? inputs.focusRingWidth
            : inputs.borderWidth
        let alpha: Float = configuration.isEnabled ? 1 : 0.55
        let visualKey = _TextFieldVisualKey(background: bg,
                                            border: border,
                                            borderWidth: borderWidth,
                                            alpha: alpha)

        return configuration.content
            .background(bg)
            .cornerRadius(inputs.radius)
            .border(border, width: borderWidth)
            .opacity(alpha)
            .animation(.semantic(.fast, in: theme), value: visualKey)
    }
}

