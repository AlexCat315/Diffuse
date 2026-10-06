import EditorCore
import Foundation
import GuavaUIApp
import GuavaUIRuntime
import GuavaUIWorkspace
#if canImport(AppKit)
import AppKit
#endif

enum EditorCommandDispatcher {
    static func isEnabled(_ command: EditorMenuCommand,
                          sceneCommandEnabled: Bool,
                          focusChain: FocusChain? = FocusChainHolder.current) -> Bool {
        switch command {
        case .undo:
            if let available = focusChain?.textEditAvailability(.undo) { return available }
        case .redo:
            if let available = focusChain?.textEditAvailability(.redo) { return available }
        default: break
        }
        guard focusChain?.modalRoot == nil else { return false }
        return sceneCommandEnabled
    }

    static func handle(_ command: EditorMenuCommand,
                       app: EditorApplication,
                       controller: WorkspaceController,
                       registry: PanelRegistry, fromCommandPalette: Bool = false) {
        let focus = FocusChainHolder.current
        if !fromCommandPalette, case .undo = command, focus?.performTextEdit(.undo) == true { return }
        if !fromCommandPalette, case .redo = command, focus?.performTextEdit(.redo) == true { return }
        guard fromCommandPalette || focus?.modalRoot == nil else { return }
        let store = app.store

        switch command {
        case .showCommandPalette:
            store.dispatch(.setCommandPaletteVisible(true))
        case .showSceneSettings:
            store.dispatch(.setInspectorSceneSettingsVisible(true))
            EditorRootViewFactory.activatePanel("inspector", in: controller)
        case .showAssets:
            EditorRootViewFactory.activatePanel("assets", in: controller)
        case .showProblems:
            store.dispatch(.setOutputTab(.problems))
            EditorRootViewFactory.activatePanel("console", in: controller)
        case let .maximizePanel(id):
            let panelID = PanelID(rawValue: id)
            EditorRootViewFactory.activatePanel(panelID, in: controller)
            _ = controller.dispatch(.toggleMaximize(panelID))
        case .restorePanels:
            _ = controller.dispatch(.restoreMaximized)
        case .saveLayout:
            EditorRootViewFactory.saveWorkspaceLayout(controller, for: store.workspaceMode,
                                                      preset: store.activeLayoutPreset)
            app.logConsole("Workspace layout saved")
        case .closeProject:
            app.requestCloseProject()
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
            guard EditorSceneAuthoringPolicy.canEditScene(during: store.state.timing.playbackState) else {
                app.logConsole("Stop simulation before duplicating entities", severity: .warning)
                return
            }
            guard let selected = store.state.selection.selectedEntityID else {
                app.logConsole("Nothing to duplicate", severity: .warning)
                return
            }
            guard !app.scene.isEntityLocked(selected) else {
                app.logConsole("Cannot duplicate a locked entity", severity: .warning)
                return
            }
            if let newID = app.scene.duplicateEntity(selected) {
                store.dispatch(.setSelectedEntity(newID))
            } else {
                app.logConsole("Could not duplicate selection", severity: .error)
            }
        case .deleteSelection:
            guard EditorSceneAuthoringPolicy.canEditScene(during: store.state.timing.playbackState) else {
                app.logConsole("Stop simulation before deleting entities", severity: .warning)
                return
            }
            let selectedIDs = store.state.selection.selectedEntityIDs
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
            } else {
                app.logConsole("Could not delete selection", severity: .error)
            }
        case let .setWorkspaceMode(next):
            guard store.state.workspace.mode != next else { return }
            if !next.isGameWorkspace { app.setViewportMode(.scene) }
            let previousMode = store.state.workspace.mode
            let previousPreset = store.state.workspace.layoutPreset
            EditorRootViewFactory.saveWorkspaceLayout(controller, for: previousMode, preset: previousPreset)
            store.dispatch(.setWorkspaceMode(next))
            let nextPreset = store.state.workspace.layoutPreset
            EditorRootViewFactory.loadLayoutPreset(into: controller, for: next, preset: nextPreset, registry: registry)
            saveShellState(app)
        case let .setLayoutPreset(nextPreset):
            let mode = nextPreset.mode
            guard nextPreset != store.state.workspace.layoutPreset
                    || mode != store.state.workspace.mode else { return }
            let previousMode = store.state.workspace.mode
            let previousPreset = store.state.workspace.layoutPreset
            EditorRootViewFactory.saveWorkspaceLayout(controller,
                                                       for: previousMode,
                                                       preset: previousPreset)
            if mode != previousMode {
                if !mode.isGameWorkspace { app.setViewportMode(.scene) }
                store.dispatch(.setWorkspaceMode(mode))
            }
            store.dispatch(.setActiveLayoutPreset(nextPreset))
            EditorRootViewFactory.loadLayoutPreset(into: controller, for: mode, preset: nextPreset, registry: registry)
            saveShellState(app)
        case .resetLayout:
            let mode = store.state.workspace.mode
            let preset = store.state.workspace.layoutPreset
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
                                                       for: store.state.workspace.mode,
                                                       preset: store.state.workspace.layoutPreset)
        case .showScripts:
            EditorRootViewFactory.activatePanel("scripts", in: controller)
        case let .setPlaybackState(next):
            guard EditorPlaybackCommandPolicy.canTransition(from: store.state.timing.playbackState,
                                                            to: next) else { return }
            app.applyPlaybackState(next)
        case .openSettings:
            app.openSettingsWindow()
        case .toggleTheme:
            store.dispatch(.setThemeMode(store.state.themeMode == .dark ? .light : .dark))
        case .buildProject:
            guard store.workspaceMode.isGameWorkspace else { return }
            app.requestProjectExport()
        case .buildAndRun:
            guard store.workspaceMode.isGameWorkspace else { return }
            app.requestProjectExport(runAfterExport: true)
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
        EditorRootViewFactory.saveShellState(mode: state.workspace.mode,
                                             preset: state.workspace.layoutPreset,
                                             themeMode: state.themeMode,
                                             language: state.language,
                                             vsyncMode: state.vsyncMode,
                                             primarySelectBehavior: state.selection.primarySelectBehavior,
                                             aiSettings: state.assistant.aiSettings,
                                             capabilitySettings: state.assistant.capabilitySettings)
    }
}
