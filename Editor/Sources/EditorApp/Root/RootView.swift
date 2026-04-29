import EditorCore
import EngineKernel
import GuavaUIApp
import GuavaUICompose
import GuavaUIRuntime
import Foundation

struct EditorRootView: View {
    let app: EditorApplication
    let controller: DockController
    let registry: PanelRegistry

    var body: some View {
        let cb = EditorCallbacks(app: app, controller: controller)
        StoreScope(app.store) { store in
            EditorPresentationBoundary(presentation: store.presentation) {
                Box(direction: .column, alignItems: .stretch, spacing: 0) {
                    ShortcutHost(onKeyDown: cb.handleShortcut)

                    EditorMainToolbar(playbackState: store.playbackState,
                                      workspaceMode: store.workspaceMode,
                                      activeLayoutPreset: store.activeLayoutPreset,
                                      onSetPlaybackState: cb.setPlaybackState,
                                      onSetWorkspaceMode: cb.setWorkspaceMode,
                                      onSetLayoutPreset: cb.setLayoutPreset,
                                      onResetLayout: cb.resetLayout,
                                      onOpenSettings: cb.openSettings)
                    Divider()

                    PanelWorkspace(controller: controller,
                                   registry: registry,
                                   semantics: .ide)
                        .flex()

                    Divider()

                    EditorStatusBar(store: app.store, getTiming: { app.currentFrameTiming() })
                }
                .background(.background)
                .flex()
            }
        }
    }
}

private struct EditorCallbacks {
    let setPlaybackState: (PlaybackState) -> Void
    let setWorkspaceMode: (EditorWorkspaceMode) -> Void
    let setLayoutPreset: (EditorLayoutPreset) -> Void
    let resetLayout: () -> Void
    let openSettings: () -> Void
    let handleShortcut: (KeyEvent) -> Bool

    init(app: EditorApplication, controller: DockController) {
        self.setPlaybackState = { next in
            let s = app.store; if s.state.playbackState != next { s.dispatch(.setPlaybackState(next)) }
        }
        self.setWorkspaceMode = { next in
            let s = app.store
            guard s.state.workspaceMode != next else { return }
            let p = s.state.workspaceMode; let pp = s.state.activeLayoutPreset
            EditorRootViewFactory.saveDockLayout(controller, for: p, preset: pp)
            s.dispatch(.setWorkspaceMode(next))
            let np = s.state.activeLayoutPreset
            EditorRootViewFactory.loadLayoutPreset(into: controller, for: next, preset: np)
            EditorRootViewFactory.saveShellState(mode: next, preset: np, themeMode: s.state.themeMode, language: s.state.language, vsyncMode: s.state.vsyncMode)
        }
        self.setLayoutPreset = { nextPreset in
            let s = app.store
            guard nextPreset != s.state.activeLayoutPreset else { return }
            let m = s.state.workspaceMode; let pp = s.state.activeLayoutPreset
            EditorRootViewFactory.saveDockLayout(controller, for: m, preset: pp)
            s.dispatch(.setActiveLayoutPreset(nextPreset))
            EditorRootViewFactory.loadLayoutPreset(into: controller, for: m, preset: nextPreset)
            EditorRootViewFactory.saveShellState(mode: m, preset: nextPreset, themeMode: s.state.themeMode, language: s.state.language, vsyncMode: s.state.vsyncMode)
        }
        self.resetLayout = {
            let s = app.store
            let m = s.state.workspaceMode; let p = s.state.activeLayoutPreset
            EditorRootViewFactory.resetLayout(into: controller, for: m, preset: p)
            EditorRootViewFactory.saveDockLayout(controller, for: m, preset: p)
            EditorRootViewFactory.saveShellState(mode: m, preset: p, themeMode: s.state.themeMode, language: s.state.language, vsyncMode: s.state.vsyncMode)
        }
        self.openSettings = { app.openSettingsWindow() }
        self.handleShortcut = { key in
            let s = app.store
            return EditorShortcutHandler.handle(key,
                                                 playbackState: s.state.playbackState,
                                                 setPlaybackState: { next in if s.state.playbackState != next { s.dispatch(.setPlaybackState(next)) } },
                                                 setWorkspaceMode: { next in
                                                     guard s.state.workspaceMode != next else { return }
                                                     let p = s.state.workspaceMode; let pp = s.state.activeLayoutPreset
                                                     EditorRootViewFactory.saveDockLayout(controller, for: p, preset: pp)
                                                     s.dispatch(.setWorkspaceMode(next))
                                                     let np = s.state.activeLayoutPreset
                                                     EditorRootViewFactory.loadLayoutPreset(into: controller, for: next, preset: np)
                                                     EditorRootViewFactory.saveShellState(mode: next, preset: np, themeMode: s.state.themeMode, language: s.state.language, vsyncMode: s.state.vsyncMode)
                                                 },
                                                 resetLayout: {
                                                     let m = s.state.workspaceMode; let p = s.state.activeLayoutPreset
                                                     EditorRootViewFactory.resetLayout(into: controller, for: m, preset: p)
                                                     EditorRootViewFactory.saveDockLayout(controller, for: m, preset: p)
                                                     EditorRootViewFactory.saveShellState(mode: m, preset: p, themeMode: s.state.themeMode, language: s.state.language, vsyncMode: s.state.vsyncMode)
                                                 },
                                                 openSettings: { app.openSettingsWindow() })
        }
    }
}
