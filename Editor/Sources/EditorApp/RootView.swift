import EditorCore
import EngineKernel
import GuavaUIApp
import GuavaUICompose
import GuavaUIRuntime
import Foundation

/// 编辑器根视图。装配 `DockController` + `PanelRegistry` + 一个三列 `PanelWorkspace`。
struct EditorRootView: View {
    let app: EditorApplication
    let controller: DockController
    let registry: PanelRegistry

    var body: some View {
        StoreScope(app.store) { store in
            let _: Void = {
                EditorLocalizationPreferences.language = store.state.language
                EditorRootViewFactory.localizeDockTitles(in: controller)
            }()
            let setPlaybackState: (PlaybackState) -> Void = { next in
                if store.state.playbackState != next {
                    store.dispatch(.setPlaybackState(next))
                }
            }

            let setWorkspaceMode: (EditorWorkspaceMode) -> Void = { next in
                guard store.state.workspaceMode != next else { return }
                let previous = store.state.workspaceMode
                let previousPreset = store.state.activeLayoutPreset
                EditorRootViewFactory.saveDockLayout(controller,
                                                     for: previous,
                                                     preset: previousPreset)
                store.dispatch(.setWorkspaceMode(next))
                let nextPreset = store.state.activeLayoutPreset
                EditorRootViewFactory.loadLayoutPreset(into: controller,
                                                      for: next,
                                                      preset: nextPreset)
                EditorRootViewFactory.saveShellState(mode: next,
                                                     preset: nextPreset,
                                                     themeMode: store.state.themeMode,
                                                     language: store.state.language,
                                                     vsyncMode: store.state.vsyncMode)
            }

            let setLayoutPreset: (EditorLayoutPreset) -> Void = { nextPreset in
                guard nextPreset != store.state.activeLayoutPreset else { return }
                let mode = store.state.workspaceMode
                let previousPreset = store.state.activeLayoutPreset
                EditorRootViewFactory.saveDockLayout(controller,
                                                     for: mode,
                                                     preset: previousPreset)
                store.dispatch(.setActiveLayoutPreset(nextPreset))
                EditorRootViewFactory.loadLayoutPreset(into: controller,
                                                      for: mode,
                                                      preset: nextPreset)
                EditorRootViewFactory.saveShellState(mode: mode,
                                                     preset: nextPreset,
                                                     themeMode: store.state.themeMode,
                                                     language: store.state.language,
                                                     vsyncMode: store.state.vsyncMode)
            }

            let resetLayout: () -> Void = {
                let mode = store.state.workspaceMode
                let preset = store.state.activeLayoutPreset
                EditorRootViewFactory.resetLayout(into: controller,
                                                  for: mode,
                                                  preset: preset)
                EditorRootViewFactory.saveDockLayout(controller,
                                                     for: mode,
                                                     preset: preset)
                EditorRootViewFactory.saveShellState(mode: mode,
                                                     preset: preset,
                                                     themeMode: store.state.themeMode,
                                                     language: store.state.language,
                                                     vsyncMode: store.state.vsyncMode)
            }

            let handleShortcut: (KeyEvent) -> Bool = { key in
                EditorShortcutHandler.handle(key,
                                             playbackState: store.state.playbackState,
                                             setPlaybackState: setPlaybackState,
                                             setWorkspaceMode: setWorkspaceMode,
                                             resetLayout: resetLayout,
                                             openSettings: {
                                                 app.openSettingsWindow()
                                             })
            }

            Box(direction: .column, alignItems: .stretch, spacing: 0) {
                ShortcutHost(onKeyDown: handleShortcut)

                EditorMainToolbar(playbackState: store.state.playbackState,
                                  workspaceMode: store.state.workspaceMode,
                                  activeLayoutPreset: store.state.activeLayoutPreset,
                                  onSetPlaybackState: setPlaybackState,
                                  onSetWorkspaceMode: setWorkspaceMode,
                                  onSetLayoutPreset: setLayoutPreset,
                                  onResetLayout: resetLayout,
                                  onOpenSettings: {
                                      app.openSettingsWindow()
                                  })
                Divider()

                PanelWorkspace(controller: controller,
                               registry: registry,
                               semantics: .ide)
                    .flex()

                Divider()
                EditorStatusBar(isConnected: store.state.connected,
                                sceneRevision: store.state.sceneRevision,
                                selectedCount: store.state.selectedEntityIDs.count,
                                aiStatusMessage: store.state.aiStatusMessage)
            }
            .appearance(store.state.themeMode == .dark ? .dark : .light)
            .background(.background)
            .flex()
        }
    }

}