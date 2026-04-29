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

                    EditorMenuBar(workspaceMode: store.workspaceMode,
                                  activeLayoutPreset: store.activeLayoutPreset,
                                  onCommand: cb.handleMenuCommand)
                    Divider()

                    EditorMainToolbar(playbackState: store.playbackState,
                                      workspaceMode: store.workspaceMode,
                                      activeLayoutPreset: store.activeLayoutPreset,
                                      onNewScene: cb.newScene,
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
    let newScene: () -> Void
    let handleMenuCommand: (EditorMenuCommand) -> Void
    let handleShortcut: (KeyEvent) -> Bool

    init(app: EditorApplication, controller: DockController) {
        self.newScene = { app.resetPreviewScene() }
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
        self.handleMenuCommand = { command in
            let s = app.store
            switch command {
            case .newScene:
                app.resetPreviewScene()
            case .openScene:
                app.logConsole("Open Scene is not connected to a file picker yet", severity: .warning)
            case .saveScene:
                app.logConsole("Save Scene is not connected to scene serialization yet", severity: .warning)
            case .importAssets:
                app.logConsole("Import Assets scans the project folder on launch", severity: .info)
            case .undo:
                app.logConsole("Undo is not available for this command path yet", severity: .warning)
            case .redo:
                app.logConsole("Redo is not available for this command path yet", severity: .warning)
            case let .setWorkspaceMode(next):
                guard s.state.workspaceMode != next else { return }
                let previousMode = s.state.workspaceMode
                let previousPreset = s.state.activeLayoutPreset
                EditorRootViewFactory.saveDockLayout(controller, for: previousMode, preset: previousPreset)
                s.dispatch(.setWorkspaceMode(next))
                let nextPreset = s.state.activeLayoutPreset
                EditorRootViewFactory.loadLayoutPreset(into: controller, for: next, preset: nextPreset)
                EditorRootViewFactory.saveShellState(mode: next,
                                                     preset: nextPreset,
                                                     themeMode: s.state.themeMode,
                                                     language: s.state.language,
                                                     vsyncMode: s.state.vsyncMode)
            case let .setLayoutPreset(nextPreset):
                guard nextPreset != s.state.activeLayoutPreset else { return }
                let mode = s.state.workspaceMode
                let previousPreset = s.state.activeLayoutPreset
                EditorRootViewFactory.saveDockLayout(controller, for: mode, preset: previousPreset)
                s.dispatch(.setActiveLayoutPreset(nextPreset))
                EditorRootViewFactory.loadLayoutPreset(into: controller, for: mode, preset: nextPreset)
                EditorRootViewFactory.saveShellState(mode: mode,
                                                     preset: nextPreset,
                                                     themeMode: s.state.themeMode,
                                                     language: s.state.language,
                                                     vsyncMode: s.state.vsyncMode)
            case .resetLayout:
                let mode = s.state.workspaceMode
                let preset = s.state.activeLayoutPreset
                EditorRootViewFactory.resetLayout(into: controller, for: mode, preset: preset)
                EditorRootViewFactory.saveDockLayout(controller, for: mode, preset: preset)
                EditorRootViewFactory.saveShellState(mode: mode,
                                                     preset: preset,
                                                     themeMode: s.state.themeMode,
                                                     language: s.state.language,
                                                     vsyncMode: s.state.vsyncMode)
            case let .setPlaybackState(next):
                if s.state.playbackState != next {
                    s.dispatch(.setPlaybackState(next))
                }
            case .openSettings:
                app.openSettingsWindow()
            case .toggleTheme:
                s.dispatch(.setThemeMode(s.state.themeMode == .dark ? .light : .dark))
            case .buildProject:
                app.logConsole("Build Editor command recorded", detail: "Use swift build in Editor until build jobs are wired")
            case .buildAndRun:
                app.logConsole("Build and Run command recorded", detail: "Use swift run EditorApp until build jobs are wired")
            case .openDocumentation:
                app.logConsole("Documentation command recorded", detail: "Docs live under docs/")
            case .about:
                app.logConsole("GuavaNext Editor", detail: "Swift native editor shell")
            }
        }
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
                                                 newScene: { app.resetPreviewScene() },
                                                 openSettings: { app.openSettingsWindow() })
        }
    }
}
