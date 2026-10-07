import EditorCore

/// One command policy for menus, search, keyboard dispatch and native menus.
enum EditorWorkspaceCommandPolicy {
    static func allows(_ command: EditorMenuCommand, in mode: EditorWorkspaceMode) -> Bool {
        let profile = mode.profile
        switch command {
        case .showScripts: return profile.allowsPanel("scripts")
        case .showPanel(let id), .maximizePanel(let id): return profile.allowsPanel(id)
        case .buildProject, .buildAndRun: return profile.features.contains(.gameBuild)
        case .setPlaybackState: return profile.features.contains(.gameplay)
        default: return true
        }
    }

    static func requiresManualSurface(_ command: EditorMenuCommand) -> Bool {
        switch command {
        case .showPanel, .showScripts, .showAssets, .showProblems, .showSceneSettings, .maximizePanel:
            return true
        default: return false
        }
    }
}
