import GuavaUIRuntime

/// Filled button using the `error` color slot. Used for irreversible
/// actions (delete, discard). Same chrome as `PrimaryButtonStyle` but keyed
/// off the `error` colour. State variants are produced by compositing the
/// theme's state-layer overlays so the destructive ramp tracks the rest of
/// the system without per-style colour math.
public struct DestructiveButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        BuiltinButtonChrome(kind: .destructive,
                            configuration: configuration,
                            foreground: .onAccent)
    }
}

