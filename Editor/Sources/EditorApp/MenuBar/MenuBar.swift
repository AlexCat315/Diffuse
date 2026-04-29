import EditorCore

enum EditorMenuCommand {
    case newScene
    case openScene
    case saveScene
    case importAssets
    case undo
    case redo
    case setWorkspaceMode(EditorWorkspaceMode)
    case setLayoutPreset(EditorLayoutPreset)
    case resetLayout
    case setPlaybackState(PlaybackState)
    case openSettings
    case toggleTheme
    case buildProject
    case buildAndRun
    case openDocumentation
    case about
}
