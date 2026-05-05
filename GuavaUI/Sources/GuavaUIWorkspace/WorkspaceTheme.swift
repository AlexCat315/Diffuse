import GuavaUICompose
import GuavaUIRuntime

public struct WorkspaceTheme: Sendable {
    public var sideRailWidth: Float
    public var bottomRailHeight: Float
    public var tabBarHeight: Float
    public var splitDividerThickness: Float

    public init(sideRailWidth: Float = 40,
                bottomRailHeight: Float = 40,
                tabBarHeight: Float = 30,
                splitDividerThickness: Float = 1) {
        self.sideRailWidth = sideRailWidth
        self.bottomRailHeight = bottomRailHeight
        self.tabBarHeight = tabBarHeight
        self.splitDividerThickness = splitDividerThickness
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

