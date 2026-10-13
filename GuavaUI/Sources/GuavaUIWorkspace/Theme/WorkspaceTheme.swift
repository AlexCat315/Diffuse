import GuavaUICompose
import GuavaUIRuntime

/// Workspace metrics. Panels are cards, so the geometry stays compact: two
/// cards sit *adjacent* across a hairline, and the grab area around that
/// hairline is drawn on top of the cards instead of reserving canvas between
/// them. A gutter that reserves margin is what made the panels look detached.
public struct WorkspaceTheme: Sendable {
    public var sideRailWidth: Float
    public var bottomRailHeight: Float
    public var tabBarHeight: Float
    /// The hairline drawn between two cards.
    public var splitDividerThickness: Float
    /// Extra grab area on each side of the hairline. It overhangs the cards and
    /// therefore reserves no layout space.
    public var splitDividerHitSlop: Float
    public var animatesLayout: Bool

    public init(sideRailWidth: Float = 40,
                bottomRailHeight: Float = 40,
                tabBarHeight: Float = 34,
                splitDividerThickness: Float = 1,
                splitDividerHitSlop: Float = 6,
                animatesLayout: Bool = false) {
        self.sideRailWidth = sideRailWidth
        self.bottomRailHeight = bottomRailHeight
        self.tabBarHeight = tabBarHeight
        self.splitDividerThickness = splitDividerThickness
        self.splitDividerHitSlop = splitDividerHitSlop
        self.animatesLayout = animatesLayout
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
