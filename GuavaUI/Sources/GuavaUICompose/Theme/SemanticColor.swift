import GuavaUIRuntime

/// Late-bound color reference resolved against the active `Theme`.
///
/// `Color` is a value type and intentionally does not carry a theme reference,
/// so semantic colors are expressed as `SemanticColorRef` and resolved at
/// modifier-apply time via `Node.theme`. This keeps `Color` cheap to copy and
/// the resolution cost paid once per node per recompose.
public struct SemanticColorRef: Sendable {
    let resolve: @Sendable (Theme) -> Color
    public init(_ resolve: @escaping @Sendable (Theme) -> Color) {
        self.resolve = resolve
    }
}

public extension SemanticColorRef {
    static let background       = SemanticColorRef { $0.colors.background }
    static let surface          = SemanticColorRef { $0.colors.surface }
    static let surfaceVariant   = SemanticColorRef { $0.colors.surfaceVariant }
    static let surfaceSunken    = SemanticColorRef { $0.colors.surfaceSunken }

    static let onBackground     = SemanticColorRef { $0.colors.onBackground }
    static let onSurface        = SemanticColorRef { $0.colors.onSurface }
    static let onSurfaceVariant = SemanticColorRef { $0.colors.onSurfaceVariant }
    static let onSurfaceMuted   = SemanticColorRef { $0.colors.onSurfaceMuted }

    static let accent           = SemanticColorRef { $0.colors.accent }
    static let onAccent         = SemanticColorRef { $0.colors.onAccent }
    static let accentMuted      = SemanticColorRef { $0.colors.accentMuted }

    static let success          = SemanticColorRef { $0.colors.success }
    static let warning          = SemanticColorRef { $0.colors.warning }
    static let error            = SemanticColorRef { $0.colors.error }
    static let info             = SemanticColorRef { $0.colors.info }

    static let border           = SemanticColorRef { $0.colors.border }
    static let borderStrong     = SemanticColorRef { $0.colors.borderStrong }
    static let divider          = SemanticColorRef { $0.colors.divider }
    static let focusRing        = SemanticColorRef { $0.colors.focusRing }
    static let selection        = SemanticColorRef { $0.colors.selection }
    static let overlay          = SemanticColorRef { $0.colors.overlay }
}

/// Late-bound text-style reference resolved against the active `Typography`.
public struct SemanticFontRef: Sendable {
    let resolve: @Sendable (Theme) -> TextStyleToken
    public init(_ resolve: @escaping @Sendable (Theme) -> TextStyleToken) {
        self.resolve = resolve
    }
}

public extension SemanticFontRef {
    static let display    = SemanticFontRef { $0.typography.display }
    static let title      = SemanticFontRef { $0.typography.title }
    static let headline   = SemanticFontRef { $0.typography.headline }
    static let body       = SemanticFontRef { $0.typography.body }
    static let bodyStrong = SemanticFontRef { $0.typography.bodyStrong }
    static let caption    = SemanticFontRef { $0.typography.caption }
    static let label      = SemanticFontRef { $0.typography.label }
    static let mono       = SemanticFontRef { $0.typography.mono }
}
