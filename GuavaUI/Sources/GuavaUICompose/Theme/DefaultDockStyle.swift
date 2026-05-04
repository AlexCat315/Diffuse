import GuavaUIRuntime

/// Default dock chrome: a denser recessed tab strip, a restrained 1px active
/// indicator, and clearer pane dividers so large editor layouts read as a
/// single ordered shell instead of stacked cards.
public struct DefaultDockStyle: DockStyle {
    public init() {}

    public func resolve(_ config: DockStyleConfiguration) -> DockAppearance {
        let t = config.theme
        return DockAppearance(
            tabBarBackground: t.colors.surfaceSunken,
            tabBarHeight: 30,
            tabHorizontalPadding: t.spacing.sm,
            tabHorizontalSpacing: 6,
            tabVerticalPadding: 3,
            tabActiveBackground: t.colors.surfaceVariant,
            tabActiveForeground: t.colors.onSurface,
            tabInactiveForeground: t.colors.onSurfaceMuted,
            tabActiveAccentBar: t.colors.accent,
            tabActiveAccentBarHeight: 1,
            closeButtonSize: 16,
            splitDividerThickness: 3,
            splitDividerColor: t.colors.borderStrong,
            splitDividerHitSlop: 8,
            leafBackground: t.colors.surface,
            emptyLeafBackground: t.colors.surfaceSunken,
            satelliteTitleBarHeight: 24
        )
    }
}
