import Foundation
import EngineKernel
import EditorCore
import GuavaUIApp
import GuavaUIRuntime
import GuavaUIWorkspace
import RHIWGPU
import CardBattleRuntime

@MainActor
private func runEditor() throws {
    let launchOptions = try EditorAppLaunchOptions.load()
    let backend = WGPUBackend(config: launchOptions.backendConfig)
    let events = PlatformEventBridge()
    let shellState = EditorRootViewFactory.loadShellState()
    let app = try EditorApplication(projectDirectory: launchOptions.projectDirectory,
                                backendConfig: launchOptions.backendConfig,
                                backend: backend,
                                events: events,
                                initialAISettings: shellState?.aiSettings ?? .default,
                                initialCapabilitySettings: shellState?.capabilitySettings ?? .default)
    app.bootstrap()
    defer { app.shutdown() }

    // Set up full GuavaUI in-game UI host. The render thread reads snapshots via
    // InGameUIRegistry; the main thread drives the ViewGraph via host.tick().
    let inGameUIHost = InGameUIHost(backend: backend)
    InGameUIRegistry.shared.provider = inGameUIHost

    // Bootstrap the in-game battle HUD with a demo battle state and install it
    // as the ViewGraph root so the HUD is visible over the 3D viewport.
    let initialBattleState = BattleStateMachine.reduce(
        BattleSampleFactory.makeThreeKingdomsDuel(),
        command: .startPlayerTurn(drawCount: 4)
    )
    let hudModel = BattleHUDModel(
        snapshot: BattleHUDSnapshot.make(from: initialBattleState, playerID: .player)
            ?? BattleHUDSnapshot(phase: .setup, turn: 0, energy: 0, maxEnergy: 0,
                                 health: 0, maxHealth: 0,
                                 opponentHealth: 0, opponentMaxHealth: 0,
                                 hand: [], skills: [])
    )
    inGameUIHost.setRootView(InGameBattleHUDView(model: hudModel))

    if let shellState {
        app.store.dispatch(.setWorkspaceMode(shellState.workspaceMode))
        app.store.dispatch(.setActiveLayoutPreset(shellState.activeLayoutPreset))
        app.store.dispatch(.setThemeMode(shellState.themeMode))
        app.store.dispatch(.setLanguage(shellState.language))
        app.store.dispatch(.setVSyncMode(shellState.vsyncMode))
        app.store.dispatch(.setPrimarySelectBehavior(shellState.primarySelectBehavior))
        app.store.dispatch(.setCapabilitySettings(shellState.capabilitySettings))
        EditorLocalizationPreferences.language = shellState.language
    }

    let registry = EditorRootViewFactory.makeRegistry(app: app)
    let controller = EditorRootViewFactory.makeController(for: app.store.state.workspaceMode,
                                                          preset: app.store.state.activeLayoutPreset,
                                                          registry: registry)
    var settingsWindowID: WindowID?

    var lastShellPreferences = (
        themeMode: app.store.state.themeMode,
        language: app.store.state.language,
        vsyncMode: app.store.state.vsyncMode,
        primarySelectBehavior: app.store.state.primarySelectBehavior,
        capabilitySettings: app.store.state.capabilitySettings
    )
    let shellPreferenceToken = app.store.subscribe { store in
        let next = (
            themeMode: store.state.themeMode,
            language: store.state.language,
            vsyncMode: store.state.vsyncMode,
            primarySelectBehavior: store.state.primarySelectBehavior,
            capabilitySettings: store.state.capabilitySettings
        )
        guard next != lastShellPreferences else { return }
        if next.language != lastShellPreferences.language {
            EditorLocalizationPreferences.language = next.language
            EditorRootViewFactory.localizeWorkspaceTitles(in: controller, registry: registry)
            EditorRootViewFactory.localizePanelTitles(in: registry)
            EditorRootViewFactory.saveWorkspaceLayout(controller,
                                                      for: store.state.workspaceMode,
                                                      preset: store.state.activeLayoutPreset)
        }
        lastShellPreferences = next
        EditorRootViewFactory.saveShellState(mode: store.state.workspaceMode,
                                             preset: store.state.activeLayoutPreset,
                                             themeMode: store.state.themeMode,
                                             language: store.state.language,
                                             vsyncMode: store.state.vsyncMode,
                                             primarySelectBehavior: store.state.primarySelectBehavior,
                                             aiSettings: store.state.aiSettings,
                                             capabilitySettings: store.state.capabilitySettings)
        app.requestDisplayRefresh()
    }
    defer { app.store.unsubscribe(shellPreferenceToken) }
    func applyVSyncMode(_ mode: EditorVSyncMode, to display: AppDisplayHandle) {
        display.setVSyncEnabled(mode.isEnabled)
    }

    try AppRuntime.run(
        config: AppConfig(title: "GuavaNext Editor",
                          backendConfig: launchOptions.backendConfig,
                          titleBarStyle: .hiddenInset),
        backend: backend,
        events: events,
        onTick: { dt in
            app.tick(deltaTime: dt)
            let size = app.viewportDrawableSize
            inGameUIHost.tick(width: Int(size.width), height: Int(size.height))
        },
        onDisplayReady: { display in
            display.installNativeMenuBar(NativeMenuBar(appName: "GuavaNext Editor", menus: []))
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
                                         primarySelectBehavior: app.store.state.primarySelectBehavior,
                                         aiSettings: app.store.state.aiSettings,
                                         capabilitySettings: app.store.state.capabilitySettings)
    EditorRootViewFactory.saveWorkspaceLayout(controller,
                                              for: app.store.state.workspaceMode,
                                              preset: app.store.state.activeLayoutPreset)
}

do {
    try runEditor()
} catch {
    fputs("[EditorApp] startup failed: \(error)\n", stderr)
    exit(1)
}
