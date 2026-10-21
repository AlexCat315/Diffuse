internal import EditorCore
private import Foundation
internal import GuavaUI
internal import GuavaUIRuntime
internal import GuavaUIWorkspace
#if canImport(AppKit)
private import AppKit
#endif

enum EditorCommandDispatcher {
    static func isEnabled(_ command: EditorCommand,
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

    static func handle(_ command: EditorCommand,
                       app: EditorApplication,
                       controller: WorkspaceController,
                       registry: WorkspacePanelRegistry, fromCommandPalette: Bool = false) {
        let focus = FocusChainHolder.current
        if !fromCommandPalette, case .undo = command, focus?.performTextEdit(.undo) == true { return }
        if !fromCommandPalette, case .redo = command, focus?.performTextEdit(.redo) == true { return }
        guard fromCommandPalette || focus?.modalRoot == nil else { return }
        let store = app.store
        guard EditorWorkspaceCommandPolicy.allows(command, in: store.workspaceMode) else { return }
        switch command {
        case let .showCommandPalette(scope):
            store.dispatch(.setCommandPaletteQuery(TextBuffer(scope.prefix)))
            store.dispatch(.setCommandPaletteVisible(true))
        case .showSceneSettings:
            store.dispatch(.setInspectorSceneSettingsVisible(true))
            EditorRootViewFactory.activatePanel("inspector", in: controller)
        case .showAssets:
            EditorRootViewFactory.activatePanel("assets", in: controller)
        case .showProblems:
            store.dispatch(.setOutputTab(.problems))
            EditorRootViewFactory.activatePanel("console", in: controller)
        case let .showPanel(id):
            if id == "inspector" { store.dispatch(.setInspectorSceneSettingsVisible(false)) }
            EditorRootViewFactory.activatePanel(WorkspacePanelID(rawValue: id), in: controller)
        case let .maximizePanel(id):
            let panelID = WorkspacePanelID(rawValue: id)
            EditorRootViewFactory.activatePanel(panelID, in: controller)
            _ = controller.dispatch(.toggleMaximize(panelID))
        case let .togglePanel(id):
            let panelID = WorkspacePanelID(rawValue: id)
            if let group = controller.document.groupContaining(panelID: panelID), group.activePanelID == panelID,
               !group.isCollapsed, controller.maximizedPanelID == nil,
               controller.dispatch(.collapse(group.id)).didChange {
                return
            }
            handle(.showPanel(id), app: app, controller: controller, registry: registry,
                   fromCommandPalette: fromCommandPalette)
        case let .togglePanelArea(area):
            togglePanelArea(area, in: controller)
        case .restorePanels:
            _ = controller.dispatch(.restoreMaximized)
            for group in controller.document.groups.values where group.isCollapsed {
                _ = controller.dispatch(.expand(group.id))
            }
        case .saveLayout:
            EditorRootViewFactory.saveWorkspaceLayout(controller, for: store.workspaceMode,
                                                      preset: store.activeLayoutPreset)
            app.logConsole("Workspace layout saved")
            EditorNotifications.of(app).post(L("Workspace layout saved"), id: "layout")
        case .closeProject:
            app.requestCloseProject()
        case .newScene:
            app.requestNewScene()
        case .openScene:
            EditorSceneFileCoordinator.requestOpen(app: app)
        case .saveScene:
            if app.saveSceneManifest() != nil {
                EditorNotifications.of(app).post(L("Scene saved"), id: "save", tone: .success)
            } else {
                EditorNotifications.of(app).post(L("Could not save the scene"), id: "save", tone: .danger, duration: nil,
                                                 action: ToastAction(L("Show Problems")) {
                    handle(.showProblems, app: app, controller: controller, registry: registry, fromCommandPalette: true)
                })
            }
        case .saveDocument:
            let documents = app.workstation.documents
            if let path = documents.selectedPath {
                documents.save(path)
                // A failure stays in the editor's error banner, next to the text.
                if documents.error == nil {
                    let name = path.split(separator: "/").last.map(String.init) ?? path
                    EditorNotifications.of(app).post(L("Saved") + " " + name, id: "save", tone: .success)
                }
            }
        case .revertDocument:
            let documents = app.workstation.documents
            if let path = documents.selectedPath { documents.reload(path, discard: true) }
        case .closeDocument:
            let documents = app.workstation.documents
            if let path = documents.selectedPath { documents.close(path) }
        case .importAssets:
            EditorRootViewFactory.activatePanel("assets", in: controller)
            EditorAssetImportCoordinator.requestImport(app: app)
        case .undo:
            app.undo()
        case .redo:
            app.redo()
        case .duplicateSelection:
            guard EditorSceneAuthoringPolicy.canEditScene(during: store.state.timing.playbackState) else {
                blockedByPlayback("Stop simulation before duplicating entities", app: app)
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
                blockedByPlayback("Stop simulation before deleting entities", app: app)
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
        case .selectAll:
            store.dispatch(.setSelectedEntities(Set(HierarchyPanelModel.allEntityIDs(in: app.scene.roots))))
        case .clearSelection:
            store.dispatch(.setSelectedEntity(nil))
        case .invertSelection:
            let selected = store.state.selection.selectedEntityIDs
            let all = Set(HierarchyPanelModel.allEntityIDs(in: app.scene.roots))
            store.dispatch(.setSelectedEntities(all.subtracting(selected)))
        case .selectDescendants:
            let descendants = HierarchyPanelModel.descendantIDs(of: store.state.selection.selectedEntityIDs,
                                                                in: app.scene.roots, includesSelection: true)
            if !descendants.isEmpty { store.dispatch(.setSelectedEntities(descendants)) }
        case let .spawnEntity(template):
            guard EditorSceneAuthoringPolicy.canEditScene(during: store.state.timing.playbackState) else {
                blockedByPlayback("Stop simulation before adding entities", app: app)
                return
            }
            if let id = app.scene.spawnEntity(template: template) { store.dispatch(.setSelectedEntity(id)) }
        case .frameSelection:
            let selected = store.state.selection.selectedEntityIDs
            if !selected.isEmpty { app.scene.frameEntities(selected) }
        case .toggleSelectionVisibility:
            let selected = store.state.selection.selectedEntityIDs
            guard !selected.isEmpty else { return }
            let allHidden = selected.allSatisfy { !app.scene.isHierarchyVisible($0) }
            if !app.scene.setHierarchyVisibility(allHidden, for: selected) {
                app.logConsole("Could not change hierarchy visibility", severity: .warning)
            }
        case .toggleSelectionLock:
            let selected = store.state.selection.selectedEntityIDs
            guard !selected.isEmpty else { return }
            app.scene.setEntityLocked(!selected.allSatisfy { app.scene.isEntityLocked($0) }, entityIDs: selected)
        case let .setWorkspaceMode(next):
            guard store.state.workspace.mode != next else { return }
            if !next.isGameWorkspace {
                if store.playbackState != .stopped {
                    app.applyPlaybackState(.stopped)
                    EditorNotifications.of(app).post(L("Game stopped"), id: "playback-stopped", duration: 3,
                                                     message: L("This Space does not run the game."))
                }
                app.setViewportMode(.scene)
            }
            let previousMode = store.state.workspace.mode
            let previousPreset = store.state.workspace.layoutPreset
            EditorRootViewFactory.saveWorkspaceLayout(controller, for: previousMode, preset: previousPreset)
            store.dispatch(.setWorkspaceMode(next))
            let nextPreset = store.state.workspace.layoutPreset
            EditorRootViewFactory.loadLayoutPreset(into: controller, for: next, preset: nextPreset, registry: registry)
            saveShellState(app)
        case let .setLayoutPreset(nextPreset):
            let mode = nextPreset.mode
            let previousMode = store.state.workspace.mode
            let previousPreset = store.state.workspace.layoutPreset
            EditorRootViewFactory.saveWorkspaceLayout(controller,
                                                       for: previousMode,
                                                       preset: previousPreset)
            if mode != previousMode {
                if !mode.isGameWorkspace {
                    if store.playbackState != .stopped { app.applyPlaybackState(.stopped) }
                    app.setViewportMode(.scene)
                }
                store.dispatch(.setWorkspaceMode(mode))
            }
            store.dispatch(.setActiveLayoutPreset(nextPreset))
            // A named preset applies its built-in arrangement. Loading the
            // saved custom dock here could make unrelated presets identical.
            EditorRootViewFactory.resetLayout(into: controller, for: mode, preset: nextPreset, registry: registry)
            saveShellState(app)
        case .resetLayout:
            let mode = store.state.workspace.mode
            let preset = store.state.workspace.layoutPreset
            EditorRootViewFactory.resetLayout(into: controller, for: mode, preset: preset, registry: registry)
            EditorRootViewFactory.saveWorkspaceLayout(controller, for: mode, preset: preset)
            saveShellState(app)
            EditorNotifications.of(app).post(L("Layout reset"), id: "layout")
        case .reopenClosedPanel:
            let result = controller.dispatch(.reopenLastClosed)
            guard result.didChange else {
                app.logConsole("No closed panel to reopen", severity: .warning)
                EditorNotifications.of(app).post(L("No closed panel to reopen"), id: "layout")
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
        case .togglePlayback:
            let next = EditorPlaybackCommandPolicy.toggleTarget(from: store.state.timing.playbackState)
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

    private static func blockedByPlayback(_ message: String, app: EditorApplication) {
        app.logConsole(message, severity: .warning)
        EditorNotifications.of(app).postBlockedByPlayback(L(message), app: app)
    }

    /// Collapses every group docked on the edge while any of them shows;
    /// expands them all when the edge is already hidden.
    private static func togglePanelArea(_ area: EditorPanelArea, in controller: WorkspaceController) {
        let slot: WorkspaceSlotID = switch area {
        case .leading: .leading
        case .trailing: .trailing
        case .bottom: .bottom
        }
        let groups = controller.document.slots[slot]?.layout?.leafGroupIDs ?? []
        guard !groups.isEmpty else { return }
        if controller.maximizedPanelID != nil { _ = controller.dispatch(.restoreMaximized) }
        let showing = groups.contains { controller.document.groups[$0]?.isCollapsed == false }
        for id in groups { _ = controller.dispatch(showing ? .collapse(id) : .expand(id)) }
    }

    private static func openDocumentation(app: EditorApplication) {
        guard let url = URL(string: "https://github.com/AlexCat315/GuavaStudio/tree/main/docs") else {
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
        EditorRootViewFactory.saveShellState(workspace: state.workspace,
                                             themeMode: state.themeMode,
                                             language: state.language,
                                             vsyncMode: state.vsyncMode,
                                             primarySelectBehavior: state.selection.primarySelectBehavior,
                                             aiSettings: state.assistant.aiSettings,
                                             capabilitySettings: state.assistant.capabilitySettings)
    }
}
