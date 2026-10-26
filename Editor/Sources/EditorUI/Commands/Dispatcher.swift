internal import EditorCore
private import Foundation
internal import CoveUI
internal import CoveUIRuntime
internal import CoveUIWorkspace
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
        guard EditorWorkspaceCommandPolicy.allows(command, in: store.content) else { return }
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
            let requested = WorkspacePanelID(rawValue: id)
            let panelID = EditorRootViewFactory.dockedPanel(for: requested, in: controller)
            // A sidebar view is showing when the sidebar shows it.
            if panelID != EditorSidebar.panelID || EditorSidebar.of(controller).selection == requested,
               let group = controller.document.groupContaining(panelID: panelID), group.activePanelID == panelID,
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
            EditorRootViewFactory.saveWorkspaceLayout(controller)
            app.logConsole("Workspace layout saved")
            EditorNotifications.of(app).post(L("Workspace layout saved"), id: "layout")
        case .openFolder:
            MainActor.assumeIsolated { EditorLaunchContext.current?.requestOpenFolder() }
        case let .activateProject(directory):
            MainActor.assumeIsolated {
                do { try EditorLaunchContext.current?.activate(directory) }
                catch {
                    EditorNotifications.of(app).post(error.localizedDescription, id: "open-project", tone: .danger, duration: nil)
                }
            }
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
                // A failure stays in the editor's error banner, next to the text.
                Task { @MainActor in
                    guard await app.saveDocumentFormatting(path) else { return }
                    let name = path.split(separator: "/").last.map(String.init) ?? path
                    EditorNotifications.of(app).post(L("Saved") + " " + name, id: "save", tone: .success)
                }
            }
        case .revertDocument:
            let documents = app.workstation.documents
            if let path = documents.selectedPath { app.workstation.revertDocument(path) }
        case .closeDocument:
            let documents = app.workstation.documents
            if let path = documents.selectedPath { app.workstation.closeDocument(path) }
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
        case .focusAssistant:
            EditorAssistantSurface.of(app).focus()
        case let .showView(view):
            EditorAssistantSurface.of(app).show(view)
        case .toggleView:
            EditorAssistantSurface.of(app).toggleView()
        case let .showContent(content):
            EditorContentFollower.show(content, app: app, controller: controller)
        case .resetLayout:
            EditorRootViewFactory.resetLayout(into: controller, registry: registry)
            EditorNotifications.of(app).post(L("Layout reset"), id: "layout")
        case .reopenClosedPanel:
            let result = controller.dispatch(.reopenLastClosed)
            guard result.didChange else {
                app.logConsole("No closed panel to reopen", severity: .warning)
                EditorNotifications.of(app).post(L("No closed panel to reopen"), id: "layout")
                return
            }
            EditorRootViewFactory.saveWorkspaceLayout(controller)
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
            app.requestProjectExport()
        case .buildAndRun:
            app.requestProjectExport(runAfterExport: true)
        case let .runTask(kind):
            let tasks = app.workstation.tasks
            guard tasks.snapshot.isAvailable else { return }
            EditorRootViewFactory.activatePanel("tasks", in: controller)
            if kind == .test { tasks.test() } else { tasks.build() }
        case let .plugin(pluginID, name):
            PluginCommandRunner.run(pluginID: pluginID, name: name, app: app)
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
        guard let url = URL(string: "https://github.com/AlexCat315/Diffuse/tree/main/docs") else {
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
            _ = display.openWindow(title: L("About Cove"), width: 440, height: 280) {
                EditorAboutView()
            }
        }
    }
}
