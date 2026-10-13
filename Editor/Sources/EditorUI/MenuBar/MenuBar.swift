import EditorCore

enum EditorMenuCommand {
    case showCommandPalette
    case showSceneSettings
    case showAssets
    case showProblems
    case showPanel(String)
    case maximizePanel(String)
    case restorePanels
    case saveLayout
    case closeProject
    case newScene
    case openScene
    case saveScene
    case importAssets
    case undo
    case redo
    case duplicateSelection
    case deleteSelection
    case setInteractionMode(EditorInteractionMode)
    case setWorkspaceMode(EditorWorkspaceMode)
    case setLayoutPreset(EditorLayoutPreset)
    case resetLayout
    case reopenClosedPanel
    case showScripts
    case setPlaybackState(PlaybackState)
    case openSettings
    case toggleTheme
    case buildProject
    case buildAndRun
    case openDocumentation
    case about
}
