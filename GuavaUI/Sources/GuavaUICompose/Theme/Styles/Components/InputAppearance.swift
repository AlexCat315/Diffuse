import GuavaUIRuntime

/// Token group for editable text inputs (`TextField` and any future
/// `Input`-shaped composite). Centralises the chrome the primitive paints
/// so palette swaps and density tweaks land in one place rather than via
/// inline `theme.colors.*` reads scattered through the primitive.
///
/// Slot taxonomy:
/// - **Backgrounds**: `background` (resting fill), `backgroundDisabled`
///   (deemphasised fill applied when the field is non-editable). Both
///   already account for nesting inside `surface`-coloured panels — no
///   separate readonly slot is required because read-only retains the
///   resting background.
/// - **Borders**: 1-px stroke per state (`borderColor`, `borderHover`,
///   `borderFocused`, `borderError`, `borderDisabled`); `focusRingWidth`
///   replaces the resting `borderWidth` while focused so focus reads as a
///   thicker ring without requiring a separate halo node.
/// - **Addons** (`prepend` / `append`): `addonBackground` for the joined
///   slab fill, `addonForeground` for the label text, `dividerColor` for
///   the 1-px hairline between slab and editable surface.
/// - **Geometry**: `radius` controls corner rounding (typically the same as
///   `theme.radius.sm`); `borderWidth` is the resting stroke thickness so
///   layout-critical paint and the focused ring agree.
public struct InputAppearance: Sendable {
    public var background: Color
    public var backgroundDisabled: Color

    public var borderColor: Color
    public var borderHover: Color
    public var borderFocused: Color
    public var borderError: Color
    public var borderDisabled: Color

    public var borderWidth: Float
    public var focusRingWidth: Float

    public var addonBackground: Color
    public var addonForeground: Color
    public var dividerColor: Color

    public var radius: Float

    public init(background: Color,
                backgroundDisabled: Color,
                borderColor: Color,
                borderHover: Color,
                borderFocused: Color,
                borderError: Color,
                borderDisabled: Color,
                borderWidth: Float,
                focusRingWidth: Float,
                addonBackground: Color,
                addonForeground: Color,
                dividerColor: Color,
                radius: Float) {
        self.background = background
        self.backgroundDisabled = backgroundDisabled
        self.borderColor = borderColor
        self.borderHover = borderHover
        self.borderFocused = borderFocused
        self.borderError = borderError
        self.borderDisabled = borderDisabled
        self.borderWidth = borderWidth
        self.focusRingWidth = focusRingWidth
        self.addonBackground = addonBackground
        self.addonForeground = addonForeground
        self.dividerColor = dividerColor
        self.radius = radius
    }
}
