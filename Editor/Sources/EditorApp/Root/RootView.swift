import EditorCore
import EngineKernel
import GuavaUIApp
import GuavaUICompose
import GuavaUIRuntime
import GuavaUIWorkspace
import Foundation

struct EditorRootView: View {
    let app: EditorApplication
    let controller: WorkspaceController
    let registry: PanelRegistry

    var body: some View {
        StoreScope(app.store) { store in
            let cb = EditorCallbacks(app: app, controller: controller, registry: registry,
                                     commandPaletteVisible: store.commandPaletteVisible)
            EditorPresentationBoundary(presentation: store.presentation) {
                LayerRoot {
                    Box(direction: .column, alignItems: .stretch, spacing: 0) {
                        ShortcutHost(onKeyDown: cb.handleShortcut)

                        ImmersiveWindowTitleBar {
                            Row(alignment: .center, spacing: 8) {
                                EditorApplicationMenuBar(
                                    workspaceMode: store.workspaceMode,
                                    activeLayoutPreset: store.activeLayoutPreset,
                                    playbackState: store.playbackState,
                                    canUndo: app.canUndo,
                                    canRedo: app.canRedo,
                                    hasSelection: !store.selectedEntityIDs.isEmpty,
                                    onCommand: cb.handleMenuCommand
                                )

                                LayoutPresetSelector(
                                    workspaceMode: store.workspaceMode,
                                    activePreset: store.activeLayoutPreset,
                                    onSelectPreset: { preset in
                                        cb.handleMenuCommand(.setLayoutPreset(preset))
                                    }
                                )
                            }
                        }

                        // Floating-island chrome: no full-width divider — the
                        // canvas margin separates the title bar from the
                        // workspace, and the rounded panel slabs carry the
                        // structure.
                        PanelWorkspace(controller: controller,
                                       registry: registry)
                            .flex()
                            .frame(minWidth: 0, minHeight: 0)
                            .padding(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
                            .layoutRole("editor-workspace")
                            .debugName("editor-workspace")

                        EditorStatusBar(store: store)
                    }
                    .background(.background)
                    .flex()
                    .frame(width: .percent(100),
                           height: .percent(100),
                           minWidth: 0,
                           minHeight: 0)
                } portals: {
                    PortalHost()
                    if store.commandPaletteVisible {
                        CommandPaletteOverlay(app: app)
                    }
                    if let pendingClose = store.pendingCloseRequest {
                        UnsavedChangesDialog(app: app, request: pendingClose)
                    }
                }
            }
        }
    }
}

private struct EditorCallbacks {
    let handleShortcut: (KeyEvent) -> Bool
    let handleMenuCommand: (EditorMenuCommand) -> Void

    init(app: EditorApplication,
         controller: WorkspaceController,
         registry: PanelRegistry,
         commandPaletteVisible: Bool) {
        self.handleMenuCommand = { command in
            EditorCommandDispatcher.handle(command, app: app, controller: controller, registry: registry)
        }
        self.handleShortcut = { key in
            let s = app.store
            return EditorShortcutHandler.handle(
                key,
                playbackState: s.state.playbackState,
                commandPaletteVisible: commandPaletteVisible,
                setPlaybackState: { next in
                    EditorCommandDispatcher.handle(.setPlaybackState(next),
                                                   app: app,
                                                   controller: controller,
                                                   registry: registry)
                },
                setWorkspaceMode: { next in
                    EditorCommandDispatcher.handle(.setWorkspaceMode(next),
                                                   app: app,
                                                   controller: controller,
                                                   registry: registry)
                },
                resetLayout: {
                    EditorCommandDispatcher.handle(.resetLayout,
                                                   app: app,
                                                   controller: controller,
                                                   registry: registry)
                },
                reopenClosedPanel: {
                    EditorCommandDispatcher.handle(.reopenClosedPanel,
                                                   app: app,
                                                   controller: controller,
                                                   registry: registry)
                },
                newScene: {
                    EditorCommandDispatcher.handle(.newScene, app: app, controller: controller, registry: registry)
                },
                openScene: {
                    EditorCommandDispatcher.handle(.openScene, app: app, controller: controller, registry: registry)
                },
                saveScene: {
                    EditorCommandDispatcher.handle(.saveScene, app: app, controller: controller, registry: registry)
                },
                duplicateSelection: {
                    EditorCommandDispatcher.handle(.duplicateSelection,
                                                   app: app,
                                                   controller: controller,
                                                   registry: registry)
                },
                deleteSelection: {
                    EditorCommandDispatcher.handle(.deleteSelection,
                                                   app: app,
                                                   controller: controller,
                                                   registry: registry)
                },
                buildProject: {
                    EditorCommandDispatcher.handle(.buildProject, app: app, controller: controller, registry: registry)
                },
                buildAndRun: {
                    EditorCommandDispatcher.handle(.buildAndRun, app: app, controller: controller, registry: registry)
                },
                openSettings: {
                    EditorCommandDispatcher.handle(.openSettings,
                                                   app: app,
                                                   controller: controller,
                                                   registry: registry)
                },
                openCommandPalette: { s.dispatch(.setCommandPaletteVisible(true)) },
                closeCommandPalette: { s.dispatch(.setCommandPaletteVisible(false)) },
                undo: {
                    EditorCommandDispatcher.handle(.undo, app: app, controller: controller, registry: registry)
                },
                redo: {
                    EditorCommandDispatcher.handle(.redo, app: app, controller: controller, registry: registry)
                }
            )
        }
    }
}
