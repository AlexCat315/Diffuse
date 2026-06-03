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
    private(set) var display: AppDisplayHandle?
    private var settingsWindowID: WindowID?

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

        let registry = EditorRootViewFactory.makeRegistry(app: app)
        let controller = EditorRootViewFactory.makeController(
            for: app.store.state.workspaceMode,
            preset: app.store.state.activeLayoutPreset,
            registry: registry
        )

        subscribeShellPreferences(app: app, controller: controller, registry: registry)
        bundle = EditorLaunchBundle(app: app, controller: controller, registry: registry)

        if let display {
            wireDisplayHandlers(app: app, display: display)
        }

        RecentProjectsStore.record(directory)
        publisher.send()
    }

    @MainActor func wireDisplay(_ display: AppDisplayHandle) {
        self.display = display
        if let app = bundle?.app {
            wireDisplayHandlers(app: app, display: display)
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
        app.shutdown()
    }

    @MainActor private func wireDisplayHandlers(app: EditorApplication, display: AppDisplayHandle) {
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
        app.setOpenSettingsWindowHandler { [weak self] in
            guard let self else { return }
            if let id = settingsWindowID, display.isWindowOpen(id) { return }
            settingsWindowID = display.openWindow(title: L("Settings"), width: 360, height: 420) {
                EditorSettingsWindowRoot(app: app)
            }
        }
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
