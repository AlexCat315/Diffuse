import GuavaUIRuntime

/// Background-less button. At rest only the label is drawn; hover/press
/// fade in a state-layer overlay. Used for tertiary actions and toolbar
/// items. Focus ring still appears on keyboard focus.
public struct GhostButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        BuiltinButtonChrome(kind: .ghost,
                            configuration: configuration,
                            foreground: .onSurface)
    }
}

