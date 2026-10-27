import RenderBackend
import EditorCore
import EngineCore
import EngineKernel
import Foundation
import CoveLogging
import CoveUI
import CoveUIRuntime
import CoveUIWorkspace
import CoveUIAgent
import PlatformShell
import NativeRHI

/// One project in the window's list. Its editor loads when it first comes to
/// the front and then stays loaded, so its agent keeps working while another
/// project is in front.
struct EditorProjectEntry: Equatable {
    let directory: String
    let name: String
}

/// The window's projects. Several stay loaded at once; one is in front.
final class EditorLaunchContext: @unchecked Sendable {
    /// The window's projects for commands and menus, which have no view to pass it through.
    nonisolated(unsafe) static weak var current: EditorLaunchContext?

    private(set) var projects: [EditorProjectEntry] = []
    private(set) var activeDirectory: String?
    /// Why the last folder could not open while no project was in front.
    private(set) var openFailure: String?
    private var loaded: [String: EditorLaunchBundle] = [:]
    private(set) var display: AppDisplayHandle?
    private var diagnostics: UIDiagnostics?
    private var shouldExpandEditorWindow = !EditorAppLaunchOptions.settingsRequested
    private var settingsWindowID: WindowID?
    private var nativeMenuState: NativeMenuState?
    private var frameCadence = EditorFrameCadence()
    /// Projects whose unsaved changes the user already answered during one window close.
    private var closeAnswered = Set<ObjectIdentifier>()

    private let inGameUI: InGameUIHost
    let renderDevice: Device
    let events: PlatformEventBridge
    private(set) var shellState: EditorRootViewFactory.EditorShellState?

    var bundle: EditorLaunchBundle? { activeDirectory.flatMap { loaded[$0] } }
    /// Whether a real project is in front. The untitled workspace is a loaded
    /// editor but not a project, so it does not count here.
    var isProjectLoaded: Bool {
        activeDirectory.map { !EditorScratchWorkspace.isScratch($0) } ?? false
    }
    /// Every loaded editor, including the untitled one, which is not a project
    /// and therefore never appears in `projects`.
    var loadedBundles: [EditorLaunchBundle] {
        let listed = projects.compactMap { loaded[$0.directory] }
        let listedDirectories = Set(projects.map(\.directory))
        return listed + Array(loaded.filter { !listedDirectories.contains($0.key) }.values)
    }
    private let publisher = _ObservablePublisher<EditorLaunchContext>()

    init(renderDevice: Device,
         inGameUI: InGameUIHost,
         events: PlatformEventBridge,
         shellState: EditorRootViewFactory.EditorShellState?) {
        self.inGameUI = inGameUI
        self.renderDevice = renderDevice
        self.events = events
        self.shellState = shellState
        EditorLocalizationPreferences.language = shellState?.language ?? .system
        Self.current = self
    }

    func bundle(for directory: String) -> EditorLaunchBundle? { loaded[directory] }

    // MARK: Project list

    /// Brings the saved projects back; only the one in front loads now. A
    /// `front` folder (`--project-dir`) joins the list and takes the front.
    @MainActor func restoreProjects(front: String? = nil) throws {
        let saved = EditorProjectList.load()
        // An earlier build saved the fallback workspace as a project named
        // "Untitled". It is not one, so it is dropped on the way in as well as
        // on the way out — otherwise it would come back on the next launch.
        projects = saved.paths.filter { !EditorScratchWorkspace.isScratch($0) }.compactMap { path in
            (try? EditorProjectLifecycle.inspect(URL(fileURLWithPath: path, isDirectory: true), validateScene: false))
                .map { EditorProjectEntry(directory: $0.directory.path, name: $0.name) }
        }
        if let front {
            do { return try openProject(directory: front) }
            catch {
                // A bad launch folder must not leave the window without an
                // editor: report it and fall through to the normal restore.
                LogSystem.logger("com.cove.editor").warning("Launch project did not open",
                    metadata: ["project": "\(front)", "error": "\(error)"])
                openFailure = error.localizedDescription
            }
        }
        let preferred = saved.active.flatMap { active in projects.firstIndex { $0.directory == active } } ?? 0
        for entry in projects[min(preferred, projects.count)...] + projects[..<min(preferred, projects.count)] {
            do { try activate(entry.directory); break }
            catch {
                LogSystem.logger("com.cove.editor").warning("Saved project did not open",
                    metadata: ["project": "\(entry.directory)", "error": "\(error)"])
                projects.removeAll { $0.directory == entry.directory }
            }
        }
        // Nothing to restore: open the untitled workspace so the window shows a
        // workbench instead of an empty shell.
        ensureWorkspaceIsOpen()
        persist()
        publisher.send()
    }

    /// Adds a folder to the window, or brings it to the front when it is already there.
    @MainActor func openProject(directory: String) throws {
        let location = try EditorProjectLifecycle.adopt(URL(fileURLWithPath: directory, isDirectory: true))
        let path = location.directory.path
        if !projects.contains(where: { $0.directory == path }) {
            projects.append(EditorProjectEntry(directory: path, name: location.name))
        }
        do { try activate(path) }
        catch {
            if loaded[path] == nil { projects.removeAll { $0.directory == path } }
            persist()
            publisher.send()
            throw error
        }
    }

    @MainActor func requestOpenFolder() {
        guard let display else { return }
        display.requestOpenFolder(defaultPath: bundle?.app.projectDirectory) { [weak self] path in
            MainActor.assumeIsolated {
                guard let self, let path else { return }
                do {
                    try self.openProject(directory: path)
                    self.openFailure = nil
                } catch {
                    if let app = self.bundle?.app {
                        EditorNotifications.of(app).post(error.localizedDescription, id: "open-project",
                                                         tone: .danger, duration: nil)
                    } else {
                        self.openFailure = error.localizedDescription
                    }
                }
                self.publisher.send()
                self.display?.requestDisplay()
            }
        }
    }

    /// Opens the fallback workspace: a real project folder in Application
    /// Support, so the workbench and the agent are usable without choosing a
    /// project first. Returns false when even that could not be opened.
    @MainActor @discardableResult
    func openScratchWorkspace() -> Bool {
        let directory: URL
        do { directory = try EditorScratchWorkspace.prepare() }
        catch {
            openFailure = error.localizedDescription
            publisher.send()
            display?.requestDisplay()
            return false
        }
        let path = directory.path
        // The untitled workspace is not a project: it never joins the window's
        // project list, it only backs the editor while no project is open.
        do { try activate(path) }
        catch {
            projects.removeAll { $0.directory == path }
            persist()
            publisher.send()
            openFailure = error.localizedDescription
            display?.requestDisplay()
            return false
        }
        return true
    }

    /// A window always has a workspace. The workbench, every panel and the
    /// agent all need a root, so when there is no project to show the editor
    /// makes an untitled one instead of leaving the window without an editor.
    @MainActor func ensureWorkspaceIsOpen() {
        guard activeDirectory == nil else { return }
        openScratchWorkspace()
    }

    /// Puts a project in front, loading its editor the first time.
    @MainActor func activate(_ directory: String) throws {
        guard directory != activeDirectory || loaded[directory] == nil else { return }
        let next = try loaded[directory] ?? makeBundle(directory: directory)
        loaded[directory] = next
        if let settingsWindowID, let display, display.isWindowOpen(settingsWindowID) {
            display.closeWindow(settingsWindowID)
        }
        settingsWindowID = nil
        activeDirectory = directory
        openFailure = nil
        applyShellState(to: next.app)
        if let display {
            display.setVSyncEnabled(next.app.store.state.vsyncMode.isEnabled)
            refreshNativeMenu(next, display: display, force: true)
            display.requestDisplay()
        }
        persist()
        publisher.send()
    }

    /// Removes a project from the window; the next one comes to the front.
    @MainActor func closeProject(_ directory: String) {
        guard let index = projects.firstIndex(where: { $0.directory == directory }) else { return }
        // The untitled workspace is the window's fallback: closing it on its own
        // would only reopen it, so it stays.
        if EditorScratchWorkspace.isScratch(directory), projects.count == 1 { return }
        if let bundle = loaded.removeValue(forKey: directory) {
            if directory == activeDirectory { saveShellState(from: bundle.app) }
            teardown(bundle)
        }
        projects.remove(at: index)
        if directory == activeDirectory {
            activeDirectory = nil
            if let settingsWindowID, let display, display.isWindowOpen(settingsWindowID) {
                display.closeWindow(settingsWindowID)
            }
            settingsWindowID = nil
            let neighbours = projects[min(index, projects.count)...] + projects[..<min(index, projects.count)]
            for entry in neighbours {
                if (try? activate(entry.directory)) != nil { break }
            }
            if activeDirectory == nil {
                // Nothing left to show: keep the window usable with the
                // untitled workspace instead of emptying it out.
                openScratchWorkspace()
                if activeDirectory == nil {
                    display?.installNativeMenuBar(projectlessMenu())
                    nativeMenuState = nil
                }
            }
        }
        persist()
        publisher.send()
        display?.requestDisplay()
    }

    private func persist() {
        let catalog = Dictionary(uniqueKeysWithValues: projects.map { ($0.directory, $0.name) })
        for bundle in loadedBundles { bundle.app.setPluginWorkspaceCatalog(catalog) }
        // The scratch workspace is created on demand in Application Support, so
        // it stays out of the saved list: the next launch restores the user's
        // own projects instead of reopening it.
        let paths = projects.map(\.directory).filter { !EditorScratchWorkspace.isScratch($0) }
        let active = activeDirectory.flatMap { EditorScratchWorkspace.isScratch($0) ? nil : $0 }
        EditorProjectList(paths: paths, active: active).save()
    }

    // MARK: Window

    @MainActor func wireDisplay(_ display: AppDisplayHandle) {
        self.display = display
        frameCadence = EditorFrameCadence()
        expandEditorWindowIfReady()
        for bundle in loadedBundles { wireAppDisplay(bundle.app, display: display) }
        display.setWindowCloseInterceptor { [weak self, weak display] windowID in
            guard let self else { return true }
            // Auxiliary windows (settings) close freely; only the main window
            // and whole-app quit guard unsaved work.
            if let windowID, windowID != display?.mainWindowID { return true }
            self.closeAnswered.removeAll()
            return !self.askBeforeClose(windowID: windowID)
        }
        if let bundle {
            display.setVSyncEnabled(bundle.app.store.state.vsyncMode.isEnabled)
            refreshNativeMenu(bundle, display: display, force: true)
        } else {
            display.installNativeMenuBar(projectlessMenu())
        }
    }

    /// Called after the user answers one project's unsaved changes for a window
    /// close: asks the next project, or closes once none is left.
    @MainActor func continueClose(windowID: UInt32?, after app: EditorApplication) {
        closeAnswered.insert(ObjectIdentifier(app))
        guard !askBeforeClose(windowID: windowID), let display else { return }
        if let windowID { display.closeWindow(windowID) } else { display.quit() }
    }

    /// Shows the unsaved-changes prompt in the first project that still needs one.
    @MainActor private func askBeforeClose(windowID: UInt32?) -> Bool {
        let ordered = (bundle.map { [$0] } ?? []) + loadedBundles.filter { $0.app !== bundle?.app }
        guard let next = ordered.first(where: { candidate in
            !closeAnswered.contains(ObjectIdentifier(candidate.app))
                && (candidate.app.hasUnsavedSceneChanges || candidate.app.workstation.hasUnsavedChanges)
        }) else { return false }
        try? activate(next.app.projectDirectory)
        next.app.store.dispatch(.requestClose(EditorPendingCloseRequest(windowID: windowID)))
        return true
    }

    @MainActor func projectlessMenu() -> NativeMenuBar {
        EditorNativeMenuBuilder.projectless { [weak self] in self?.requestOpenFolder() }
    }

    @MainActor func wireDiagnostics(_ diagnostics: UIDiagnostics?) {
        self.diagnostics = diagnostics
        for bundle in loadedBundles { bundle.app.setUIDiagnostics(diagnostics) }
    }

    /// Only the project in front simulates and renders; the others' agents run on their own tasks.
    @MainActor func tick(deltaTime: Double) {
        expandEditorWindowIfReady()
        synchronizeFrameCadence()
        bundle?.app.tick(deltaTime: deltaTime)
    }

    @MainActor private func synchronizeFrameCadence() {
        guard let display else { return }
        let state = bundle?.app.store.state
        let continuous = state.map { state in
            EditorViewportFrameDrive.wantsContinuousFrames(
                viewportRealtimeEnabled: state.viewport.realtimeEnabled,
                playbackState: state.timing.playbackState,
                continuousViewportInteractionActive: EditorViewportInputController.shared.isContinuousSceneInteractionActive)
        } ?? false
        if let mode = frameCadence.update(continuous: continuous, vsyncEnabled: state?.vsyncMode.isEnabled ?? true) {
            display.setFrameRateMode(mode)
        }
    }

    @MainActor private func expandEditorWindowIfReady() {
        guard shouldExpandEditorWindow, let display, display.mainWindowID != nil else { return }
        display.maximizeWindow()
        shouldExpandEditorWindow = false
    }

    @MainActor func shutdown() {
        if let bundle {
            saveShellState(from: bundle.app)
            EditorRootViewFactory.saveWorkspaceLayout(bundle.controller)
        }
        for bundle in loadedBundles { teardown(bundle) }
        loaded.removeAll()
        nativeMenuState = nil
    }

    // MARK: Loading

    @MainActor private func makeBundle(directory: String) throws -> EditorLaunchBundle {
        let app = try EditorApplication(
            projectDirectory: directory,
            renderDevice: renderDevice,
            inGameUI: inGameUI,
            events: events,
            initialAISettings: shellState?.aiSettings ?? .default,
            initialCapabilitySettings: shellState?.capabilitySettings ?? .default
        )
        app.setPluginPeers { [weak self] in self?.loadedBundles.map(\.app) ?? [] }
        app.setPluginWorkspaceResolver { [weak self] directory in
            guard let self, self.projects.contains(where: { $0.directory == directory }) else { throw PluginCommandError.unavailable }
            if let loaded = self.loaded[directory] { return loaded.app }
            let next = try self.makeBundle(directory: directory)
            self.loaded[directory] = next
            self.persist()
            return next.app
        }
        app.setCloseProjectHandler { [weak self, weak app] in
            MainActor.assumeIsolated {
                guard let self, let app else { return }
                self.closeProject(app.projectDirectory)
            }
        }
        app.bootstrap()
        app.setUIDiagnostics(diagnostics)
        app.workstation.versionControl.startMonitoring()
        Task { @MainActor in await app.workstation.tasks.refresh() }
        if EditorAppLaunchOptions.watchPluginPackagesRequested {
            app.startWatchingPluginPackages()
        }
        if let path = EditorAppLaunchOptions.reviewPluginPath {
            Task { @MainActor in
                await app.inspectPluginForManagement(at: URL(fileURLWithPath: path, isDirectory: true))
            }
        }
        applyShellState(to: app)

        // Restore the project's saved scene (File → Save Scene writes
        // .cove/editor-scene-manifest.json). Without this, saved edits only
        // come back via a manual File → Open Scene — a relaunch always showed
        // the seeded preview scene.
        let hasScene = app.restoreProjectSceneAtLaunch() != nil

        let registry = EditorRootViewFactory.makeRegistry(app: app)
        // A project with a saved scene opens on it; any other project opens on its code.
        let controller = EditorRootViewFactory.makeController(registry: registry, content: hasScene ? .scene : .files)
        let bundle = EditorLaunchBundle(app: app, controller: controller, registry: registry)
        bundle.contentToken = EditorContentFollower.follow(controller, app: app)

        EditorWorkbenchLink.of(app).controller = controller
        app.setActivatePanelHandler { [weak controller] id in
            guard let controller else { return }
            EditorRootViewFactory.activatePanel(WorkspacePanelID(rawValue: id), in: controller)
        }
        subscribeShellPreferences(bundle)
        subscribeWorkspacePersistence(bundle)
        subscribeNativeMenu(bundle)
        app.setWorkbenchChangeHandler { [weak self, weak bundle] in
            guard let self, let bundle else { return }
            self.relayoutWorkbench(bundle)
        }
        app.setPluginNotificationHandler { [weak app] text, isError in
            guard let app else { return }
            EditorNotifications.of(app).post(text, id: "plugin", tone: isError ? .danger : .info, duration: isError ? nil : 2)
        }
        if let display { wireAppDisplay(app, display: display) }
        return bundle
    }

    @MainActor private func teardown(_ bundle: EditorLaunchBundle) {
        let app = bundle.app
        if let token = bundle.shellPreferenceToken { app.store.unsubscribe(token) }
        if let token = bundle.nativeMenuToken { app.store.unsubscribe(token) }
        if let token = bundle.documentMenuToken { app.workstation.documents._unregisterObserver(token) }
        if let token = bundle.workspaceSubscriptionToken { bundle.controller.unsubscribe(token) }
        if let token = bundle.contentToken { bundle.controller.unsubscribe(token) }
        bundle.workspacePersistenceTask?.cancel()
        app.setCloseProjectHandler(nil)
        app.setOpenSettingsWindowHandler(nil)
        app.setDisplayInvalidationHandler(nil)
        app.setViewportRenderCompletionHandler(nil)
        app.setVSyncModeHandler(nil)
        app.shutdown()
        EditorNotifications.release(app)
        EditorWorkbenchLink.release(app)
        EditorAssistantSurface.release(app)
        EditorRecentCommands.release(app)
    }

    /// Window preferences are shared: the project coming to the front takes the latest ones.
    @MainActor private func applyShellState(to app: EditorApplication) {
        guard let s = shellState else { return }
        app.store.dispatch(.setThemeMode(s.themeMode))
        app.store.dispatch(.setThemeID(s.themeID))
        app.store.dispatch(.setLanguage(s.language))
        app.store.dispatch(.setVSyncMode(s.vsyncMode))
        app.store.dispatch(.setPrimarySelectBehavior(s.primarySelectBehavior))
        app.store.dispatch(.setCapabilitySettings(s.capabilitySettings))
        EditorLocalizationPreferences.language = s.language
    }

    private func saveShellState(from app: EditorApplication) {
        let state = app.store.state
        shellState = .init(themeMode: state.themeMode, themeID: state.presentation.themeID,
                           language: state.language,
                           vsyncMode: state.vsyncMode,
                           primarySelectBehavior: state.selection.primarySelectBehavior,
                           aiSettings: state.assistant.aiSettings,
                           capabilitySettings: state.assistant.capabilitySettings)
        EditorRootViewFactory.saveShellState(
            themeMode: state.themeMode, themeID: state.presentation.themeID,
            language: state.language,
            vsyncMode: state.vsyncMode,
            primarySelectBehavior: state.selection.primarySelectBehavior,
            aiSettings: state.assistant.aiSettings,
            capabilitySettings: state.assistant.capabilitySettings
        )
    }

    @MainActor private func wireAppDisplay(_ app: EditorApplication, display: AppDisplayHandle) {
        app.setVSyncModeHandler { [weak self, weak app] mode in
            guard let self, let app, app === self.bundle?.app else { return }
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
            settingsWindowID = display.openWindow(title: L("Settings"), width: 1040, height: 780) {
                EditorSettingsWindowRoot(app: app)
            }
        }
    }

    private struct NativeMenuState: Equatable {
        var project: ObjectIdentifier
        var commands: EditorCommandContext
        var language: EditorLanguage
    }

    @MainActor
    private func subscribeNativeMenu(_ bundle: EditorLaunchBundle) {
        let app = bundle.app
        bundle.nativeMenuToken = app.store.subscribe { [weak self, weak bundle] _ in
            MainActor.assumeIsolated {
                guard let self, let bundle, let display = self.display else { return }
                self.refreshNativeMenu(bundle, display: display)
            }
        }
        bundle.documentMenuToken = app.workstation.documents._registerObserver { [weak self, weak bundle] in
            MainActor.assumeIsolated {
                guard let self, let bundle, let display = self.display else { return }
                self.refreshNativeMenu(bundle, display: display)
            }
        }
    }

    /// Packages start after the workbench is built and may come and go while it
    /// runs, so their panels and commands join and leave the live layout.
    @MainActor
    private func relayoutWorkbench(_ bundle: EditorLaunchBundle) {
        EditorRootViewFactory.syncContributedPanels(app: bundle.app, registry: bundle.registry)
        bundle.controller.replace(EditorRootViewFactory.reconciledWorkspaceDocument(bundle.controller.document,
                                                                                    registry: bundle.registry))
        if let display { refreshNativeMenu(bundle, display: display) }
        bundle.app.requestDisplayRefresh()
    }

    /// The menu bar follows the project in front only.
    @MainActor
    private func refreshNativeMenu(_ bundle: EditorLaunchBundle, display: AppDisplayHandle, force: Bool = false) {
        let app = bundle.app
        guard app === self.bundle?.app else { return }
        let next = NativeMenuState(project: ObjectIdentifier(app), commands: EditorCommandContext(app: app),
                                   language: app.store.state.language)
        guard force || next != nativeMenuState else { return }
        nativeMenuState = next
        // Menu labels are built outside the Compose presentation boundary, so
        // explicitly align the localization preference before regenerating.
        EditorLocalizationPreferences.language = next.language
        display.installNativeMenuBar(EditorNativeMenuBuilder.make(
            catalog: .make(next.commands),
            onCommand: { [weak app, weak bundle] command in
                guard let app, let bundle else { return }
                EditorCommandDispatcher.handle(command,
                                               app: app,
                                               controller: bundle.controller,
                                               registry: bundle.registry)
            }
        ))
    }

    private func subscribeShellPreferences(_ bundle: EditorLaunchBundle) {
        let app = bundle.app
        var lastPrefs = shellPrefs(app.store)
        bundle.shellPreferenceToken = app.store.subscribe { [weak self, weak bundle] store in
            guard let self else { return }
            let next = self.shellPrefs(store)
            guard next != lastPrefs else { return }
            if next.language != lastPrefs.language, let bundle {
                EditorLocalizationPreferences.language = next.language
                EditorRootViewFactory.localizeWorkspaceTitles(in: bundle.controller, registry: bundle.registry)
                EditorRootViewFactory.localizePanelTitles(in: bundle.registry)
                EditorRootViewFactory.saveWorkspaceLayout(bundle.controller)
            }
            lastPrefs = next
            self.saveShellState(from: app)
            app.requestDisplayRefresh()
        }
    }

    @MainActor
    private func subscribeWorkspacePersistence(_ bundle: EditorLaunchBundle) {
        bundle.workspaceSubscriptionToken = bundle.controller.subscribe { [weak self, weak bundle] _ in
            Task { @MainActor in
                guard let self, let bundle else { return }
                self.scheduleWorkspacePersistence(bundle)
            }
        }
    }

    @MainActor
    private func scheduleWorkspacePersistence(_ bundle: EditorLaunchBundle) {
        bundle.workspacePersistenceTask?.cancel()
        bundle.workspacePersistenceTask = Task { @MainActor [weak bundle] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let bundle else { return }
            EditorRootViewFactory.saveWorkspaceLayout(bundle.controller)
            bundle.workspacePersistenceTask = nil
        }
    }

    private typealias ShellPrefs = (
        themeMode: EditorThemeMode,
        themeID: String,
        language: EditorLanguage,
        vsyncMode: EditorVSyncMode,
        primarySelectBehavior: SelectionPrimaryModifierBehavior,
        capabilitySettings: EditorCapabilitySettings
    )

    private func shellPrefs(_ store: EditorStore) -> ShellPrefs {
        (store.state.themeMode,
         store.state.presentation.themeID,
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

/// One loaded project and the subscriptions that tie it to the window.
final class EditorLaunchBundle {
    let app: EditorApplication
    let controller: WorkspaceController
    let registry: WorkspacePanelRegistry
    fileprivate var shellPreferenceToken: EditorStore.SubscriptionToken?
    fileprivate var nativeMenuToken: EditorStore.SubscriptionToken?
    /// Document edits do not pass through the store, but Save and Close File
    /// availability depends on them.
    fileprivate var documentMenuToken: AnyHashable?
    fileprivate var workspaceSubscriptionToken: WorkspaceController.SubscriptionToken?
    fileprivate var contentToken: WorkspaceController.SubscriptionToken?
    fileprivate var workspacePersistenceTask: Task<Void, Never>?

    init(app: EditorApplication, controller: WorkspaceController, registry: WorkspacePanelRegistry) {
        self.app = app
        self.controller = controller
        self.registry = registry
    }
}
