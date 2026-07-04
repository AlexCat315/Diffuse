import GuavaUIRuntime

/// Tonal / surface-variant button. Lower visual weight than primary.
/// Reads from the theme's state-layer ramp for hover/press so palette
/// changes don't require recomputing `lighter`/`darker` mixes here.
public struct SecondaryButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        BuiltinButtonChrome(kind: .secondary,
                            configuration: configuration,
                            foreground: .onSurface)
    }
}

