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
        let cb = EditorCallbacks(app: app, controller: controller, registry: registry)
        StoreScope(app.store) { store in
            EditorPresentationBoundary(presentation: store.presentation) {
                LayerRoot {
                    Box(direction: .column, alignItems: .stretch, spacing: 0) {
                        ShortcutHost(onKeyDown: cb.handleShortcut)

                        PanelWorkspace(controller: controller,
                                       registry: registry)
                            .flex()
                            .layoutRole("editor-workspace")
                            .debugName("editor-workspace")

                        Divider()

                        EditorStatusBar(store: app.store, getTiming: { app.currentFrameTiming() })
                            .layoutRole("editor-status-bar")
                            .debugName("editor-status-bar")
                    }
                    .background(.background)
                    .flex()
                } portals: {
                    PortalHost()
                }
            }
        }
    }
}

private struct EditorCallbacks {
    let handleShortcut: (KeyEvent) -> Bool

    init(app: EditorApplication, controller: WorkspaceController, registry: PanelRegistry) {
        self.handleShortcut = { key in
            let s = app.store
            return EditorShortcutHandler.handle(key,
                                                 playbackState: s.state.playbackState,
                                                 setPlaybackState: { next in if s.state.playbackState != next { s.dispatch(.setPlaybackState(next)) } },
                                                 setWorkspaceMode: { next in
                                                     guard s.state.workspaceMode != next else { return }
                                                     let p = s.state.workspaceMode; let pp = s.state.activeLayoutPreset
                                                     EditorRootViewFactory.saveWorkspaceLayout(controller, for: p, preset: pp)
                                                     s.dispatch(.setWorkspaceMode(next))
                                                     let np = s.state.activeLayoutPreset
                                                     EditorRootViewFactory.loadLayoutPreset(into: controller, for: next, preset: np, registry: registry)
                                                     EditorRootViewFactory.saveShellState(mode: next, preset: np, themeMode: s.state.themeMode, language: s.state.language, vsyncMode: s.state.vsyncMode, primarySelectBehavior: s.state.primarySelectBehavior)
                                                 },
                                                 resetLayout: {
                                                     let m = s.state.workspaceMode; let p = s.state.activeLayoutPreset
                                                     EditorRootViewFactory.resetLayout(into: controller, for: m, preset: p, registry: registry)
                                                     EditorRootViewFactory.saveWorkspaceLayout(controller, for: m, preset: p)
                                                     EditorRootViewFactory.saveShellState(mode: m, preset: p, themeMode: s.state.themeMode, language: s.state.language, vsyncMode: s.state.vsyncMode, primarySelectBehavior: s.state.primarySelectBehavior)
                                                 },
                                                 newScene: { app.resetPreviewScene() },
                                                 openSettings: { app.openSettingsWindow() })
        }
    }
}
