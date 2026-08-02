import EditorCore
import Foundation
import GuavaUIApp
import GuavaUIWorkspace
#if canImport(AppKit)
import AppKit
#endif

enum EditorCommandDispatcher {
    static func handle(_ command: EditorMenuCommand,
                       app: EditorApplication,
                       controller: WorkspaceController,
                       registry: PanelRegistry) {
        let store = app.store

        switch command {
        case .newScene:
            app.requestNewScene()
        case .openScene:
            EditorSceneFileCoordinator.requestOpen(app: app)
        case .saveScene:
            _ = app.saveSceneManifest()
        case .importAssets:
            EditorRootViewFactory.activatePanel("assets", in: controller)
            EditorAssetImportCoordinator.requestImport(app: app)
        case .undo:
            app.undo()
        case .redo:
            app.redo()
        case .duplicateSelection:
            guard let selected = store.state.selectedEntityID else {
                app.logConsole("Nothing to duplicate", severity: .warning)
                return
            }
            guard !app.scene.isEntityLocked(selected) else {
                app.logConsole("Cannot duplicate a locked entity", severity: .warning)
                return
            }
            if let newID = app.scene.duplicateEntity(selected) {
                store.dispatch(.setSelectedEntity(newID))
            }
        case .deleteSelection:
            let selectedIDs = store.state.selectedEntityIDs
            guard !selectedIDs.isEmpty else {
                app.logConsole("Nothing to delete", severity: .warning)
                return
            }
            guard selectedIDs.allSatisfy({ !app.scene.isEntityLocked($0) }) else {
                app.logConsole("Cannot delete locked entities", severity: .warning)
                return
            }
            if app.scene.deleteEntities(selectedIDs) {
                store.dispatch(.setSelectedEntity(nil))
            }
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
        case .reopenClosedPanel:
            let result = controller.dispatch(.reopenLastClosed)
            guard result.didChange else {
                app.logConsole("No closed panel to reopen", severity: .warning)
                return
            }
            EditorRootViewFactory.saveWorkspaceLayout(controller,
                                                       for: store.state.workspaceMode,
                                                       preset: store.state.activeLayoutPreset)
        case let .setPlaybackState(next):
            guard EditorPlaybackCommandPolicy.canTransition(from: store.state.playbackState,
                                                            to: next) else { return }
            app.applyPlaybackState(next)
        case .openSettings:
            app.openSettingsWindow()
        case .toggleTheme:
            store.dispatch(.setThemeMode(store.state.themeMode == .dark ? .light : .dark))
        case .buildProject:
            _ = app.exportProject()
        case .buildAndRun:
            if let output = app.exportProject() {
                _ = app.runExportedProject(at: output)
            }
        case .openDocumentation:
            openDocumentation(app: app)
        case .about:
            openAboutWindow(app: app)
        }
    }

    private static func openDocumentation(app: EditorApplication) {
        guard let url = URL(string: "https://github.com/AlexCat315/Guava-Engine/tree/main/docs") else {
            app.logConsole("Unable to open documentation", severity: .error)
            return
        }
        #if canImport(AppKit)
        guard NSWorkspace.shared.open(url) else {
            app.logConsole("Unable to open documentation", severity: .error, detail: url.absoluteString)
            return
        }
        app.logConsole("Opened documentation", detail: url.absoluteString)
        #else
        app.logConsole("Documentation", detail: url.absoluteString)
        #endif
    }

    private static func openAboutWindow(app: EditorApplication) {
        guard let display = AppDisplayHandleHolder.current else {
            app.logConsole("Unable to open About", severity: .error, detail: "No active display")
            return
        }
        MainActor.assumeIsolated {
            _ = display.openWindow(title: L("About Guava"), width: 440, height: 280) {
                EditorAboutView()
            }
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
