import Darwin
import EngineKernel
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
        app.store.dispatch(.setVSyncMode(shellState.vsyncMode))
        app.store.dispatch(.setPrimarySelectBehavior(shellState.primarySelectBehavior))
        EditorLocalizationPreferences.language = shellState.language
    }

    let controller = EditorRootViewFactory.makeController(for: app.store.state.workspaceMode,
                                                          preset: app.store.state.activeLayoutPreset)
    let registry = EditorRootViewFactory.makeRegistry(app: app)
    var settingsWindowID: WindowID?
    var displayHandle: AppDisplayHandle?
    func installNativeMenu(on display: AppDisplayHandle) {
        display.installNativeMenuBar(EditorNativeMenuBuilder.make(
            workspaceMode: app.store.state.workspaceMode,
            activeLayoutPreset: app.store.state.activeLayoutPreset,
            playbackState: app.store.state.playbackState,
            onCommand: { command in
                EditorCommandDispatcher.handle(command, app: app, controller: controller)
            }
        ))
    }
    var lastNativeMenuState = (
        workspaceMode: app.store.state.workspaceMode,
        activeLayoutPreset: app.store.state.activeLayoutPreset,
        playbackState: app.store.state.playbackState,
        language: app.store.state.language
    )
    let nativeMenuToken = app.store.subscribe { store in
        let next = (
            workspaceMode: store.state.workspaceMode,
            activeLayoutPreset: store.state.activeLayoutPreset,
            playbackState: store.state.playbackState,
            language: store.state.language
        )
        guard next != lastNativeMenuState else { return }
        lastNativeMenuState = next
        if let displayHandle {
            installNativeMenu(on: displayHandle)
        }
    }
    defer { app.store.unsubscribe(nativeMenuToken) }
    var lastShellPreferences = (
        themeMode: app.store.state.themeMode,
        language: app.store.state.language,
        vsyncMode: app.store.state.vsyncMode,
        primarySelectBehavior: app.store.state.primarySelectBehavior
    )
    let shellPreferenceToken = app.store.subscribe { store in
        let next = (
            themeMode: store.state.themeMode,
            language: store.state.language,
            vsyncMode: store.state.vsyncMode,
            primarySelectBehavior: store.state.primarySelectBehavior
        )
        guard next != lastShellPreferences else { return }
        if next.language != lastShellPreferences.language {
            EditorLocalizationPreferences.language = next.language
            EditorRootViewFactory.localizeDockTitles(in: controller)
            EditorRootViewFactory.localizePanelTitles(in: registry)
        }
        lastShellPreferences = next
        EditorRootViewFactory.saveShellState(mode: store.state.workspaceMode,
                                             preset: store.state.activeLayoutPreset,
                                             themeMode: store.state.themeMode,
                                             language: store.state.language,
                                             vsyncMode: store.state.vsyncMode,
                                             primarySelectBehavior: store.state.primarySelectBehavior)
        app.requestDisplayRefresh()
    }
    defer { app.store.unsubscribe(shellPreferenceToken) }
    func applyVSyncMode(_ mode: EditorVSyncMode, to display: AppDisplayHandle) {
        display.setVSyncEnabled(mode.isEnabled)
    }

    try AppRuntime.run(
        config: AppConfig(title: "GuavaNext Editor",
                          backendConfig: launchOptions.backendConfig,
                          titleBarStyle: .standard),
        backend: backend,
        events: events,
        onTick: { dt in app.tick(deltaTime: dt) },
        onDisplayReady: { display in
            displayHandle = display
            installNativeMenu(on: display)
            applyVSyncMode(app.store.state.vsyncMode, to: display)
            app.setVSyncModeHandler { mode in
                applyVSyncMode(mode, to: display)
            }
            app.setDisplayInvalidationHandler {
                display.requestDisplay()
            }
            app.setViewportRenderCompletionHandler { _ in
                display.requestDisplay()
            }
            app.setOpenSettingsWindowHandler {
                if let existing = settingsWindowID,
                   display.isWindowOpen(existing) {
                    return
                }
                settingsWindowID = display.openWindow(title: L("Settings"),
                                                      width: 360,
                                                      height: 420) {
                    EditorSettingsWindowRoot(app: app)
                }
            }
        }
    ) {
        EditorRootView(app: app, controller: controller, registry: registry)
    }

    // Save layout state on shutdown
    EditorRootViewFactory.saveShellState(mode: app.store.state.workspaceMode,
                                         preset: app.store.state.activeLayoutPreset,
                                         themeMode: app.store.state.themeMode,
                                         language: app.store.state.language,
                                         vsyncMode: app.store.state.vsyncMode,
                                         primarySelectBehavior: app.store.state.primarySelectBehavior)
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
