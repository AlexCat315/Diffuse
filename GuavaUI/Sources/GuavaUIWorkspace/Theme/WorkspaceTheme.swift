import GuavaUICompose
import GuavaUIRuntime

/// Workspace metrics. Panes are borderless rounded blocks resting on the
/// window canvas; the gutter between two panes is what separates them, so no
/// rule is drawn. The grab area of a split overhangs both panes and reserves
/// no layout space beyond the gutter.
public struct WorkspaceTheme: Sendable {
    public var sideRailWidth: Float
    public var bottomRailHeight: Float
    public var tabBarHeight: Float
    /// Empty canvas between two panes.
    public var gutter: Float
    /// Extra grab area on each side of a gutter. It overhangs the panes.
    public var splitDividerHitSlop: Float
    public var animatesLayout: Bool
    /// A collapsed group leaves a strip of its tab icons on its edge. Hosts
    /// with their own panel launcher (an activity bar) turn the strips off;
    /// a collapsed group then takes no space until it is expanded again.
    public var showsCollapsedRails: Bool

    public init(sideRailWidth: Float = 40,
                bottomRailHeight: Float = 40,
                tabBarHeight: Float = 34,
                gutter: Float = 6,
                splitDividerHitSlop: Float = 6,
                animatesLayout: Bool = false,
                showsCollapsedRails: Bool = true) {
        self.sideRailWidth = sideRailWidth
        self.bottomRailHeight = bottomRailHeight
        self.tabBarHeight = tabBarHeight
        self.gutter = gutter
        self.splitDividerHitSlop = splitDividerHitSlop
        self.animatesLayout = animatesLayout
        self.showsCollapsedRails = showsCollapsedRails
    }
}

public enum WorkspaceThemeEnvironment {
    public static let key = CompositionLocal<WorkspaceTheme>(defaultValue: WorkspaceTheme())
}

public extension View {
    func workspaceTheme(_ theme: WorkspaceTheme) -> some View {
        compositionLocal(WorkspaceThemeEnvironment.key, theme)
    }
}

func resolveWorkspaceTheme(on node: Node) -> WorkspaceTheme {
    node.compositionValue(of: WorkspaceThemeEnvironment.key)
}
