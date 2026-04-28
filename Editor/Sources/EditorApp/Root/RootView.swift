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
        StoreScope(app.store, select: { state in
            RootStateKey(connected: state.connected,
                         sceneRevision: state.sceneRevision,
                         selectedCount: state.selectedEntityIDs.count,
                         aiStatusMessage: state.aiStatusMessage,
                         playbackState: state.playbackState,
                         workspaceMode: state.workspaceMode,
                         activeLayoutPreset: state.activeLayoutPreset,
                         themeMode: state.themeMode)
        }) { store in
            Box(direction: .column, alignItems: .stretch, spacing: 0) {
                ShortcutHost(onKeyDown: { key in
                    EditorShortcutHandler.handle(key,
                                                 playbackState: store.state.playbackState,
                                                 setPlaybackState: { next in if store.state.playbackState != next { store.dispatch(.setPlaybackState(next)) } },
                                                 setWorkspaceMode: { next in
                                                     guard store.state.workspaceMode != next else { return }
                                                     let p = store.state.workspaceMode; let pp = store.state.activeLayoutPreset
                                                     EditorRootViewFactory.saveDockLayout(controller, for: p, preset: pp)
                                                     store.dispatch(.setWorkspaceMode(next))
                                                     let np = store.state.activeLayoutPreset
                                                     EditorRootViewFactory.loadLayoutPreset(into: controller, for: next, preset: np)
                                                     EditorRootViewFactory.saveShellState(mode: next, preset: np, themeMode: store.state.themeMode, language: store.state.language, vsyncMode: store.state.vsyncMode)
                                                 },
                                                 resetLayout: {
                                                     let m = store.state.workspaceMode; let p = store.state.activeLayoutPreset
                                                     EditorRootViewFactory.resetLayout(into: controller, for: m, preset: p)
                                                     EditorRootViewFactory.saveDockLayout(controller, for: m, preset: p)
                                                     EditorRootViewFactory.saveShellState(mode: m, preset: p, themeMode: store.state.themeMode, language: store.state.language, vsyncMode: store.state.vsyncMode)
                                                 },
                                                 openSettings: { app.openSettingsWindow() })
                })

                EditorMainToolbar(playbackState: store.state.playbackState,
                                  workspaceMode: store.state.workspaceMode,
                                  activeLayoutPreset: store.state.activeLayoutPreset,
                                  onSetPlaybackState: { next in
                                      let s = app.store; if s.state.playbackState != next { s.dispatch(.setPlaybackState(next)) }
                                  },
                                  onSetWorkspaceMode: { next in
                                      let s = app.store
                                      guard s.state.workspaceMode != next else { return }
                                      let p = s.state.workspaceMode; let pp = s.state.activeLayoutPreset
                                      EditorRootViewFactory.saveDockLayout(controller, for: p, preset: pp)
                                      s.dispatch(.setWorkspaceMode(next))
                                      let np = s.state.activeLayoutPreset
                                      EditorRootViewFactory.loadLayoutPreset(into: controller, for: next, preset: np)
                                      EditorRootViewFactory.saveShellState(mode: next, preset: np, themeMode: s.state.themeMode, language: s.state.language, vsyncMode: s.state.vsyncMode)
                                  },
                                  onSetLayoutPreset: { nextPreset in
                                      let s = app.store
                                      guard nextPreset != s.state.activeLayoutPreset else { return }
                                      let m = s.state.workspaceMode; let pp = s.state.activeLayoutPreset
                                      EditorRootViewFactory.saveDockLayout(controller, for: m, preset: pp)
                                      s.dispatch(.setActiveLayoutPreset(nextPreset))
                                      EditorRootViewFactory.loadLayoutPreset(into: controller, for: m, preset: nextPreset)
                                      EditorRootViewFactory.saveShellState(mode: m, preset: nextPreset, themeMode: s.state.themeMode, language: s.state.language, vsyncMode: s.state.vsyncMode)
                                  },
                                  onResetLayout: {
                                      let s = app.store
                                      let m = s.state.workspaceMode; let p = s.state.activeLayoutPreset
                                      EditorRootViewFactory.resetLayout(into: controller, for: m, preset: p)
                                      EditorRootViewFactory.saveDockLayout(controller, for: m, preset: p)
                                      EditorRootViewFactory.saveShellState(mode: m, preset: p, themeMode: s.state.themeMode, language: s.state.language, vsyncMode: s.state.vsyncMode)
                                  },
                                  onOpenSettings: { app.openSettingsWindow() })
                Divider()

                PanelWorkspace(controller: controller,
                               registry: registry,
                               semantics: .ide)
                    .flex()

                Divider()
                let timing = app.currentFrameTiming()
                EditorStatusBar(isConnected: store.state.connected,
                                sceneRevision: store.state.sceneRevision,
                                selectedCount: store.state.selectedEntityIDs.count,
                                aiStatusMessage: store.state.aiStatusMessage,
                                fps: timing.framesPerSecond,
                                frameMs: timing.frameMilliseconds)
            }
            .appearance(store.state.themeMode == .dark ? .dark : .light)
            .background(.background)
            .flex()
        }
    }
}

private struct RootStateKey: Hashable {
    let connected: Bool
    let sceneRevision: UInt64
    let selectedCount: Int
    let aiStatusMessage: String?
    let playbackState: PlaybackState
    let workspaceMode: EditorWorkspaceMode
    let activeLayoutPreset: EditorLayoutPreset
    let themeMode: EditorThemeMode
}
