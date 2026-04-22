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
            tabBarHeight: 28,
            tabHorizontalPadding: t.spacing.md,
            tabHorizontalSpacing: 6,
            tabVerticalPadding: 4,
            tabActiveBackground: t.colors.surface,
            tabActiveForeground: t.colors.onSurface,
            tabInactiveForeground: t.colors.onSurfaceVariant,
            tabActiveAccentBar: t.colors.accent,
            tabActiveAccentBarHeight: 1,
            closeButtonSize: 14,
            splitDividerThickness: 1,
            splitDividerColor: t.colors.borderStrong,
            splitDividerHitSlop: 4,
            leafBackground: t.colors.surface,
            emptyLeafBackground: t.colors.surfaceSunken,
            satelliteTitleBarHeight: 22
        )
    }
}
