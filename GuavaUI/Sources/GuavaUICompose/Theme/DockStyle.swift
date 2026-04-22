import GuavaUIRuntime

/// Resolved appearance values for a `DockContainer`. Built-in primitives
/// (`_DockSplit`, `_DockResizeHandle`, `_DockTabsLeaf`, `_DockTabBarItem`)
/// read this directly so palette swaps or custom dock chrome don't require
/// touching the primitives.
public struct DockAppearance: Sendable {
    // Tab strip
    public var tabBarBackground: Color
    public var tabBarHeight: Float
    public var tabHorizontalPadding: Float
    /// Spacing between the icon, label, and close button inside one tab.
    public var tabHorizontalSpacing: Float
    /// Vertical padding inside one tab's content row.
    public var tabVerticalPadding: Float
    public var tabActiveBackground: Color?
    public var tabActiveForeground: Color
    public var tabInactiveForeground: Color
    public var tabActiveAccentBar: Color
    public var tabActiveAccentBarHeight: Float
    /// Side length of the close-X glyph button inside a closable tab.
    public var closeButtonSize: Float

    // Split divider
    public var splitDividerThickness: Float
    public var splitDividerColor: Color
    public var splitDividerHitSlop: Float

    // Leaf chrome
    public var leafBackground: Color
    public var emptyLeafBackground: Color

    // Satellite (floating) window chrome
    /// Visible height of the satellite window's drag/title bar.
    public var satelliteTitleBarHeight: Float

    public init(tabBarBackground: Color,
                tabBarHeight: Float,
                tabHorizontalPadding: Float,
                tabHorizontalSpacing: Float,
                tabVerticalPadding: Float,
                tabActiveBackground: Color?,
                tabActiveForeground: Color,
                tabInactiveForeground: Color,
                tabActiveAccentBar: Color,
                tabActiveAccentBarHeight: Float,
                closeButtonSize: Float,
                splitDividerThickness: Float,
                splitDividerColor: Color,
                splitDividerHitSlop: Float,
                leafBackground: Color,
                emptyLeafBackground: Color,
                satelliteTitleBarHeight: Float) {
        self.tabBarBackground = tabBarBackground
        self.tabBarHeight = tabBarHeight
        self.tabHorizontalPadding = tabHorizontalPadding
        self.tabHorizontalSpacing = tabHorizontalSpacing
        self.tabVerticalPadding = tabVerticalPadding
        self.tabActiveBackground = tabActiveBackground
        self.tabActiveForeground = tabActiveForeground
        self.tabInactiveForeground = tabInactiveForeground
        self.tabActiveAccentBar = tabActiveAccentBar
        self.tabActiveAccentBarHeight = tabActiveAccentBarHeight
        self.closeButtonSize = closeButtonSize
        self.splitDividerThickness = splitDividerThickness
        self.splitDividerColor = splitDividerColor
        self.splitDividerHitSlop = splitDividerHitSlop
        self.leafBackground = leafBackground
        self.emptyLeafBackground = emptyLeafBackground
        self.satelliteTitleBarHeight = satelliteTitleBarHeight
    }
}

public struct DockStyleConfiguration: Sendable {
    public let theme: Theme
}

public protocol DockStyle: Sendable {
    func resolve(_ configuration: DockStyleConfiguration) -> DockAppearance
}

public struct AnyDockStyle: @unchecked Sendable {
    public let resolve: (DockStyleConfiguration) -> DockAppearance
    public init<S: DockStyle>(_ style: S) {
        self.resolve = { config in style.resolve(config) }
    }
}

public enum DockStyleEnvironment {
    public static let key = CompositionLocal<AnyDockStyle>(
        defaultValue: AnyDockStyle(DefaultDockStyle())
    )
}

public extension View {
    func dockStyle<S: DockStyle>(_ style: S) -> some View {
        compositionLocal(DockStyleEnvironment.key, AnyDockStyle(style))
    }
}

public extension DockStyle where Self == DefaultDockStyle {
    static var `default`: DefaultDockStyle { DefaultDockStyle() }
}
