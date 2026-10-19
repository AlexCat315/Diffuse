import GuavaUIRuntime

/// Field chrome for a numeric field with a prefix chip: one rounded input
/// whose leading addon slab is the scrub chip, separated by a hairline. The
/// border, hover and focus ring wrap chip and text together.
struct NumericPrefixFieldStyle: TextFieldStyle {
    let chip: AnyView

    func makeBody(configuration: TextFieldStyleConfiguration) -> some View {
        let theme = configuration.theme, inputs = theme.inputs
        let border: Color = {
            if !configuration.isEnabled { return inputs.borderDisabled }
            if configuration.isError { return inputs.borderError }
            if configuration.isFocused { return inputs.borderFocused }
            return configuration.isHovered ? inputs.borderHover : inputs.borderColor
        }()
        let width = configuration.isFocused ? inputs.focusRingWidth : inputs.borderWidth
        let alpha: Float = configuration.isEnabled || theme.textEmphasis.disabled != nil ? 1 : 0.55
        return Box(direction: .row, alignItems: .stretch, spacing: 0) {
            chip.flex(0, shrink: 0)
            Box {}.frame(width: 1).background(inputs.dividerColor).flex(0, shrink: 0)
            configuration.content.flex(1, shrink: 1, basis: 0).frame(minWidth: 0)
        }
        .background(configuration.isEnabled ? inputs.background : inputs.backgroundDisabled)
        .cornerRadius(inputs.radius)
        .border(border, width: width)
        .clipped()
        .opacity(alpha)
        // Fill the field like the default style's content does.
        .flex(1, shrink: 1)
        .animation(.semantic(.fast, in: theme), value: _TextFieldInteractionKey(
            isFocused: configuration.isFocused, isEditing: configuration.isEditing,
            isError: configuration.isError, isEnabled: configuration.isEnabled))
    }
}
