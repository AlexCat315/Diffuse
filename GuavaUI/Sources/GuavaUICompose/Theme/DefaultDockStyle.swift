import GuavaUIRuntime

/// Default dock chrome: a `surfaceVariant` tab strip with an `accent`
/// underline beneath the active tab and a 1-px `border` divider between
/// split panes. Hit-slop on the divider widens its grab area to ~6 px while
/// keeping the visible line at 1 px.
public struct DefaultDockStyle: DockStyle {
    public init() {}

    public func resolve(_ config: DockStyleConfiguration) -> DockAppearance {
        let t = config.theme
        return DockAppearance(
            tabBarBackground: t.colors.surfaceVariant,
            tabBarHeight: 32,
            tabHorizontalPadding: t.spacing.md,
            tabHorizontalSpacing: 6,
            tabVerticalPadding: 6,
            tabActiveBackground: t.colors.surface,
            tabActiveForeground: t.colors.onSurface,
            tabInactiveForeground: t.colors.onSurfaceMuted,
            tabActiveAccentBar: t.colors.accent,
            tabActiveAccentBarHeight: 2,
            closeButtonSize: 16,
            splitDividerThickness: 1,
            splitDividerColor: t.colors.border,
            splitDividerHitSlop: 5,
            leafBackground: t.colors.surface,
            emptyLeafBackground: t.colors.surfaceSunken,
            satelliteTitleBarHeight: 24
        )
    }
}
