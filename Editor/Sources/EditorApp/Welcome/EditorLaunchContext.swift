import EditorCore
import EngineKernel
import Foundation
import GuavaUIApp
import GuavaUICompose
import GuavaUIRuntime
import GuavaUIWorkspace
import PlatformShell
import RHIWGPU

/// Thread-safe liveness flag shared between the loop thread (which refreshes it
/// from the redraw policy each present) and the engine's viewport-render
/// completion callback (which may fire on a background thread). Lets the
/// callback decide whether to drive a full-rate frame without touching
/// main-thread editor state.
private final class RedrawLiveFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set(_ newValue: Bool) { lock.lock(); value = newValue; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}

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

        // Render-on-demand policy: keep redrawing at full rate only while the
        // scene is genuinely live — playing the simulation, or the user is
        // dragging the camera / a gizmo / holding a fly-camera key. Otherwise
        // the host parks at a 10fps idle heartbeat instead of rebuilding the
        // whole IDE every frame on a static scene. Input, recomposition (store
        // changes), and UI animations still wake a frame immediately, so the
        // editor stays responsive; the heartbeat is just a safety floor so a
        // live viewport / any unmodeled change still refreshes a few times a
        // second. Explicit invalidations (selection, scene edits, preference
        // changes) go through `setDisplayInvalidationHandler` above and redraw
        // immediately regardless of this policy.
        let liveFlag = RedrawLiveFlag()
        // Evaluated on the loop thread after every present. Returns whether the
        // scene is live (drives full-rate redraw) and mirrors it into `liveFlag`
        // so the viewport-completion callback — which may run on a background
        // thread — can read liveness without touching main-thread state.
        display.setRedrawPolicy(continuous: { [weak app] in
            let live: Bool = {
                guard let app else { return false }
                if app.store.state.playbackState == .playing { return true }
                let viewport = EditorViewportInputController.shared
                return viewport.hasActivePointerSession || !viewport.pressedScancodes.isEmpty
            }()
            liveFlag.set(live)
            return live
        }, idleFrameRate: 10)
        app.setViewportRenderCompletionHandler { _ in
            // A fresh engine viewport frame only needs to spin the loop back up
            // to full rate while the scene is live; when idle, the 10fps
            // heartbeat already repaints (and re-renders) it, so don't.
            if liveFlag.get() { display.requestDisplay() }
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
