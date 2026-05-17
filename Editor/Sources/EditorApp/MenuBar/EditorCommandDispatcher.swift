import EditorCore
import GuavaUIApp
import GuavaUIWorkspace

@MainActor
enum EditorCommandDispatcher {
    static func handle(_ command: EditorMenuCommand,
                       app: EditorApplication,
                       controller: WorkspaceController,
                       registry: PanelRegistry) {
        let store = app.store

        switch command {
        case .newScene:
            app.resetPreviewScene()
        case .openScene:
            _ = app.openSceneManifest()
        case .saveScene:
            _ = app.saveSceneManifest()
        case .importAssets:
            _ = app.reloadAssets()
        case .undo:
            app.logConsole("Undo is not available for this command path yet", severity: .warning)
        case .redo:
            app.logConsole("Redo is not available for this command path yet", severity: .warning)
        case let .setWorkspaceMode(next):
            guard store.state.workspaceMode != next else { return }
            let previousMode = store.state.workspaceMode
            let previousPreset = store.state.activeLayoutPreset
            EditorRootViewFactory.saveWorkspaceLayout(controller, for: previousMode, preset: previousPreset)
            store.dispatch(.setWorkspaceMode(next))
            let nextPreset = store.state.activeLayoutPreset
            EditorRootViewFactory.loadLayoutPreset(into: controller, for: next, preset: nextPreset, registry: registry)
            saveShellState(app)
        case let .setLayoutPreset(nextPreset):
            guard nextPreset != store.state.activeLayoutPreset else { return }
            let mode = store.state.workspaceMode
            let previousPreset = store.state.activeLayoutPreset
            EditorRootViewFactory.saveWorkspaceLayout(controller, for: mode, preset: previousPreset)
            store.dispatch(.setActiveLayoutPreset(nextPreset))
            EditorRootViewFactory.loadLayoutPreset(into: controller, for: mode, preset: nextPreset, registry: registry)
            saveShellState(app)
        case .resetLayout:
            let mode = store.state.workspaceMode
            let preset = store.state.activeLayoutPreset
            EditorRootViewFactory.resetLayout(into: controller, for: mode, preset: preset, registry: registry)
            EditorRootViewFactory.saveWorkspaceLayout(controller, for: mode, preset: preset)
            saveShellState(app)
        case let .setPlaybackState(next):
            app.applyPlaybackState(next)
        case .openSettings:
            app.openSettingsWindow()
        case .toggleTheme:
            store.dispatch(.setThemeMode(store.state.themeMode == .dark ? .light : .dark))
        case .buildProject:
            app.logConsole("Build Editor command recorded", detail: "Use swift build in Editor until build jobs are wired")
        case .buildAndRun:
            app.logConsole("Build and Run command recorded", detail: "Use swift run EditorApp until build jobs are wired")
        case .openDocumentation:
            app.logConsole("Documentation command recorded", detail: "Docs live under docs/")
        case .about:
            app.logConsole("GuavaNext Editor", detail: "Swift native editor shell")
        }
    }

    private static func saveShellState(_ app: EditorApplication) {
        let state = app.store.state
        EditorRootViewFactory.saveShellState(mode: state.workspaceMode,
                                             preset: state.activeLayoutPreset,
                                             themeMode: state.themeMode,
                                             language: state.language,
                                             vsyncMode: state.vsyncMode,
                                             primarySelectBehavior: state.primarySelectBehavior)
    }
}
