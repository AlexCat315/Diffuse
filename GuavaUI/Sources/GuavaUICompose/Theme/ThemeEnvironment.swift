import GuavaUIRuntime

/// `CompositionLocal` key carrying the active `Theme` down the composition
/// tree. Always resolves: descendants without an ancestor `.theme(_:)`
/// modifier see `Theme.defaultDark`.
public enum ThemeEnvironment {
    public static let key = CompositionLocal<Theme>(defaultValue: .defaultDark)
    static let bodyStyle = CompositionLocal<TextStyleToken?>(defaultValue: nil)
    static let bodyStyleAttachment = "__theme_body_style"
}

public extension View {
    /// Provide `theme` to every descendant of this view. Nearer providers
    /// override farther ones; absent providers fall back to
    /// `Theme.defaultDark`.
    ///
    /// ```swift
    /// RootView().theme(.defaultDark)
    /// ```
    func theme(_ theme: Theme) -> some View {
        compositionLocal(ThemeEnvironment.key, theme)
            .compositionLocal(ThemeEnvironment.bodyStyle, theme.typography.body.resolvingFamily(theme.typography.family))
    }

    /// Animate a custom palette when its ordinary domain value changes. The
    /// renderer retains the previous frame; layout and input use the new theme.
    func theme<Value: Equatable>(_ theme: Theme, transition: ThemeTransition, value: Value) -> some View {
        CircularThemeHost(theme: theme, value: value, transition: transition, content: self)
    }
}

public extension Node {
    /// The `Theme` resolved for this node by walking its ancestor chain.
    /// Falls back to `Theme.defaultDark` when no provider is reachable.
    var theme: Theme {
        compositionValue(of: ThemeEnvironment.key)
    }
}
