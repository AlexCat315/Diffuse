import EditorCore
import GuavaUIApp
import GuavaUIWorkspace

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
            app.undo()
        case .redo:
            app.redo()
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
            _ = app.exportProject()
        case .buildAndRun:
            if let output = app.exportProject() {
                app.logConsole("Run exported build",
                               detail: "swift run GuavaPlayer --project \(output.path)")
            }
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
                                             primarySelectBehavior: state.primarySelectBehavior,
                                             aiSettings: state.aiSettings,
                                             capabilitySettings: state.capabilitySettings)
    }
}
