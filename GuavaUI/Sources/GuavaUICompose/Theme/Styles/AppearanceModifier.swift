import GuavaUIRuntime

/// Coarse light / dark switch. Set via `.appearance(_:)` to swap the active
/// theme for an entire subtree without spelling out a custom `Theme`.
///
/// (The token slot bag in this codebase is already named `ColorScheme`, so
/// the SwiftUI-flavoured `ColorScheme` enum is spelled `Appearance` here to
/// avoid the collision.)
public enum Appearance: Sendable, Equatable {
    case dark
    case light
}

public extension View {
    /// Apply one of the built-in `Theme.defaultDark` / `Theme.defaultLight`
    /// presets to the receiver subtree. Equivalent to
    /// `.theme(Theme.defaultLight)` for `.light`, etc. Composes naturally
    /// with `.theme(_:)` — whichever modifier appears last (innermost) wins
    /// for descendants.
    func appearance(_ appearance: Appearance) -> some View {
        switch appearance {
        case .dark:  return AnyView(self.theme(.defaultDark))
        case .light: return AnyView(self.theme(.defaultLight))
        }
    }
}
