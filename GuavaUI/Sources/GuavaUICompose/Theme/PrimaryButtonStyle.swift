import GuavaUIRuntime

/// Filled, accent-coloured button. Default style for `Button`.
///
/// Visual recipe (consumes the theme's accent ramp directly):
/// - Rest:    fill = `accent`,         border = transparent.
/// - Hover:   fill = `accentHover`.
/// - Pressed: fill = `accentPressed`.
/// - Disabled: fill = `surfaceVariant`, foreground = `onSurfaceMuted`.
/// - Focused: 2px `focusRing` border replaces the highlight ring.
///
/// No drop shadow at this layer — primary buttons live on top of `surface`
/// (Layer 1); they don't need to "lift" off it. Use `.shadow(...)` on the
/// owning button if a popover-style elevation is required.
public struct PrimaryButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        BuiltinButtonChrome(kind: .primary,
                            configuration: configuration,
                            foreground: configuration.isEnabled ? .onAccent : .onSurfaceMuted)
    }
}

