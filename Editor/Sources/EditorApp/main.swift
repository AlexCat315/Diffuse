import Darwin
import EditorCore
import GuavaUIApp
import GuavaUIRuntime
import RHIWGPU

@MainActor
private func runEditor() throws {
    let launchOptions = try EditorAppLaunchOptions.load()
    var resolvedBackendConfig = launchOptions.backendConfig
    if resolvedBackendConfig.libraryPath == nil {
        resolvedBackendConfig.libraryPath = EditorApplication.locateWGPUDylib()
    }
    let backend = WGPUBackend(config: resolvedBackendConfig)
    let events = PlatformEventBridge()
    let app = try EditorApplication(projectDirectory: launchOptions.projectDirectory,
                                backendConfig: launchOptions.backendConfig,
                                backend: backend,
                                events: events)
    app.bootstrap()
    defer { app.shutdown() }

    if let shellState = EditorRootViewFactory.loadShellState() {
        app.store.dispatch(.setWorkspaceMode(shellState.workspaceMode))
        app.store.dispatch(.setActiveLayoutPreset(shellState.activeLayoutPreset))
        app.store.dispatch(.setThemeMode(shellState.themeMode))
        app.store.dispatch(.setLanguage(shellState.language))
        EditorLocalizationPreferences.language = shellState.language
    }

    let controller = EditorRootViewFactory.makeController(for: app.store.state.workspaceMode,
                                                          preset: app.store.state.activeLayoutPreset)
    let registry = EditorRootViewFactory.makeRegistry(app: app)

    try AppRuntime.run(
        config: AppConfig(title: "GuavaNext Editor",
                          backendConfig: launchOptions.backendConfig),
        backend: backend,
        events: events,
        onTick: { dt in app.tick(deltaTime: dt) },
        onDisplayReady: { display in
            app.setViewportRenderCompletionHandler { _ in
                display.requestDisplay()
            }
        }
    ) {
        EditorRootView(app: app, controller: controller, registry: registry)
    }

    // Save layout state on shutdown
    EditorRootViewFactory.saveShellState(mode: app.store.state.workspaceMode,
                                         preset: app.store.state.activeLayoutPreset,
                                         themeMode: app.store.state.themeMode,
                                         language: app.store.state.language)
    EditorRootViewFactory.saveDockLayout(controller,
                                         for: app.store.state.workspaceMode,
                                         preset: app.store.state.activeLayoutPreset)
}

do {
    try runEditor()
} catch {
    fputs("[EditorApp] startup failed: \(error)\n", stderr)
    exit(1)
}
