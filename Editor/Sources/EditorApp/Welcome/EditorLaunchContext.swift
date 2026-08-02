import EditorCore
import EngineKernel
import Foundation
import GuavaUIApp
import GuavaUICompose
import GuavaUIRuntime
import GuavaUIWorkspace
import PlatformShell
import RHIWGPU

final class EditorLaunchContext: @unchecked Sendable {
    private(set) var bundle: EditorLaunchBundle?
    private var shellPreferenceToken: EditorStore.SubscriptionToken?
    private var nativeMenuToken: EditorStore.SubscriptionToken?
    private var workspaceSubscriptionToken: WorkspaceController.SubscriptionToken?
    private var workspacePersistenceTask: Task<Void, Never>?
    private(set) var display: AppDisplayHandle?
    private var settingsWindowID: WindowID?
    private var nativeMenuState: NativeMenuState?

    let backendConfig: WGPUDeviceConfig
    let backend: WGPUBackend
    let events: PlatformEventBridge
    let shellState: EditorRootViewFactory.EditorShellState?

    var isProjectLoaded: Bool { bundle != nil }
    private let publisher = _ObservablePublisher<EditorLaunchContext>()

    init(backendConfig: WGPUDeviceConfig,
         backend: WGPUBackend,
         events: PlatformEventBridge,
         shellState: EditorRootViewFactory.EditorShellState?) {
        self.backendConfig = backendConfig
        self.backend = backend
        self.events = events
        self.shellState = shellState
    }

    @MainActor func loadProject(directory: String) throws {
        let app = try EditorApplication(
            projectDirectory: directory,
            backendConfig: backendConfig,
            backend: backend,
            events: events,
            initialAISettings: shellState?.aiSettings ?? .default,
            initialCapabilitySettings: shellState?.capabilitySettings ?? .default
        )
        app.bootstrap()

        if let s = shellState {
            app.store.dispatch(.setWorkspaceMode(s.workspaceMode))
            app.store.dispatch(.setActiveLayoutPreset(s.activeLayoutPreset))
            app.store.dispatch(.setThemeMode(s.themeMode))
            app.store.dispatch(.setLanguage(s.language))
            app.store.dispatch(.setVSyncMode(s.vsyncMode))
            app.store.dispatch(.setPrimarySelectBehavior(s.primarySelectBehavior))
            app.store.dispatch(.setCapabilitySettings(s.capabilitySettings))
            EditorLocalizationPreferences.language = s.language
        }

        // Restore the project's saved scene (File → Save Scene writes
        // .guava/editor-scene-manifest.json). Without this, saved edits only
        // come back via a manual File → Open Scene — a relaunch always showed
        // the seeded preview scene.
        _ = app.restoreProjectSceneAtLaunch()

        let registry = EditorRootViewFactory.makeRegistry(app: app)
        let controller = EditorRootViewFactory.makeController(
            for: app.store.state.workspaceMode,
            preset: app.store.state.activeLayoutPreset,
            registry: registry
        )

        subscribeShellPreferences(app: app, controller: controller, registry: registry)
        subscribeWorkspacePersistence(app: app, controller: controller)
        subscribeNativeMenu(app: app, controller: controller, registry: registry)
        bundle = EditorLaunchBundle(app: app, controller: controller, registry: registry)

        if let display {
            wireDisplayHandlers(app: app,
                                controller: controller,
                                registry: registry,
                                display: display)
        }

        RecentProjectsStore.record(directory)
        publisher.send()
    }

    @MainActor func wireDisplay(_ display: AppDisplayHandle) {
        self.display = display
        if let bundle {
            wireDisplayHandlers(app: bundle.app,
                                controller: bundle.controller,
                                registry: bundle.registry,
                                display: display)
        }
    }

    @MainActor func tick(deltaTime: Double) {
        bundle?.app.tick(deltaTime: deltaTime)
    }

    @MainActor func shutdown() {
        guard let bundle else { return }
        let app = bundle.app
        let state = app.store.state
        EditorRootViewFactory.saveShellState(
            mode: state.workspaceMode,
            preset: state.activeLayoutPreset,
            themeMode: state.themeMode,
            language: state.language,
            vsyncMode: state.vsyncMode,
            primarySelectBehavior: state.primarySelectBehavior,
            aiSettings: state.aiSettings,
            capabilitySettings: state.capabilitySettings
        )
        EditorRootViewFactory.saveWorkspaceLayout(
            bundle.controller,
            for: state.workspaceMode,
            preset: state.activeLayoutPreset
        )
        if let token = shellPreferenceToken {
            app.store.unsubscribe(token)
        }
        if let token = nativeMenuToken {
            app.store.unsubscribe(token)
        }
        if let token = workspaceSubscriptionToken {
            bundle.controller.unsubscribe(token)
        }
        workspacePersistenceTask?.cancel()
        workspacePersistenceTask = nil
        app.shutdown()
    }

    @MainActor private func wireDisplayHandlers(app: EditorApplication,
                                                controller: WorkspaceController,
                                                registry: PanelRegistry,
                                                display: AppDisplayHandle) {
        display.setVSyncEnabled(app.store.state.vsyncMode.isEnabled)
        app.setVSyncModeHandler { mode in
            display.setVSyncEnabled(mode.isEnabled)
        }
        app.setDisplayInvalidationHandler {
            display.requestDisplay()
        }
        app.setViewportRenderCompletionHandler { _ in
            display.requestDisplay()
        }
        display.setWindowCloseInterceptor { [weak app, weak display] windowID in
            guard let app else { return true }
            // Auxiliary windows (settings) close freely; only the main window
            // and whole-app quit guard the scene.
            if let windowID, windowID != display?.mainWindowID { return true }
            guard app.hasUnsavedSceneChanges else {
                return true
            }
            app.store.dispatch(.requestClose(EditorPendingCloseRequest(windowID: windowID)))
            return false
        }
        app.setOpenSettingsWindowHandler { [weak self] in
            guard let self else { return }
            if let id = settingsWindowID, display.isWindowOpen(id) { return }
            settingsWindowID = display.openWindow(title: L("Settings"), width: 520, height: 680) {
                EditorSettingsWindowRoot(app: app)
            }
        }
        refreshNativeMenu(app: app,
                          controller: controller,
                          registry: registry,
                          display: display,
                          force: true)
    }

    private struct NativeMenuState: Equatable {
        var workspaceMode: EditorWorkspaceMode
        var layoutPreset: EditorLayoutPreset
        var playbackState: PlaybackState
        var canUndo: Bool
        var canRedo: Bool
        var hasSelection: Bool
        var language: EditorLanguage
    }

    @MainActor
    private func subscribeNativeMenu(app: EditorApplication,
                                     controller: WorkspaceController,
                                     registry: PanelRegistry) {
        nativeMenuToken = app.store.subscribe { [weak self, weak app, weak controller, weak registry] _ in
            MainActor.assumeIsolated {
                guard let self, let app, let controller, let registry,
                      let display = self.display else { return }
                self.refreshNativeMenu(app: app,
                                       controller: controller,
                                       registry: registry,
                                       display: display)
            }
        }
    }

    @MainActor
    private func refreshNativeMenu(app: EditorApplication,
                                   controller: WorkspaceController,
                                   registry: PanelRegistry,
                                   display: AppDisplayHandle,
                                   force: Bool = false) {
        let store = app.store.state
        let next = NativeMenuState(workspaceMode: store.workspaceMode,
                                   layoutPreset: store.activeLayoutPreset,
                                   playbackState: store.playbackState,
                                   canUndo: app.canUndo,
                                   canRedo: app.canRedo,
                                   hasSelection: !store.selectedEntityIDs.isEmpty,
                                   language: store.language)
        guard force || next != nativeMenuState else { return }
        nativeMenuState = next
        // Menu labels are built outside the Compose presentation boundary, so
        // explicitly align the localization preference before regenerating.
        EditorLocalizationPreferences.language = next.language
        display.installNativeMenuBar(EditorNativeMenuBuilder.make(
            workspaceMode: next.workspaceMode,
            activeLayoutPreset: next.layoutPreset,
            playbackState: next.playbackState,
            canUndo: next.canUndo,
            canRedo: next.canRedo,
            hasSelection: next.hasSelection,
            onCommand: { [weak app, weak controller, weak registry] command in
                guard let app, let controller, let registry else { return }
                EditorCommandDispatcher.handle(command,
                                               app: app,
                                               controller: controller,
                                               registry: registry)
            }
        ))
    }

    private func subscribeShellPreferences(app: EditorApplication,
                                           controller: WorkspaceController,
                                           registry: PanelRegistry) {
        var lastPrefs = shellPrefs(app.store)
        shellPreferenceToken = app.store.subscribe { [weak controller, weak registry] store in
            let next = self.shellPrefs(store)
            guard next != lastPrefs else { return }
            if next.language != lastPrefs.language, let controller, let registry {
                EditorLocalizationPreferences.language = next.language
                EditorRootViewFactory.localizeWorkspaceTitles(in: controller, registry: registry)
                EditorRootViewFactory.localizePanelTitles(in: registry)
                EditorRootViewFactory.saveWorkspaceLayout(
                    controller,
                    for: store.state.workspaceMode,
                    preset: store.state.activeLayoutPreset
                )
            }
            lastPrefs = next
            EditorRootViewFactory.saveShellState(
                mode: store.state.workspaceMode,
                preset: store.state.activeLayoutPreset,
                themeMode: store.state.themeMode,
                language: store.state.language,
                vsyncMode: store.state.vsyncMode,
                primarySelectBehavior: store.state.primarySelectBehavior,
                aiSettings: store.state.aiSettings,
                capabilitySettings: store.state.capabilitySettings
            )
            app.requestDisplayRefresh()
        }
    }

    @MainActor
    private func subscribeWorkspacePersistence(app: EditorApplication,
                                               controller: WorkspaceController) {
        workspaceSubscriptionToken = controller.subscribe { [weak self, weak app, weak controller] _ in
            Task { @MainActor in
                guard let self, let app, let controller else { return }
                self.scheduleWorkspacePersistence(app: app, controller: controller)
            }
        }
    }

    @MainActor
    private func scheduleWorkspacePersistence(app: EditorApplication,
                                              controller: WorkspaceController) {
        workspacePersistenceTask?.cancel()
        workspacePersistenceTask = Task { @MainActor [weak self, weak app, weak controller] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self, let app, let controller else { return }
            let state = app.store.state
            EditorRootViewFactory.saveWorkspaceLayout(controller,
                                                       for: state.workspaceMode,
                                                       preset: state.activeLayoutPreset)
            self.workspacePersistenceTask = nil
        }
    }

    private typealias ShellPrefs = (
        themeMode: EditorThemeMode,
        language: EditorLanguage,
        vsyncMode: EditorVSyncMode,
        primarySelectBehavior: SelectionPrimaryModifierBehavior,
        capabilitySettings: EditorCapabilitySettings
    )

    private func shellPrefs(_ store: EditorStore) -> ShellPrefs {
        (store.state.themeMode,
         store.state.language,
         store.state.vsyncMode,
         store.state.primarySelectBehavior,
         store.state.capabilitySettings)
    }
}

extension EditorLaunchContext: _ObservableObject {
    func _registerObserver(_ handler: @escaping () -> Void) -> AnyHashable {
        publisher.register(on: self, handler: handler)
    }
    func _unregisterObserver(_ token: AnyHashable) {
        publisher.unregister(token)
    }
}

struct EditorLaunchBundle {
    let app: EditorApplication
    let controller: WorkspaceController
    let registry: PanelRegistry
}
