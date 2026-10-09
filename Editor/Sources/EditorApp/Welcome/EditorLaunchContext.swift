import EditorCore
import EngineCore
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
    private var shouldExpandEditorWindow = false
    private var settingsWindowID: WindowID?
    private var nativeMenuState: NativeMenuState?

    let backendConfig: WGPUDeviceConfig
    let renderDevice: EngineRenderDevice
    var backend: WGPUBackend? { renderDevice.wgpuBackend }
    let events: PlatformEventBridge
    private(set) var shellState: EditorRootViewFactory.EditorShellState?

    var isProjectLoaded: Bool { bundle != nil }
    private let publisher = _ObservablePublisher<EditorLaunchContext>()

    init(backendConfig: WGPUDeviceConfig,
         renderDevice: EngineRenderDevice,
         events: PlatformEventBridge,
         shellState: EditorRootViewFactory.EditorShellState?) {
        self.backendConfig = backendConfig
        self.renderDevice = renderDevice
        self.events = events
        self.shellState = shellState
        EditorLocalizationPreferences.language = shellState?.language ?? .system
    }

    convenience init(backendConfig: WGPUDeviceConfig,
                     backend: WGPUBackend,
                     events: PlatformEventBridge,
                     shellState: EditorRootViewFactory.EditorShellState?) {
        self.init(backendConfig: backendConfig, renderDevice: .wgpu(backend),
                  events: events, shellState: shellState)
    }

    @MainActor func loadProject(directory: String) throws {
        let location = try EditorProjectLifecycle.inspect(URL(fileURLWithPath: directory, isDirectory: true))
        guard bundle == nil else {
            throw EditorProjectLifecycle.Failure("Close the current project before opening another project.")
        }
        let directory = location.directory.path
        let app = try EditorApplication(
            projectDirectory: directory,
            backendConfig: backendConfig,
            renderDevice: renderDevice,
            events: events,
            initialAISettings: shellState?.aiSettings ?? .default,
            initialCapabilitySettings: shellState?.capabilitySettings ?? .default
        )
        app.setCloseProjectHandler { [weak self] in
            MainActor.assumeIsolated { self?.closeProject() }
        }
        app.bootstrap()

        if let s = shellState {
            app.store.dispatch(.setInteractionMode(s.workspace.interactionMode))
            app.store.dispatch(.setWorkspaceMode(s.workspace.mode))
            app.store.dispatch(.setActiveLayoutPreset(s.workspace.layoutPreset))
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
            for: app.store.state.workspace.mode,
            preset: app.store.state.workspace.layoutPreset,
            registry: registry
        )

        app.setActivatePanelHandler { [weak controller] id in
            guard let controller else { return }
            EditorRootViewFactory.activatePanel(PanelID(rawValue: id), in: controller)
        }
        subscribeShellPreferences(app: app, controller: controller, registry: registry)
        subscribeWorkspacePersistence(app: app, controller: controller)
        subscribeNativeMenu(app: app, controller: controller, registry: registry)
        bundle = EditorLaunchBundle(app: app, controller: controller, registry: registry)
        shouldExpandEditorWindow = true

        if let display {
            expandEditorWindowIfReady()
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
        expandEditorWindowIfReady()
        if let bundle {
            wireDisplayHandlers(app: bundle.app,
                                controller: bundle.controller,
                                registry: bundle.registry,
                                display: display)
        }
    }

    @MainActor func tick(deltaTime: Double) {
        expandEditorWindowIfReady()
        bundle?.app.tick(deltaTime: deltaTime)
    }

    @MainActor private func expandEditorWindowIfReady() {
        guard shouldExpandEditorWindow, isProjectLoaded, let display, display.mainWindowID != nil else { return }
        display.maximizeWindow()
        shouldExpandEditorWindow = false
    }

    @MainActor func shutdown() {
        guard let bundle else { return }
        let app = bundle.app
        let state = app.store.state
        shellState = .init(workspace: state.workspace,
                           themeMode: state.themeMode,
                           language: state.language,
                           vsyncMode: state.vsyncMode,
                           primarySelectBehavior: state.selection.primarySelectBehavior,
                           aiSettings: state.assistant.aiSettings,
                           capabilitySettings: state.assistant.capabilitySettings)
        EditorRootViewFactory.saveShellState(
            workspace: state.workspace,
            themeMode: state.themeMode,
            language: state.language,
            vsyncMode: state.vsyncMode,
            primarySelectBehavior: state.selection.primarySelectBehavior,
            aiSettings: state.assistant.aiSettings,
            capabilitySettings: state.assistant.capabilitySettings
        )
        EditorRootViewFactory.saveWorkspaceLayout(
            bundle.controller,
            for: state.workspace.mode,
            preset: state.workspace.layoutPreset
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
        app.setCloseProjectHandler(nil)
        app.setOpenSettingsWindowHandler(nil)
        app.setDisplayInvalidationHandler(nil)
        app.setViewportRenderCompletionHandler(nil)
        app.shutdown()
        self.bundle = nil
        shellPreferenceToken = nil
        nativeMenuToken = nil
        workspaceSubscriptionToken = nil
        nativeMenuState = nil
    }

    @MainActor func closeProject() {
        if let settingsWindowID, let display, display.isWindowOpen(settingsWindowID) {
            display.closeWindow(settingsWindowID)
        }
        settingsWindowID = nil
        shouldExpandEditorWindow = false
        shutdown()
        display?.restoreWindow()
        display?.setWindowCloseInterceptor { _ in true }
        display?.installNativeMenuBar(NativeMenuBar(appName: "GuavaNext Editor", menus: []))
        publisher.send()
        display?.requestDisplay()
    }

    /// Only a freshly created, bundled example receives this explicit execution grant.
    @MainActor func createProject(name: String, parent: URL, template: EditorProjectTemplate) throws {
        let location = try EditorProjectLifecycle.create(name: name, parent: parent, template: template)
        try loadProject(directory: location.directory.path)
        if template == .crystalRush, let app = bundle?.app {
            app.scriptWorkspace.setProjectTrusted(true)
            app.scriptWorkspace.compileSelected()
            app.logConsole("Preparing Crystal Rush", detail: "When compilation finishes, press Play, then Space to start. WASD moves, Shift sprints, R restarts.")
        }
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
            guard app.hasUnsavedSceneChanges || app.scriptWorkspace.snapshot.documents.contains(where: \.isDirty) else {
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
        var interactionMode: EditorInteractionMode
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
        let next = NativeMenuState(workspaceMode: store.workspace.mode,
                                   interactionMode: store.workspace.interactionMode,
                                   layoutPreset: store.workspace.layoutPreset,
                                   playbackState: store.timing.playbackState,
                                   canUndo: app.canUndo,
                                   canRedo: app.canRedo,
                                   hasSelection: !store.selection.selectedEntityIDs.isEmpty,
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
            interactionMode: next.interactionMode,
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
                    for: store.state.workspace.mode,
                    preset: store.state.workspace.layoutPreset
                )
            }
            lastPrefs = next
            EditorRootViewFactory.saveShellState(
                workspace: store.state.workspace,
                themeMode: store.state.themeMode,
                language: store.state.language,
                vsyncMode: store.state.vsyncMode,
                primarySelectBehavior: store.state.selection.primarySelectBehavior,
                aiSettings: store.state.assistant.aiSettings,
                capabilitySettings: store.state.assistant.capabilitySettings
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
                                                       for: state.workspace.mode,
                                                       preset: state.workspace.layoutPreset)
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
         store.state.selection.primarySelectBehavior,
         store.state.assistant.capabilitySettings)
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
