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

                        EditorApplicationMenuBar(
                            workspaceMode: store.workspaceMode,
                            activeLayoutPreset: store.activeLayoutPreset,
                            playbackState: store.playbackState,
                            onCommand: cb.handleMenuCommand
                        )

                        Divider()

                        PanelWorkspace(controller: controller,
                                       registry: registry)
                            .flex()
                            .frame(minWidth: 0, minHeight: 0)
                            .layoutRole("editor-workspace")
                            .debugName("editor-workspace")

                        Divider()

                        EditorStatusBar(store: app.store, getTiming: { app.currentFrameTiming() })
                            .layoutRole("editor-status-bar")
                            .debugName("editor-status-bar")
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
                    app.applyPlaybackState(next)
                },
                setWorkspaceMode: { next in
                    guard s.state.workspaceMode != next else { return }
                    let p = s.state.workspaceMode; let pp = s.state.activeLayoutPreset
                    EditorRootViewFactory.saveWorkspaceLayout(controller, for: p, preset: pp)
                    s.dispatch(.setWorkspaceMode(next))
                    let np = s.state.activeLayoutPreset
                    EditorRootViewFactory.loadLayoutPreset(into: controller, for: next, preset: np, registry: registry)
                    EditorRootViewFactory.saveShellState(mode: next,
                                                         preset: np,
                                                         themeMode: s.state.themeMode,
                                                         language: s.state.language,
                                                         vsyncMode: s.state.vsyncMode,
                                                         primarySelectBehavior: s.state.primarySelectBehavior,
                                                         aiSettings: s.state.aiSettings,
                                                         capabilitySettings: s.state.capabilitySettings)
                },
                resetLayout: {
                    let m = s.state.workspaceMode; let p = s.state.activeLayoutPreset
                    EditorRootViewFactory.resetLayout(into: controller, for: m, preset: p, registry: registry)
                    EditorRootViewFactory.saveWorkspaceLayout(controller, for: m, preset: p)
                    EditorRootViewFactory.saveShellState(mode: m,
                                                         preset: p,
                                                         themeMode: s.state.themeMode,
                                                         language: s.state.language,
                                                         vsyncMode: s.state.vsyncMode,
                                                         primarySelectBehavior: s.state.primarySelectBehavior,
                                                         aiSettings: s.state.aiSettings,
                                                         capabilitySettings: s.state.capabilitySettings)
                },
                newScene: { app.resetPreviewScene() },
                openSettings: { app.openSettingsWindow() },
                openCommandPalette: { s.dispatch(.setCommandPaletteVisible(true)) },
                closeCommandPalette: { s.dispatch(.setCommandPaletteVisible(false)) },
                undo: { app.undo() },
                redo: { app.redo() }
            )
        }
    }
}
