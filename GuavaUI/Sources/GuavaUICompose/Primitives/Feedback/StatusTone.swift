import GuavaUIRuntime

/// Semantic intent shared by GuavaUI's feedback components.
///
/// A tone is a meaning, not a colour. Components derive their ink, fill and
/// glyph from it, so re-theming — or shipping a monochrome theme — never has
/// to touch a call site.
public enum StatusTone: Sendable, Hashable, CaseIterable {
    case neutral, info, success, warning, danger

    /// The tone's primary ink: text, glyphs and outline borders.
    public var color: SemanticColorRef {
        switch self {
        case .neutral: .onSurfaceVariant
        case .info: .info
        case .success: .success
        case .warning: .warning
        case .danger: .error
        }
    }

    /// Glyph that carries the meaning without relying on hue, so the tone stays
    /// readable for colour-blind users and in monochrome themes.
    public var icon: BundleImageResource {
        switch self {
        case .neutral: UIIcons.Shape.circle
        case .info: UIIcons.Status.info
        case .success: UIIcons.Status.checkCircle
        case .warning: UIIcons.Status.alertTriangle
        case .danger: UIIcons.Status.xCircle
        }
    }

    /// Ink that stays legible on a surface filled solidly with `color`.
    ///
    /// Derived from the resolved colour's Rec. 709 relative luminance rather
    /// than a fixed white: a theme is free to pick a light amber for
    /// `.warning`, and white ink would wash out on it.
    public func ink(onSolid theme: Theme) -> Color {
        let c = color.resolve(theme)
        let luminance = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
        return luminance > 0.62 ? Color(red: 26, green: 28, blue: 33) : .white
    }
}
