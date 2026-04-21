import GuavaUIRuntime

/// Token-derivation helpers used by default styles to fabricate hover / pressed
/// variants from a base color without enlarging the `ColorScheme` API.
public extension Color {
    /// Linearly mix toward black by `amount` (0...1). Alpha is preserved.
    func darker(_ amount: Float) -> Color {
        let t = max(0, min(1, amount))
        return Color(r: r * (1 - t),
                     g: g * (1 - t),
                     b: b * (1 - t),
                     a: a)
    }

    /// Linearly mix toward white by `amount` (0...1). Alpha is preserved.
    func lighter(_ amount: Float) -> Color {
        let t = max(0, min(1, amount))
        return Color(r: r + (1 - r) * t,
                     g: g + (1 - g) * t,
                     b: b + (1 - b) * t,
                     a: a)
    }

    /// Linear blend toward `other` by `amount` (0...1). Alpha blends too.
    func mixed(with other: Color, amount: Float) -> Color {
        let t = max(0, min(1, amount))
        return Color(r: r + (other.r - r) * t,
                     g: g + (other.g - g) * t,
                     b: b + (other.b - b) * t,
                     a: a + (other.a - a) * t)
    }
}
